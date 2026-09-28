-- Lossless YAML emission, yq v4 parsing and complete-document reconciliation.
local M = {}
M.fields = {
  'owner',
  'key',
  'original_environment_scope',
  'environment_scope',
  'description',
  'variable_type',
  'protected',
  'masked',
  'hidden',
  'raw',
  'trailing_newlines',
  'value',
}
local allowed = {}
for _, f in ipairs(M.fields) do
  allowed[f] = true
end
local editable = { 'environment_scope', 'description', 'value', 'variable_type', 'protected', 'masked', 'raw' }
local function scalar(v)
  if v == nil or v == vim.NIL then
    return 'null'
  end
  return vim.json.encode(v)
end

function M.from_api(owner, r)
  return {
    owner = owner.kind == 'project' and 'project' or owner.path,
    key = r.key,
    original_environment_scope = r.environment_scope or '*',
    environment_scope = r.environment_scope or '*',
    description = r.description == nil and vim.NIL or r.description,
    value = type(r.value) == 'string' and r.value or vim.NIL,
    variable_type = r.variable_type == nil and vim.NIL or r.variable_type,
    protected = r.protected,
    masked = r.masked,
    hidden = r.hidden,
    raw = r.raw,
  }
end

function M.emit(entries, mode)
  local lines = { '# GlabCI ' .. mode .. ' • owner, key and original_environment_scope are read-only', 'variables:' }
  for _, entry in ipairs(entries) do
    local e = vim.deepcopy(entry)
    local value = e.value
    if type(value) == 'string' and value:find('\n', 1, true) and not value:find '[\r%z\1-\8\11-\31]' then
      local end_newlines = #(value:match '\n*$' or '')
      e.trailing_newlines = end_newlines > 0 and end_newlines or nil
      e.value = value:sub(1, #value - end_newlines)
      -- A trailing newline removed from a one-line value needs a block too.
      e._block = true
    end
    for i, field in ipairs(M.fields) do
      if not (field == 'original_environment_scope' and mode == 'create') and (field ~= 'trailing_newlines' or e.trailing_newlines) then
        local prefix = i == 1 and '  - ' or '    '
        if field == 'value' and e._block then
          lines[#lines + 1] = prefix .. 'value: |-'
          for part in (e.value .. '\n'):gmatch '(.-)\n' do
            lines[#lines + 1] = '      ' .. part
          end
        else
          lines[#lines + 1] = prefix .. field .. ': ' .. scalar(e[field])
        end
      end
    end
  end
  return lines
end

function M.parse(lines, cb)
  local ok = pcall(vim.system, { 'yq', 'eval', '-o=json', '.', '-' }, { text = true, stdin = table.concat(lines, '\n') .. '\n' }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        return cb(nil, 'Invalid YAML (check syntax and indentation)') -- stderr may quote secrets
      end
      local decoded, doc = pcall(vim.json.decode, obj.stdout or '')
      if not decoded then
        return cb(nil, 'Invalid YAML document')
      end
      cb(doc)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(nil, 'yq v4 is required to edit variables')
    end)
  end
end

local function id(e)
  return vim.json.encode { e.owner, e.key, e.original_environment_scope }
end
M.identity = id
local function same(a, b)
  return vim.deep_equal(a == nil and vim.NIL or a, b == nil and vim.NIL or b)
end
function M.reconcile(doc, originals, mode, owner, applied)
  if type(doc) ~= 'table' or not vim.islist(doc.variables) or #vim.tbl_keys(doc) ~= 1 then
    return nil, 'Expected only a top-level variables: sequence'
  end
  if mode == 'create' and #doc.variables ~= 1 then
    return nil, 'Create exactly one variable'
  end
  local indexed = {}
  for _, e in ipairs(originals) do
    indexed[id(e)] = e
  end
  local seen, destinations, changes = {}, {}, {}
  for _, e in ipairs(doc.variables) do
    if type(e) ~= 'table' then
      return nil, 'Each variable must be a mapping'
    end
    for field in pairs(e) do
      if not allowed[field] then
        return nil, 'Unknown field: ' .. tostring(field)
      end
    end
    local original = indexed[id(e)]
    if mode ~= 'create' and not original then
      return nil, 'Unknown or changed identity (owner/key/original_environment_scope); use % to create'
    end
    -- Keep matching against the immutable YAML identity, while comparing
    -- with the most recently applied version after a partial E failure.
    original = (applied and applied[id(e)]) or original
    if mode == 'create' and (e.original_environment_scope ~= nil or e.owner ~= owner) then
      return nil, 'Create owner is fixed; omit original_environment_scope'
    end
    if
      type(e.owner) ~= 'string'
      or type(e.key) ~= 'string'
      or not e.key:match '^[%w_]+$'
      or #e.key > 255
      or type(e.environment_scope) ~= 'string'
      or e.environment_scope == ''
    then
      return nil, 'Invalid owner, key or environment_scope'
    end
    if e.environment_scope:find '[\r\n%z]' then
      return nil, 'Invalid environment_scope'
    end
    if type(e.description) == 'string' and #e.description > 255 then
      return nil, 'Description exceeds 255 bytes'
    end
    if
      (type(e.description) ~= 'string' and e.description ~= vim.NIL)
      or (type(e.value) ~= 'string' and e.value ~= vim.NIL)
      or (e.variable_type ~= 'env_var' and e.variable_type ~= 'file' and e.variable_type ~= vim.NIL)
    then
      return nil, 'description/value/variable_type has the wrong type'
    end
    for _, field in ipairs { 'protected', 'masked', 'raw', 'hidden' } do
      if type(e[field]) ~= 'boolean' and e[field] ~= vim.NIL then
        return nil, field .. ' must be a boolean or null'
      end
    end
    if e.trailing_newlines ~= nil then
      if type(e.trailing_newlines) ~= 'number' or e.trailing_newlines < 1 or e.trailing_newlines % 1 ~= 0 or type(e.value) ~= 'string' then
        return nil, 'trailing_newlines must be a positive integer with a string value'
      end
      e.value = e.value .. string.rep('\n', e.trailing_newlines)
      e.trailing_newlines = nil
    end
    if e.masked == true and type(e.value) == 'string' and (e.value:find '\n' or #e.value < 8 or e.value:find '[ %z\r]') then
      return nil, 'Masked value does not meet GitLab masking constraints'
    end
    if original and not same(e.hidden, original.hidden) then
      return nil, 'hidden cannot be changed after creation'
    end
    if original then
      for _, field in ipairs { 'protected', 'masked', 'raw', 'description', 'variable_type' } do
        if e[field] == vim.NIL and not same(e[field], original[field]) then
          return nil, field .. ' is unavailable; supply an explicit boolean'
        end
      end
    elseif e.value == vim.NIL or e.variable_type == vim.NIL or e.description == vim.NIL then
      return nil, 'New variable requires a value, description and variable_type'
    elseif e.hidden == true and e.masked ~= true then
      return nil, 'Hidden variables must also be masked'
    end
    local identity = id(e)
    if seen[identity] then
      return nil, 'Duplicate original identity: ' .. e.key
    end
    seen[identity] = true
    local dest = vim.json.encode { e.owner, e.key, e.environment_scope }
    if destinations[dest] then
      return nil, 'Duplicate destination scope: ' .. e.key
    end
    destinations[dest] = true
    if mode == 'create' then
      changes[#changes + 1] = { new = e }
    else
      local changed = false
      for _, field in ipairs(editable) do
        if not same(e[field], original[field]) then
          changed = true
        end
      end
      if changed then
        if e.value == vim.NIL then
          return nil, 'Value unavailable: enter an explicit value before updating ' .. e.key
        end
        changes[#changes + 1] = { old = original, new = e }
      end
    end
  end
  for _, original in ipairs(originals) do
    if not seen[id(original)] then
      return nil, 'Missing existing entry: ' .. original.key .. ' (delete with D only)', original
    end
  end
  return changes
end

function M.body(e, create)
  local body = {}
  for _, field in ipairs { 'key', 'environment_scope', 'description', 'value', 'variable_type', 'protected', 'masked', 'raw' } do
    if e[field] ~= vim.NIL and e[field] ~= nil then
      body[field] = e[field]
    end
  end
  if create and e.hidden == true then
    body.masked_and_hidden = true
  end
  return body
end
return M
