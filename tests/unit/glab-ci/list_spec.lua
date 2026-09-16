local h = require 'helpers'
local state = require 'glab-ci.state'
local list_view = require 'glab-ci.views.list'

return {
  {
    name = 'pipeline list renders a current timestamp with a local offset as less than a minute ago',
    run = function()
      local win = vim.api.nvim_get_current_win()
      local old_buf = vim.api.nvim_win_get_buf(win)
      local buf = vim.api.nvim_create_buf(false, true)
      local offset = os.date '%z'
      offset = offset:sub(1, 3) .. ':' .. offset:sub(4, 5)
      local created_at = (os.date '%Y-%m-%dT%H:%M:%S') .. offset

      h.with_system(function(cmd, _, callback)
        h.eq({ 'glab', 'ci', 'list', '-F', 'json' }, cmd)
        callback {
          code = 0,
          stdout = string.format('[{"id":42,"status":"running","created_at":"%s"}]', created_at),
          stderr = '',
        }
        return {}
      end, function()
        vim.api.nvim_win_set_buf(win, buf)
        list_view.open(buf, win)
        h.wait_until(function()
          return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]:find('less than a minute ago', 1, true) ~= nil
        end)
      end)

      vim.api.nvim_win_set_buf(win, old_buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      state.list_buf = nil
      state.list_win = nil
    end,
  },
}
