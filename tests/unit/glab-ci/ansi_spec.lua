local ansi = require 'glab-ci.ansi'
local h = require 'helpers'

return {
  {
    name = 'ansi parser preserves SGR state across chunk boundaries',
    run = function()
      local first = ansi.parse 'plain \27[3'
      h.eq({}, first.lines)

      local second = ansi.parse('1mred\27[0m\n', first.state)
      h.eq({ 'plain red' }, second.lines)
      h.eq({ { lnum0 = 0, col_start = 6, col_end = 9, hl = 'GlabRed' } }, second.extmarks)
    end,
  },
  {
    name = 'ansi parser drops progress output and consumes OSC sequences',
    run = function()
      local parsed = ansi.parse 'progress 10%\rprogress 20%\nvisible\27]8;;https://gitlab.com\7 link\27]8;;\7\n'
      h.eq({ 'progress 20%', 'visible link' }, parsed.lines)
      h.eq({}, parsed.extmarks)
    end,
  },
}
