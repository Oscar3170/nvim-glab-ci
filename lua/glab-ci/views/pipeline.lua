-- Pipeline detail view (`glab-ci-pipeline`).
--
-- Phase 2: this module owns the pipeline (jobs list) buffer. The buffer is
-- created once and reused — every `<CR>` from the list view swaps it into
-- the layout window (replacing the list), re-renders its contents in place,
-- and starts a 5 s timer. `state.job_ids[buf]` is rebuilt every render so
-- cursor-line -> job-id lookups always match the current contents.
--
-- Phase 3 adds `R` / `T` / `C` keymaps for retry / trigger / cancel, each
-- guarded by the job's current status. Phase 4 adds `<CR>` to open the log
-- buffer in the same window via `views/log.lua`.
--
-- Single-window drill-down: selecting a pipeline replaces the pipeline list
-- in the *same* window (`M.open`), rather than opening a second pane to the
-- right (Phase 5's `right_win` vsplit). If the window is showing the log
-- when a new pipeline is opened, the log's stream is killed first (review
-- 4.3). When `glab ci get` fails (e.g. deleted pipeline), the stale jobs
-- list is swapped back to the pipeline list per PLAN §13 (review 4.5). The
-- teardown story stays as-is: when the layout is torn down, init.lua's
-- teardown deletes this buffer and the log buffer, and closes the window.
local M = {}

local state = require 'glab-ci.state'
local highlights = require 'glab-ci.highlights'
local glab = require 'glab-ci.glab'
local util = require 'glab-ci.util'
local actions = require 'glab-ci.actions'
local log_view = require 'glab-ci.views.log'

local ns = vim.api.nvim_create_namespace 'glab_ci_pipeline'

-- Cache of the last successfully fetched pipeline, used to re-render the
-- buffer without a network round-trip (`M.redraw`) so transient per-job
-- action feedback shows up immediately on keypress instead of waiting for
-- the next `ci get`.
local last_pipeline = nil

-- Coerce an optional JSON value back to a string for `string.format`.
-- A decoded payload of the wrong shape (table / boolean instead of
-- string, e.g. from a non-gitlab API response shape) would make `%s`/
-- `%d` raise inside the render callback (review 6); nil stays nil so
-- `or ''` fallbacks below keep working.
local function str(v)
  return type(v) == 'string' and v or nil
end

-- Short SHA (first 8 chars) for the header line. Empty string if missing.
local function short_sha(sha)
  sha = str(sha)
  if not sha or #sha < 8 then
    return sha or ''
  end
  return sha:sub(1, 8)
end

