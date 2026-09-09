-- Pipeline list view (`glab-ci-list`).
--
-- Phase 2: this module owns the list buffer's content, refresh, keymaps and
-- lifecycle. `init.lua` bootstraps the bottom-panel layout and hands the
-- list window + buffer to `M.open(buf, win)`. The list buffer is reused
-- across re-renders — `state.ids[buf]` is rebuilt every time so cursor-line
-- -> pipeline-id lookups always match the current contents. `<CR>` delegates
-- to `views/pipeline.open` which swaps the pipeline (jobs) buffer into the
-- *same* window, replacing the list — no side-by-side pane.
--
-- Phase 3 adds the branch filter: `state.branch` is passed to `ci_list` as
-- `-r <ref>`; `f` prompts for a ref via `vim.ui.input`, `c` clears it. The
-- header line shows the active filter (or `all`).
local M = {}

local state = require 'glab-ci.state'
local highlights = require 'glab-ci.highlights'
local glab = require 'glab-ci.glab'
local util = require 'glab-ci.util'
local pipeline_view = require 'glab-ci.views.pipeline'

local ns = vim.api.nvim_create_namespace 'glab_ci_list'

-- Format a relative-time string like glab's "(about 1 day ago)" from an ISO 8601
-- timestamp. Both times are interpreted as local so the *difference* is
-- correct regardless of timezone offsets in the input.
local function rel_time(iso)
  local t = util.parse_iso(iso)
  if not t then
    return ''
  end
  local then_epoch = os.time(t)
  local now_epoch = os.time(os.date '!*t')
  local diff = os.difftime(now_epoch, then_epoch)
  if diff < 0 then
    return 'in the future'
  end
  if diff < 60 then
    return 'less than a minute ago'
  end
  if diff < 3600 then
    return string.format('about %d minute%s ago', math.floor(diff / 60), diff < 120 and '' or 's')
  end
  if diff < 86400 then
    return string.format('about %d hour%s ago', math.floor(diff / 3600), diff < 7200 and '' or 's')
  end
  if diff < 2592000 then
    return string.format('about %d day%s ago', math.floor(diff / 86400), diff < 172800 and '' or 's')
  end
  return string.format('about %d month%s ago', math.floor(diff / 2592000), diff < 5184000 and '' or 's')
end

