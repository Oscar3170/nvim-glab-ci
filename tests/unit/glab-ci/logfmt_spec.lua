local logfmt = require 'glab-ci.logfmt'
local h = require 'helpers'

return {
  {
    name = 'log formatter parses a GitLab trace prefix',
    run = function()
      local line = '2026-08-19T19:47:08.434178Z 00O Running with gitlab-runner'
      local rec, prefix = logfmt.parse_line(line)

      h.eq('00', rec.stream)
      h.eq('O', rec.typ)
      h.eq(nil, rec.border)
      h.eq('Running with gitlab-runner', rec.content)
      h.eq(#'2026-08-19T19:47:08.434178Z 00O ', prefix)
    end,
  },
  {
    name = 'log formatter keeps section borders and formats timestamps',
    run = function()
      local rec = assert(logfmt.parse_line '2026-08-19T19:47:08.434178Z 00O+section content')
      h.eq('+', rec.border)
      h.eq('section content', rec.content)
      h.eq('2026-08-19 19:47:08.434', logfmt.fmt_timestamp(rec.ts, { show = true, date = true, prec = 'ms', local_tz = false }))
      h.eq(nil, logfmt.fmt_timestamp(rec.ts, { show = false }))
    end,
  },
}
