-- Shared state for the GlabCI plugin.
--
-- Phase 1 introduced the per-buffer primitives the list view needs (`ids`,
-- `timers`, `inflight`) plus timer/buffer-lifecycle helpers. Phase 2
-- extended the state with the fields needed for the layout (`layout_open`,
-- `list_win/list_buf/pipeline_buf/pipeline_id`) and the per-pipeline
-- `job_ids` table. Phase 3 added the list-view branch filter (`branch`).
-- Phase 4 adds the log view fields (`log_buf`, `log_job`, `log_follow`,
-- `ansi_state`, `job_id`/`log_status`).
--
-- Live layout (current): the original current window is preserved
-- untouched, the list opens in a `:botright split` below it, and the
-- *same* window hosts the drill-down. Selecting a pipeline swaps the list
-- buffer out for the pipeline buffer (the jobs list replaces the pipeline
-- list — no side-by-side panes like Phase 5's `right_win`), and opening a
-- job swaps in the log buffer. Each level's buffer is `bufhidden=hide`, so
-- `q` / `<Esc>` swaps the previous level back in. There is no `right_win`
-- anymore: `list_win` is the single layout pane.
--
-- Convention (review 5.4): this module holds the layout/timer fields and
-- the few cross-module lifecycle helpers (`start_timer`, `stop_timer`,
-- `forget_buf`, `kill_log_stream`, ...). View modules mutate view-owned
-- fields directly (`state.pipeline_id`, `state.log_follow`, `state.branch`,
-- the `_job_*` header fields, ...) — the plan's §6 "state is mutated only
-- via helpers" rule was dropped in Phase 2 because per-view buffer
-- ownership made helper indirection a false abstraction. Keep this file to
-- lifecycle helpers + data, not logic.
local M = {}

local uv = vim.uv or vim.loop

-- Shared autocmd group for all GlabCI autocmds (per-buffer lifecycle +
-- layout teardown). Buffer-scoped autocmds self-clean on wipe, and `once`
-- guards the teardown handler, but a named group is the convention for
-- plugin-wide autocmd management (review 7).
M.augroup = vim.api.nvim_create_augroup('GlabCI', { clear = true })

-- Per-buffer mappings used by the list / pipeline views. These are direct
-- tables on the state module; callers access them as `state.ids[buf]`,
-- `state.timers[buf]`, `state.inflight[buf]`. Helpers below cover the
-- operations that need coordination across modules.
M.ids = {} -- buf -> { [lnum] = pipeline_id }
M.job_ids = {} -- buf -> { [lnum] = { id = int, status = string, ... } }
M.job_action = {} -- buf -> { [job_id] = { text = string, hl = string } }; transient per-job action feedback
M.timers = {} -- buf -> uv_timer
M.timer_layouts = {} -- buf -> layout that owns the timer callback context
M.inflight = {} -- buf -> bool, guards against overlapping refreshes

-- Single-window layout. `layout_open` is true between the first `:GlabCI`
-- and the layout teardown (BufWipeout on the list buffer, or WinClosed on
-- the layout window — see `init.bootstrap_layout`). `list_win` is the one
-- layout pane and hosts the list / pipeline / log buffers in turn;
-- `list_buf` is the list buffer, `pipeline_buf` the jobs-list buffer.
M.layout_open = false
M.list_win = nil
M.list_buf = nil
M.pipeline_buf = nil -- pipeline detail (jobs list) buffer
M.pipeline_id = nil -- pipeline currently rendered in pipeline_buf
M._pipeline_id = nil -- pipeline id carried into the log view (`log.lua`)
M._pipeline_ref = nil -- ref / branch of the open pipeline, e.g. "main"
M._pipeline_iid = nil -- iid (project-scoped identifier) of the pipeline
M._pipeline_sha = nil -- short sha, "rendered as commit <8 hex>"

-- List-view branch filter (Phase 3). `nil` means "all branches"; any
-- other string is passed to `glab ci list -r <ref>`.
M.branch = nil

-- Log view. The log buffer is reused across all jobs (a single `BufDelete`
-- for it preserves the buffer so we can swap it back in when the user
-- re-opens a log).
--   log_buf              -- dedicated buffer for the log (shown in list_win)
--   job_id               -- job currently shown in `log_buf`
--   _job_name            -- job name (e.g. "plan")
--   _job_stage           -- job stage (e.g. "tf-plan")
--   _job_started_at      -- ISO 8601 start timestamp, may be nil
--   _job_finished_at     -- ISO 8601 finish timestamp, may be nil
--   _job_duration        -- API-supplied duration in seconds
--   log_status           -- job status when the stream started (drives follow-mode)
--   log_follow           -- tail-f: snap cursor to last line after each chunk
--   log_job              -- `vim.system` handle for the running trace (killable)
--   ansi_state           -- private parser state for `glab-ci.ansi`
M.log_buf = nil
M.job_id = nil
M._job_name = nil
M._job_stage = nil
M._job_started_at = nil
M._job_finished_at = nil
M._job_duration = nil
M.log_status = nil
M.log_follow = false
M.log_job = nil
M.ansi_state = nil
-- Per-layout log-view state. The panel's prior local winbar is restored
-- exactly when leaving the log, and expanded is reset on full teardown.
M.log_header_expanded = false
M.log_previous_winbar = nil
M.log_winbar_saved = false

-- Each invocation of :GlabCI owns an independent layout.  The view modules
-- retain their small, state-module API, while this context switcher makes the
-- layout-specific fields above point at the layout that owns the current
-- buffer/callback.  This is important for concurrent trace streams: a
-- callback for one panel must never overwrite another panel's job state.
local layout_fields = {
  'layout_open',
  'list_win',
  'list_buf',
  'pipeline_buf',
  'pipeline_id',
  '_pipeline_id',
  '_pipeline_ref',
  '_pipeline_iid',
  '_pipeline_sha',
  'branch',
  'log_buf',
  'job_id',
  '_job_name',
  '_job_stage',
  '_job_started_at',
  '_job_finished_at',
  '_job_duration',
  'log_status',
  'log_follow',
  'log_job',
  'ansi_state',
  'log_header_expanded',
  'log_previous_winbar',
  'log_winbar_saved',
}
local defaults = {}
for _, field in ipairs(layout_fields) do
  defaults[field] = M[field]
end

M.layouts = {}
M.current_layout = nil
M.buf_layouts = {}
M.win_layouts = {}
-- Buffers that represent the same remote resource are shared by layouts.
-- Entries keep their consumers so ownership can move if the layout that
-- originally created a buffer closes first.
M.shared_views = { list = {}, pipeline = {} }
local switchers = {}

--- Register private module state that must follow the active layout.
function M.on_layout_switch(save, load)
  switchers[#switchers + 1] = { save = save, load = load }
  if M.current_layout then
    load(M.current_layout)
  end
end

--- Make `layout` the active state context.
function M.sync_current_layout()
  if not M.current_layout then
    return
  end
  for _, field in ipairs(layout_fields) do
    M.current_layout[field] = M[field]
  end
end

function M.activate(layout)
  -- Async callbacks may outlive a panel that was closed. Do not resurrect
  -- its state after teardown.
  if layout and not M.layouts[layout] then
    return false
  end
  if M.current_layout == layout then
    return true
  end
  if M.current_layout then
    for _, switcher in ipairs(switchers) do
      switcher.save(M.current_layout)
    end
    M.sync_current_layout()
  end
  M.current_layout = layout
  if layout then
    for _, field in ipairs(layout_fields) do
      M[field] = layout[field]
    end
    for _, switcher in ipairs(switchers) do
      switcher.load(layout)
    end
  end
  return true
end

--- Create and activate a new independent GlabCI panel.
function M.create_layout()
  local layout = {}
  for _, field in ipairs(layout_fields) do
    layout[field] = defaults[field]
  end
  M.layouts[layout] = true
  M.activate(layout)
  return layout
end

function M.register_buf(layout, buf)
  M.buf_layouts[buf] = layout
end

function M.register_win(layout, win)
  M.win_layouts[win] = layout
end

function M.activate_for_current_win()
  local layout = M.win_layouts[vim.api.nvim_get_current_win()]
  if layout then
    M.activate(layout)
  end
  return layout
end

--- Attach the active layout to a shared view. Returns its existing buffer,
--- or nil when the caller must create and register a new one.
function M.acquire_shared_view(kind, key)
  local views = M.shared_views[kind]
  local entry = views[key]
  if not entry then
    entry = { users = {} }
    views[key] = entry
  end
  entry.users[M.current_layout] = true
  M.current_layout.shared_views = M.current_layout.shared_views or {}
  M.current_layout.shared_views[kind] = key
  if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then
    return entry.buf
  end
  return nil
end

function M.set_shared_view_buf(kind, key, buf)
  local entry = M.shared_views[kind][key]
  entry.buf = buf
  M.register_buf(M.current_layout, buf)
end

function M.shared_view(kind, key)
  return M.shared_views[kind][key]
end

function M.shared_view_for_buf(kind, buf)
  for _, entry in pairs(M.shared_views[kind]) do
    if entry.buf == buf then
      return entry
    end
  end
end

--- Detach one layout and return true when it was the final user, in which
--- case the caller should stop refresh work and delete the buffer.
function M.release_shared_view(layout, kind)
  local key = layout and layout.shared_views and layout.shared_views[kind]
  if not key then
    return false
  end
  local entry = M.shared_views[kind][key]
  layout.shared_views[kind] = nil
  if not entry then
    return false
  end
  entry.users[layout] = nil
  local next_owner = next(entry.users)
  if next_owner then
    M.buf_layouts[entry.buf] = next_owner
    M.timer_layouts[entry.buf] = next_owner
    return false
  end
  M.shared_views[kind][key] = nil
  return true
end

function M.context_for_buf(buf)
  return M.buf_layouts[buf]
end

function M.activate_for_buf(buf)
  local layout = M.context_for_buf(buf)
  if layout then
    M.activate(layout)
  end
  return layout
end

function M.destroy_layout(layout)
  if not layout then
    return
  end
  M.layouts[layout] = nil
  for buf, owner in pairs(M.buf_layouts) do
    if owner == layout then
      M.buf_layouts[buf] = nil
    end
  end
  for win, owner in pairs(M.win_layouts) do
    if owner == layout then
      M.win_layouts[win] = nil
    end
  end
  if M.current_layout == layout then
    M.current_layout = nil
    for _, field in ipairs(layout_fields) do
      M[field] = defaults[field]
    end
  end
end

-- Log display preferences. Like `branch`, these survive layout teardown
-- (they are user preferences, not per-run state), so a fresh `:GlabCI`
-- remembers how the user had the log styled. Each is toggled independently:
--   prec        -- time precision: 'us' | 'ms' | 's' (cycled with `t`)
--   show_date   -- include the date part (toggled with `d`)
--   show_ts     -- show the timestamp at all (toggled with `o`)
--   local_tz    -- system timezone for timestamps, on by default (`T`)
--   show_stream -- render the `NNx[+]` stream indicator, on by default (`i`)
M.log_ts = {
  prec = 's',
  show_date = false,
  show_ts = true,
  local_tz = true,
  show_stream = true,
}

-- Reset all layout-related state. Called from the list buffer's
-- `BufWipeout` so a fresh `:GlabCI` starts clean. Does not clear
-- `branch` — that's a user preference that survives layout teardown.
function M.reset_layout()
  M.layout_open = false
  M.list_win = nil
  M.list_buf = nil
  M.pipeline_buf = nil
  M.log_buf = nil
  M.pipeline_id = nil
  M._pipeline_id = nil
  M._pipeline_ref = nil
  M._pipeline_iid = nil
  M._pipeline_sha = nil
  M.job_id = nil
  M._job_name = nil
  M._job_stage = nil
  M._job_started_at = nil
  M._job_finished_at = nil
  M._job_duration = nil
  M.log_status = nil
  M.log_follow = false
  M.log_job = nil
  M.ansi_state = nil
  M.log_header_expanded = false
  M.log_previous_winbar = nil
  M.log_winbar_saved = false
  M.job_action = {}
  -- A layout teardown should not invalidate other open panels.
  M.destroy_layout(M.current_layout)
end

-- Cancel and forget the running `glab ci trace` stream, if any. Stops the
-- underlying subprocess (SIGTERM), clears `log_job`, and is a no-op when
-- nothing is streaming. Used both by `BufWipeout` (full teardown) and by
-- `log_view` when the user navigates to a different job.
function M.kill_log_stream()
  if M.log_job then
    pcall(function()
      M.log_job:kill(15)
    end)
    M.log_job = nil
  end
end

-- Stop and clean up the refresh timer for a buffer.
function M.stop_timer(buf)
  local t = M.timers[buf]
  if t then
    t:stop()
    t:close()
    M.timers[buf] = nil
    M.timer_layouts[buf] = nil
  end
end

-- Start (or restart) a periodic timer for a buffer. `on_tick` is called on
-- the main loop thread; if the buffer has been wiped, the timer self-stops.
function M.start_timer(buf, interval_ms, on_tick)
  M.stop_timer(buf)
  M.timer_layouts[buf] = M.context_for_buf(buf) or M.current_layout
  local timer = uv.new_timer()
  M.timers[buf] = timer
  timer:start(interval_ms, interval_ms, function()
    vim.schedule(function()
      local layout = M.timer_layouts[buf]
      if vim.api.nvim_buf_is_valid(buf) and M.activate(layout) then
        on_tick()
      else
        M.stop_timer(buf)
      end
    end)
  end)
end

-- Forget all per-buffer state for `buf` (timer + the id/inflight tables).
-- Called from each view's `BufDelete` autocmd so teardown is idempotent.
function M.forget_buf(buf)
  M.stop_timer(buf)
  M.ids[buf] = nil
  M.job_ids[buf] = nil
  M.job_action[buf] = nil
  M.inflight[buf] = nil
end

-- Delete a buffer if it still exists. No-op for `nil` so callers don't have
-- to guard against the "buffer was never created" case.
function M.delete_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

return M
