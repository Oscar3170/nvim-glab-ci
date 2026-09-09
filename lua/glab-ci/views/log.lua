-- Job log view (`glab-ci-log`).
--
-- Phase 4. Renders the streamed log of a single job in the layout window.
-- The buffer is created once and reused across all jobs (any active
-- `glab ci trace` stream is killed when switching jobs). ANSI SGR escapes
-- in the output are translated to extmark highlights via the
-- `glab-ci.ansi` module; everything else (CR, LF, OSC, unknown CSI,
-- section markers) is consumed there so the buffer only ever contains
-- printable lines.
--
-- Log-prefix display (Phase 4.5). Each printable line usually starts with a
-- GitLab machine prefix `2026-08-19T19:47:08.434178Z 00O <message>` (or
-- `00O+<message>` inside collapsible sections) — a UTC timestamp, a two-
-- digit stream + O/E type, and an optional `+` border (see
-- `glab-ci.logfmt`). Lines are stored as structured records so the
-- prefix can be re-rendered on demand. Independent toggles: `t` cycles the
-- time precision (µs→ms→s), `d` hides/shows the date, `o` hides/shows the
-- whole timestamp, `T` toggles system timezone (on by default) vs UTC, and
-- `i` hides/shows the stream indicator. Highlights: the whole `NNx[+]`
-- indicator token is dark blue (O) or red (E), and `00` (job-control)
-- content is light grey. Records also carry their ANSI marks re-based onto
-- the content, so re-rendering keeps the job's own colors.
--
-- Sections & noise (Phase 4.6). `section_start`/`section_end` markers are
-- hidden and instead become manual fold regions: the content between a
-- matched start/end collapses (default) into a fold whose `foldtext` shows
-- the section title — toggle with the standard `zs`/`zo`/`za`/`zR` keys.
-- The glab CLI wrapper header (blank line, "Getting job trace...",
-- "Showing logs for … job #N.") is dropped so the buffer starts at the
-- trace.
--
-- Streaming happens via `vim.system` with a `stdout` handler (`glab.ci_trace`
-- wraps it in `vim.schedule_wrap`); chunks are parsed incrementally so very
-- long logs don't block. Follow mode (toggle with `f`) snaps the cursor to
-- the last line after each chunk if the cursor was on the last line
-- beforehand — standard `tail -f` behavior. A generation counter discards
-- stale callbacks from a killed prior stream.
--
-- State machine (PLAN §10):
--   open(new_job, refresh_cb)
--     -> kill any in-flight stream, reset buffer + parser state, decide
--        follow based on status (on for running/pending, off otherwise),
--        start `glab ci trace`. `refresh_cb` is the pipeline view's
--        refresh — passed in from views/pipeline.lua to break the log <->
--        pipeline require cycle (review 7).
--   stream exit (job finished naturally)
--     -> follow -> off, re-fetch the job via one-shot `glab ci get` so
--        the log header shows the finished status (review 4.4), and kick
--        off a pipeline refresh so the pipeline view surfaces the new
--        state.
--   `r` re-fetch
--     -> kill, reset, restart stream (preserves current follow setting).
--   `f` toggle follow
--     -> flip the flag, snap to bottom if newly enabled.
--   `<Esc>` / `q` back-to-pipeline
--     -> kill in-flight trace (PLAN §10: 'r and going back both call
--        state.log_job:kill(15) first'), swap pipeline buffer back into
--        the layout window, restart pipeline timer, refresh pipeline view.
local M = {}

local state = require 'glab-ci.state'
local glab = require 'glab-ci.glab'
local ansi = require 'glab-ci.ansi'
local util = require 'glab-ci.util'
local logfmt = require 'glab-ci.logfmt'

local ns = vim.api.nvim_create_namespace 'glab_ci_log'

-- Structured records for every content line currently in the log buffer,
-- used to re-render when the user toggles a display preference (`t` / `T` /
-- `i`). Each entry is `{ ts, stream, typ, border, content, marks }` where
-- `marks` are ANSI extmark byte-ranges *relative to the content* (the record
-- keeps the prefix factored out so re-rendering can rebuild the prefix at
-- the new width). The header lines are not stored here — they're rebuilt on
-- demand.
local log_lines = {}

-- Fold bookkeeping for the `00` job-control sections, based on the hidden
-- `section_start`/`section_end` markers. `folds` mirrors the completed
-- section ranges in *record-index* space (`{ start_rec, end_rec, name }`);
-- manual buffer folds are created from these with `apply_folds` and
-- re-created after `rerender` (which rewrites the whole buffer and so clears
-- manual folds). `open_sections` is the LIFO stack of sections still
-- streaming. `fold_names[buf]` maps a fold's start line to its title for
-- the `foldtext` expression.
local folds = {}
local open_sections = {}
local fold_names = {}

-- Number of leading header lines in the log buffer. The header is always
-- the 3 context lines + divider, so the first content record renders at
-- 1-indexed buffer line `HEADER_LINES + rec_idx`.
local HEADER_LINES = 4

-- Pipeline refresh callback, passed in from views/pipeline.lua's `<CR>`
-- keymap (`open(job, refresh_cb)`). Used to (a) restart the
-- pipeline timer + refresh when the user goes back to the pipeline view
-- and (b) refresh the pipeline when a stream exits. A passed-in callback
-- replaces the old `pcall(require, ...)` cycle-breaker: pipeline.lua
-- requires log.lua for `<CR>`, so log.lua requiring pipeline.lua back
-- would recurse while that module is still loading.
local pipeline_refresh

-- Set true by the `r` (re-fetch) keymap while its "Re-fetching job log…"
-- notify is showing; cleared (and the message retracted) on the first
-- streamed chunk or on stream exit, whichever comes first.
local dismiss_refetch = false

-- True while the transient "Getting job trace…" placeholder line is shown
-- in the log buffer. It's pre-seeded on `start_trace` and removed on the
-- first real log line (or on stream exit if the job produced no output).
local placeholder_present = false

-- Forward declaration: `ensure_buf`'s `r` keymap references `start_trace`
-- in a closure created before the function's definition text. Declaring
-- the local here (it is assigned at module load, below) keeps the closure
-- bound to this upvalue instead of falling back to a global — same gotcha
-- as `job_under_cursor` in views/pipeline.lua. There, the local was
-- hoisted above the keymaps; here a forward declaration is equally safe
-- because the assignment runs before `ensure_buf` is ever called.
local start_trace

-- Resolve the *current* timestamp/stream display config from the user's
-- orthogonal `state.log_ts` preferences.
local PREC_CYCLE = { 'us', 'ms', 's' }
local function current_cfg()
  return {
    show = state.log_ts.show_ts,
    date = state.log_ts.show_date,
    prec = state.log_ts.prec,
    local_tz = state.log_ts.local_tz,
    show_stream = state.log_ts.show_stream,
  }
end

-- Short tag for the current timestamp config, shown in the header so the
-- user can see at a glance what `t` / `d` / `o` / `T` currently select.
local function ts_label()
  local ts = state.log_ts
  if not ts.show_ts then
    return 'off'
  end
  return ts.prec .. (ts.show_date and '' or '-t') .. (ts.local_tz and '' or '|utc')
end

-- Format an ISO 8601 timestamp as `YYYY-MM-DD HH:MM:SS` in *local* time.
-- The local components alone are usually enough to identify when
-- something ran. Returns the input unchanged if it doesn't match the
-- expected shape so a malformed timestamp still appears in the header.
local function friendly_time(iso)
  -- Defensive: never index a non-string (e.g. vim.NIL from JSON null
  -- would crash `iso:match` with E5108). The decode boundary in
  -- `glab.ci_get`/`ci_list` already normalizes vim.NIL to nil, but
  -- callers may pass values from other sources.
  if type(iso) ~= 'string' then
    return nil
  end
  local t = util.parse_iso(iso)
  if not t then
    return iso
  end
  return string.format('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- Header lines for the log buffer. Three rows + a divider:
--   1. ● <name> @ <stage>   job#<id>   pipeline#<iid> (ref <ref>, commit <sha8>)
--   2. status: <status>  •  duration: <duration>  •  follow:<on|off>
--   3. started: <iso>  •  finished: <iso>  (omitted when unknown)
--
-- The divider matches the pipeline view's style. `job.follow_on` reflects
-- `state.log_follow` so the user can see at a glance whether tail-f
-- is active. All callers build `job` via `job_context(follow_on)`, which
-- carries the flag as a field — there is no separate second argument
-- (it used to read a `follow_on` parameter that was never passed, so the
-- header always showed `follow:off`).
local function header_lines(job)
  -- Coerce header fields at the boundary: the job object originates from
  -- the decoded `jobs` array, and a wrongly-shaped value (table/boolean)
  -- would make `string.format` raise (review 6).
  local name = type(job.name) == 'string' and job.name ~= '' and job.name or ('job ' .. tostring(job.id or '?'))
  local stage = type(job.stage) == 'string' and job.stage or '?'
  local id = tostring(job.id or '?')
  local ref = type(job.pipeline_ref) == 'string' and job.pipeline_ref or '?'
  local iid = tostring(job.pipeline_iid or job.pipeline_id or '?')
  local sha = type(job.pipeline_sha) == 'string' and job.pipeline_sha or '?'
  local status = type(job.status) == 'string' and job.status or '?'
  local follow = job.follow_on and 'on' or 'off'

  local duration_str
  if type(job.duration) == 'number' and job.duration > 0 then
    duration_str = util.fmt_duration(job.duration, status, job.started_at)
  elseif job.started_at and not job.finished_at then
    duration_str = 'running'
  else
    duration_str = '—'
  end
  local started_str = job.started_at and friendly_time(job.started_at) or '—'
  local finished_str = job.finished_at and friendly_time(job.finished_at) or '—'

  local line1 = string.format('● %s @ %s   job#%s   pipeline#%s (ref %s, commit %s)', name, stage, id, iid, ref, sha)
  local line2 = string.format('  status: %s  •  duration: %s  •  follow:%s  •  ts:%s', status, duration_str, follow, ts_label())
  local line3 = string.format('  started: %s  •  finished: %s', started_str, finished_str)
  return {
    line1,
    line2,
    line3,
    util.DIVIDER,
  }
end

-- Replace the entire contents of the log buffer with `lines` and clear
-- all extmarks. Toggles modifiable briefly; the buffer is normally
-- `modifiable = false` so the user can't accidentally edit it.
local function reset_buf(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- Replace just the header lines (the first `n` lines) with `new_lines`,
-- leaving log content untouched. Used to update the `follow:on/off` token
-- when the user toggles follow or when the stream exits.
local function replace_header(buf, new_lines)
  if #new_lines == 0 then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, #new_lines, false, new_lines)
  vim.bo[buf].modifiable = false
end

-- Build the job-context object the header line wants. Pulled together
-- here so callers don't have to memorize which fields live on `state.*`
-- vs which come from the `<CR>` argument.
local function job_context(follow_on)
  return {
    id = state.job_id,
    name = state._job_name,
    stage = state._job_stage,
    status = state.log_status,
    duration = state._job_duration,
    started_at = state._job_started_at,
    finished_at = state._job_finished_at,
    pipeline_id = state._pipeline_id,
    pipeline_ref = state._pipeline_ref,
    pipeline_iid = state._pipeline_iid,
    pipeline_sha = state._pipeline_sha,
    follow_on = follow_on,
  }
end

-- Render one structured log record into (prefix + content) text plus the
-- per-record extmark byte-ranges (0-indexed, relative to this line).
-- Highlights: the whole stream indicator token (`NNx`, plus a `+` border
-- char when present) is colored dark blue for stdout (O) / red for stderr
-- (E); a `00` (job-control) content is light grey, with any ANSI marks
-- from the job overlapping it. The separator space is dropped when a `+`
-- border is present (GitLab emits those lines as `00O+content`).
local function render_record(rec, cfg)
  local parts = {}
  local marks = {}
  local col = 0

  local ts_str = logfmt.fmt_timestamp(rec.ts, cfg)
  if ts_str then
    parts[#parts + 1] = ts_str
    col = col + #ts_str
    parts[#parts + 1] = ' '
    col = col + 1
  end

  if cfg.show_stream and rec.stream then
    local blen = rec.border and #rec.border or 0
    local ind0 = col
    parts[#parts + 1] = rec.stream
    parts[#parts + 1] = rec.typ
    if rec.border then
      parts[#parts + 1] = rec.border
    end
    col = col + #rec.stream + #rec.typ + blen
    marks[#marks + 1] = { s = ind0, e = col, hl = (rec.typ == 'O') and 'GlabLogO' or 'GlabLogE' }
    if not rec.border then
      parts[#parts + 1] = ' '
      col = col + 1
    end
  end

  local prefix_len = col
  parts[#parts + 1] = rec.content
  local clen = #rec.content
  -- Content coloring, in priority order:
  --   `00O+` section lines (border `+`) -> teal
  --   `00` job-control log -> light grey
  --   `01O` command echoes (`$ …`) -> green
  -- otherwise it inherits the buffer's Normal fg (overlaid by ANSI marks).
  if rec.border == '+' then
    marks[#marks + 1] = { s = prefix_len, e = prefix_len + clen, hl = 'GlabLogSection' }
  elseif rec.stream == '00' then
    marks[#marks + 1] = { s = prefix_len, e = prefix_len + clen, hl = 'GlabLogControl' }
  elseif rec.stream == '01' and rec.typ == 'O' and rec.content:match '^%$ ' then
    marks[#marks + 1] = { s = prefix_len, e = prefix_len + clen, hl = 'GlabLogCmd' }
  end
  for _, m in ipairs(rec.marks or {}) do
    marks[#marks + 1] = { s = prefix_len + m.s, e = prefix_len + m.e, hl = m.hl }
  end
  return table.concat(parts), marks
end

-- Convert one ANSI-parsed chunk (`parsed.lines` + `parsed.extmarks`) into
-- structured records, stash them in `log_lines` for later re-rendering, and
-- return the *currently configured* rendered lines + line-relative marks
-- plus any folds that closed within this chunk.
--
-- The ANSI parser produced marks relative to the full raw line (including
-- the machine prefix), so each is re-based onto the content by subtracting
-- that line's consumed prefix length; marks fully inside the prefix are
-- dropped and any straddling span is clamped to the content start.
--
-- Besides the usual log content, this pass also consumes two noise sources
-- so they never reach the buffer:
--   * `section_start`/`section_end` markers are recorded as folds (not
--     displayed); the content between a matched start/end becomes a manual
--     fold region.
--   * the glab CLI wrapper header (blank, "Getting job trace...",
--     "Showing logs for … job #N.") is dropped.
local function record_chunk(parsed)
  -- Pass 1: parse + classify each line into an item, tracking sections.
  local items = {}
  local rec_idx = #log_lines + 1 -- next absolute record index to assign
  for i, line in ipairs(parsed.lines) do
    local rec, prefix = logfmt.parse_line(line)
    if not rec then
      rec, prefix = { ts = nil, stream = nil, typ = nil, border = nil, content = line, marks = {} }, 0
    end
    rec.marks = rec.marks or {}
    local item = { rec = rec, prefix = prefix, display = false, fold = nil }
    -- Detect section markers (Lua patterns have no `|` alternation, so
    -- match the two prefixes separately).
    local kind, sname
    if rec.content:match '^section_start:' then
      kind, sname = 'start', rec.content:match '^section_start:[^:]*:(.*)$'
    elseif rec.content:match '^section_end:' then
      kind, sname = 'end', rec.content:match '^section_end:[^:]*:(.*)$'
    end
    if kind == 'start' then
      -- The section's first content record is the next displayed line.
      open_sections[#open_sections + 1] = { name = sname, start_rec = rec_idx }
    elseif kind == 'end' then
      -- Close the innermost open section; its content spans the display
      -- records since its start up to now. Neovim manual folds nest, so a
      -- fold is created for *every* closed section even when nested inside
      -- an enclosing one — closing the inner hides its own range, closing
      -- the outer hides everything within it.
      local sec = table.remove(open_sections)
      if sec and sec.start_rec <= rec_idx - 1 then
        folds[#folds + 1] = { start_rec = sec.start_rec, end_rec = rec_idx - 1, name = sec.name }
        item.fold = folds[#folds]
      end
    elseif rec.stream == nil and (rec.content == '' or rec.content == 'Getting job trace...' or rec.content:match '^Showing logs for .* job #[0-9]+%.?$') then
      -- glab wrapper noise; drop entirely.
    else
      item.display = true
      item.rec_idx = rec_idx
      rec_idx = rec_idx + 1
    end
    items[i] = item
  end

  -- Pass 2: re-base ANSI marks onto content for displayed items only.
  for _, m in ipairs(parsed.extmarks) do
    local item = items[m.lnum0 + 1]
    if item and item.display then
      local s = m.col_start - item.prefix
      local e = m.col_end - item.prefix
      if e > 0 then
        if s < 0 then
          s = 0
        end
        table.insert(item.rec.marks, { s = s, e = e, hl = m.hl })
      end
    end
  end

  -- Pass 3: render displayed items and stash their records.
  local cfg = current_cfg()
  local out_lines, out_marks, new_folds = {}, {}, {}
  for _, item in ipairs(items) do
    if item.display then
      local text, lmarks = render_record(item.rec, cfg)
      local line_idx = #out_lines
      out_lines[#out_lines + 1] = text
      for _, m in ipairs(lmarks) do
        out_marks[#out_marks + 1] = { lnum0 = line_idx, col_start = m.s, col_end = m.e, hl = m.hl }
      end
      log_lines[#log_lines + 1] = item.rec
    elseif item.fold then
      -- A section closed this chunk; hand it to the caller to fold after
      -- the buffer append.
      new_folds[#new_folds + 1] = item.fold
    end
  end
  return out_lines, out_marks, new_folds
end

-- Map a record index to its 1-indexed buffer line (after the fixed header).
local function content_line(rec_idx)
  return HEADER_LINES + rec_idx
end

-- Create manual folds for `list` (records `{ start_rec, end_rec, name }`)
-- and register their titles for `M.foldtext`. Must run after the relevant
-- lines exist in the buffer. Manual folds are flat, so nested/overlapping
-- ranges were already rejected by `record_chunk`.
local function apply_folds(buf, list)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local names = fold_names[buf] or {}
  fold_names[buf] = names
  for _, f in ipairs(list) do
    local s = content_line(f.start_rec)
    local e = content_line(f.end_rec)
    if s <= e then
      names[s] = { name = f.name, start_line = s, end_line = e }
      pcall(vim.cmd, string.format('%d,%dfold', s, e))
      -- `:fold` (like `zf`) creates manual folds *closed*, and a manually
      -- closed fold is not re-opened when 'foldlevel' rises — so simply
      -- setting 'foldlevel' high leaves them collapsed. Open each section
      -- explicitly so every fold is expanded by default.
      pcall(vim.cmd, string.format('%d,%dfoldopen!', s, e))
    end
  end
end

-- `foldtext` entry point, referenced by the buffer's `foldtext` option as
-- `v:lua.require('glab-ci.views.log').foldtext()`. Runs in the fold
-- sandbox (errors are swallowed), so it must stay side-effect-free and
-- return a string. Renders the section title for the collapsed fold at the
-- cursor.
function M.foldtext()
  local buf = vim.api.nvim_get_current_buf()
  local m = fold_names[buf]
  if not m then
    return ''
  end
  local info = m[vim.v.foldstart]
  if not info then
    return ''
  end
  local n = (info.end_line or 0) - (info.start_line or 0) + 1
  return '▸ ' .. (info.name or 'section') .. '  (' .. n .. ' lines)'
end

-- The transient "Getting job trace…" line sits alone right after the
-- fixed header (buffer line `HEADER_LINES + 1`), so removing it touches
-- neither the header nor any content records / folds.
local function remove_placeholder(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local idx = HEADER_LINES -- 0-based index of the first content line
  if vim.api.nvim_buf_line_count(buf) > idx then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, idx, idx + 1, false, {})
    vim.bo[buf].modifiable = false
  end
end

-- Rebuild the whole log buffer (header + every stored content line) from
-- `log_lines` using the current display preferences. Called when the user
-- toggles `t` / `T` / `i`. Follow mode is untouched; the cursor is left to
-- Neovim's clamping on a buffer rewrite.
local function rerender()
  local buf = state.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cfg = current_cfg()
  local lines = header_lines(job_context(state.log_follow))
  local marks = {}
  -- `lines` currently holds just the header (e.g. 4 lines at buffer lines
  -- 0..3), so the first content line sits right after it. `#lines` is thus
  -- the 0-based index of the first content record (NOT `#lines - 1`, which
  -- would point at the last header line / divider).
  local content_start = #lines
  for i, rec in ipairs(log_lines) do
    local text, lmarks = render_record(rec, cfg)
    lines[#lines + 1] = text
    local abs = content_start + (i - 1)
    for _, m in ipairs(lmarks) do
      marks[#marks + 1] = { lnum0 = abs, col_start = m.s, col_end = m.e, hl = m.hl }
    end
  end
  reset_buf(buf, lines)
  -- The full rewrite discards manual folds; re-create them from `folds`.
  fold_names[buf] = nil
  apply_folds(buf, folds)
  -- Restore the transient "Getting job trace…" placeholder if it's still
  -- showing (i.e. no content has streamed yet).
  if placeholder_present then
    vim.bo[buf].modifiable = true
    local n = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, n, n, false, { 'Getting job trace...' })
    vim.bo[buf].modifiable = false
  end
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.lnum0, m.col_start, {
      end_col = m.col_end,
      hl_group = m.hl,
      priority = 100,
    })
  end
end

-- Append ANSI-parsed lines + extmarks to the log buffer. `lines` come in
-- relative to their own chunks; `marks` use 0-indexed line numbers
-- relative to `lines[1]`, which we shift by the buffer's current line
-- count before applying.
local function append_lines(buf, lines, marks)
  if #lines == 0 then
    return
  end
  local current_count = vim.api.nvim_buf_line_count(buf)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, current_count, current_count, false, lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(marks) do
    -- `m.lnum0` is the relative offset within `lines`; absolute is
    -- `current_count + m.lnum0`. Neovim extmarks accept (lnum, col,
    -- opts).
    vim.api.nvim_buf_set_extmark(buf, ns, current_count + m.lnum0, m.col_start, {
      end_col = m.col_end,
      hl_group = m.hl,
      priority = 100,
    })
  end
end

-- Ensure the log buffer exists. Created once per layout bootstrap;
-- bootstrap; reused across all jobs. Keymaps and BufDelete cleanup are
-- attached at creation time and never re-applied.
local function ensure_buf()
  if state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf) then
    return state.log_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  -- `hide` (not `wipe`) so the buffer survives being swapped out for
  -- the pipeline buffer when the user goes back. The layout teardown
  -- in `init.bootstrap_layout` deletes this buffer explicitly.
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'glab-ci-log'
  vim.api.nvim_buf_set_name(buf, 'glab://ci-log')
  state.log_buf = buf

  -- Section folds: `foldmethod=manual` so `[range]fold` regions created
  -- from `section_start`/`section_end` collapse. Open by default (the user
  -- closes sections with `zc`/`za`), so the whole log is visible on load.
  -- The `foldtext` option renders each section's title via `M.foldtext`.
  local lwin = state.list_win
  if lwin and vim.api.nvim_win_is_valid(lwin) then
    vim.wo[lwin].foldmethod = 'manual'
    vim.wo[lwin].foldlevel = 99
    vim.wo[lwin].foldcolumn = '1'
    vim.wo[lwin].foldtext = "v:lua.require('glab-ci.views.log').foldtext()"
  end

  -- BufDelete: kill any in-flight stream. Full layout teardown (windows,
  -- pipeline buffer, this buffer) lives in `init.bootstrap_layout`.
  vim.api.nvim_create_autocmd('BufDelete', {
    buffer = buf,
    group = state.augroup,
    callback = function()
      state.kill_log_stream()
    end,
  })

  -- Native `/`, `y`, `G`, `gg` all work without explicit keymaps: the
  -- buffer is non-modifiable so it behaves like a read-only file for
  -- built-in operations, including `/` search (`vim.fn.search()`).
  -- (Plan §12 lists them as keys but no remapping is required.)

  -- `f` toggles follow mode (PLAN §7.3 / §12).
  vim.keymap.set('n', 'f', function()
    state.log_follow = not state.log_follow
    if state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf) then
      replace_header(state.log_buf, header_lines(job_context(state.log_follow)))
    end
    -- When newly enabling follow, snap to bottom so the user immediately
    -- sees the latest content.
    if state.log_follow and state.list_win and vim.api.nvim_win_is_valid(state.list_win) and state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf) then
      local total = vim.api.nvim_buf_line_count(state.log_buf)
      pcall(vim.api.nvim_win_set_cursor, state.list_win, { total, 0 })
    end
  end, { buffer = buf, desc = 'Toggle follow mode' })

  -- Display toggles. All re-render from the stored `log_lines` records and
  -- refresh the header (which shows the current config). `t` cycles the
  -- timestamp time precision (µs→ms→s), `d` hides/shows the date (showing
  -- only the time), `o` hides/shows the whole timestamp, `T` flips between
  -- system tz and UTC, and `i` hides/shows the stream indicator.
  vim.keymap.set('n', 't', function()
    local idx = 1
    for i, p in ipairs(PREC_CYCLE) do
      if p == state.log_ts.prec then
        idx = i
        break
      end
    end
    state.log_ts.prec = PREC_CYCLE[idx % #PREC_CYCLE + 1]
    rerender()
  end, { buffer = buf, desc = 'Cycle timestamp precision (us/ms/s)' })
  vim.keymap.set('n', 'd', function()
    state.log_ts.show_date = not state.log_ts.show_date
    rerender()
  end, { buffer = buf, desc = 'Toggle timestamp date (show only time)' })
  vim.keymap.set('n', 'o', function()
    state.log_ts.show_ts = not state.log_ts.show_ts
    rerender()
  end, { buffer = buf, desc = 'Toggle whole timestamp' })
  vim.keymap.set('n', 'T', function()
    state.log_ts.local_tz = not state.log_ts.local_tz
    rerender()
  end, { buffer = buf, desc = 'Toggle timestamp timezone (system/UTC)' })
  vim.keymap.set('n', 'i', function()
    state.log_ts.show_stream = not state.log_ts.show_stream
    rerender()
  end, { buffer = buf, desc = 'Toggle stream indicator' })

  -- `r` re-fetches: kill any in-flight stream, reset, restart. Current
  -- follow setting is preserved (the user can flip it with `f` if they
  -- want different behavior on the refetched stream).
  vim.keymap.set('n', 'r', function()
    if not state.job_id then
      return
    end
    vim.notify('Re-fetching job log…', vim.log.levels.INFO, { title = 'glab' })
    dismiss_refetch = true -- dismiss this notify on the first streamed chunk / exit
    start_trace()
  end, { buffer = buf, desc = 'Re-fetch log' })

  -- `<Esc>` / `q` swap the pipeline buffer back into the layout window and
  -- restart the pipeline timer. Per PLAN §10 ('r and "going back" both
  -- call state.log_job:kill(15) first'), the in-flight trace is also
  -- killed — the log buffer is about to be hidden, so letting it keep
  -- streaming would just churn extmarks the user can't see. Bumping the
  -- generation counter invalidates any in-flight libuv callbacks.
  local function back_to_pipeline()
    -- Kill the trace first so its callbacks (which might run after we've
    -- moved buffers around) are no-ops.
    state.kill_log_stream()
    M._generation = M._generation + 1

    if state.pipeline_buf and vim.api.nvim_buf_is_valid(state.pipeline_buf) and state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
      vim.api.nvim_win_set_buf(state.list_win, state.pipeline_buf)
      -- The pipeline timer was stopped when the log opened (§8); restart.
      local refresh = pipeline_refresh
      state.start_timer(state.pipeline_buf, 5000, function()
        if refresh then
          refresh()
        end
      end)
      if refresh then
        refresh()
      end
    end
  end
  vim.keymap.set('n', '<Esc>', back_to_pipeline, { buffer = buf, desc = 'Back to pipeline view' })
  vim.keymap.set('n', 'q', back_to_pipeline, { buffer = buf, desc = 'Back to pipeline view' })

  return buf
end

-- Generation counter: each `start_trace` increments it. Stale callbacks
-- from a killed previous stream (which may still fire from the libuv
-- queue) compare against `M._generation` and bail out.
M._generation = 0

-- Cancel any in-flight trace, reset parser state and buffer, kick off a
-- new `glab ci trace <job_id>` stream. Called both from `M.open`
-- (new job) and from the `r` keymap (re-fetch). (Assigned to the
-- forward-declared `start_trace` local — see the declaration above.)
start_trace = function()
  state.kill_log_stream()
  state.ansi_state = nil
  log_lines = {}
  folds = {}
  open_sections = {}
  placeholder_present = false
  if state.log_buf then
    fold_names[state.log_buf] = nil
  end
  M._generation = M._generation + 1
  local gen = M._generation

  if state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf) then
    reset_buf(state.log_buf, header_lines(job_context(state.log_follow)))
    -- Pre-seed a transient "Getting job trace…" placeholder so the user
    -- sees loading feedback until the first real log line arrives. It's
    -- removed as soon as the first content streams in (or on exit if the
    -- job produced no output).
    vim.bo[state.log_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.log_buf, vim.api.nvim_buf_line_count(state.log_buf), -1, false, { 'Getting job trace...' })
    vim.bo[state.log_buf].modifiable = false
    placeholder_present = true
  end

  state.log_job = glab.ci_trace(
    state.job_id,
    -- on_stdout_chunk(err, data) — already on the main loop because
    -- `glab.ci_trace` wraps the handler with `vim.schedule_wrap` (see
    -- glab.lua). We still keep the inner `vim.schedule` for symmetry /
    -- defensiveness against direct callers bypassing the wrapper.
    function(err, data)
      if err then
        return
      end
      if not data or data == '' then
        return
      end
      if gen ~= M._generation then
        return
      end
      -- The "Re-fetching job log…" notify is retracted once real data
      -- starts streaming in.
      if dismiss_refetch then
        dismiss_refetch = false
        util.clear_msg()
      end
      local parsed = ansi.parse(data, state.ansi_state)
      state.ansi_state = parsed.state
      if not state.log_buf or not vim.api.nvim_buf_is_valid(state.log_buf) then
        return
      end
      local out_lines, out_marks, new_folds = record_chunk(parsed)
      -- Once the first real log line arrives, drop the pre-seeded
      -- "Getting job trace…" placeholder so it doesn't linger above the
      -- content.
      if placeholder_present and #out_lines > 0 then
        remove_placeholder(state.log_buf)
        placeholder_present = false
      end
      -- Snap cursor to bottom: only when follow is enabled AND the
      -- cursor was on the last line before this chunk (PLAN §10).
      local win = state.list_win
      local was_on_last = false
      if win and vim.api.nvim_win_is_valid(win) then
        local before_count = vim.api.nvim_buf_line_count(state.log_buf)
        local cursor = vim.api.nvim_win_get_cursor(win)
        was_on_last = cursor[1] == before_count
      end
      append_lines(state.log_buf, out_lines, out_marks)
      -- A section may have closed in this chunk; fold its content now that
      -- the lines are in the buffer.
      apply_folds(state.log_buf, new_folds)
      if state.log_follow and was_on_last then
        local after_count = vim.api.nvim_buf_line_count(state.log_buf)
        pcall(vim.api.nvim_win_set_cursor, win, { after_count, 0 })
      end
    end,
    -- on_exit(obj): stream ended (either because the job finished, the
    -- user closed GlabCI, or a refetch killed us).
    function(obj)
      -- Only act if we're still the current generation. A new stream
      -- may have started in the meantime (e.g. quick `r` presses).
      if gen ~= M._generation then
        return
      end
      -- Retract any still-pending "Re-fetching job log…" notify (e.g. a
      -- job that produced no output).
      if dismiss_refetch then
        dismiss_refetch = false
        util.clear_msg()
      end
      state.log_job = nil
      -- §10: stream exit -> follow -> off.
      state.log_follow = false
      if state.log_buf and vim.api.nvim_buf_is_valid(state.log_buf) then
        -- If the job produced no real output, the "Getting job trace…"
        -- placeholder is still up — drop it so it doesn't linger.
        if placeholder_present then
          remove_placeholder(state.log_buf)
          placeholder_present = false
        end
        replace_header(state.log_buf, header_lines(job_context(false)))
      end
      -- Clean exit (job finished — code 0 and we didn't kill it; the
      -- generation check above already filters killed streams).
      if obj and obj.code == 0 then
        -- Refresh the pipeline view so the job status changes surface
        -- there (this was the plan's "one-shot glab ci get re-check").
        if pipeline_refresh then
          pipeline_refresh()
        end
        -- Re-check the job itself so the log header status is not stuck
        -- on the start-of-stream value (review 4.4): a job that finished
        -- while we watched kept showing `status: running` and no
        -- started/finished timestamps until now.
        if state.pipeline_id then
          glab.ci_get(state.pipeline_id, function(pipeline)
            if gen ~= M._generation then
              return
            end
            if not state.log_buf or not vim.api.nvim_buf_is_valid(state.log_buf) then
              return
            end
            local job
            if pipeline and pipeline.jobs then
              for _, j in ipairs(pipeline.jobs) do
                if j.id == state.job_id then
                  job = j
                  break
                end
              end
            end
            if job then
              state.log_status = job.status
              state._job_duration = job.duration
              state._job_started_at = job.started_at
              state._job_finished_at = job.finished_at
              replace_header(state.log_buf, header_lines(job_context(state.log_follow)))
            end
          end)
        end
      end
    end
  )
end

-- Public entry point: open the log of `job_id` in the layout window.
--
-- Args:
--   job          -- { id, name?, stage?, status?, duration?,
--                     started_at?, finished_at?,
--                     pipeline_id?, pipeline_ref?, pipeline_iid?,
--                     pipeline_sha? }
--   refresh_cb   -- pipeline-view refresh callback (see module header).
-- All fields except `id` are optional; they're used only to populate
-- the header. The trace itself keys on `id`.
function M.open(job, refresh_cb)
  if not job or not job.id then
    return
  end
  pipeline_refresh = refresh_cb
  state.job_id = job.id
  state._job_name = job.name
  state._job_stage = job.stage
  state._job_started_at = job.started_at
  state._job_finished_at = job.finished_at
  state._job_duration = job.duration
  state._pipeline_id = job.pipeline_id or state.pipeline_id
  state._pipeline_ref = job.pipeline_ref or state._pipeline_ref
  state._pipeline_iid = job.pipeline_iid or state._pipeline_iid
  state._pipeline_sha = job.pipeline_sha or state._pipeline_sha
  state.log_status = job.status or ''
  -- Initial follow: on for in-flight jobs (running / pending), off for
  -- finished jobs (success / failed / canceled / skipped / manual /
  -- created). PLAN §10.
  state.log_follow = (job.status == 'running' or job.status == 'pending')

  local buf = ensure_buf()

  -- Stop the pipeline timer (per PLAN §8: pipeline timer paused while
  -- the log is shown).
  if state.pipeline_buf and vim.api.nvim_buf_is_valid(state.pipeline_buf) then
    state.stop_timer(state.pipeline_buf)
  end

  -- Swap the log buffer into the layout window if it's not already
  -- there.
  if state.list_win and vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_buf(state.list_win) ~= buf then
    vim.api.nvim_win_set_buf(state.list_win, buf)
  end

  start_trace()
end

-- Public helper used by the layout teardown to stop any in-flight stream
-- synchronously. The log buffer itself is deleted by `init.bootstrap_layout`
-- via `state.delete_buf(state.log_buf)`.
function M.shutdown()
  state.kill_log_stream()
  M._generation = M._generation + 1 -- invalidate any pending callbacks
  folds = {}
  open_sections = {}
  fold_names = {}
end

return M
