local M = {}
local state = require 'glab-ci.state'
local api = require 'glab-ci.variables_api'
local yaml = require 'glab-ci.variables_yaml'
local ns = vim.api.nvim_create_namespace 'glab_ci_variables'
local sessions = {} -- private, per-layout; discarded on exit from variables view
local journal = {} -- session only, at most three snapshots per identity
local function valid(b)
  return b and vim.api.nvim_buf_is_valid(b)
end
local function live(s)
  return s and not s.dead and state.layouts[s.layout] and valid(s.buf) and vim.api.nvim_win_is_valid(s.win)
end
local function warn(s, msg)
  if live(s) then
    s.error = msg
    M.render(s)
    vim.notify('glab variables: ' .. msg, vim.log.levels.ERROR)
  end
end
local function clean(text)
  return (type(text) == 'string' and text or ''):gsub('[%c\27]', ' ')
end
-- LuaJIT in Neovim has no utf8 library: iterate UTF-8 sequences instead.
local function shorten(text, width)
  text = clean(text)
  if width < 1 then
    return ''
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local out = ''
  for c in text:gmatch '[%z\1-\127\194-\244][\128-\191]*' do
    if vim.fn.strdisplaywidth(out .. c) >= width then
      break
    end
    out = out .. c
  end
  return out .. '…'
end
local function pad(text, width)
  text = shorten(text, width)
  return text .. string.rep(' ', math.max(0, width - vim.fn.strdisplaywidth(text)))
end
local function label(r)
  return r.owner.path .. ' / ' .. r.key .. ' [' .. (r.environment_scope or '*') .. ']'
end
local function identity(r)
  return vim.json.encode { r.owner.host, r.owner.kind, r.owner.id, r.key, r.environment_scope }
end
local function selected(s)
  return s.rows[vim.api.nvim_win_get_cursor(s.win)[1]]
end
local function header(s)
  if not live(s) then
    return
  end
  local title = 'CI Variables  ' .. (s.project and s.project.path_with_namespace or 'project')
  if s.groups then
    title = title .. '  + groups'
  end
  if s.loading then
    title = title .. '  loading…'
  elseif s.error then
    title = title .. '  ! error'
  end
  title = shorten(title, math.max(1, vim.api.nvim_win_get_width(s.win) - 2))
  vim.wo[s.win].winbar = '%#GlabLogWinbarTitle# ' .. title:gsub('%%', '%%%%') .. ' '
