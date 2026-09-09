local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':h:h')
vim.opt.runtimepath:prepend(root)
package.path = root .. '/tests/?.lua;' .. package.path

local failures = {}
local test_count = 0
local specs = vim.fn.globpath(root .. '/tests/unit', '**/*_spec.lua', false, true)
table.sort(specs)

for _, path in ipairs(specs) do
  local suite = assert(loadfile(path))()
  for _, test in ipairs(suite) do
    test_count = test_count + 1
    local ok, err = xpcall(test.run, debug.traceback)
    if ok then
      print(string.format('ok - %s', test.name))
    else
      failures[#failures + 1] = string.format('not ok - %s\n%s', test.name, err)
    end
  end
end

if #failures > 0 then
  error(table.concat(failures, '\n\n'), 0)
end

print(string.format('%d mocked unit tests passed', test_count))
