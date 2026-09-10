local glab = require 'glab-ci.glab'
local h = require 'helpers'

return {
  {
    name = 'ci_list decodes mocked glab JSON and normalizes null fields',
    run = function()
      local received
      h.with_system(function(cmd, _, callback)
        h.eq({ 'glab', 'ci', 'list', '-F', 'json', '-r', 'main' }, cmd)
        callback { code = 0, stdout = '[{"id": 42, "status": "success", "created_at": null}]', stderr = '' }
        return {}
      end, function()
        glab.ci_list(function(pipelines)
          received = pipelines
        end, 'main')
        h.wait_until(function()
          return received ~= nil
        end)
      end)

      h.eq(42, received[1].id)
      h.eq('success', received[1].status)
      h.eq(nil, received[1].created_at)
    end,
  },
  {
    name = 'ci_get reports a mocked command failure through a nil callback result',
    run = function()
      local received = 'pending'
      local notification
      h.with_notify(function(message)
        notification = message
      end, function()
        h.with_system(function(cmd, _, callback)
          h.eq({ 'glab', 'ci', 'get', '-p', '42', '-d', '-F', 'json' }, cmd)
          callback { code = 1, stdout = '', stderr = 'not found' }
          return {}
        end, function()
          glab.ci_get(42, function(pipeline)
            received = pipeline
          end)
          h.wait_until(function()
            return received == nil
          end)
        end)
      end)

      h.eq(nil, received)
      h.truthy(notification:match 'glab ci get failed')
    end,
  },
  {
    name = 'failure notify keeps the full stderr (no 200-char truncation)',
    run = function()
      -- glab/GitLab errors put the actionable part after a long URL, so the
      -- tail must survive into the notification (:messages shows it all).
      local tail = '": dial tcp: lookup gitlab.example.com: i/o timeout'
      local long_stderr = 'Get "https://gitlab.example.com/api/v4/projects/' .. string.rep('a', 300) .. tail
      local notification
      h.with_notify(function(message)
        notification = message
      end, function()
        h.with_system(function(_, _, callback)
          callback { code = 1, stdout = '', stderr = long_stderr }
          return {}
        end, function()
          glab.ci_list(function() end)
          h.wait_until(function()
            return notification ~= nil
          end)
        end)
      end)

      h.truthy(notification:find(long_stderr, 1, true), 'notification should contain the full stderr')
      h.truthy(notification:sub(-#tail) == tail, 'notification should end with the stderr tail')
    end,
  },
}