-- Char-aware right-pad: pads `s` with spaces to a target *character*
-- count (not byte count, which is what Lua's `string.format('%-Ns', ...)`
-- uses). Needed because the job-dur field can hold a multibyte char like
-- "—" (U+2014, 3 bytes / 1 char). With byte-aware padding, `%-8s "—"`
-- produces "—" + 5 spaces = 6 chars wide, breaking the column alignment
-- of every subsequent column (the user's report: "[failed] [skipped]
-- [success]" don't line up across rows). With char-aware padding it
-- produces "—" + 7 spaces = 8 chars wide, matching ASCII cases.
--
-- `vim.fn.strchars` is Neovim's built-in UTF-8-aware char counter.
local function rpad(s, n)
  if not s then
    s = ''
  end
  if vim.fn.strchars(s) >= n then
    return s
  end
  return s .. string.rep(' ', n - vim.fn.strchars(s))
end

-- Render the decoded pipeline object into the buffer.
local function render(buf, pipeline)
  if not pipeline or not pipeline.id then
    return
  end

  local id = pipeline.id
  local iid = str(pipeline.iid) or ''
  local ref = str(pipeline.ref) or ''
  local sha = short_sha(pipeline.sha)
  local source = str(pipeline.source) or ''
  local duration = pipeline.duration or 0
  local status = str(pipeline.status) or ''

  local header_lines = {
    string.format('Pipeline #%d (iid #%s) on %s — commit %s', id, iid, ref, sha),
    string.format('source: %s  •  duration: %s  •  status: %s', source, util.fmt_duration(duration, status, pipeline.started_at), status),
    util.DIVIDER,
  }

  local lines = {}
  for _, l in ipairs(header_lines) do
    table.insert(lines, l)
  end

  local job_ids = {}
  local marks = {}

  -- `jobs` may be `vim.NIL` (JSON null) when the pipeline has no
  -- `.gitlab-ci.yml`. Normalize to nil so the rest of the code can use
  -- `ipairs`/`#jobs` freely.
  local jobs = pipeline.jobs
  if jobs == vim.NIL then
    jobs = nil
  end
  if jobs and #jobs > 0 then
    -- Group jobs by stage preserving first-seen order of stages and jobs.
    local stage_order = {}
    local stage_jobs = {}
    for _, j in ipairs(jobs) do
      local st = j.stage or ''
      if not stage_jobs[st] then
        stage_jobs[st] = {}
        table.insert(stage_order, st)
      end
      table.insert(stage_jobs[st], j)
    end

    -- Stage column width. The previous hard-coded `%-10s` overflowed
    -- for any stage name longer than 10 chars — common on terraform
    -- repos where stages like `tf-validate` (11 chars) pushed the pipe
    -- / glyph / name / duration columns one column to the right, so
    -- rows no longer lined up. Compute the longest stage name in this
    -- render and size the column to fit (with a min of 10 to keep
    -- visually narrow pipelines from looking squished, and a hard cap
    -- of 30 so a freakishly long stage name doesn't push the rest of
    -- the row off the screen). Use char count (`vim.fn.strchars`) so
    -- a future multi-byte stage name measures correctly too.
    local stage_width = 10
    for _, j in ipairs(jobs) do
      local n = vim.fn.strchars(j.stage or '')
      if n > stage_width then
        stage_width = n
      end
    end
    stage_width = math.min(stage_width + 1, 30)

    for _, st in ipairs(stage_order) do
      for _, j in ipairs(stage_jobs[st]) do
        local lnum = #lines + 1
        -- Stash the *full* job object in `job_ids` so the <CR>
        -- keymap can hand everything (id, name, stage, status,
        -- started_at, finished_at, ...) to the log view for a rich
        -- header. The previous shape was just `{id, status}` which
        -- was enough for R/T/C status guards but lost the metadata
        -- the log header wants (stage name, started_at, ...).
        job_ids[lnum] = j
        local glyph = highlights.STATUS_GLYPH[j.status] or '·'
        local dur = util.fmt_duration(j.duration, j.status, j.started_at)
        local status_str = str(j.status) or ''
        local anno_str = j.allow_failure and 'allow_failure' or ''
        -- Transient per-job action feedback (retry / trigger / cancel),
        -- drawn right after the status bracket, e.g. `[running] ⟳ retrying…`
        -- or `[failed] ✓ retried`. Stored in `state.job_action[buf]`.
        local fb = state.job_action[buf] and state.job_action[buf][j.id]
        local fb_str = fb and (' ' .. fb.text) or ''
        local line = string.format(
          '%s │ %s %s %s [%s]%s %s',
          rpad(str(st) or '', stage_width),
          glyph,
          rpad(str(j.name) or '', 25),
          rpad(dur, 8),
          status_str,
          fb_str,
          anno_str
        )
        table.insert(lines, line)

        -- Color the status token in [brackets] with the status hl group.
        -- Locate the brackets via plain-text find so padding/alignment
        -- doesn't matter.
        local s = highlights.STATUSES[j.status] or highlights.STATUSES.created
        local bracket_open = line:find('[', 1, true)
        local bracket_close = bracket_open and line:find(']', bracket_open, true)
        if bracket_open and bracket_close then
          table.insert(marks, {
            lnum0 = lnum - 1,
            col_start = bracket_open - 1,
            col_end = bracket_close,
            hl = s.hl,
          })
        end
        -- Color the feedback label (just its text, not the leading space)
        -- with its own hl group so it stands out beside the status.
        if fb then
          local fb_start = line:find(fb.text, 1, true)
          if fb_start then
            table.insert(marks, {
              lnum0 = lnum - 1,
              col_start = fb_start - 1,
              col_end = fb_start - 1 + #fb.text,
              hl = fb.hl or 'GlabPending',
            })
          end
        end

        -- Dim the trailing `allow_failure` annotation.
        if j.allow_failure then
          local anno_start = #line - #anno_str + 1
          table.insert(marks, {
            lnum0 = lnum - 1,
            col_start = anno_start - 1,
            col_end = #line,
            hl = 'GlabDim',
          })
        end

        -- Dim the stage column too — keeps the eye on the job names.
        table.insert(marks, {
          lnum0 = lnum - 1,
          col_start = 0,
          col_end = #st + 1,
          hl = 'GlabDim',
        })
      end
    end
  else
    table.insert(lines, '(no jobs in this pipeline)')
  end

  table.insert(lines, util.DIVIDER)
  table.insert(lines, 'r: refresh • R: retry • T: trigger • C: cancel • <CR>: open log • <Esc>/q: back to list')

  state.job_ids[buf] = job_ids

  -- Stash the open pipeline's metadata so the log view can render a
  -- useful header (ref / iid / short sha). Stored only after a
  -- successful render — `M.open(pipeline_id)` runs before the
  -- data is available, so the log view sees an empty `_pipeline_*`
  -- for the very first selection until ci_get resolves.
  state._pipeline_ref = pipeline.ref
  state._pipeline_iid = pipeline.iid
  state._pipeline_sha = short_sha(pipeline.sha)

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

  -- On entry the cursor sits on the header; land it on the first job so
  -- <CR> (drill-down) works immediately. Only repositions when the cursor
  -- is not already on a job row, so refreshes / manual navigation are left
  -- alone. `next(next(job_ids))` is the smallest lnum key (keys are integers).
  local first_job = nil
  for lnum in pairs(job_ids) do
    if not first_job or lnum < first_job then
      first_job = lnum
    end
  end
  if first_job and state.list_win and vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_buf(state.list_win) == buf then
    local cur = vim.api.nvim_win_get_cursor(state.list_win)[1]
    if not job_ids[cur] then
      vim.api.nvim_win_set_cursor(state.list_win, { first_job, 0 })
    end
  end
end

-- Re-render the pipeline buffer from `last_pipeline` without a network
-- round-trip. Used to surface transient per-job action feedback
-- (in-flight retry / trigger / cancel markers) immediately on keypress
-- instead of waiting for the next `ci get`.
function M.redraw(buf)
  if last_pipeline and vim.api.nvim_buf_is_valid(buf) then
    render(buf, last_pipeline)
  end
end

-- Set (or clear) transient per-job action feedback on the current pipeline
-- render. `{ text, hl }` is stored keyed by job id and drawn right after
-- that job's status; when `clear_ms` is set the marker auto-clears after
-- that delay unless it has since been replaced. A nil `text` clears it.
local function set_job_feedback(buf, job_id, text, hl, clear_ms)
  if not state.job_action[buf] then
    state.job_action[buf] = {}
  end
  if text == nil then
    state.job_action[buf][job_id] = nil
  else
    state.job_action[buf][job_id] = { text = text, hl = hl or 'GlabPending' }
    if clear_ms and clear_ms > 0 then
      vim.defer_fn(function()
        local cur = state.job_action[buf] and state.job_action[buf][job_id]
        if cur and cur.text == text then
          state.job_action[buf][job_id] = nil
          M.redraw(buf)
        end
      end, clear_ms)
    end
  end
  M.redraw(buf)
end

-- Buffer-local keymaps + teardown cleanup for the pipeline buffer.
-- Extracted from `ensure_buf` (review 5.6) so the ~140-line closure
-- factory reads as two pieces: buffer setup and keymap wiring.
local function setup_keymaps(buf)
  -- Look up the job under the cursor via `state.job_ids[buf]`. Returns
  -- nil when the cursor is on the header / footer / a non-job line.
  --
  -- Defined *before* the keymap closures below so it's captured as an
  -- upvalue. Lua binds upvalues at closure-creation time, so a
  -- `local function job_under_cursor()` declared after a keymap that
  -- references it would be invisible to that callback (it would fall
  -- back to looking up a global of the same name, which is nil — see
  -- the "attempt to call global 'job_under_cursor' (a nil value)"
  -- error reported on the iam-gglobo-* repo).
  local function job_under_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    return state.job_ids[buf] and state.job_ids[buf][lnum]
  end

  -- Stop the timer and forget per-buffer state on teardown.
  vim.api.nvim_create_autocmd('BufDelete', {
    buffer = buf,
    group = state.augroup,
    callback = function()
      state.forget_buf(buf)
    end,
  })

  -- Local keymaps for the pipeline view.
  vim.keymap.set('n', 'r', function()
    if state.inflight[buf] or not state.pipeline_id then
      return
    end
    M.refresh(buf, true)
  end, { buffer = buf, desc = 'Refresh pipeline' })

  -- `<CR>` on a job opens its log in the same window via log_view.
  -- The pipeline view's 5 s timer is paused while the log is open
  -- (PLAN §8); the timer resumes when the user comes back.
  --
  -- Pass the full job object (not just id/name/status/pipeline_id)
  -- so the log header can display stage, started_at, finished_at,
  -- duration, etc. — see `log_view.header_lines`.
  --
  -- The second argument is a refresh callback: `log.lua` uses it to
  -- (a) restart the pipeline timer + refresh when the user goes back
  -- to the pipeline view and (b) refresh the pipeline when a stream
  -- exits. Passing it in instead of log.lua lazily requiring this
  -- module breaks the log ↔ pipeline require cycle structurally
  -- (review 7).
  vim.keymap.set('n', '<CR>', function()
    local job = job_under_cursor()
    if not job then
      vim.notify('No job under cursor', vim.log.levels.WARN, { title = 'glab' })
      return
    end
    log_view.open({
      id = job.id,
      name = job.name,
      stage = job.stage,
      status = job.status,
      duration = job.duration,
      started_at = job.started_at,
      finished_at = job.finished_at,
      pipeline_id = state.pipeline_id,
      pipeline_ref = state._pipeline_ref,
      pipeline_iid = state._pipeline_iid,
      pipeline_sha = state._pipeline_sha,
    }, function()
      M.refresh(buf)
    end)
  end, { buffer = buf, desc = 'Open job log' })

  -- R retries a failed job under the cursor. Notify otherwise.
  vim.keymap.set('n', 'R', function()
    local job = job_under_cursor()
    if not job then
      vim.notify('No job under cursor', vim.log.levels.WARN, { title = 'glab' })
      return
    end
    -- if job.status ~= 'failed' then
    --   vim.notify(string.format('Cannot retry: job status is "%s" (only failed jobs)', job.status), vim.log.levels.WARN, { title = 'glab' })
    --   return
    -- end
    set_job_feedback(buf, job.id, '⟳ retrying…', 'GlabPending')
    actions.retry(job.id, function(ok)
      set_job_feedback(buf, job.id, ok and '✓ retried' or '✗ retry failed', ok and 'GlabSuccess' or 'GlabFailed', 3000)
      M.refresh(buf)
    end)
  end, { buffer = buf, desc = 'Retry failed job' })

  -- T triggers a manual job under the cursor. Notify otherwise.
  vim.keymap.set('n', 'T', function()
    local job = job_under_cursor()
    if not job then
      vim.notify('No job under cursor', vim.log.levels.WARN, { title = 'glab' })
      return
    end
    if job.status ~= 'manual' then
      vim.notify(string.format('Cannot trigger: job status is "%s" (only manual jobs)', job.status), vim.log.levels.WARN, { title = 'glab' })
      return
    end
    set_job_feedback(buf, job.id, '⟳ triggering…', 'GlabPending')
    actions.trigger(job.id, function(ok)
      set_job_feedback(buf, job.id, ok and '✓ triggered' or '✗ trigger failed', ok and 'GlabSuccess' or 'GlabFailed', 3000)
      M.refresh(buf)
    end)
  end, { buffer = buf, desc = 'Trigger manual job' })

  -- C cancels a running/pending job under the cursor. Notify otherwise.
  vim.keymap.set('n', 'C', function()
    local job = job_under_cursor()
    if not job then
      vim.notify('No job under cursor', vim.log.levels.WARN, { title = 'glab' })
      return
    end
    if job.status ~= 'running' and job.status ~= 'pending' then
      vim.notify(string.format('Cannot cancel: job status is "%s" (only running/pending)', job.status), vim.log.levels.WARN, { title = 'glab' })
      return
    end
    set_job_feedback(buf, job.id, '⟳ cancelling…', 'GlabPending')
    actions.cancel(job.id, function(ok)
      set_job_feedback(buf, job.id, ok and '✓ canceled' or '✗ cancel failed', ok and 'GlabSuccess' or 'GlabFailed', 3000)
      M.refresh(buf)
    end)
  end, { buffer = buf, desc = 'Cancel running/pending job' })

  vim.keymap.set('n', '<Esc>', function()
    M.back_to_list()
  end, { buffer = buf, desc = 'Back to list' })

  vim.keymap.set('n', 'q', function()
    M.back_to_list()
  end, { buffer = buf, desc = 'Back to list' })
end

-- Create (or reuse) the pipeline buffer. Called from
-- `M.open` exactly once per layout bootstrap.
local function ensure_buf()
  if state.pipeline_buf and vim.api.nvim_buf_is_valid(state.pipeline_buf) then
    return state.pipeline_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  -- `hide` so the buffer survives being swapped out for the log buffer
  -- (Phase 4). Teardown deletes it explicitly.
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'glab-ci-pipeline'

  state.pipeline_buf = buf
  state.job_ids[buf] = {}

  setup_keymaps(buf)

  return buf
end

-- (Re)fetch `glab ci get -p <id> -d -F json` and update the buffer.
-- Guarded against overlapping refreshes.
function M.refresh(buf, manual)
  if state.inflight[buf] or not state.pipeline_id then
    return
  end
  -- Only user-initiated refreshes (`r`) notify; the 5 s auto-refresh timer
  -- calls without `manual` so it doesn't spam.
  if manual then
    vim.notify('Refreshing jobs list…', vim.log.levels.INFO, { title = 'glab' })
  end
  state.inflight[buf] = true
  glab.ci_get(state.pipeline_id, function(pipeline)
    state.inflight[buf] = nil
    -- Dismiss the "Refreshing jobs list…" notify once the fetch returns.
    if manual then
      util.clear_msg()
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if pipeline == nil then
      -- `glab ci get` failed (deleted pipeline, auth, network, ...).
      -- The wrapper already notified (review 4.1); per PLAN §13 stop the
      -- refresh timer so a dead pipeline isn't re-poisoned every 5 s
      -- (review 4.5) and swap the pipeline list back in so the user isn't
      -- left staring at a dead jobs list. Only swap when the window is
      -- actually showing this buffer — when the log is open, the pipeline
      -- buffer is hidden and the log keeps streaming.
      state.stop_timer(buf)
      if
        state.list_win
        and vim.api.nvim_win_is_valid(state.list_win)
        and state.list_buf
        and vim.api.nvim_buf_is_valid(state.list_buf)
        and vim.api.nvim_win_get_buf(state.list_win) == buf
      then
        vim.api.nvim_win_set_buf(state.list_win, state.list_buf)
      end
      return
    end
    last_pipeline = pipeline
    render(buf, pipeline)
  end)
end

-- Go "back to the list": swap the pipeline list buffer back into the
-- layout window and stop the per-buffer pipeline refresh timer (it was
-- started when the pipeline opened — leaving it running would just churn
-- a hidden buffer). If the window is currently showing the log, kill its
-- stream first, exactly like `M.open` does (review 4.3). Used by the
-- pipeline view's `q` / `<Esc>` keymaps and by `init.M.list()` when
-- `:GlabCI` is re-run at a deeper drill-down level.
function M.back_to_list()
  local win = state.list_win

  if
    win
    and vim.api.nvim_win_is_valid(win)
    and state.log_buf
    and vim.api.nvim_buf_is_valid(state.log_buf)
    and vim.api.nvim_win_get_buf(win) == state.log_buf
  then
    log_view.shutdown()
  end

  if state.pipeline_buf and vim.api.nvim_buf_is_valid(state.pipeline_buf) then
    state.stop_timer(state.pipeline_buf)
  end

  if win and vim.api.nvim_win_is_valid(win) and state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf) then
    vim.api.nvim_win_set_buf(win, state.list_buf)
  end