-- Render parsed pipelines into the list buffer with colored status tokens.
-- `pipelines` is an array of `{ id, iid, status, ref, created_at }`. When
-- the active branch filter (`state.branch`) has no matches, render a
-- friendlier placeholder than the bare "(no pipelines)".
local function render(buf, pipelines)
  local ref_str = state.branch and state.branch or 'all'
  local lines = {
    string.format(' glab ci list • ref: %s • 5s refresh • r: refresh • f: filter • c: clear • <CR>: open • q: close', ref_str),
    '',
  }
  local id_map = {}
  local marks = {} -- { lnum0, col_start, col_end, hl }

  if #pipelines == 0 then
    if state.branch then
      table.insert(lines, string.format(' (no pipelines for ref %s)', state.branch))
    else
      table.insert(lines, ' (no pipelines)')
    end
  end

  for _, p in ipairs(pipelines) do
    -- Defensive shape check (review 6): a payload that decodes to JSON
    -- but isn't shaped like a pipeline entry (missing/non-numeric id)
    -- must not crash the scheduled render callback — `string.format`
    -- raises on nil, which would surface as an ugly E5108-style error
    -- in the refresh callback. Skip entries we can't map to an id.
    if type(p.id) == 'number' then
      local lnum = #lines + 1
      id_map[lnum] = p.id
      -- Coerce optional fields: JSON values of the wrong type (tables,
      -- booleans) would raise inside `string.format` (review 6).
      local status = type(p.status) == 'string' and p.status or '?'
      local status_str = string.format('(%s)', status)
      local iid = type(p.iid) == 'number' and p.iid or nil
      local iid_str = iid and string.format('(#%d)', iid) or ''
      local ref = type(p.ref) == 'string' and p.ref or ''
      local line = string.format('%-10s • #%-7s %-7s %-20s %s', status_str, tostring(p.id), iid_str, ref, rel_time(p.created_at))
      table.insert(lines, line)
      local s = highlights.STATUSES[status] or highlights.STATUSES.created
      table.insert(marks, { lnum0 = lnum - 1, col_start = 0, col_end = #status_str, hl = s.hl })
    end
  end

  state.ids[buf] = id_map

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m.lnum0, m.col_start, {
      end_col = m.col_end,
      hl_group = m.hl,
      priority = 100,
    })
  end

  -- On entry the cursor sits on the header (line 1); land it on the first
  -- listed pipeline so <CR> works immediately. Only repositions when the
  -- cursor is not already on a pipeline row, so refreshes / manual
  -- navigation are left alone.
  local first = nil
  for lnum in pairs(id_map) do
    if not first or lnum < first then
      first = lnum
    end
  end
  if first and state.list_win and vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_buf(state.list_win) == buf then
    local cur = vim.api.nvim_win_get_cursor(state.list_win)[1]
    if not id_map[cur] then
      vim.api.nvim_win_set_cursor(state.list_win, { first, 0 })
    end
  end
end

-- (Re)run `glab ci list -F json [-r <ref>]` and update the buffer
-- asynchronously. Guarded against overlapping refreshes so a slow response
-- can't render stale data. `state.branch` is passed through as the
-- optional ref filter. `pipelines == nil` means the wrapper already
-- notified (review 4.1) — inflight is cleared either way so one failure
-- can't freeze the view.
--
-- `manual` is true only for user-initiated refreshes (`r`) and shows a
-- transient "Refreshing pipeline list…" message — the 5 s auto-refresh
-- timer and the filter/clear keymaps call it without `manual` so they
-- don't spam the user.
local function refresh(buf, manual)
  if state.inflight[buf] then
    return
  end
  if manual then
    vim.notify('Refreshing pipeline list…', vim.log.levels.INFO, { title = 'glab' })
  end
  state.inflight[buf] = true
  glab.ci_list(function(pipelines)
    state.inflight[buf] = nil
    -- Dismiss the "Refreshing pipeline list…" notify once the fetch returns.
    if manual then
      util.clear_msg()
    end
    if pipelines == nil then
      return
    end
    if vim.api.nvim_buf_is_valid(buf) then
      render(buf, pipelines)
    end
  end, state.branch)
end

-- Open the list buffer in the given window and wire up all its
-- buffer-local behavior. The list buffer is created fresh per layout
-- bootstrap — `state.list_buf` carries the handle afterwards.
function M.open(buf, win)
  vim.api.nvim_buf_set_name(buf, 'glab://ci-list')
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  -- `hide` (not `wipe`): the list is swapped out of the window when a
  -- pipeline is opened (the jobs list replaces it in the same window),
  -- and `q` / `<Esc>` swaps it back in. Wiping it on swap-out would kill
  -- the buffer mid-drill-down. Teardown is handled explicitly by
  -- `init.bootstrap_layout` (BufWipeout on this buffer for `q` at the
  -- list level, plus WinClosed on the layout window for `:close`).
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'glab-ci-list'

  state.list_buf = buf
  state.list_win = win

  render(buf, {})
  refresh(buf)
  state.start_timer(buf, 5000, function()
    refresh(buf)
  end)

  -- Stop the timer and forget per-buffer state when the list buffer is
  -- deleted. The full layout teardown (window + buffers) lives in
  -- `init.bootstrap_layout`.
  vim.api.nvim_create_autocmd('BufDelete', {
    buffer = buf,
    group = state.augroup,
    callback = function()
      state.forget_buf(buf)
    end,
  })

  -- <CR> opens the pipeline under the cursor in the same window,
  -- replacing the list (single-pane drill-down).
  vim.keymap.set('n', '<CR>', function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local id = state.ids[buf] and state.ids[buf][lnum]
    if id then
      pipeline_view.open(id)
    end
  end, { buffer = buf, desc = 'Open pipeline (drill-down)' })

  -- r triggers an immediate refresh (in addition to the 5s timer).
  vim.keymap.set('n', 'r', function()
    refresh(buf, true)
  end, { buffer = buf, desc = 'Refresh pipeline list' })

  -- f prompts for a branch filter via `vim.ui.input` (plain text, no
  -- completion per PLAN §7.1). An empty input clears the filter; nil
  -- (user cancelled) leaves it unchanged.
  vim.keymap.set('n', 'f', function()
    vim.ui.input({ prompt = 'Filter by branch (empty for all): ', default = state.branch or '' }, function(input)
      if input == nil then
        return
      end
      state.branch = input ~= '' and input or nil
      refresh(buf)
    end)
  end, { buffer = buf, desc = 'Filter by branch' })

  -- c clears an active branch filter (no-op if none is set).
  vim.keymap.set('n', 'c', function()
    if state.branch ~= nil then
      state.branch = nil
      refresh(buf)
    end
  end, { buffer = buf, desc = 'Clear branch filter' })

  -- q closes the list view (teardown funneled via BufWipeout on list_buf).
  vim.keymap.set('n', 'q', function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end, { buffer = buf, desc = 'Close pipeline list' })
end

return M
