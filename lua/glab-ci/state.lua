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
  M.job_action = {}
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
  end
end

-- Start (or restart) a periodic timer for a buffer. `on_tick` is called on
-- the main loop thread; if the buffer has been wiped, the timer self-stops.
function M.start_timer(buf, interval_ms, on_tick)
  M.stop_timer(buf)
  local timer = uv.new_timer()
  M.timers[buf] = timer
  timer:start(interval_ms, interval_ms, function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
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