end

-- Public entry point: load pipeline `pipeline_id` into the layout window,
-- *replacing* the pipeline list (single-pane drill-down — no second pane
-- to the right, unlike Phase 5).
--
-- Idempotent — re-calling for the same id while the pipeline is already
-- open just refreshes it. Re-calling for a different id while another is
-- open re-renders the buffer in place (no new buffer / no new window).
--
-- The layout window itself is created once by `init.bootstrap_layout`;
-- selecting a pipeline only swaps which buffer it displays. If the window
-- has been torn down under us (list_win stale), bail out.
function M.open(pipeline_id)
  state.pipeline_id = pipeline_id
  local buf = ensure_buf()

  -- If the layout window is currently showing the log, kill its trace
  -- before the pipeline buffer takes over. Otherwise the stream keeps
  -- parsing into a hidden buffer and the follow-snap logic in log.lua
  -- reads/writes the cursor of a window that no longer shows the log
  -- (review 4.3). `log_view.shutdown` SIGTERMs the subprocess and
  -- bumps the generation counter so any pending callbacks go stale.
  if
    state.log_buf
    and vim.api.nvim_buf_is_valid(state.log_buf)
    and state.list_win
    and vim.api.nvim_win_is_valid(state.list_win)
    and vim.api.nvim_win_get_buf(state.list_win) == state.log_buf
  then
    log_view.shutdown()
  end

  -- The layout window must exist (bootstrap created it). Bail if it has
  -- been torn down under us.
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
    return
  end

  -- Defer the window handoff until the data has rendered (request #1):
  -- fetch the pipeline first and only then swap the buffer in, focus, and
  -- start the 5 s timer. Selecting a pipeline never flashes a blank /
  -- loading pane over the list — the list stays visible until the jobs
  -- list is ready, and on failure we simply stay on the list.
  M.initial_load(buf)
end

-- First load for a freshly selected pipeline. Fetches `glab ci get` and,
-- only on success, swaps the pipeline buffer into the layout window,
-- focuses it, and starts the per-buffer 5 s refresh timer. On failure it
-- stays on the list (the wrapper already notified); the stale surface is
-- never handed over.
function M.initial_load(buf)
  if state.inflight[buf] or not state.pipeline_id then
    return
  end
  vim.notify(string.format('Loading jobs for pipeline #%s…', tostring(state.pipeline_id)), vim.log.levels.INFO, { title = 'glab' })
  state.inflight[buf] = true
  glab.ci_get(state.pipeline_id, function(pipeline)
    state.inflight[buf] = nil
    -- The "Loading jobs…" notify (shown when this load started) is
    -- dismissed once the data is in — whether it succeeded or failed.
    util.clear_msg()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if pipeline == nil then
      -- Deleted pipeline / auth / network; `ci get` already notified. Do
      -- not hand the window over — stay on the list.
      return
    end
    -- Data ready: now swap the pipeline buffer in and take focus.
    if state.list_win and vim.api.nvim_win_is_valid(state.list_win) and vim.api.nvim_win_get_buf(state.list_win) ~= buf then
      vim.api.nvim_win_set_buf(state.list_win, buf)
    end
    if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
      vim.api.nvim_set_current_win(state.list_win)
    end
    state.start_timer(buf, 5000, function()
      M.refresh(buf)
    end)
    last_pipeline = pipeline
    render(buf, pipeline)
  end)
end

return M
