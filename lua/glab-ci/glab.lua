-- Thin wrappers around `glab` invocations.
--
-- Each wrapper hides the `vim.system({...}, { text = true }, cb)` boilerplate
-- and handles its own error reporting via `vim.notify` (level ERROR, title
-- "glab"), so callers stay simple: just provide a success callback.
--
-- Error contract (review 4.1): **every wrapper calls `cb(nil)` when the
-- invocation fails** (non-zero exit, unparseable JSON, or `vim.system`
-- throwing because glab is missing). Callers clear their in-flight guards
-- in the callback and treat `nil` as "notify already shown, do nothing".
-- Without this, a single failure would leave `state.inflight[buf]` set
-- forever and permanently freeze the view.
--
-- Phase 2 added `ci_get` for the native pipeline detail view.
-- Phase 3 added an optional `ref` argument to `ci_list` for the
-- branch filter.
-- Phase 4 adds `ci_trace`, a streaming wrapper around `glab ci trace
-- <job-id>` that returns the underlying `vim.system` handle so callers
-- can cancel a live stream. See PLAN-glab-nativization.md §5 / §10 / §11.
local M = {}

local util = require 'glab-ci.util'

-- `vim.json.decode` maps JSON `null` to `vim.NIL` (a userdata sentinel),
-- not Lua `nil`. The rest of the codebase assumes optional fields are
-- `nil` (`job.started_at and ...`, `if not iso then return nil end`), so a
-- null timestamp such as `started_at` on a skipped job reaches string ops
-- as userdata and crashes (`iso:match` -> E5108 "attempt to index local
-- 'iso' (a userdata value)"). Recursively normalize every `vim.NIL` in a
-- decoded tree to nil at the decode boundary so consumers never see it.
local function denil(v)
  if v == vim.NIL then
    return nil
  end
  if type(v) == 'table' then
    for k, val in pairs(v) do
      v[k] = denil(val)
    end
  end
  return v
end

-- Spawn `cmd` via vim.system; on a synchronous spawn failure (glab
-- missing from PATH -> vim.system throws ENOENT, review 4.1) route the
-- error through the wrapper's standard failure path: notify + `cb(nil)`.
-- Returns the vim.system handle on success, nil on spawn failure.
local function spawn(cmd, opts, label, cb)
  local ok, handle = pcall(vim.system, cmd, opts, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        util.notify_failed(label, obj.code, obj.stderr)
        if cb then
          cb(nil)
        end
      end)
      return
    end
    if cb then
      vim.schedule(function()
        cb(obj)
      end)
    end
  end)
  if not ok then
    -- `handle` is the error text here (e.g. "vim/_core/system:324:
    -- ENOENT: no such file or directory (cmd): 'glab'").
    vim.schedule(function()
      util.notify_failed(label, nil, handle)
      if cb then
        cb(nil)
      end
    end)
    return nil
  end
  return handle
end

-- Run `glab ci list -F json [-r <ref>]` and call `cb(pipelines)` on success.
-- `cb(nil)` on failure (notify already shown). `ref` is optional — when
-- truthy, `-r <ref>` is added to the invocation (Phase 3 branch filter).
function M.ci_list(cb, ref)
  local args = { 'glab', 'ci', 'list', '-F', 'json' }
  if ref and ref ~= '' then
    table.insert(args, '-r')
    table.insert(args, ref)
  end
  spawn(args, { text = true }, 'ci list', function(obj)
    if obj == nil then
      if cb then
        cb(nil)
      end
      return
    end
    if not obj.stdout or obj.stdout == '' then
      if cb then
        cb {}
      end
      return
    end
    local ok, data = pcall(vim.json.decode, obj.stdout)
    if not ok or type(data) ~= 'table' then
      vim.notify('glab: invalid JSON response: ' .. util.truncate(obj.stdout, 200), vim.log.levels.ERROR, { title = 'glab' })
      if cb then
        cb(nil)
      end
      return
    end
    if cb then
      cb(denil(data))
    end
  end)
end

-- Run `glab ci get -p <id> -d -F json` and call `cb(pipeline)` on success.
-- `cb(nil)` on failure (notify already shown).
-- `pipeline` is the decoded top-level object (id, iid, status, source, ref,
-- sha, created_at, started_at, finished_at, duration, jobs, …). `jobs` may
-- be nil/empty when the pipeline has no `.gitlab-ci.yml` jobs.
function M.ci_get(pipeline_id, cb)
  local args = { 'glab', 'ci', 'get', '-p', tostring(pipeline_id), '-d', '-F', 'json' }
  spawn(args, { text = true }, 'ci get', function(obj)
    if obj == nil then
      if cb then
        cb(nil)
      end
      return
    end
    local ok, data = pcall(vim.json.decode, obj.stdout or '')
    if not ok or type(data) ~= 'table' then
      vim.notify('glab: invalid JSON response: ' .. util.truncate(obj.stdout, 200), vim.log.levels.ERROR, { title = 'glab' })
      if cb then
        cb(nil)
      end
      return
    end
    if cb then
      cb(denil(data))
    end
  end)
end

-- Run `glab ci trace <job-id>`. The wrapper streams stdout chunks via
-- a per-chunk handler (Neovim's `vim.system` `stdout` field — *not*
-- the deprecated `on_stdout` which silently stopped firing in 0.12).
-- Each chunk arrives in `on_stdout_chunk(err, data)` (err first, data
-- second). Wrapped with `vim.schedule_wrap` because the underlying
-- callback runs on a fast-event context (libuv stream handler), not
-- the main loop, so callers can safely touch buffers / api state
-- without `vim.schedule` themselves.
--
-- The returned `vim.system` handle is killable (call `:kill(15)` to
-- stop the trace). `on_exit(obj)` fires when the process exits;
-- `obj.code` and `obj.signal` describe how. On a spawn failure (glab
-- missing) `on_exit` still fires with `{ code = -1 }` so callers'
-- cleanup paths run — see the error contract above.
--
-- `glab ci trace` is a single invocation for both finished and running
-- jobs: it dumps the full log on stdout and (for running jobs) keeps
-- the stream open until the job leaves `running`/`pending`. The
-- behavior is identical; the caller just decides whether to follow.
function M.ci_trace(job_id, on_stdout_chunk, on_exit)
  local args = { 'glab', 'ci', 'trace', tostring(job_id) }
  -- No custom `stderr` handler: vim.system collects stderr into
  -- `obj.stderr` (it is *nil* when a custom handler is provided — the
  -- no-op handler previously made the on-exit error notify dead code,
  -- review 4.2). Trace stderr is tiny — error messages only.
  local ok, handle = pcall(vim.system, args, {
    text = true,
    stdout = vim.schedule_wrap(function(err, data)
      if err then
        return
      end
      on_stdout_chunk(err, data)
    end),
  }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        util.notify_failed('ci trace', obj.code, obj.stderr)
      end
      if on_exit then
        on_exit(obj)
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      util.notify_failed('ci trace', nil, handle)
      if on_exit then
        on_exit { code = -1, signal = 0 }
      end
    end)
    return nil
  end
  return handle
end

return M
