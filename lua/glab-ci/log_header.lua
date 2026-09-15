-- One-row, width-aware renderer for the job-log winbar.
local M = {}

local highlights = require 'glab-ci.highlights'
local util = require 'glab-ci.util'

local function text(value, fallback)
  return type(value) == 'string' and value ~= '' and value or fallback
end

function M.escape(value)
  return (text(value, ''):gsub('[\r\n]', ' '):gsub('%%', '%%%%'))
end

function M.width(value)
  return vim.fn.strdisplaywidth((value or ''):gsub('%%#.-#', ''))
end

-- Keep whole UTF-8 characters and account for double-width glyphs.
function M.truncate(value, max_width)
  value = text(value, ''):gsub('[\r\n]', ' ')
  if max_width <= 0 then
    return ''
  end
  if vim.fn.strdisplaywidth(value) <= max_width then
    return value
  end
  local ellipsis = '…'
  if max_width <= vim.fn.strdisplaywidth(ellipsis) then
    return ellipsis
  end
  local out, i = {}, 0
  while true do
    local char = vim.fn.strcharpart(value, i, 1)
    if char == '' or vim.fn.strdisplaywidth(table.concat(out) .. char .. ellipsis) > max_width then
      break
    end
    out[#out + 1] = char
    i = i + 1
  end
  return table.concat(out) .. ellipsis
end

local function time(iso)
  if type(iso) ~= 'string' then
    return nil
  end
  local parsed = util.parse_iso(iso)
  if not parsed then
    return iso
  end
  return string.format('%02d:%02d:%02d', parsed.hour, parsed.min, parsed.sec)
end

local function duration(job)
  if type(job.duration) == 'number' and job.duration > 0 then
    return util.fmt_duration(job.duration, job.status, job.started_at)
  end
  if job.started_at and not job.finished_at then
    return 'running'
  end
  return nil
end

local function ts_label(ts)
  if type(ts) ~= 'table' or not ts.show_ts then
    return 'off'
  end
  return tostring(ts.prec or 's') .. (ts.show_date and '' or '-t') .. (ts.local_tz == false and '|utc' or '')
end

local function status_info(status)
  status = text(status, 'unknown')
  local known = highlights.STATUSES[status]
  return status, highlights.STATUS_GLYPH[status] or '·', known and ('GlabLogWinbar' .. status:sub(1, 1):upper() .. status:sub(2)) or 'GlabLogWinbarDim'
end

local function segment(value, hl, key, variants)
  return { value = value, hl = hl, key = key, variants = variants or { value } }
end

local function visible(segments)
  local out = {}
  for _, s in ipairs(segments) do
    if s.value and s.value ~= '' then
      out[#out + 1] = s.value
    end
  end
  return table.concat(out, ' · ')
end

local function format(segments)
  local out = {}
  local first = true
  for _, s in ipairs(segments) do
    if s.value and s.value ~= '' then
      if not first then
        out[#out + 1] = '%#GlabLogWinbarDim# · '
      end
      out[#out + 1] = '%#' .. s.hl .. '#'
      out[#out + 1] = M.escape(s.value)
      first = false
    end
  end
  return table.concat(out)
end

local function downgrade(segments, order)
  for _, key in ipairs(order) do
    for _, s in ipairs(segments) do
      if s.key == key and s.value then
        local index = s.variant or 1
        if index < #s.variants then
          s.variant = index + 1
          s.value = s.variants[s.variant]
          return true
        end
      end
    end
  end
  return false
end

--- Render a single-line statusline format. `width` is the panel width.
--- The returned `text` deliberately excludes statusline highlight directives.
function M.render(job, width, expanded, timestamp_settings)
  job = type(job) == 'table' and job or {}
  width = math.max(1, tonumber(width) or 1)
  local status, glyph, status_hl = status_info(job.status)
  local id = job.id ~= nil and tostring(job.id) or '?'
  local name = text(job.name, 'job ' .. id)
  local stage = text(job.stage, nil)
  local iid = job.pipeline_iid or job.pipeline_id
  iid = iid ~= nil and tostring(iid) or nil
  local ref = text(job.pipeline_ref, nil)
  local sha = text(job.pipeline_sha, nil)
  if sha then
    sha = vim.fn.strcharpart(sha, 0, 8)
  end

  local segments = {
    segment(glyph .. ' ' .. status, status_hl, 'status', { glyph .. ' ' .. status, glyph }),
    segment(name, 'GlabLogWinbarTitle', 'name'),
  }
  if stage then
    segments[#segments + 1] = segment('@ ' .. stage, 'GlabLogWinbarDim', 'stage', { '@ ' .. stage, false })
  end
  local dur = duration(job)
  if dur then
    segments[#segments + 1] = segment(dur, 'GlabLogWinbarDim', 'duration', { dur, false })
  end
  if expanded and id ~= '?' then
    segments[#segments + 1] = segment('job #' .. id, 'GlabLogWinbarDim', 'job', { 'job #' .. id, false })
  end
  if iid then
    local wide = (expanded and 'pipeline #' or 'pipeline #') .. iid
    segments[#segments + 1] = segment(wide, 'GlabLogWinbarAccent', 'pipeline', { wide, '#' .. iid, false })
  end
  if ref or sha then
    local full = (ref or '?') .. (sha and '@' .. sha or '')
    segments[#segments + 1] = segment(full, 'GlabLogWinbarAccent', 'ref', { full, ref, false })
  end
  if expanded then
    local started, finished = time(job.started_at), time(job.finished_at)
    if started or finished then
      segments[#segments + 1] =
        segment((started or '—') .. '→' .. (finished or '—'), 'GlabLogWinbarDim', 'times', { (started or '—') .. '→' .. (finished or '—'), false })
    end
  end
  local follow = job.follow_on and 'follow on' or 'follow off'
  -- Follow is useful state, but trace content remains usable without it;
  -- drop it before identity and metadata when the panel gets tight.
  segments[#segments + 1] = segment(follow, job.follow_on and 'GlabLogWinbarRunning' or 'GlabLogWinbarDim', 'follow', { follow, false })
  if expanded then
    segments[#segments + 1] = segment('ts ' .. ts_label(timestamp_settings), 'GlabLogWinbarDim', 'ts', { 'ts ' .. ts_label(timestamp_settings), false })
  end

  local order = expanded and { 'follow', 'ts', 'times', 'ref', 'duration', 'stage', 'job', 'pipeline', 'status' }
    or { 'follow', 'ref', 'pipeline', 'duration', 'stage', 'status' }
  while M.width(visible(segments)) > width and downgrade(segments, order) do
    -- reduce optional fields before shortening identity
  end

  -- The job name is the only required field allowed to shrink. It is kept
  -- between status and explicit follow state even in very narrow windows.
  local fixed = 0
  for _, s in ipairs(segments) do
    if s.key ~= 'name' and s.value then
      fixed = fixed + vim.fn.strdisplaywidth(s.value)
    end
  end
  local shown = 0
  for _, s in ipairs(segments) do
    if s.value and s.value ~= '' then
      shown = shown + 1
    end
  end
  local separators = math.max(0, shown - 1) * vim.fn.strdisplaywidth ' · '
  for _, s in ipairs(segments) do
    if s.key == 'name' then
      s.value = M.truncate(s.value, math.max(1, width - fixed - separators))
      break
    end
  end

  local plain = visible(segments)
  return {
    text = plain,
    width = M.width(plain),
    format = format(segments) .. '%#GlabLogWinbar#%=',
    status = status,
    glyph = glyph,
    status_hl = status_hl,
  }
end

return M
