local M = {}

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(message or string.format('expected %s, got %s', vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.truthy(value, message)
  if not value then
    error(message or 'expected a truthy value', 2)
  end
end

function M.wait_until(predicate, message, timeout)
  if not vim.wait(timeout or 500, predicate, 10) then
    error(message or 'timed out waiting for asynchronous callback', 2)
  end
end

function M.with_system(mock, fn)
  local original = vim.system
  vim.system = mock
  local ok, result = xpcall(fn, debug.traceback)
  vim.system = original
  if not ok then
    error(result, 0)
  end
  return result
end

function M.with_notify(mock, fn)
  local original = vim.notify
  vim.notify = mock
  local ok, result = xpcall(fn, debug.traceback)
  vim.notify = original
  if not ok then
    error(result, 0)
  end
  return result
end

return M
