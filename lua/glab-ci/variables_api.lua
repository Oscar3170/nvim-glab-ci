-- Authenticated, value-safe GitLab REST boundary. Never include secrets in argv or diagnostics.
local M = {}
local function enc(s)
  return tostring(s):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', c:byte())
  end)
end
M.encode = enc

local function request(method, path, body, cb, host)
  local args = { 'glab', 'api', path, '--method', method }
  if host then
    args[#args + 1] = '--hostname'
    args[#args + 1] = host
  end
  local opts = { text = true }
  if body then
    args[#args + 1] = '--input'
    args[#args + 1] = '-'
    opts.stdin = vim.json.encode(body)
  end
  local ok = pcall(vim.system, args, opts, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(nil, 'GitLab request failed (' .. method .. ' ' .. path:gsub('%?.*', '') .. '); check permissions, scope and GitLab tier')
        return
      end
      if method == 'DELETE' then
        cb(true)
        return
      end
      local decoded, data = pcall(vim.json.decode, result.stdout or '')
      if not decoded or type(data) ~= 'table' then
        cb(nil, 'Invalid GitLab JSON response')
      else
        cb(data)
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil, 'Cannot start glab; check installation and authentication')
    end)
  end
end
M.request = request

function M.project(cb)
  request('GET', 'projects/:id', nil, function(project, err)
    if not project then
      return cb(nil, err)
    end
    if
      (type(project.id) ~= 'number' and type(project.id) ~= 'string')
      or type(project.path_with_namespace) ~= 'string'
      or type(project.namespace) ~= 'table'
      or type(project.namespace.full_path) ~= 'string'
    then
      return cb(nil, 'Project response is missing namespace.full_path')
    end
    project.host = (project.web_url or ''):match '^https?://([^/]+)'
    if not project.host then
      return cb(nil, 'Project response is missing a valid web_url host')
    end
    cb(project)
  end)
end

function M.owners(project)
  local owners = { { kind = 'project', id = project.id, path = project.path_with_namespace, host = project.host } }
  local path = project.namespace.full_path
  if project.namespace.kind == 'user' then
    path = nil
  end
  while path and path ~= '' do
    owners[#owners + 1] = { kind = 'group', id = path, path = path, host = project.host }
    path = path:match '^(.*)/[^/]+$'
  end
  return owners
end

function M.endpoint(owner)
  return (owner.kind == 'group' and 'groups/' or 'projects/') .. enc(owner.id) .. '/variables'
end

local function scope_path(owner, key, scope)
  return M.endpoint(owner) .. '/' .. enc(key) .. '?filter%5Benvironment_scope%5D=' .. enc(scope)
end

function M.list(owner, cb)
  local all = {}
  local function page(n)
    request('GET', M.endpoint(owner) .. '?per_page=100&page=' .. n, nil, function(items, err)
      if not items then
        return cb(nil, err)
      end
      if not vim.islist(items) then
        return cb(nil, 'Invalid variable list for ' .. owner.path)
      end
      for _, item in ipairs(items) do
        if type(item) ~= 'table' or type(item.key) ~= 'string' or type(item.environment_scope) ~= 'string' then
          return cb(nil, 'Incomplete variable identity for ' .. owner.path)
        end
      end
      vim.list_extend(all, items)
      if #items == 100 then
        page(n + 1)
      else
        cb(all)
      end
    end, owner.host)
  end
  page(1)
end

function M.get(owner, key, scope, cb)
  request('GET', scope_path(owner, key, scope), nil, function(record, err)
    if record and (record.key ~= key or record.environment_scope ~= scope) then
      return cb(nil, 'Exact variable scope not found for ' .. owner.path .. '/' .. key)
    end
    cb(record, err)
  end, owner.host)
end

function M.update(owner, key, old_scope, record, cb)
  request('PUT', scope_path(owner, key, old_scope), record, cb, owner.host)
end
function M.create(owner, record, cb)
  request('POST', M.endpoint(owner), record, cb, owner.host)
end
function M.delete(owner, key, scope, cb)
  request('DELETE', scope_path(owner, key, scope), nil, cb, owner.host)
end
return M
