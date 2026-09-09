-- Job-level actions (Phase 3).
--
-- Three thin wrappers around `glab ci {retry,trigger,cancel job}`. Each
-- calls `glab`, notifies on failure, and runs `cb()` on success. Callers
-- are responsible for the status guards (which job statuses permit which
-- action) — see `views/pipeline.lua`. See PLAN-glab-nativization.md §5 /
-- §11.
local M = {}

local util = require 'glab-ci.util'

-- Run a glab invocation, notify on failure, call `cb(ok)` on completion.
-- `ok` is `true` on success and `false` on failure (the error is already
-- notified). The bool lets callers give per-job feedback ("✓ retried" vs
-- "✗ retry failed"). The `vim.system` spawn itself is pcall'd: a missing
-- glab binary throws synchronously (ENOENT), which would otherwise escape
-- into the user's keymap callback (review 4.1).
local function run(args, label, cb)
  local ok, err = pcall(vim.system, vim.list_extend({ 'glab' }, args), { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        util.notify_failed(label, obj.code, obj.stderr)
        if cb then
          cb(false)
        end
      end)
      return
    end
    if cb then
      vim.schedule(function()
        cb(true)
      end)
    end
  end)
  if not ok then
    vim.schedule(function()
      util.notify_failed(label, nil, err)
      if cb then
        cb(false)
      end
    end)
  end
end

-- Retry a failed job: `glab ci retry <job-id>`.
function M.retry(job_id, cb)
  run({ 'ci', 'retry', tostring(job_id) }, 'ci retry', cb)
end

-- Trigger a manual job: `glab ci trigger <job-id>`.
function M.trigger(job_id, cb)
  run({ 'ci', 'trigger', tostring(job_id) }, 'ci trigger', cb)
end

-- Cancel a running/pending job: `glab ci cancel job <job-id>`.
function M.cancel(job_id, cb)
  run({ 'ci', 'cancel', 'job', tostring(job_id) }, 'ci cancel job', cb)
end

return M
