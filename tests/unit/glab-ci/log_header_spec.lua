local header = require 'glab-ci.log_header'
local highlights = require 'glab-ci.highlights'
local h = require 'helpers'

local job = {
  id = 20915337,
  name = 'apply',
  stage = 'tf-apply',
  status = 'success',
  duration = 29,
  started_at = '2026-09-09T15:53:11Z',
  finished_at = '2026-09-09T15:53:40Z',
  pipeline_iid = 4,
  pipeline_ref = 'main',
  pipeline_sha = '161df7e3deadbeef',
  follow_on = false,
}

return {
  {
    name = 'log header uses the shared status glyph and composed highlight',
    run = function()
      for status, glyph in pairs(highlights.STATUS_GLYPH) do
        local rendered = header.render({ name = 'job', status = status }, 120, false, {})
        h.eq(glyph, rendered.glyph)
        h.eq('GlabLogWinbar' .. status:sub(1, 1):upper() .. status:sub(2), rendered.status_hl)
      end
    end,
  },
  {
    name = 'log header safely handles unknown status and literal percent values',
    run = function()
      local rendered = header.render({ name = '100% deploy', status = { bad = true } }, 120, false, {})
      h.eq('·', rendered.glyph)
      h.eq('GlabLogWinbarDim', rendered.status_hl)
      h.truthy(rendered.format:find('100%% deploy', 1, true))
      h.truthy(not rendered.text:find('\n', 1, true))
    end,
  },
  {
    name = 'compact header chooses useful variants at narrow widths',
    run = function()
      local wide = header.render(job, 160, false, {})
      h.truthy(wide.text:find('pipeline #4', 1, true))
      h.truthy(wide.text:find('main@161df7e3', 1, true))
      local narrow = header.render(job, 38, false, {})
      h.truthy(narrow.width <= 38)
      h.truthy(not narrow.text:find('follow off', 1, true))
      h.truthy(narrow.text:find('apply', 1, true))
    end,
  },
  {
    name = 'detailed header includes metadata and remains one display row',
    run = function()
      local wide = header.render(job, 220, true, { show_ts = true, show_date = false, prec = 's', local_tz = true })
      h.truthy(wide.text:find('job #20915337', 1, true))
      h.truthy(wide.text:find('15:53:11→15:53:40', 1, true))
      h.truthy(wide.text:find('ts s-t', 1, true))
      local narrow = header.render(job, 30, true, {})
      h.truthy(narrow.width <= 30)
      h.truthy(not narrow.text:find('\n', 1, true))
    end,
  },
  {
    name = 'log header truncates Unicode at display width without malformed format',
    run = function()
      local rendered = header.render({ name = '部署🚀部署🚀部署', stage = 'مرحلة', status = 'running', follow_on = false }, 28, false, {})
      h.truthy(rendered.width <= 28)
      h.truthy(rendered.text:find('部署', 1, true) or rendered.text:find('…', 1, true))
      h.truthy(not rendered.format:find('\n', 1, true))
    end,
  },
}
