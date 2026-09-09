local h = require 'helpers'

return {
  {
    name = 'plugin registers GlabCI and opens a mocked pipeline list',
    run = function()
      vim.cmd 'runtime plugin/glab-ci.lua'
      local command = vim.api.nvim_get_commands({}).GlabCI
      h.truthy(command)
      h.eq('*', command.nargs)

      local state = require 'glab-ci.state'
      h.with_system(function(cmd, _, callback)
        h.eq({ 'glab', 'ci', 'list', '-F', 'json' }, cmd)
        callback { code = 0, stdout = '[]', stderr = '' }
        return {}
      end, function()
        vim.cmd 'GlabCI'
        h.wait_until(function()
          return state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf)
        end)
      end)

      h.eq('glab-ci-list', vim.bo[state.list_buf].filetype)
      vim.api.nvim_buf_delete(state.list_buf, { force = true })
      h.wait_until(function()
        return not state.layout_open
      end)
    end,
  },
}
