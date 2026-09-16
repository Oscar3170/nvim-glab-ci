local h = require 'helpers'
local state = require 'glab-ci.state'
local log_view = require 'glab-ci.views.log'
local glab = require 'glab-ci.glab'

return {
  {
    name = 'log winbar renders in and restores the shared panel window',
    run = function()
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_create_buf(false, true)
      local old_buf = vim.api.nvim_get_current_buf()
      local old_winbar = vim.wo[win].winbar
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].winbar = 'original winbar'
      state.list_win = win
      state.log_buf = buf
      state.log_winbar_saved = true
      state.log_previous_winbar = 'original winbar'
      state.job_id = 7
      state._job_name = 'deploy'
      state.log_status = 'running'
      state.log_follow = true

      log_view.render_winbar()
      h.truthy(vim.wo[win].winbar:find('GlabLogWinbarRunning', 1, true))
      log_view.restore_winbar()
      h.eq('original winbar', vim.wo[win].winbar)

      vim.api.nvim_win_set_buf(win, old_buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.wo[win].winbar = old_winbar
      state.list_win = nil
      state.log_buf = nil
      state.log_previous_winbar = nil
      state.log_winbar_saved = false
      state.log_follow = false
    end,
  },
  {
    name = 'log resize autocmd count stays constant across log buffers',
    run = function()
      local win = vim.api.nvim_get_current_win()
      local old_buf = vim.api.nvim_get_current_buf()
      local original_trace = glab.ci_trace
      glab.ci_trace = function()
        return { kill = function() end }
      end
      local function count_resize_handlers(event)
        return #vim.api.nvim_get_autocmds { group = 'GlabCI', event = event }
      end
      local baseline_win = count_resize_handlers 'WinResized'
      local baseline_vim = count_resize_handlers 'VimResized'
      -- Another test may already have opened a log; handlers are global and
      -- deliberately installed once, so opening this test's first buffer
      -- either creates the one handler or reuses the existing one.
      local expected_win = baseline_win == 0 and 1 or baseline_win
      local expected_vim = baseline_vim == 0 and 1 or baseline_vim

      for _ = 1, 3 do
        state.list_win = win
        log_view.open { id = 9, name = 'test', status = 'running' }
        h.eq(expected_win, count_resize_handlers 'WinResized')
        h.eq(expected_vim, count_resize_handlers 'VimResized')
        local log_buf = state.log_buf
        log_view.shutdown()
        vim.api.nvim_win_set_buf(win, old_buf)
        vim.api.nvim_buf_delete(log_buf, { force = true })
        state.reset_layout()
        h.eq(expected_win, count_resize_handlers 'WinResized')
        h.eq(expected_vim, count_resize_handlers 'VimResized')
      end
      glab.ci_trace = original_trace
    end,
  },
  {
    name = 'opening an already-visible job log focuses its window',
    run = function()
      local first_win = vim.api.nvim_get_current_win()
      local old_buf = vim.api.nvim_get_current_buf()
      local original_trace = glab.ci_trace
      local starts = 0
      glab.ci_trace = function()
        starts = starts + 1
        return { kill = function() end }
      end

      state.list_win = first_win
      log_view.open { id = 99, name = 'test', status = 'running' }
      local log_buf = state.log_buf
      h.eq('glab://ci-job-log/99', vim.api.nvim_buf_get_name(log_buf))

      vim.cmd 'botright split'
      local second_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(second_win, old_buf)
      state.list_win = second_win
      log_view.open { id = 99, name = 'test', status = 'running' }
      h.eq(first_win, vim.api.nvim_get_current_win())
      h.eq(1, starts)

      log_view.shutdown()
      vim.api.nvim_win_set_buf(first_win, old_buf)
      vim.api.nvim_win_close(second_win, true)
      vim.api.nvim_buf_delete(log_buf, { force = true })
      state.list_win = nil
      state.reset_layout()
      glab.ci_trace = original_trace
    end,
  },
  {
    name = 'first streamed trace record replaces the loading placeholder at line one',
    run = function()
      local win = vim.api.nvim_get_current_win()
      local old_buf = vim.api.nvim_get_current_buf()
      local original_trace = glab.ci_trace
      local old_local_tz = state.log_ts.local_tz
      state.log_ts.local_tz = false
      local stdout
      glab.ci_trace = function(_, on_stdout)
        stdout = on_stdout
        return { kill = function() end }
      end
      state.list_win = win
      log_view.open { id = 9, name = 'test', status = 'running' }
      stdout(nil, '2026-08-19T19:47:08.434178Z 00O first record\n')
      h.eq('19:47:08 00O first record', vim.api.nvim_buf_get_lines(state.log_buf, 0, 1, false)[1])

      log_view.shutdown()
      glab.ci_trace = original_trace
      state.log_ts.local_tz = old_local_tz
      vim.api.nvim_win_set_buf(win, old_buf)
      vim.api.nvim_buf_delete(state.log_buf, { force = true })
      state.reset_layout()
    end,
  },
}