end
function M.render(s)
  if not live(s) then
    return
  end
  local info = vim.fn.getwininfo(s.win)[1]
  local width = math.max(1, vim.api.nvim_win_get_width(s.win) - (info and info.textoff or 0) - 1)
  local cursor = vim.api.nvim_win_get_cursor(s.win)
  local old = s.rows[cursor[1]]
  local target = s.selection or (old and identity(old))
  local lines = {}
  if s.error then
    lines[#lines + 1] = shorten(' ! ' .. s.error, width)
  end
  local rows, marks, landing = {}, {}, nil
  for index, owner in ipairs(s.owners or {}) do
    if index == 1 or s.groups then
      -- The winbar already names the project. Only ancestors need a small
      -- path label to distinguish duplicate keys owned by different groups.
      if owner.kind == 'group' then
        lines[#lines + 1] = shorten(clean(owner.path), width)
        marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], 'GlabVarGroup' }
      end
      local entries = s.entries[owner.path] or {}
      if s.owner_errors and s.owner_errors[owner.path] then
        lines[#lines + 1] = shorten('   ! ' .. s.owner_errors[owner.path], width)
      elseif #entries == 0 then
        lines[#lines + 1] = '   (no variables)'
      end
      for _, r in ipairs(entries) do
        local line_no = #lines + 1
        rows[line_no] = r
        if identity(r) == target then
          landing = line_no
        end
        local keyw = math.min(24, math.max(3, math.floor(width * 0.26)))
        local scopew = math.min(18, math.max(1, math.floor(width * 0.16)))
        local descw = width >= 50 and math.min(28, math.floor(width * 0.20)) or 0
        local ascii = vim.g.glab_ci_ascii_icons == true
        local icons = (r.variable_type == 'file' and (ascii and 'F' or '󰈔') or ' ')
          .. (r.protected == true and (ascii and 'P' or '󰌾') or ' ')
          .. (r.hidden == true and (ascii and 'H' or '󰈉') or r.masked == true and (ascii and 'M' or '󰈉') or ' ')
        local prefix = pad(r.key, keyw)
        marks[#marks + 1] = { line_no - 1, 0, #shorten(r.key, keyw), 'GlabVarKey' }
        if width >= 22 then
          prefix = prefix .. ' '
          local at = #prefix
          prefix = prefix .. icons
          for _, icon in ipairs {
            { r.variable_type == 'file', ascii and 'F' or '󰈔', 'GlabVarIcon' },
            { r.protected == true, ascii and 'P' or '󰌾', 'GlabVarIcon' },
            {
              r.hidden == true or r.masked == true,
              ascii and (r.hidden == true and 'H' or 'M') or '󰈉',
              r.hidden == true and 'GlabVarHidden' or 'GlabVarIcon',
            },
          } do
            if icon[1] then
              marks[#marks + 1] = { line_no - 1, at, at + #icon[2], icon[3] }
            end
            at = at + (icon[1] and #icon[2] or 1)
          end
        end
        prefix = prefix .. ' '
        local scope = shorten(r.environment_scope or '*', scopew)
        local scope_start = #prefix
        prefix = prefix .. pad(scope, scopew) .. ' '
        if r.environment_scope == '*' then
          marks[#marks + 1] = { line_no - 1, scope_start, scope_start + #scope, 'GlabVarScopeDefault' }
        end
        if descw > 0 then
          prefix = prefix .. pad(r.description or '', descw) .. ' '
        end
        local preview = type(r.value) ~= 'string' and 'unavailable' or (s.reveal and clean(r.value) or '••••••')
        lines[#lines + 1] = shorten(prefix .. preview, width)
        if s.expanded[identity(r)] then
          local value = type(r.value) == 'string' and r.value or 'unavailable'
          -- Only real newlines create buffer rows. Long source lines wrap
          -- visually in the window, preserving the value's logical lines.
          for part in (value .. '\n'):gmatch '(.-)\n' do
            lines[#lines + 1] = clean(part)
            rows[#lines] = r
            if #lines[#lines] > 0 then
              marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], 'GlabDim' }
            end
          end
        end
      end
      lines[#lines + 1] = ''
    end
  end
  s.rows = rows
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    local length = #lines[m[1] + 1]
    if m[2] < length then
      vim.api.nvim_buf_set_extmark(s.buf, ns, m[1], m[2], { end_col = math.min(m[3], length), hl_group = m[4] })
    end
  end
  if landing or not rows[vim.api.nvim_win_get_cursor(s.win)[1]] then
    local first = landing
    if not first then
      for i in pairs(rows) do
        if not first or i < first then
          first = i
        end
      end
    end
    if first then
      -- Expansion keeps the selected row in place. Preserve its byte column
      -- as well as its identity; only clamp when the new row is shorter.
      local col = old and identity(old) == target and cursor[2] or 0
      vim.api.nvim_win_set_cursor(s.win, { first, math.min(col, math.max(0, #lines[first] - 1)) })
    end
  end
  s.selection = nil
  header(s)
end
local function fetch(s, groups)
  if not live(s) or s.loading then
    return
  end
  s.loading = true
  s.error = nil
  M.render(s)
  local owners = groups and s.owners or { s.owners[1] }
  local entries, errors, n = {}, {}, 1
  local function next_owner()
    if not live(s) then
      return
    end
    local owner = owners[n]
    if not owner then
      s.loading = false
      for path, list in pairs(entries) do
        s.entries[path] = list
        s.owner_errors[path] = nil
      end
      s.error = #errors > 0 and table.concat(errors, '; ') or nil
      M.render(s)
      return
    end
    n = n + 1
    api.list(owner, function(items, err)
      if not live(s) then
        return
      end
      if items then
        for _, r in ipairs(items) do
          r.owner = owner
        end
        entries[owner.path] = items
      else
        s.owner_errors[owner.path] = err or 'read failed (check permissions / tier)'
        errors[#errors + 1] = owner.path .. ': ' .. s.owner_errors[owner.path]
      end
      next_owner()
    end)
  end
  next_owner()
end
local function ancestors(s, cb)
  -- Group identity comes from the project namespace; there is no group API
  -- read required to enumerate paths. Permission errors occur on list/create.
  if not s.owners then
    return cb(nil)
  end
  cb(vim.list_slice(s.owners, 2))
end
local function scratch(buf, filetype)
  vim.bo[buf].buftype = filetype == 'yaml' and 'acwrite' or 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].modeline = false
  if filetype ~= 'yaml' then
    vim.bo[buf].undolevels = -1
  end
  vim.bo[buf].filetype = filetype
end
local function wipe(buf)
  if valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end
local function diff_lines(changes)
  local lines = { 'Review variable changes (full values) • y: apply • q / <Esc>: cancel', '' }
  for _, change in ipairs(changes) do
    local a, b = change.old, change.new
    local r = b or a
    lines[#lines + 1] = '@@ '
      .. r.owner
      .. ' / '
      .. r.key
      .. '  '
      .. (a and a.environment_scope or '(new)')
      .. ' -> '
      .. (b and b.environment_scope or '(deleted)')
      .. ' @@'
    for _, field in ipairs { 'environment_scope', 'description', 'value', 'variable_type', 'protected', 'masked', 'hidden', 'raw' } do
      local before = a and a[field] or nil
      local after = b and b[field] or nil
      if not vim.deep_equal(before, after) or not a or not b then
        local function add(sign, value)
          if value == vim.NIL or value == nil then
            value = field == 'value' and 'unavailable' or 'null'
          end
          lines[#lines + 1] = sign .. ' ' .. field .. ':'
          for part in (tostring(value) .. '\n'):gmatch '(.-)\n' do
            local displayed = part:gsub('%c', function(c)
              return string.format('\\x%02X', c:byte())
            end)
            lines[#lines + 1] = sign .. ' ' .. displayed
          end
        end
        add('-', before)
        add('+', after)
      end
    end
  end
  return lines
end
local function review(s, changes, confirm, cancel)
  if not live(s) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  scratch(buf, 'diff')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, diff_lines(changes))
  vim.bo[buf].modifiable = false
  local width = math.max(20, math.min(vim.o.columns - 4, 100))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = 2,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = math.max(3, math.min(vim.o.lines - 5, 28)),
    style = 'minimal',
    border = 'rounded',
  })
  s.review = { buf = buf, win = win }
  local done = false
  local function close(yes)
    if done then
      return
    end
    done = true
    s.review = nil
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    wipe(buf)
    if live(s) then
      (yes and confirm or cancel)()
    end
  end
  vim.keymap.set('n', 'y', function()
    close(true)
  end, { buffer = buf })
  for _, key in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', key, function()
      close(false)
    end, { buffer = buf })
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    group = state.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        close(false)
      end)
    end,
  })
end
local function remote_equal(remote, snapshot)
  local a = yaml.from_api(remote.owner, remote)
  for _, field in ipairs { 'value', 'environment_scope', 'description', 'variable_type', 'protected', 'masked', 'hidden', 'raw' } do
    if not vim.deep_equal(a[field], snapshot[field]) then
      return false
    end
  end
  return true
end
local function preflight(s, owner, old, new, cb)
  if not old then
    return api.get(owner, new.key, new.environment_scope, function(found)
      if found then
        cb(nil, 'Destination already exists: ' .. new.key)
      else
        -- A GET failure can be 404 or permission denied: list instead.
        api.list(owner, function(items, err)
          if not items then
            return cb(nil, err)
          end
          for _, item in ipairs(items) do
            if item.key == new.key and item.environment_scope == new.environment_scope then
              return cb(nil, 'Destination already exists: ' .. new.key)
            end
          end
          cb(true)
        end)
      end
    end)
  end
  api.get(owner, old.key, old.environment_scope, function(remote, err)
    if not remote then
      if new then
        return api.get(owner, new.key, new.environment_scope, function(applied)
          if applied then
            applied.owner = owner
          end
          cb(applied and remote_equal(applied, new) and 'already' or nil, err or 'Original record no longer exists')
        end)
      end
      return cb(nil, err or 'Original record no longer exists')
    end
    remote.owner = owner
    if new and remote_equal(remote, new) then
      return cb 'already'
    end
    if not remote_equal(remote, old) then
      return cb(nil, 'Remote record changed: ' .. label(remote))
    end
    if new and new.environment_scope ~= old.environment_scope then
      api.list(owner, function(items, list_err)
        if not items then
          return cb(nil, list_err)
        end
        for _, item in ipairs(items) do
          if item.key == new.key and item.environment_scope == new.environment_scope then
            return cb(nil, 'Destination scope occupied: ' .. new.key)
          end
        end
        cb(true)
      end)
    else
      cb(true)
    end
  end)
end
local function journal_key(s, owner, r)
  return vim.json.encode { s.project.host, owner.kind, owner.id, r.key, r.environment_scope }
end
local function record_history(s, owner, old, new)
  if not old or type(old.value) ~= 'string' then
    return
  end
  local prior, dest = journal_key(s, owner, old), journal_key(s, owner, new)
  local history = journal[prior] or {}
  journal[prior] = nil
  history[#history + 1] = { at = os.date '%Y-%m-%d %H:%M:%S', record = vim.deepcopy(old) }
  while #history > 3 do
    table.remove(history, 1)
  end
  journal[dest] = history
end
local function run_changes(s, changes, editor, on_success)
  local owners = {}
  for _, owner in ipairs(s.owners) do
    owners[owner.kind == 'project' and 'project' or owner.path] = owner
  end
  local completed = {}
  local function fail(err)
    local message = (err or 'Request failed') .. (#completed > 0 and ('; already saved: ' .. table.concat(completed, ', ')) or '')
    if editor then
      editor.error = message
      M.reopen(s, editor)
    else
      warn(s, message)
    end
    fetch(s, s.groups)
  end
  local function step(i)
    if not live(s) then
      return
    end
    local change = changes[i]
    if not change then
      if editor then
        wipe(editor.buf)
        s.editor = nil
      end
      fetch(s, s.groups)
      if on_success then
        on_success()
      end
      return
    end
    local old, new = change.old, change.new
    local r = new or old
    local owner = owners[r.owner]
    if not owner then
      return fail('Unknown owner: ' .. r.owner)
    end
    preflight(s, owner, old, new, function(ok, err)
      if not live(s) then
        return
      end
      if not ok then
        return fail(err)
      end
      if ok == 'already' then
        return step(i + 1)
      end
      local function result(response, reason)
        if not live(s) then
          return
        end
        if not response then
          return fail(reason or ('Write failed for ' .. r.owner .. '/' .. r.key))
        end
        if old and new then
          record_history(s, owner, old, new)
          if editor then
            editor.applied[yaml.identity(new)] = vim.deepcopy(new)
          end
        end
        completed[#completed + 1] = r.owner .. '/' .. r.key .. ' [' .. r.environment_scope .. ']'
        step(i + 1)
      end
      if not new then
        api.delete(owner, old.key, old.environment_scope, result)
      elseif not old then
        api.create(owner, yaml.body(new, true), result)
      else
        api.update(owner, old.key, old.environment_scope, yaml.body(new), function(response, reason)
          if not response then
            return result(nil, reason)
          end
          if response.key ~= new.key or response.environment_scope ~= new.environment_scope then
            return result(nil, 'Update response has unexpected scope; inspect ' .. new.key)
          end
          api.get(owner, new.key, new.environment_scope, function(verified, verify_err)
            if not live(s) then
              return
            end
            if not verified then
              return fail('Update may have succeeded but verification failed for ' .. r.owner .. '/' .. r.key .. ': ' .. (verify_err or 'not found'))
            end
            verified.owner = owner
            if not remote_equal(verified, new) then
              return fail('Update may have succeeded but remote fields differ for ' .. r.owner .. '/' .. r.key)
            end
            result(response)
          end)
        end)
      end
    end)
  end
  step(1)
end
function M.reopen(s, editor)
  if not live(s) or not valid(editor.buf) then
    return
  end
  if editor.error then
    vim.bo[editor.buf].modifiable = true
    vim.api.nvim_buf_set_lines(editor.buf, 0, 0, false, { '# ' .. clean(editor.error) })
    editor.error = nil
  end
  vim.api.nvim_set_current_win(s.win)
  vim.cmd 'belowright split'
  editor.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(editor.win, editor.buf)
  vim.wo[editor.win].wrap = s.previous_wrap
  vim.api.nvim_win_set_height(editor.win, math.max(10, math.floor(vim.o.lines * 0.55)))
  vim.api.nvim_win_set_cursor(editor.win, { math.min(editor.cursor or 1, vim.api.nvim_buf_line_count(editor.buf)), 0 })
  -- QuitPre clears 'modified' to bypass E37. Restore it after reopening so
  -- ZZ still invokes BufWriteCmd, even if undo returned to a prior undo state.
  if editor.was_closed then
    vim.bo[editor.buf].modified = true
  end
  editor.closing = false
  vim.api.nvim_create_autocmd('WinClosed', {
    group = state.augroup,
    pattern = tostring(editor.win),
    once = true,
    callback = function()
      vim.schedule(function()
        if live(s) and s.editor == editor and not editor.closing then
          editor.closing = true
          editor.was_closed = true
          if editor.discard then
            s.editor = nil
            wipe(editor.buf)
            return
          end
          yaml.parse(vim.api.nvim_buf_get_lines(editor.buf, 0, -1, false), function(doc, parse_err)
            if not live(s) or s.editor ~= editor then
              return
            end
            if not doc then
              editor.error = parse_err
              return M.reopen(s, editor)
            end
            local changes, err, missing = yaml.reconcile(doc, editor.originals, editor.mode, editor.owner, editor.applied)
            if not changes then
              if missing then
                local lines = yaml.emit({ missing }, 'edit')
                local last = vim.api.nvim_buf_line_count(editor.buf)
                vim.api.nvim_buf_set_lines(editor.buf, last, last, false, vim.list_slice(lines, 3))
              end
              editor.error = err
              return M.reopen(s, editor)
            end
            if #changes == 0 then
              s.editor = nil
              wipe(editor.buf)
              vim.api.nvim_set_current_win(s.win)
              return
            end
            review(s, changes, function()
              run_changes(s, changes, editor)
            end, function()
              M.reopen(s, editor)
            end)
          end)
        end
      end)
    end,
  })
end
local function open_editor(s, records, mode, owner)
  if s.editor then
    if s.editor.win and vim.api.nvim_win_is_valid(s.editor.win) then
      vim.api.nvim_set_current_win(s.editor.win)
      vim.api.nvim_win_set_buf(s.editor.win, s.editor.buf)
    end
    return
  end
  if vim.fn.executable 'yq' ~= 1 or not vim.fn.system({ 'yq', '--version' }):match 'version v4%.' then
    return warn(s, 'yq v4 is required to edit variables')
  end
  local entries = {}
  for _, r in ipairs(records) do
    entries[#entries + 1] = mode == 'create' and r or yaml.from_api(r.owner, r)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'glab://ci-variables-editor/' .. buf)
  scratch(buf, 'yaml')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, yaml.emit(entries, mode))
  local editor = { buf = buf, originals = mode == 'create' and {} or vim.deepcopy(entries), applied = {}, mode = mode, owner = owner, cursor = 1 }
  s.editor = editor
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = state.augroup,
    buffer = buf,
    callback = function()
      if vim.api.nvim_get_current_buf() == buf then
        editor.cursor = vim.api.nvim_win_get_cursor(0)[1]
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = state.augroup,
    buffer = buf,
    callback = function()
      -- :w never writes to disk or submits. ZZ then closes and triggers review.
      vim.bo[buf].modified = false
    end,
  })
  local cmdline_autocmd = vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = state.augroup,
    callback = function()
      if vim.api.nvim_get_current_buf() == buf and vim.fn.getcmdtype() == ':' then
        local cmd = vim.fn.getcmdline()
        editor.discard_next = cmd:match '^%s*q!%s*$' ~= nil or cmd:match '^%s*quit!%s*$' ~= nil or cmd:match '^%s*close!%s*$' ~= nil
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = state.augroup,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_autocmd, cmdline_autocmd)
    end,
  })
  vim.keymap.set('n', 'ZQ', function()
    editor.discard_next = true
    vim.cmd 'q!'
  end, { buffer = buf, desc = 'Discard variable edit' })
  vim.api.nvim_create_autocmd('QuitPre', {
    group = state.augroup,
    buffer = buf,
    callback = function()
      editor.cursor = vim.api.nvim_win_get_cursor(0)[1]
      editor.discard = editor.discard_next or vim.v.cmdbang == 1
      editor.discard_next = false
      vim.bo[buf].modified = false -- bypass E37; snapshot stays in the hidden buffer
    end,
  })
  M.reopen(s, editor)
end
local function help(s)
  if s.help then
    if vim.api.nvim_win_is_valid(s.help.win) then
      vim.api.nvim_win_close(s.help.win, true)
      wipe(s.help.buf)
      s.help = nil
      return
    end
    wipe(s.help.buf)
    s.help = nil
  end
  local buf = vim.api.nvim_create_buf(false, true)
  scratch(buf, 'text')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    'Variables • keys',
    '',
    'r refresh  <leader>G include ancestor groups  H reveal/hide all values',
    '<CR> expand/collapse full value  e edit row  E edit visible rows',
    '% create project  g% create group  D delete  U restore version',
    '<leader>? help  q / <Esc> back (or dismiss help)',
    '',
    '󰈔 file variable   󰌾 protected   󰈉 masked / hidden',
    'Fallback: set vim.g.glab_ci_ascii_icons = true for F / P / M / H.',
    'Project in winbar; ancestor paths label group rows. Scopes do not merge.',
  })
  local win = vim.api.nvim_open_win(
    buf,
    true,
    { relative = 'editor', row = 2, col = 2, width = math.max(20, math.min(vim.o.columns - 4, 75)), height = 11, style = 'minimal', border = 'rounded' }
  )
  local popup = { buf = buf, win = win }
  s.help = popup
  vim.api.nvim_create_autocmd('WinClosed', {
    group = state.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        wipe(buf)
        if s.help == popup then
          s.help = nil
        end
      end)
    end,
  })
  local function dismiss()
    if s.help and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    wipe(buf)
    s.help = nil
  end
  for _, k in ipairs { 'q', '<Esc>', '<leader>?' } do
    vim.keymap.set('n', k, dismiss, { buffer = buf })
  end
end
function M.shutdown(layout)
  local s = sessions[layout]
  if not s then
    return
  end
  s.dead = true
  for _, popup in ipairs { s.help, s.review } do
    if popup then
      if vim.api.nvim_win_is_valid(popup.win) then
        vim.api.nvim_win_close(popup.win, true)
      end
      wipe(popup.buf)
    end
  end
  if s.editor then
    if s.editor.win and vim.api.nvim_win_is_valid(s.editor.win) then
      vim.api.nvim_win_close(s.editor.win, true)
    end
    wipe(s.editor.buf)
  end
  if vim.api.nvim_win_is_valid(s.win) then
    vim.wo[s.win].winbar = s.previous_winbar
    vim.wo[s.win].wrap = s.previous_wrap
  end
  wipe(s.buf)
  if s.resize_autocmd then
    pcall(vim.api.nvim_del_autocmd, s.resize_autocmd)
  end
  sessions[layout] = nil
end
function M.open()
  local layout, win = state.current_layout, state.list_win
  if not layout or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  scratch(buf, 'glab-ci-variables')
  vim.bo[buf].modifiable = false
  local s = {
    layout = layout,
    win = win,
    buf = buf,
    previous_winbar = vim.wo[win].winbar,
    previous_wrap = vim.wo[win].wrap,
    entries = {},
    owner_errors = {},
    rows = {},
    expanded = {},
    groups = false,
    reveal = false,
  }
  sessions[layout] = s
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = true
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = state.augroup,
    buffer = buf,
    once = true,
    callback = function()
      if not s.dead then
        vim.schedule(function()
          if sessions[layout] == s then
            state.activate(layout)
            if vim.api.nvim_win_is_valid(win) and valid(state.list_buf) then
              vim.api.nvim_win_set_buf(win, state.list_buf)
              vim.wo[win].winbar = s.previous_winbar
              vim.wo[win].wrap = s.previous_wrap
            end
            M.shutdown(layout)
          end
        end)
      end
    end,
  })
  s.resize_autocmd = vim.api.nvim_create_autocmd('WinResized', {
    group = state.augroup,
    callback = function()
      if live(s) then
        M.render(s)
      end
    end,
  })
  local function map(key, fn)
    vim.keymap.set('n', key, function()
      if live(s) then
        state.activate(layout)
        fn()
      end
    end, { buffer = buf })
  end
  map('r', function()
    fetch(s, s.groups)
  end)
  map('<leader>G', function()
    s.groups = not s.groups
    if s.groups then
      fetch(s, true)
    else
      M.render(s)
    end
  end)
  map('H', function()
    s.reveal = not s.reveal
    if not s.reveal then
      s.expanded = {}
    end
    M.render(s)
  end)
  map('<CR>', function()
    local r = selected(s)
    if r then
      s.selection = identity(r)
      s.expanded[identity(r)] = not s.expanded[identity(r)]
      M.render(s)
    end
  end)
  map('<leader>?', function()
    help(s)
  end)
  map('e', function()
    local r = selected(s)
    if r then
      s.selection = identity(r)
      open_editor(s, { r }, 'edit')
    end
  end)
  map('E', function()
    local all = {}
    for i, owner in ipairs(s.owners or {}) do
      if i == 1 or s.groups then
        vim.list_extend(all, s.entries[owner.path] or {})
      end
    end
    if #all > 0 then
      local r = selected(s)
      s.selection = r and identity(r)
      open_editor(s, all, 'edit')
    end
  end)
  local function create(owner)
    open_editor(s, {
      {
        owner = owner.kind == 'project' and 'project' or owner.path,
        key = '',
        environment_scope = '*',
        description = '',
        value = '',
        variable_type = 'env_var',
        protected = false,
        masked = false,
        hidden = false,
        raw = true,
      },
    }, 'create', owner.kind == 'project' and 'project' or owner.path)
  end
  map('%', function()
    if s.owners then
      create(s.owners[1])
    end
  end)
  map('g%', function()
    ancestors(s, function(groups)
      if not groups or #groups == 0 then
        return warn(s, 'No ancestor groups available')
      end
      vim.ui.select(groups, {
        prompt = 'Create variable in group',
        format_item = function(o)
          return o.path
        end,
      }, function(owner)
        if owner and live(s) then
          create(owner)
        end
      end)
    end)
  end)
  map('D', function()
    local r = selected(s)
    if not r then
      return
    end
    local old = yaml.from_api(r.owner, r)
    vim.ui.input({ prompt = 'Type ' .. label(r) .. ' to delete: ' }, function(answer)
      if answer ~= label(r) or not live(s) then
        return
      end
      review(s, { { old = old } }, function()
        run_changes(s, { { old = old } })
      end, function()
        vim.api.nvim_set_current_win(s.win)
      end)
    end)
  end)
  map('U', function()
    local r = selected(s)
    if not r then
      return
    end
    local history = journal[journal_key(s, r.owner, r)] or {}
    if #history == 0 then
      return warn(s, 'No restorable update snapshots for ' .. r.key)
    end
    local versions = {}
    for i = #history, 1, -1 do
      versions[#versions + 1] = history[i]
    end
    vim.ui.select(versions, {
      prompt = 'Restore version of ' .. label(r),
      format_item = function(v)
        return v.at .. '  scope: ' .. v.record.environment_scope
      end,
    }, function(version)
      if not version or not live(s) then
        return
      end
      local old = yaml.from_api(r.owner, r)
      local new = vim.deepcopy(version.record)
      new.original_environment_scope = old.environment_scope
      review(s, { { old = old, new = new } }, function()
        run_changes(s, { { old = old, new = new } })
      end, function()
        vim.api.nvim_set_current_win(s.win)
      end)
    end)
  end)
  local function back()
    -- Leaving the view would wipe the secret-bearing editor (and its undo
    -- history). While an edit/review is active, return to it instead; only
    -- :q! / ZQ in the editor explicitly discards the user's text.
    if s.review and vim.api.nvim_win_is_valid(s.review.win) then
      vim.api.nvim_set_current_win(s.review.win)
      return
    end
    if s.editor then
      if s.editor.win and vim.api.nvim_win_is_valid(s.editor.win) and valid(s.editor.buf) then
        vim.api.nvim_set_current_win(s.editor.win)
        if vim.api.nvim_win_get_buf(s.editor.win) ~= s.editor.buf then
          vim.api.nvim_win_set_buf(s.editor.win, s.editor.buf)
        end
      else
        vim.notify('Variable edit is still being processed; finish the review before leaving', vim.log.levels.WARN)
      end
      return
    end
    if vim.api.nvim_win_is_valid(win) and valid(state.list_buf) then
      vim.api.nvim_win_set_buf(win, state.list_buf)
      vim.wo[win].winbar = s.previous_winbar
      vim.wo[win].wrap = s.previous_wrap
    end
    M.shutdown(layout)
  end
  map('q', back)
  map('<Esc>', back)
  api.project(function(project, err)
    if not live(s) then
      return
    end
    if not project then
      return warn(s, err)
    end
    s.project = project
    s.owners = api.owners(project)
    fetch(s, false)
  end)
  M.render(s)
end
return M
