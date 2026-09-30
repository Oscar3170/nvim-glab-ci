local h = require 'helpers'
local M = {}
function M.keys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
end
function M.groups()
  M.keys((vim.g.mapleader or '\\') .. 'G')
end
function M.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
function M.with_panel(project, list, run)
  local api = require 'glab-ci.variables_api'
  local state = require 'glab-ci.state'
  local view = require 'glab-ci.views.variables'
  local saved = { project = api.project, list = api.list, columns = vim.o.columns, ascii = vim.g.glab_ci_ascii_icons }
  local system = vim.system
  local win, side
  api.project = function(cb)
    cb(project)
  end
  api.list = list
  vim.g.glab_ci_ascii_icons = true
  local ok, err = xpcall(function()
    h.with_system(function(cmd, opts, cb)
      if cmd[1] ~= 'glab' then
        return system(cmd, opts, cb)
      end
      cb { code = 0, stdout = '[]' }
      return {}
    end, function()
      h.wait_until(function()
        return next(state.layouts) == nil and vim.fn.bufnr 'glab://ci-list' == -1
      end)
      vim.o.columns = 180
      vim.cmd 'GlabCI'
      win = state.list_win
      vim.cmd 'normal v'
      local buf = vim.api.nvim_win_get_buf(win)
      vim.cmd 'vnew'
      side = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(win)
      vim.wo[win].number = false
      vim.wo[win].relativenumber = false
      vim.wo[win].signcolumn = 'no'
      vim.wo[win].foldcolumn = '0'
      run(win, buf, function(width)
        vim.api.nvim_win_set_width(win, width)
        vim.api.nvim_exec_autocmds('WinResized', {})
        h.eq(width, vim.api.nvim_win_get_width(win))
        return math.max(1, width - vim.fn.getwininfo(win)[1].textoff - 1)
      end)
    end)
  end, debug.traceback)
  if win and vim.api.nvim_win_is_valid(win) then
    view.shutdown(state.win_layouts[win])
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  if side and vim.api.nvim_win_is_valid(side) then
    vim.api.nvim_win_close(side, true)
  end
  api.project, api.list = saved.project, saved.list
  vim.o.columns, vim.g.glab_ci_ascii_icons = saved.columns, saved.ascii
  if not ok then
    error(err, 0)
  end
  h.wait_until(function()
    return next(state.layouts) == nil and vim.fn.bufnr 'glab://ci-list' == -1
  end)
end
return M
