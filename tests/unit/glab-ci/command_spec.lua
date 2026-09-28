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
  {
    name = 'q tears down a list panel without closing Neovim’s final window',
    run = function()
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

        local list_win = state.list_win
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if win ~= list_win then
            vim.api.nvim_win_close(win, true)
          end
        end
        h.eq(1, #vim.api.nvim_tabpage_list_wins(0))

        vim.api.nvim_set_current_win(list_win)
        vim.cmd 'normal q'
        h.wait_until(function()
          return not state.layout_open
        end)
        h.eq(1, #vim.api.nvim_tabpage_list_wins(0))
      end)
    end,
  },
  {
    name = 'GlabCI opens independent panels with shared list and pipeline buffers',
    run = function()
      local state = require 'glab-ci.state'
      h.with_system(function(cmd, _, callback)
        if cmd[3] == 'list' then
          h.eq({ 'glab', 'ci', 'list', '-F', 'json' }, cmd)
          callback { code = 0, stdout = '[]', stderr = '' }
        else
          h.eq({ 'glab', 'ci', 'get', '-p', '42', '-d', '-F', 'json' }, cmd)
          callback { code = 0, stdout = '{"id":42,"iid":42,"status":"running","jobs":[]}', stderr = '' }
        end
        return {}
      end, function()
        vim.cmd 'GlabCI'
        h.wait_until(function()
          return state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf)
        end)
        local first_buf, first_win = state.list_buf, state.list_win

        vim.cmd 'GlabCI'
        h.wait_until(function()
          return state.list_win ~= first_win and vim.api.nvim_buf_is_valid(state.list_buf)
        end)
        local second_buf, second_win = state.list_buf, state.list_win
        h.eq(first_buf, second_buf)
        h.eq('glab://ci-list', vim.api.nvim_buf_get_name(first_buf))
        h.truthy(first_win ~= second_win)
        h.eq(false, vim.wo[first_win].winfixheight)
        h.eq(false, vim.wo[second_win].winfixheight)

        local pipeline_view = require 'glab-ci.views.pipeline'
        state.activate(state.win_layouts[first_win])
        pipeline_view.open(42)
        local first_pipeline_buf = state.pipeline_buf
        state.activate(state.win_layouts[second_win])
        pipeline_view.open(42)
        h.eq(first_pipeline_buf, state.pipeline_buf)
        h.eq('glab://ci-pipeline/42', vim.api.nvim_buf_get_name(first_pipeline_buf))
        h.wait_until(function()
          return vim.api.nvim_win_get_buf(first_win) == first_pipeline_buf and vim.api.nvim_win_get_buf(second_win) == first_pipeline_buf
        end)

        local glab = require 'glab-ci.glab'
        local log_view = require 'glab-ci.views.log'
        local original_trace = glab.ci_trace
        glab.ci_trace = function()
          return { kill = function() end }
        end
        state.activate(state.win_layouts[first_win])
        log_view.open { id = 99, name = 'test', status = 'running', pipeline_id = 42 }
        local log_buf = state.log_buf
        state.activate(state.win_layouts[second_win])
        pipeline_view.open(42)
        h.eq(log_buf, vim.api.nvim_win_get_buf(first_win))
        glab.ci_trace = original_trace

        vim.cmd 'wincmd ='
        vim.api.nvim_win_close(first_win, true)
        vim.api.nvim_win_close(second_win, true)
        h.wait_until(function()
          return next(state.layouts) == nil
        end)
      end)
    end,
  },
}
