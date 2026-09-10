-- Small shared helpers for the GlabCI views.
--
-- Extracted (Phase 5) to remove the copy-paste that had accumulated:
-- `fmt_duration` / ISO-8601 parsing lived verbatim in 4 places, the
-- error-notify block appeared 4×, and the divider string 2×. The
-- plan's §3 concern ("keep files small") is what *created* the copies,
-- so a tiny util module is the resolution. See PLAN §16.5.
local M = {}

-- Parse an ISO 8601 timestamp (`YYYY-MM-DDTHH:MM:SS...`) into os.time-
-- compatible components. Returns nil for non-strings or non-matching
-- input, so callers can treat "no / malformed timestamp" uniformly
-- without crashing (`iso:match` on a non-string raises E5108).
function M.parse_iso(iso)
  if type(iso) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
  if not y then
    return nil
  end
  return {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    -- Both endpoints are interpreted as local time so the *difference*
    -- is correct regardless of timezone offsets in the input.
    isdst = false,
  }
end

-- Elapsed seconds since an ISO 8601 timestamp (0 when unknown).
function M.elapsed_since(iso)
  local t = M.parse_iso(iso)
  if not t then
    return 0
  end
  local then_epoch = os.time(t)
  local now_epoch = os.time(os.date '!*t')
  return math.max(0, os.difftime(now_epoch, then_epoch))
end

-- Format a job duration as `5m12s` / `42s` / `—`. Prefers `duration`
-- from the API; falls back to elapsed-since `started_at` for in-flight
-- jobs where the API value can lag (or be 0). Defensive about the shape
-- of `duration`: a decoded payload with the wrong type must not crash
-- the render callback (review 6).
function M.fmt_duration(duration, status, started_at)
  local d = type(duration) == 'number' and duration or 0
  if (not d or d == 0) and (status == 'running' or status == 'pending') then
    d = M.elapsed_since(started_at)
  end
  if not d or d <= 0 then
    return '—'
  end
  local total = math.floor(d)
  local m = math.floor(total / 60)
  local s = total % 60
  if m > 0 then
    return string.format('%dm%02ds', m, s)
  end
  return string.format('%ds', s)
end

-- Truncate long stderr/stdout in notify messages.
function M.truncate(s, n)
  s = s or ''
  if #s <= n then
    return s
  end
  return s:sub(1, n) .. '...'
end

-- One ERROR notification for a failed glab invocation, with a
-- consistent message + title across every wrapper. `code` is the
-- process exit code, or nil when the failure happened before the
-- process could run (e.g. `vim.system` threw ENOENT because glab is
-- missing) — in that case `stderr` carries the error text.
function M.notify_failed(label, code, stderr)
  local detail = (stderr or ''):gsub('%s+$', '')
  if detail == '' then
    detail = '(no error output)'
  end
  local msg = code and string.format('glab %s failed (exit %d): %s', label, code, detail) or string.format('glab %s failed: %s', label, detail)
  vim.notify(msg, vim.log.levels.ERROR, { title = 'glab' })
end

-- Clear the last message from the command-line / message area. Plain
-- `vim.notify` (no notify plugin such as nvim-notify) just echoes into the
-- message area and leaves the line there, so a "Loading…" / "Refreshing…"
-- status we showed would otherwise linger after its task finished. Per
-- `:h nvim_echo`, echoing an empty message overwrites the last one,
-- retracting it from the display. Call after the matching task completes.
function M.clear_msg()
  vim.api.nvim_echo({}, false, {})
end

-- Section divider shared by the pipeline and log views.
M.DIVIDER =
  '─────────────────────────────────────────────────────────────────'

return M
