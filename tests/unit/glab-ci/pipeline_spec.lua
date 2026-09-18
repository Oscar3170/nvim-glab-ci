local h = require 'helpers'
local state = require 'glab-ci.state'
local init = require 'glab-ci'
local pipeline_view = require 'glab-ci.views.pipeline'
local log_view = require 'glab-ci.views.log'

local function job_line(buf, id)
  for lnum, job in pairs(state.job_ids[buf]) do
    if job.id == id then
      return lnum
    end
  end
end

return {
  {
    name = 'created jobs can be canceled and unstarted jobs cannot open logs',
    run = function()
      local cancel_cmd
      local opened_logs = {}
      local original_open = log_view.open
      log_view.open = function(job)
        opened_logs[#opened_logs + 1] = job.id
      end

      h.with_system(function(cmd, _, callback)
        if cmd[3] == 'list' then
          callback { code = 0, stdout = '[]', stderr = '' }
        elseif cmd[3] == 'get' then
          callback {
            code = 0,
            stdout = [[{
              "id":42,
              "jobs":[
                {"id":1,"stage":"deploy-long-name","name":"a deliberately long job name","status":"created","started_at":null},
                {"id":2,"stage":"build","name":"短い","status":"manual","started_at":null},
                {"id":3,"stage":"build","name":"pending","status":"pending","started_at":null},
                {"id":4,"stage":"build","name":"done","status":"success","started_at":"2026-01-01T00:00:00Z"}
              ]
            }]],
            stderr = '',
          }
        elseif cmd[3] == 'cancel' then
          cancel_cmd = cmd
          callback { code = 0, stdout = '', stderr = '' }
        else
          error('unexpected glab command: ' .. vim.inspect(cmd))
        end
        return {}
      end, function()
        init.list()
        h.wait_until(function()
          return state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf)
        end)

        pipeline_view.open(42)
        h.wait_until(function()
          return state.pipeline_buf and state.job_ids[state.pipeline_buf] and job_line(state.pipeline_buf, 4)
        end)

        local buf, win = state.pipeline_buf, state.list_win
        local function status_column(id)
          local line = vim.api.nvim_buf_get_lines(buf, job_line(buf, id) - 1, job_line(buf, id), false)[1]
          local start = assert(line:find('[', 1, true))
          return vim.fn.strdisplaywidth(line:sub(1, start - 1))
        end
        h.eq(status_column(1), status_column(2))
        h.eq(status_column(2), status_column(4))

        local open_log = vim.fn.maparg('<CR>', 'n', false, true).callback
        local cancel = vim.fn.maparg('C', 'n', false, true).callback

        for _, id in ipairs { 1, 2, 3 } do
          vim.api.nvim_win_set_cursor(win, { job_line(buf, id), 0 })
          open_log()
        end
        h.eq({}, opened_logs)

        vim.api.nvim_win_set_cursor(win, { job_line(buf, 1), 0 })
        cancel()
        h.wait_until(function()
          return cancel_cmd ~= nil
        end)
        h.eq({ 'glab', 'ci', 'cancel', 'job', '1' }, cancel_cmd)

        vim.api.nvim_win_set_cursor(win, { job_line(buf, 4), 0 })
        open_log()
        h.eq({ 4 }, opened_logs)

        vim.api.nvim_win_close(win, true)
        h.wait_until(function()
          return next(state.layouts) == nil
        end)
      end)

      log_view.open = original_open
    end,
  },
}
