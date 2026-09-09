-- GitLab job-log line prefix parsing + timestamp formatting.
--
-- `glab ci trace` emits raw GitLab traces, where each line carries a
-- machine-generated prefix before the actual log message:
--
--   2026-08-19T19:47:08.434178Z 00O Running with gitlab-runner ...
--   2026-08-19T19:47:09.112002Z 01E fatal: unable to access ...
--   2026-08-19T19:47:10.182919Z 00O+Executing "step_script" stage ...
--
-- Prefix anatomy (left to right):
--   * timestamp  -- ISO-8601 UTC, `YYYY-MM-DDTHH:MM:SS[.ffffff]Z`
--                  (GitLab emits microsecond precision; `Z` = UTC).
--   * a space.
--   * stream     -- two-digit stream index (`00` = job-control writer,
--                  `01`+ = the runner's script channels).
--   * type       -- `O` (stdout) or `E` (stderr) for that stream.
--   * border     -- GitLab prefixes lines inside a collapsible section with
--                  a `+` immediately after the type (no separator space).
--                  Absent for normal lines.
--   * separator  -- one space (only when there's no `+` border).
--   * content    -- the actual log message. Leading whitespace is part of
--                  the content and is preserved.
--
-- This module only handles the *pure* transform of a single line: split off
-- the prefix, and reformat the timestamp per the user's display config. The
-- view (`views/log.lua`) calls `parse_line` while appending streamed chunks
-- and `fmt_timestamp` when rendering / re-rendering, and it maps the parsed
-- fields onto extmark highlights (the whole indicator token colored, `00`
-- content light grey).
--
-- Kept dependency-free of Neovim so it's trivially smoke-testable.
local M = {}

-- Split the machine prefix off one raw trace line.
--
-- Returns `rec` (a record of the parsed prefix) plus the byte length of the
-- consumed prefix, or `(nil, 0)` when the line has no such prefix (plain
-- output, or a line `ansi.lua` already collapsed). `rec` shape:
--   ts        { year, month, day, hour, min, sec, frac?, is_utc }
--   stream    two-digit string e.g. "00"
--   typ       "O" | "E"
--   border    "+" for collapsible-section lines, else nil
--   content   the message after the prefix (leading whitespace preserved)
-- The byte prefix length lets the view re-base per-content ANSI extmarks
-- (which the ANSI parser produced relative to the whole raw line).
function M.parse_line(line)
  if type(line) ~= 'string' then
    return nil, 0
  end
  -- First token = timestamp; `rest` = indicator + content. Split into small
  -- matches (Lua patterns cap out at 9 captures) rather than one giant one.
  local ts_part, rest = line:match '^(%S+)%s+(.+)$'
  if not ts_part then
    return nil, 0
  end
  local stream, typ, border = rest:match '^(%d%d)([OE])([+]?)'
  if not stream then
    return nil, 0
  end
  -- `ts_part` looks like `YYYY-MM-DDTHH:MM:SS[.fffff]Z?` (GitLab: UTC `Z`).
  local y, mo, d, h, mi, s, frac, tz = ts_part:match '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)(Z?)$'
  if not y then
    return nil, 0
  end
  -- `after` = stream + type stripped; it begins with the `+` border (already
  -- consumed above) or the single separator space. Content keeps all its
  -- leading whitespace: we drop exactly one separator space (non-border
  -- lines only) and keep the rest verbatim.
  local after = rest:sub(#stream + #typ + 1)
  local content
  if border and border ~= '' then
    content = after:sub(2) -- strip the '+'; no separator space on such lines
  else
    content = after
    if content:sub(1, 1) == ' ' then
      content = content:sub(2) -- drop the single separator space
    end
  end
  return {
    ts = {
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = tonumber(h),
      min = tonumber(mi),
      sec = tonumber(s),
      frac = (frac ~= '') and frac or nil, -- fractional seconds, without '.'
      is_utc = tz == 'Z',
    },
    stream = stream,
    typ = typ,
    border = (border ~= '') and border or nil,
    content = content,
  },
    #line - #content
end

-- Convert a UTC time table to the machine's local time, moment-preserving.
-- `os.time` interprets a table as *local* time, so feeding raw UTC fields
-- through it yields a wrong epoch; correct for the local↔UTC offset the
-- naive lookup implies. `utc.isdst` is fixed false to avoid DST flicker at
-- the boundary; good enough for log display.
local function utc_to_local(y, mo, d, h, mi, s)
  local naive = os.time { year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }
  local off = os.difftime(naive, os.time(os.date('!*t', naive)))
  return os.date('*t', naive + off)
end

-- Format a parsed `ts` record per the display config `cfg`:
--   cfg.show      -- nil/false hides the timestamp entirely
--   cfg.date      -- include the date part
--   cfg.prec      -- 's' | 'ms' | 'us' time precision
--   cfg.local_tz  -- true = convert UTC (`Z`) timestamps to system tz;
--                   false = keep raw (UTC) components
-- Returns the display string, or nil when the timestamp is hidden.
function M.fmt_timestamp(ts, cfg)
  if not ts or not cfg.show then
    return nil
  end
  local y, mo, d, h, mi, s = ts.year, ts.month, ts.day, ts.hour, ts.min, ts.sec
  if cfg.local_tz and ts.is_utc then
    local t = utc_to_local(y, mo, d, h, mi, s)
    y, mo, d, h, mi, s = t.year, t.month, t.day, t.hour, t.min, t.sec
  end
  local parts = {}
  if cfg.date then
    parts[#parts + 1] = string.format('%04d-%02d-%02d', y, mo, d)
  end
  local time = string.format('%02d:%02d:%02d', h, mi, s)
  if cfg.prec ~= 's' and ts.frac and tonumber(ts.frac) and tonumber(ts.frac) > 0 then
    local digits = cfg.prec == 'ms' and 3 or 6
    local f = ts.frac:sub(1, digits)
    while #f < digits do
      f = f .. '0'
    end
    time = time .. '.' .. f
  end
  parts[#parts + 1] = time
  return table.concat(parts, ' ')
end

return M
