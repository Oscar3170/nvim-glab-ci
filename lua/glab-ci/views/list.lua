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
-- timestamp. `util.iso_epoch` accounts for the timestamp's timezone offset.
local function rel_time(iso)
  local then_epoch = util.iso_epoch(iso)
  if not then_epoch then
    return ''
  end
  local now_epoch = os.time()
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
local function render(buf, pipelines, branch)
  local ref_str = branch or 'all'
  local lines = {
    string.format(' glab ci list • ref: %s • 5s refresh • r: refresh • f: filter • c: clear • <CR>: open • q: close', ref_str),
    '',
  }
  local id_map = {}
  local marks = {} -- { lnum0, col_start, col_end, hl }

  if #pipelines == 0 then
    if branch then
      table.insert(lines, string.format(' (no pipelines for ref %s)', branch))
    else
      table.insert(lines, ' (no pipelines)')
    end
  end

  -- Calculate widths from this response rather than relying on fixed fields.
  -- GitLab status names (notably `canceling`) and refs may be longer than
  -- the old columns, which made the id, ref, and time columns drift by row.
  local entries = {}
  local status_width, id_width, iid_width, ref_width = 10, 8, 7, 20
  for _, p in ipairs(pipelines) do
    -- Defensive shape check (review 6): a payload that decodes to JSON
    -- but isn't shaped like a pipeline entry (missing/non-numeric id)
    -- must not crash the scheduled render callback.
    if type(p.id) == 'number' then
      local status = type(p.status) == 'string' and p.status or '?'
      local iid = type(p.iid) == 'number' and p.iid or nil
      local entry = {
        id = p.id,
        status = status,
        status_str = string.format('(%s)', status),
        id_str = '#' .. tostring(p.id),
        iid_str = iid and string.format('(#%d)', iid) or '',
        ref = type(p.ref) == 'string' and p.ref or '',
        time = rel_time(p.created_at),
      }
      table.insert(entries, entry)
      status_width = math.max(status_width, vim.fn.strdisplaywidth(entry.status_str))
      id_width = math.max(id_width, vim.fn.strdisplaywidth(entry.id_str))
      iid_width = math.max(iid_width, vim.fn.strdisplaywidth(entry.iid_str))
      ref_width = math.max(ref_width, vim.fn.strdisplaywidth(entry.ref))
    end
  end

  for _, entry in ipairs(entries) do
    local lnum = #lines + 1
    id_map[lnum] = entry.id
    local line = table.concat {
      util.rpad_display(entry.status_str, status_width),
      ' • ',
      util.rpad_display(entry.id_str, id_width),
      ' ',
      util.rpad_display(entry.iid_str, iid_width),
      ' ',
      util.rpad_display(entry.ref, ref_width),
      ' ',
      entry.time,
    }
    table.insert(lines, line)
    local s = highlights.STATUSES[entry.status] or highlights.STATUSES.created
    table.insert(marks, { lnum0 = lnum - 1, col_start = 0, col_end = #entry.status_str, hl = s.hl })
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
  state.activate_for_buf(buf)
  local layout = state.context_for_buf(buf)
  local shared = state.shared_view_for_buf('list', buf)
  local branch = shared and shared.branch or state.branch
  if state.inflight[buf] then
    return
  end
  if manual then
    vim.notify('Refreshing pipeline list…', vim.log.levels.INFO, { title = 'glab' })
  end
  state.inflight[buf] = true
  glab.ci_list(function(pipelines)
    if layout and not state.activate(layout) then
      return
    end
    state.inflight[buf] = nil
    -- Dismiss the "Refreshing pipeline list…" notify once the fetch returns.
    if manual then
      util.clear_msg()
    end
    if pipelines == nil then
      return
    end
    if vim.api.nvim_buf_is_valid(buf) then
      render(buf, pipelines, branch)
    end
  end, branch)
end

-- Open the list buffer in the given window and wire up all its
-- buffer-local behavior. The list buffer is created fresh per layout
-- bootstrap — `state.list_buf` carries the handle afterwards.
function M.open(buf, win)
  state.activate_for_buf(buf)
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

  render(buf, {}, state.shared_view_for_buf('list', buf) and state.shared_view_for_buf('list', buf).branch or state.branch)
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

  local function map(lhs, callback, desc)
    vim.keymap.set('n', lhs, function()
      state.activate_for_current_win()
      callback()
    end, { buffer = buf, desc = desc })
  end

  -- <CR> opens the pipeline under the cursor in the same window,
  -- replacing the list (single-pane drill-down).
  map('<CR>', function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local id = state.ids[buf] and state.ids[buf][lnum]
    if id then
      pipeline_view.open(id)
    end
  end, 'Open pipeline (drill-down)')

  -- r triggers an immediate refresh (in addition to the 5s timer).
  map('r', function()
    refresh(buf, true)
  end, 'Refresh pipeline list')

  -- f prompts for a branch filter via `vim.ui.input` (plain text, no
  -- completion per PLAN §7.1). An empty input clears the filter; nil
  -- (user cancelled) leaves it unchanged.
  map('f', function()
    local layout = state.context_for_buf(buf)
    local shared = state.shared_view_for_buf('list', buf)
    vim.ui.input({ prompt = 'Filter by branch (empty for all): ', default = (shared and shared.branch) or state.branch or '' }, function(input)
      if layout and not state.activate(layout) then
        return
      end
      if input == nil then
        return
      end
      local branch = input ~= '' and input or nil
      state.branch = branch
      if shared then
        shared.branch = branch
      end
      refresh(buf)
    end)
  end, 'Filter by branch')

  -- c clears an active branch filter (no-op if none is set).
  map('c', function()
    local shared = state.shared_view_for_buf('list', buf)
    if (shared and shared.branch) or state.branch ~= nil then
      state.branch = nil
      if shared then
        shared.branch = nil
      end
      refresh(buf)
    end
  end, 'Clear branch filter')

  -- q closes only this panel. The list buffer may be visible in other
  -- GlabCI windows, so it is released by the layout's WinClosed teardown.
  map('q', function()
    local win = state.list_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, 'Close pipeline list')
end

return M
