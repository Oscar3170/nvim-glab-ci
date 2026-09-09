-- ANSI / SGR parser for GlabCI log buffers (Phase 4).
--
-- Converts raw bytes from `glab ci trace <job-id>` (a mix of printable text,
-- `\r` / `\n` and various ANSI escape sequences GitLab writes into its traces)
-- into a list of completed log lines plus per-line extmark ranges that
-- re-apply the original SGR colors / bold / underline in the buffer.
-- Parser state is preserved across calls so chunks can split at any byte
-- boundary, including inside an escape sequence.
--
-- Design (per PLAN-glab-nativization.md §9):
--   * CSI sequences (`\x1b[ params final-byte`): consumed; only SGR (final
--     `m`) affects highlights, every other CSI sequence (`K`, `G`, `J`,
--     `?25l`, `2J`, ...) is parsed and discarded.
--   * OSC sequences (`\x1b] ... terminator`): consumed and discarded. Termin-
--     ated by BEL (`\x07`) or ST (`\x1b\\`).
--   * Other 2-byte ESC sequences: consumed and discarded.
--   * `\r` without a following `\n` -> drop the current line (progress-bar
--     replacement; also erases GitLab's `section_start:<ts>:<name>\r\x1b[0K`
--     markers, which always appear right before `\r\x1b[0K`).
--   * `\r\n` -> treat as `\n` (a single line break).
--   * Chunks can split at any byte boundary inside an escape sequence:
--     incomplete sequences are buffered in `state` and completed by the
--     next chunk. (Multi-byte UTF-8 split across chunks is NOT reassembled
--     — `vim.system` with `text = true` decodes each chunk independently,
--     so a split codepoint arrives as U+FFFD per chunk. Rare and
--     cosmetic; the plan's §9 only promises escape-sequence splitting.)
--
-- Output extmarks use 0-indexed byte positions (matching how Neovim
-- extmarks work). `lnum0` in `extmarks` is 0-indexed *relative to
-- lines[1]* of the current parse call so the caller can convert to absolute
-- lines by adding the running line count.
local M = {}

-- Map SGR code -> hl group. Loaded lazily from `glab-ci.highlights.ANSI_HL`
-- so the mapping stays in one place. Falls back to a small inline table if
-- the module is unavailable (e.g. when this file is required directly by
-- tests).
local function sgr_table()
  local ok, hl = pcall(require, 'glab-ci.highlights')
  if ok and hl and hl.ANSI_HL then
    return hl.ANSI_HL
  end
  -- Fallback: same mapping duplicated. Kept in sync with highlights.lua.
  return {
    [0] = nil,
    [1] = 'GlabBold',
    [2] = 'GlabDim',
    [4] = 'GlabUnderline',
    [22] = nil,
    [24] = nil,
    [30] = 'GlabBlack',
    [31] = 'GlabRed',
    [32] = 'GlabGreen',
    [33] = 'GlabYellow',
    [34] = 'GlabBlue',
    [35] = 'GlabMagenta',
    [36] = 'GlabCyan',
    [37] = 'GlabWhite',
    [90] = 'GlabBrightBlack',
    [91] = 'GlabBrightRed',
    [92] = 'GlabBrightGreen',
    [93] = 'GlabBrightYellow',
    [94] = 'GlabBrightBlue',
    [95] = 'GlabBrightMagenta',
    [96] = 'GlabBrightCyan',
    [97] = 'GlabBrightWhite',
  }
end

-- State shape (created by M.new_state; mutated in place by M.parse):
--   mode         - nil | 'await' | 'csi' | 'osc' | 'osc_st'
--                  nil       = normal byte mode
--                  'await'   = just saw ESC (0x1b); waiting for next byte
--                  'csi'     = inside CSI, accumulating until final byte
--                  'osc'     = inside OSC, accumulating until BEL or ST
--                  'osc_st'  = saw ESC inside OSC; next byte should be '\\'
--   esc_buf      - bytes accumulated in the current escape (CSI dispatch)
--   line         - bytes accumulated for the in-progress line
--   pos          - byte length of `line` (next byte goes at this offset)
--   line_marks   - { { col_start, col_end, hl } } closed marks for `line`
--   marks_pos    - start column (in `line`) of the currently-open mark
--   cur_hl       - current SGR hl group; nil means "no SGR active"
--   cr_pending   - true if last byte was `\r` (waiting to see if it's CRLF)
local function new_state()
  return {
    mode = nil,
    esc_buf = '',
    line = '',
    pos = 0,
    line_marks = {},
    marks_pos = 0,
    cur_hl = nil,
    cr_pending = false,
  }
end
M.new_state = new_state

-- Map an SGR code to a hl group name. Returns nil for "no change" / "reset"
-- (SGR 0 / 22 / 24 -> reset; codes we don't recognize -> ignored).
local function sgr_to_hl(code)
  return sgr_table()[code]
end

-- Parse a chunk; returns { lines, extmarks, state }.
--
-- `state` may be nil on the first call (a fresh state is created). The caller
-- should pass back the returned `state` on subsequent calls.
function M.parse(chunk, prev_state)
  local s = prev_state or new_state()

  local output_lines = {}
  local output_marks = {}

  -- Close the currently-open mark (if any) at byte position `at_pos`. The
  -- mark spans [marks_pos, at_pos] with hl = cur_hl. Always resets cur_hl
  -- to nil so the next SGR opens a fresh span.
  local function emit_mark(at_pos)
    if s.cur_hl ~= nil then
      table.insert(s.line_marks, {
        col_start = s.marks_pos,
        col_end = at_pos,
        hl = s.cur_hl,
      })
      s.cur_hl = nil
    end
    s.marks_pos = at_pos
  end

  -- Commit the in-progress line and its marks to the output arrays, then
  -- reset all line-local state. Always emits the trailing mark first so a
  -- line that ends while an SGR is active closes that span.
  local function flush_line()
    emit_mark(s.pos)
    table.insert(output_lines, s.line)
    local line_idx = #output_lines - 1
    for _, m in ipairs(s.line_marks) do
      table.insert(output_marks, {
        lnum0 = line_idx,
        col_start = m.col_start,
        col_end = m.col_end,
        hl = m.hl,
      })
    end
    s.line = ''
    s.line_marks = {}
    s.pos = 0
    s.marks_pos = 0
    s.cur_hl = nil
  end

  -- Discard the in-progress line (CR semantics: progress-bar replacement).
  -- Marks are discarded along with the bytes they would have applied to.
  local function drop_line()
    s.line = ''
    s.line_marks = {}
    s.pos = 0
    s.marks_pos = 0
    s.cur_hl = nil
  end

  -- Process a complete CSI sequence `\x1b[<params><final-byte>`. Only SGR
  -- (final byte `m`) affects highlights; every other final byte (`K`, `G`,
  -- `J`, `H`, `?25l`, ...) is discarded.
  local function process_csi(seq)
    local final = seq:sub(-1)
    if final ~= 'm' then
      return
    end
    local params_str = seq:sub(3, -2) -- strip \x1b[ prefix and final `m`
    if params_str == '' then
      -- Empty SGR is equivalent to `SGR 0` (reset).
      emit_mark(s.pos)
      s.cur_hl = nil
      return
    end
    -- Multi-attribute SGR (e.g. `1;31` for bold + red) is layered by
    -- emitting one mark per attribute; for v1 we use a single hl group and
    -- let the last code win. Compound SGR is rare in glab traces.
    for code in params_str:gmatch '%d+' do
      local n = tonumber(code)
      emit_mark(s.pos)
      s.cur_hl = sgr_to_hl(n)
    end
  end

  local i = 1
  local len = #chunk
  local mode = s.mode

  while i <= len do
    local b = chunk:byte(i)

    if mode == 'csi' then
      -- CSI: any byte until final byte (0x40-0x7e). Anything else (parameter
      -- bytes in 0x30-0x3f and intermediate bytes in 0x20-0x2f) is part of
      -- the sequence.
      if b >= 0x40 and b <= 0x7e then
        s.esc_buf = s.esc_buf .. string.char(b)
        process_csi(s.esc_buf)
        s.esc_buf = ''
        mode = nil
      else
        s.esc_buf = s.esc_buf .. string.char(b)
      end
      i = i + 1
    elseif mode == 'osc' then
      if b == 0x07 then
        -- BEL terminator.
        mode = nil
        s.esc_buf = ''
      elseif b == 0x1b then
        -- Possibly start of ST (`\x1b\\`).
        mode = 'osc_st'
        s.esc_buf = ''
      else
        s.esc_buf = s.esc_buf .. string.char(b)
      end
      i = i + 1
    elseif mode == 'osc_st' then
      -- Previous byte was 0x1b inside OSC; this byte should be `\` if it's ST.
      -- We don't strictly verify (just trust well-formed OSC); out-of-sync
      -- recovery just resets and discards whatever we had buffered.
      mode = nil
      s.esc_buf = ''
      i = i + 1
    elseif mode == 'await' then
      -- Previous byte was ESC; this byte determines the escape flavor.
      if b == string.byte '[' then
        mode = 'csi'
        s.esc_buf = '\x1b['
      elseif b == string.byte ']' then
        mode = 'osc'
        s.esc_buf = '\x1b]'
      else
        -- 2-byte ESC sequence (e.g. `\x1bM`, `\x1bD`); consume this byte
        -- and discard both.
        mode = nil
        s.esc_buf = ''
      end
      i = i + 1
    else
      -- Normal byte mode.
      if b == 0x1b then
        -- About to start an escape; close any open mark first.
        emit_mark(s.pos)
        mode = 'await'
        s.esc_buf = '\x1b'
        i = i + 1
      elseif b == 0x07 then
        -- Stray BEL (no OSC context); discard.
        i = i + 1
      elseif b == 0x0d then
        -- CR alone is a "drop current line" signal (progress bar replace-
        -- ment), but CRLF is just a normal line break and must preserve
        -- the line content. Defer until the next byte tells us which it
        -- is: LF -> swallowed (CRLF = LF); anything else -> drop_line
        -- and re-process the byte.
        s.cr_pending = true
        i = i + 1
      elseif b == 0x0a then
        -- LF (with or without preceding CR): flush line.
        s.cr_pending = false
        flush_line()
        i = i + 1
      else
        if s.cr_pending then
          -- Non-LF byte after lone CR -> CR was not CRLF; apply now.
          s.cr_pending = false
          drop_line()
        end
        -- Append byte to in-progress line. Multi-byte UTF-8 accumulates
        -- byte-by-byte. A codepoint split across two chunks decodes as
        -- U+FFFD in the *earlier* chunk already (vim.system's `text = true`
        -- decodes each chunk independently), so the buffer may show a
        -- replacement char at a chunk boundary — rare, cosmetic, and out
        -- of scope (the plan's §9 only promises escape-sequence splitting,
        -- which IS handled — see module header).
        s.line = s.line .. string.char(b)
        s.pos = s.pos + 1
        i = i + 1
      end
    end
  end

  s.mode = mode

  return {
    lines = output_lines,
    extmarks = output_marks,
    state = s,
  }
end

return M
