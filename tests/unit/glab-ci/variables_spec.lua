local h = require 'helpers'
local api = require 'glab-ci.variables_api'
local yaml = require 'glab-ci.variables_yaml'
local function parse(lines)
  local result, err, done
  yaml.parse(lines, function(doc, failure)
    result, err, done = doc, failure, true
  end)
  h.wait_until(function()
    return done
  end, 'yq parse timed out', 3000)
  h.eq(nil, err)
  return result
end
local project = {
  id = 17,
  path_with_namespace = 'team/platform/app',
  namespace = { full_path = 'team/platform' },
  web_url = 'https://gitlab.example/team/platform/app',
  host = 'gitlab.example',
}
local record = {
  key = 'S',
  value = 'original',
  environment_scope = '*',
  description = '',
  variable_type = 'env_var',
  protected = false,
  masked = false,
  hidden = false,
  raw = true,
}
return {
  {
    name = 'current repository project resolves host and complete ancestor paths',
    run = function()
      h.with_system(function(cmd, _, cb)
        h.eq({ 'glab', 'api', 'projects/:id', '--method', 'GET' }, cmd)
        cb { code = 0, stdout = vim.json.encode(project) }
        return {}
      end, function()
        local found
        api.project(function(result)
          found = result
        end)
        h.wait_until(function()
          return found ~= nil
        end)
        h.eq('gitlab.example', found.host)
        h.eq('team', api.owners(found)[3].path)
        found.namespace.kind = 'user'
        h.eq(1, #api.owners(found))
      end)
    end,
  },
  {
    name = 'variables API paginates, escapes scope, uses stdin and never exposes a value in argv',
    run = function()
      local calls = {}
      h.with_system(function(cmd, opts, callback)
        calls[#calls + 1] = { cmd, opts }
        if cmd[3]:find('&page=1', 1, true) then
          local page = {}
          for i = 1, 100 do
            page[i] = { key = 'K', environment_scope = tostring(i) }
          end
          callback { code = 0, stdout = vim.json.encode(page) }
        elseif cmd[3]:find('&page=2', 1, true) then
          callback { code = 0, stdout = vim.json.encode { { key = 'K', environment_scope = 'production' } } }
        else
          callback { code = 0, stdout = vim.json.encode(record) }
        end
        return {}
      end, function()
        local owners = api.owners(project)
        h.eq({ 'team/platform/app', 'team/platform', 'team' }, { owners[1].path, owners[2].path, owners[3].path })
        local done
        api.list(owners[2], function(items)
          h.eq(101, #items)
          done = true
        end)
        h.wait_until(function()
          return done
        end)
        api.update(owners[2], 'K / ?', 'a/b *', { value = 'TOP SECRET', environment_scope = 'new' }, function()
          done = 'updated'
        end)
        h.wait_until(function()
          return done == 'updated'
        end)
        h.truthy(calls[3][1][3]:find('K%20%2F%20%3F', 1, true))
        h.truthy(calls[3][1][3]:find('a%2Fb%20%2A', 1, true))
        h.eq('-', calls[3][1][#calls[3][1]])
        h.truthy(calls[3][2].stdin:find('TOP SECRET', 1, true))
        h.eq(false, table.concat(calls[3][1], ' '):find('TOP SECRET', 1, true) ~= nil)
      end)
    end,
  },
  {
    name = 'scoped lookup rejects wrong record and never exposes failure stderr',
    run = function()
      local owner = api.owners(project)[2]
      local calls = 0
      h.with_system(function(cmd, _, cb)
        calls = calls + 1
        if calls == 1 then
          cb { code = 0, stdout = vim.json.encode { key = 'S', environment_scope = 'other' } }
        else
          cb { code = 1, stderr = 'server echoed secret value: PRIVATE' }
        end
        return {}
      end, function()
        local done
        api.get(owner, 'S', 'production', function(r, err)
          h.eq(nil, r)
          h.truthy(err:find('Exact variable scope', 1, true))
          done = true
        end)
        h.wait_until(function()
          return done
        end)
        done = false
        api.get(owner, 'S', '*', function(r, err)
          h.eq(nil, r)
          h.eq(false, err:find('PRIVATE', 1, true) ~= nil)
          done = true
        end)
        h.wait_until(function()
          return done
        end)
      end)
    end,
  },
  {
    name = 'YAML emitter round trips exact values and rejects missing entries and duplicate scopes',
    run = function()
      for _, value in ipairs { '', 'a:b # "ü"', '🦊\n🪵', 'a\nb', 'a\nb\n', 'a\nb\n\n', '\n', '\nabc', 'a\r\nb', 'a\0b', 'escape\27[31m' } do
        local source = yaml.from_api({ kind = 'project' }, vim.tbl_extend('force', record, { value = value }))
        local emitted = yaml.emit({ source }, 'edit')
        local value_line, last_field, trailing_line
        for i, line in ipairs(emitted) do
          local field = line:match '^    ([%w_]+):'
          if field then
            last_field = field
            if field == 'value' then
              value_line = i
            elseif field == 'trailing_newlines' then
              trailing_line = i
            end
          end
        end
        h.eq('value', last_field)
        if trailing_line then
          h.truthy(trailing_line < value_line)
        end
        local doc = parse(emitted)
        local changes, err = yaml.reconcile(doc, { source }, 'edit')
        h.eq(nil, err)
        h.eq(0, #changes, 'round trip failed for ' .. vim.inspect(value))
      end
      local source = yaml.from_api({ kind = 'project' }, record)
      local null_description = yaml.from_api({ kind = 'project' }, vim.tbl_extend('force', record, { description = vim.NIL }))
      h.eq(0, #assert(yaml.reconcile(parse(yaml.emit({ null_description }, 'edit')), { null_description }, 'edit')))
      local changes, err = yaml.reconcile({ variables = {} }, { source }, 'edit')
      h.eq(nil, changes)
      h.truthy(err:find('Missing', 1, true))
      local doc = parse(yaml.emit({ source, source }, 'edit'))
      changes, err = yaml.reconcile(doc, { source }, 'edit')
      h.eq(nil, changes)
      h.truthy(err:find('Duplicate', 1, true))
      local bad = vim.deepcopy(source)
      bad.environment_scope = 'staging'
      bad.hidden = true
      changes, err = yaml.reconcile({ variables = { bad } }, { source }, 'edit')
      h.eq(nil, changes)
      h.truthy(err:find('hidden', 1, true))
      bad.hidden = false
      changes, err = yaml.reconcile({ variables = { bad } }, { source }, 'edit')
      h.eq(1, #changes)
      h.eq('*', changes[1].old.environment_scope)
      h.eq('staging', changes[1].new.environment_scope)
      local new = {
        owner = 'team/platform',
        key = 'NEW',
        environment_scope = 'production',
        description = '',
        value = 'secret123',
        variable_type = 'env_var',
        protected = false,
        masked = true,
        hidden = true,
        raw = true,
      }
      local created = assert(yaml.reconcile(parse(yaml.emit({ new }, 'create')), {}, 'create', new.owner))
      h.eq(1, #created)
      h.eq(true, yaml.body(created[1].new, true).masked_and_hidden)
      new.masked = false
      changes, err = yaml.reconcile(parse(yaml.emit({ new }, 'create')), {}, 'create', new.owner)
      h.eq(nil, changes)
      h.truthy(err:find('Hidden', 1, true))
      new.hidden = false
      new.key = string.rep('K', 255)
      h.eq(1, #assert(yaml.reconcile(parse(yaml.emit({ new }, 'create')), {}, 'create', new.owner)))
      new.key = new.key .. 'K'
      changes, err = yaml.reconcile(parse(yaml.emit({ new }, 'create')), {}, 'create', new.owner)
      h.eq(nil, changes)
      h.truthy(err:find('key', 1, true) or err:find('Key', 1, true))
    end,
  },
  {
    name = 'variables load owners sequentially with a trailing indicator and full inline errors',
    run = function()
      local state = require 'glab-ci.state'
      local original_project, original_list = api.project, api.list
      local project_cb, requests
      requests = {}
      api.project = function(cb)
        project_cb = cb
      end
      api.list = function(owner, cb)
        requests[#requests + 1] = { owner = owner, cb = cb }
      end
      local ok, err = xpcall(function()
        h.with_system(function(_, _, cb)
          cb { code = 0, stdout = '[]' }
          return {}
        end, function()
          vim.cmd 'GlabCI'
          local win = state.list_win
          vim.cmd 'normal v'
          local buf = vim.api.nvim_win_get_buf(win)
          local function lines()
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          end
          h.eq({ ' Loading variables…' }, lines())
          h.eq(false, vim.wo[win].winbar:find('loading', 1, true) ~= nil)
          project_cb(project)
          h.eq('team/platform/app', requests[1].owner.path)
          h.eq({ ' Loading variables…' }, lines())
          vim.api.nvim_feedkeys((vim.g.mapleader or '\\') .. 'G', 'xt', false)
          h.eq(false, vim.tbl_contains(lines(), 'team/platform')) -- project still pending
          h.eq(false, vim.tbl_contains(lines(), '   (no variables)'))
          h.eq('team/platform/app', requests[2].owner.path) -- visibility restarted fetch
          requests[1].cb { vim.deepcopy(record) } -- canceled callback is ignored
          h.eq({ ' Loading variables…' }, lines())
          requests[2].cb { vim.deepcopy(record) }
          h.eq('team/platform', requests[3].owner.path)
          h.truthy(lines()[1]:match '^S')
          h.eq(' Loading variables for group team/platform…', lines()[#lines()])
          h.truthy(vim.tbl_contains(lines(), 'team/platform')) -- project finished; this group is now loading
          h.eq(false, vim.tbl_contains(lines(), 'team'))
          h.eq(false, vim.tbl_contains(lines(), '   (no variables)'))
          local failure = 'GitLab request failed; check permissions ' .. string.rep('detail-', 40)
          requests[3].cb(nil, failure)
          h.eq('team', requests[4].owner.path)
          local result = lines()
          h.eq(false, result[1]:find('!', 1, true) ~= nil)
          h.truthy(vim.tbl_contains(result, 'team/platform ! ' .. failure))
          h.truthy(vim.tbl_contains(result, 'team')) -- only shown after the preceding group failed
          h.truthy(vim.fn.index(result, 'team/platform ! ' .. failure) < vim.fn.index(result, 'team'))
          h.eq(false, vim.tbl_contains(result, '   (no variables)'))
          h.eq(' Loading variables for group team…', result[#result])
          h.eq(true, vim.wo[win].wrap)
          h.truthy(vim.fn.strdisplaywidth(' ! ' .. failure) > vim.api.nvim_win_get_width(win))
          requests[4].cb(nil, 'Not permitted')
          result = lines()
          h.eq(false, vim.tbl_contains(result, ' Loading variables…'))
          h.truthy(vim.tbl_contains(result, 'team ! Not permitted'))
          h.truthy(result[#result] ~= '')
          h.eq(false, vim.wo[win].winbar:find('error', 1, true) ~= nil)
          vim.cmd 'normal r'
          h.eq({ ' Loading variables…' }, lines())
          requests[5].cb {}
          h.truthy(vim.tbl_contains(lines(), '   (no variables)'))
          h.eq(false, vim.tbl_contains(lines(), 'team/platform ! ' .. failure)) -- stale group error is hidden during refresh
          h.eq(' Loading variables for group team/platform…', lines()[#lines()])
          -- Hiding groups invalidates the outstanding group request.
          vim.api.nvim_feedkeys((vim.g.mapleader or '\\') .. 'G', 'xt', false)
          requests[6].cb {}
          h.eq(' Loading variables…', lines()[#lines()])
          requests[7].cb {}
          h.eq(false, vim.tbl_contains(lines(), ' Loading variables…'))
          vim.cmd 'normal q'
          vim.cmd 'GlabCI'
          local failed_win = state.list_win
          vim.cmd 'normal v'
          local failed_buf = vim.api.nvim_win_get_buf(failed_win)
          h.eq({ ' Loading variables…' }, vim.api.nvim_buf_get_lines(failed_buf, 0, -1, false))
          local project_failure = 'Failed to resolve project ' .. string.rep('id/', 30)
          project_cb(nil, project_failure)
          h.eq({ ' ! ' .. project_failure }, vim.api.nvim_buf_get_lines(failed_buf, 0, -1, false))
          vim.cmd 'normal q' -- variables -> list
          vim.cmd 'normal q' -- close second list panel
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal q' -- close first list panel
          h.wait_until(function()
            return next(state.layouts) == nil and vim.fn.bufnr 'glab://ci-list' == -1
          end)
        end)
      end, debug.traceback)
      api.project, api.list = original_project, original_list
      if not ok then
        error(err)
      end
    end,
  },
  {
    name = 'two variable panels own separate buffers, group rows and selection mappings',
    run = function()
      local state = require 'glab-ci.state'
      local original_project, original_list = api.project, api.list
      local old_ascii = vim.g.glab_ci_ascii_icons
      vim.g.glab_ci_ascii_icons = true
      api.project = function(cb)
        cb(project)
      end
      api.list = function(owner, cb)
        local item = vim.deepcopy(record)
        item.value = owner.path .. '\nsecret' .. string.rep('x', 150)
        item.variable_type, item.protected, item.hidden = 'file', true, true
        cb { item }
      end
      local ok, err = xpcall(function()
        h.with_system(function(_, _, cb)
          cb { code = 0, stdout = '[]' }
          return {}
        end, function()
          vim.cmd 'GlabCI'
          local win1 = state.list_win
          vim.cmd 'normal v'
          local buf1 = vim.api.nvim_win_get_buf(win1)
          local default_lines = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
          vim.cmd 'GlabCI'
          local win2 = state.list_win
          local prior_wrap = vim.wo[win2].wrap
          vim.cmd 'normal v'
          local buf2 = vim.api.nvim_win_get_buf(win2)
          h.truthy(buf1 ~= buf2)
          local first = vim.api.nvim_buf_get_lines(buf2, 0, 1, false)[1]
          h.truthy(first:match '^S') -- project path is already in the winbar
          h.eq(false, first:find('PROJECT', 1, true) ~= nil)
          local row = vim.api.nvim_win_get_cursor(win2)[1]
          local line = vim.api.nvim_buf_get_lines(buf2, row - 1, row, false)[1]
          h.truthy(line:match '^S') -- no leading whitespace
          h.truthy(line:find('FPH', 1, true))
          h.truthy(line:find('FPH', 1, true) < line:find('*', 1, true))
          local ns = vim.api.nvim_get_namespaces().glab_ci_variables
          local marks = vim.api.nvim_buf_get_extmarks(buf2, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
          local dimmed = false
          for _, mark in ipairs(marks) do
            if mark[4].hl_group == 'GlabVarScopeDefault' then
              h.eq('*', line:sub(mark[3] + 1, mark[4].end_col))
              dimmed = true
            end
          end
          h.truthy(dimmed)
          local title = vim.wo[win2].winbar
          h.truthy(title:find('CI Variables', 1, true))
          h.truthy(title:find(project.path_with_namespace, 1, true))
          h.eq(false, title:find(' / S ', 1, true) ~= nil)
          vim.api.nvim_win_set_cursor(win2, { 1, 0 })
          vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf2 })
          h.eq(title, vim.wo[win2].winbar)
          vim.api.nvim_win_set_cursor(win2, { row, 0 })
          vim.cmd 'normal th'
          vim.cmd 'normal td'
          h.eq(default_lines, vim.api.nvim_buf_get_lines(buf1, 0, -1, false)) -- both toggles are panel-local
          line = vim.api.nvim_buf_get_lines(buf2, row - 1, row, false)[1]
          h.truthy(line:sub(-3) == '…')
          local text_width = vim.api.nvim_win_get_width(win2) - vim.fn.getwininfo(win2)[1].textoff
          h.truthy(vim.fn.strdisplaywidth(line) < text_width)
          h.eq(true, vim.wo[win2].wrap)
          vim.cmd 'normal G'
          h.eq(vim.api.nvim_buf_line_count(buf2), vim.api.nvim_win_get_cursor(win2)[1])
          h.eq(false, vim.tbl_contains(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), 'team/platform'))
          vim.api.nvim_win_set_cursor(win2, { row, 0 })
          vim.api.nvim_feedkeys((vim.g.mapleader or '\\') .. 'G', 'xt', false)
          h.wait_until(function()
            return vim.tbl_contains(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), 'team/platform')
          end)
          h.eq(false, vim.tbl_contains(vim.api.nvim_buf_get_lines(buf1, 0, -1, false), 'team/platform'))
          local row = vim.api.nvim_win_get_cursor(win2)[1]
          vim.api.nvim_win_set_cursor(win2, { row, 12 })
          local before = vim.api.nvim_buf_line_count(buf2)
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
          h.eq({ row, 12 }, vim.api.nvim_win_get_cursor(win2))
          h.eq(before + 2, vim.api.nvim_buf_line_count(buf2))
          h.eq({ 'team/platform/app', 'secret' .. string.rep('x', 150) }, vim.api.nvim_buf_get_lines(buf2, row, row + 2, false))
          h.truthy(vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(buf2, row + 1, row + 2, false)[1]) > text_width)
          h.truthy(vim.api.nvim_win_get_cursor(win2)[1] == row)
          vim.api.nvim_win_set_cursor(win2, { row + 2, 80 }) -- a soft-wrapped screen segment still belongs to this variable
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
          h.eq(before, vim.api.nvim_buf_line_count(buf2))
          vim.cmd 'normal q'
          h.eq(prior_wrap, vim.wo[win2].wrap)
          h.eq(false, vim.api.nvim_buf_is_valid(buf2))
          h.truthy(vim.api.nvim_buf_is_valid(buf1))
          vim.api.nvim_set_current_win(win1)
          vim.cmd 'normal q'
          h.eq(false, vim.api.nvim_buf_is_valid(buf1))
          if vim.api.nvim_win_is_valid(win1) then
            vim.api.nvim_win_close(win1, true)
          end
          if vim.api.nvim_win_is_valid(win2) then
            vim.api.nvim_win_close(win2, true)
          end
          h.wait_until(function()
            return next(state.layouts) == nil and vim.fn.bufnr 'glab://ci-list' == -1
          end, 'panel buffers not wiped', 3000)
        end)
      end, debug.traceback)
      api.project, api.list = original_project, original_list
      vim.g.glab_ci_ascii_icons = old_ascii
      if not ok then
        error(err)
      end
    end,
  },
  {
    name = 'variable keys use free width and show long keys over columns on cursor hover',
    run = function()
      local state = require 'glab-ci.state'
      local original_project, original_list = api.project, api.list
      local columns, old_ascii = vim.o.columns, vim.g.glab_ci_ascii_icons
      vim.g.glab_ci_ascii_icons = true
      local key = 'INTERPLAY_WS_USERNAME_HML_DEPLOYMENT_ENV'
      local long_key = string.rep('K', 255)
      api.project = function(cb)
        cb(project)
      end
      api.list = function(_, cb)
        local a, b = vim.deepcopy(record), vim.deepcopy(record)
        a.key, b.key = key, long_key
        a.variable_type, a.protected, a.hidden = 'file', true, true
        cb { a, b }
      end
      local ok, err = xpcall(function()
        h.with_system(function(_, _, cb)
          cb { code = 0, stdout = '[]' }
          return {}
        end, function()
          vim.o.columns = 140
          vim.cmd 'GlabCI'
          local win = state.list_win
          vim.cmd 'normal v'
          local buf = vim.api.nvim_win_get_buf(win)
          local function line(row)
            return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
          end
          local hover_ns = vim.api.nvim_get_namespaces().glab_ci_variables_key_hover
          local function hovered(row)
            return vim.api.nvim_buf_get_extmarks(buf, hover_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
          end
          h.truthy(line(1):sub(1, #key) == key)
          h.truthy(line(1):find('FPH *', 1, true) ~= nil)
          h.eq(vim.fn.strdisplaywidth(line(1):sub(1, line(1):find('*', 1, true) - 1)), vim.fn.strdisplaywidth(line(2):sub(1, line(2):find('*', 1, true) - 1))) -- shared key display width, not byte width
          h.eq(0, #hovered(1))
          h.truthy(line(2):find('…', 1, true) ~= nil)
          vim.api.nvim_win_set_cursor(win, { 2, 0 })
          vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
          local marks = hovered(2)
          h.eq(1, #marks)
          h.eq(0, marks[1][3])
          h.eq('overlay', marks[1][4].virt_text_pos)
          h.truthy(marks[1][4].virt_text[1][1]:sub(1, 40) == string.rep('K', 40))
          h.truthy(vim.fn.strdisplaywidth(marks[1][4].virt_text[1][1]) <= vim.api.nvim_win_get_width(win))
          vim.api.nvim_win_set_cursor(win, { 1, 0 })
          vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
          h.eq(0, #hovered(2))
          vim.cmd 'vnew'
          local side_win = vim.api.nvim_get_current_win()
          vim.api.nvim_set_current_win(win)
          vim.api.nvim_win_set_width(win, 44)
          vim.api.nvim_exec_autocmds('WinResized', {})
          h.truthy(line(1):find('…', 1, true) ~= nil)
          h.eq(1, #hovered(1))
          h.eq(key, hovered(1)[1][4].virt_text[1][1]) -- full key fits over scope and preview
          h.truthy(line(1):sub(1, 8) == key:sub(1, 8)) -- overlay did not change buffer text
          vim.api.nvim_set_current_win(side_win)
          h.eq(0, #hovered(1))
          vim.api.nvim_set_current_win(win)
          h.eq(1, #hovered(1))
          vim.cmd 'normal q' -- variables -> list
          vim.cmd 'normal q' -- close list
          vim.api.nvim_win_close(side_win, true)
          h.wait_until(function()
            return next(state.layouts) == nil and vim.fn.bufnr 'glab://ci-list' == -1
          end)
        end)
      end, debug.traceback)
      vim.o.columns = columns
      vim.g.glab_ci_ascii_icons = old_ascii
      api.project, api.list = original_project, original_list
      if not ok then
        error(err)
      end
    end,
  },
  {
    name = 'q and Escape on variables panel return to the open editor without discarding edits',
    run = function()
      local state = require 'glab-ci.state'
      local original_project, original_list = api.project, api.list
      api.project = function(cb)
        cb(project)
      end
      api.list = function(_, cb)
        cb { vim.deepcopy(record) }
      end
      local ok, err = xpcall(function()
        h.with_system(function(cmd, _, cb)
          h.eq({ 'glab', 'ci', 'list', '-F', 'json' }, cmd)
          cb { code = 0, stdout = '[]' }
          return {}
        end, function()
          vim.cmd 'GlabCI'
          local win = state.list_win
          vim.cmd 'normal v'
          local variables_buf = vim.api.nvim_win_get_buf(win)
          vim.cmd 'normal e'
          local editor_win = vim.api.nvim_get_current_win()
          local editor_buf = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_lines(editor_buf, 0, 0, false, { '# keep this edit' })
          for _, key in ipairs { 'q', '<Esc>' } do
            vim.api.nvim_set_current_win(win)
            if key == '<Esc>' then
              vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
            else
              vim.cmd 'normal q'
            end
            h.eq(editor_win, vim.api.nvim_get_current_win())
            h.eq(editor_buf, vim.api.nvim_get_current_buf())
            h.eq(variables_buf, vim.api.nvim_win_get_buf(win))
            h.eq('# keep this edit', vim.api.nvim_buf_get_lines(editor_buf, 0, 1, false)[1])
          end
          vim.cmd 'normal ZQ'
          h.wait_until(function()
            return not vim.api.nvim_buf_is_valid(editor_buf)
          end)
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal q'
          h.eq(false, vim.api.nvim_buf_is_valid(variables_buf))
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
          h.wait_until(function()
            return vim.fn.bufnr 'glab://ci-list' == -1
          end)
        end)
      end, debug.traceback)
      api.project, api.list = original_project, original_list
      if not ok then
        error(err)
      end
    end,
  },
  {
    name = 'partial E failure preserves text and retries without rewriting completed records',
    run = function()
      local state = require 'glab-ci.state'
      local view = require 'glab-ci.views.variables'
      local saved = { project = api.project, list = api.list, get = api.get, update = api.update }
      local system = vim.system
      local records = {}
      for _, key in ipairs { 'A', 'B' } do
        records[key] = vim.tbl_extend('force', record, { key = key, value = 'old-' .. key })
      end
      local fail_b, calls = true, { A = 0, B = 0 }
      api.project = function(cb)
        cb(project)
      end
      api.list = function(_, cb)
        cb { vim.deepcopy(records.A), vim.deepcopy(records.B) }
      end
      api.get = function(_, key, _, cb)
        cb(vim.deepcopy(records[key]))
      end
      api.update = function(_, key, _, body, cb)
        calls[key] = calls[key] + 1
        if key == 'B' and fail_b then
          return cb(nil, 'B: denied')
        end
        records[key].value = body.value
        cb(vim.deepcopy(records[key]))
      end
      local ok, err = xpcall(function()
        h.with_system(function(cmd, opts, cb)
          if cmd[1] ~= 'glab' then
            return system(cmd, opts, cb)
          end
          cb { code = 0, stdout = '[]' }
          return {}
        end, function()
          vim.cmd 'GlabCI'
          local win = state.list_win
          view.open()
          vim.cmd 'normal E'
          local editor = vim.api.nvim_get_current_buf()
          local lines = vim.api.nvim_buf_get_lines(editor, 0, -1, false)
          for i, line in ipairs(lines) do
            lines[i] = line:gsub('"old%-', '"new-')
          end
          vim.api.nvim_buf_set_lines(editor, 0, -1, false, lines)
          vim.cmd 'q'
          h.wait_until(function()
            return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'diff'
          end, 'missing E review', 3000)
          vim.cmd 'normal y'
          h.wait_until(function()
            return vim.api.nvim_get_current_buf() == editor
              and vim.api.nvim_buf_get_lines(editor, 0, 1, false)[1]:find('already saved: project/A', 1, true) ~= nil
          end, 'partial failure did not reopen editor', 3000)
          h.eq('new-A', records.A.value)
          h.eq('old-B', records.B.value)
          fail_b = false
          vim.cmd 'q'
          h.wait_until(function()
            return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'diff'
          end, 'retry missing diff', 3000)
          local diff = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), '\n')
          h.eq(false, diff:find('project / A', 1, true) ~= nil)
          h.truthy(diff:find('project / B', 1, true))
          vim.cmd 'normal y'
          h.wait_until(function()
            return records.B.value == 'new-B' and not vim.api.nvim_buf_is_valid(editor)
          end)
          h.eq({ A = 1, B = 2 }, calls)
          view.shutdown(state.win_layouts[win])
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
          h.wait_until(function()
            return vim.fn.bufnr 'glab://ci-list' == -1
          end)
        end)
      end, debug.traceback)
      api.project, api.list, api.get, api.update = saved.project, saved.list, saved.get, saved.update
      if not ok then
        error(err)
      end
    end,
  },
  {
    name = 'update journal caps snapshots at three and restores a prior scope',
    run = function()
      local state = require 'glab-ci.state'
      local view = require 'glab-ci.views.variables'
      local saved = { project = api.project, list = api.list, get = api.get, update = api.update, select = vim.ui.select }
      local current = vim.deepcopy(record)
      local system = vim.system
      current.key, current.value, current.environment_scope = 'HISTORY', 'version0', '*'
      api.project = function(cb)
        cb(project)
      end
      api.list = function(_, cb)
        cb { vim.deepcopy(current) }
      end
      api.get = function(_, _, scope, cb)
        if scope == current.environment_scope then
          cb(vim.deepcopy(current))
        else
          cb(nil, 'missing scope')
        end
      end
      api.update = function(_, _, _, body, cb)
        current.value, current.environment_scope = body.value, body.environment_scope
        cb(vim.deepcopy(current))
      end
      local selected_count
      vim.ui.select = function(versions, opts, cb)
        selected_count = #versions
        h.eq(false, opts.format_item(versions[1]):find('version', 1, true) ~= nil)
        cb(versions[1])
      end
      local ok, err = xpcall(function()
        h.with_system(function(cmd, opts, cb)
          if cmd[1] ~= 'glab' then
            return system(cmd, opts, cb)
          end
          cb { code = 0, stdout = '[]' }
          return {}
        end, function()
          vim.cmd 'GlabCI'
          local win = state.list_win
          view.open()
          local function change(from, to, rename)
            vim.api.nvim_set_current_win(win)
            vim.cmd 'normal e'
            local editor = vim.api.nvim_get_current_buf()
            local lines = vim.api.nvim_buf_get_lines(editor, 0, -1, false)
            for index, line in ipairs(lines) do
              lines[index] = line:gsub('"version' .. from .. '"', '"version' .. to .. '"')
              if rename and line:match '^    environment_scope:' then
                lines[index] = lines[index]:gsub('"%*"', '"stage"')
              end
            end
            vim.api.nvim_buf_set_lines(editor, 0, -1, false, lines)
            vim.cmd 'q'
            h.wait_until(function()
              return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'diff'
            end, 'missing update review', 3000)
            vim.cmd 'normal y'
            h.wait_until(function()
              return current.value == 'version' .. to and not vim.api.nvim_buf_is_valid(editor)
            end)
          end
          change(0, 1, true)
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal U'
          h.eq(1, selected_count)
          vim.cmd 'normal y'
          h.wait_until(function()
            return current.value == 'version0' and current.environment_scope == '*'
          end, 'restore did not reverse scope rename')
          change(0, 1, true)
          for i = 2, 4 do
            change(i - 1, i)
          end
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal U'
          h.eq(3, selected_count)
          h.eq('diff', vim.bo[vim.api.nvim_get_current_buf()].filetype)
          vim.cmd 'normal y'
          h.wait_until(function()
            return current.value == 'version3'
          end)
          view.shutdown(state.win_layouts[win])
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
          h.wait_until(function()
            return vim.fn.bufnr 'glab://ci-list' == -1
          end)
        end)
      end, debug.traceback)
      api.project, api.list, api.get, api.update, vim.ui.select = saved.project, saved.list, saved.get, saved.update, saved.select
      if not ok then
        error(err)
      end
    end,
  },
  {
    name = 'modified :q and ZZ review without writes; cancel keeps text; confirm updates',
    run = function()
      local state = require 'glab-ci.state'
      local view = require 'glab-ci.views.variables'
      local original = { project = api.project, list = api.list, get = api.get, update = api.update }
      local writes = 0
      local system = vim.system
      api.project = function(cb)
        cb(project)
      end
      api.list = function(owner, cb)
        cb(owner.kind == 'project' and { vim.deepcopy(record) } or {})
      end
      api.get = function(_, _, _, cb)
        cb(vim.deepcopy(record))
      end
      api.update = function(_, _, _, body, cb)
        writes = writes + 1
        record.value = body.value
        cb(vim.tbl_extend('force', record, body))
      end
      local ok, err = xpcall(function()
        h.with_system(function(cmd, _, cb)
          if cmd[1] == 'glab' then
            cb { code = 0, stdout = '[]' }
            return {}
          end
          return system(cmd, _, cb)
        end, function()
          vim.cmd 'GlabCI'
          state.activate_for_current_win()
          view.open()
          local win = state.list_win
          h.wait_until(function()
            return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'glab-ci-variables'
          end)
          vim.cmd 'normal e'
          local editor = vim.api.nvim_get_current_buf()
          h.eq('yaml', vim.bo[editor].filetype)
          local lines = vim.api.nvim_buf_get_lines(editor, 0, -1, false)
          for i, line in ipairs(lines) do
            lines[i] = line:gsub('"original"', '"changed"')
          end
          vim.api.nvim_buf_set_lines(editor, 0, -1, false, lines)
          vim.cmd 'w'
          h.eq(0, writes)
          h.eq(editor, vim.api.nvim_get_current_buf())
          vim.cmd 'q'
          h.wait_until(function()
            return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'diff'
          end, 'modified :q did not open review', 3000)
          h.eq(0, writes)
          local review_win = vim.api.nvim_get_current_win()
          local review_buf = vim.api.nvim_get_current_buf()
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal q'
          h.eq(review_win, vim.api.nvim_get_current_win())
          h.eq(review_buf, vim.api.nvim_get_current_buf())
          h.truthy(vim.api.nvim_buf_is_valid(editor))
          h.eq(0, writes)
          vim.cmd 'normal q'
          h.wait_until(function()
            return vim.api.nvim_get_current_buf() == editor
          end, 'cancel did not reopen editor')
          h.truthy(table.concat(vim.api.nvim_buf_get_lines(editor, 0, -1, false), '\n'):find('changed', 1, true))
          vim.api.nvim_buf_set_lines(editor, 0, 0, false, { 'variables: [invalid' })
          vim.cmd 'q'
          h.wait_until(function()
            return vim.api.nvim_get_current_buf() == editor and vim.api.nvim_buf_get_lines(editor, 0, 1, false)[1]:find('Invalid YAML', 1, true) ~= nil
          end, 'parse error did not preserve and reopen editor', 3000)
          h.eq(0, writes)
          vim.api.nvim_buf_set_lines(editor, 0, 2, false, {})
          vim.cmd 'normal ZZ'
          h.wait_until(function()
            return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'diff'
          end, 'ZZ did not open review', 3000)
          h.eq(0, writes)
          vim.cmd 'normal y'
          h.wait_until(function()
            return writes == 1
          end)
          h.eq(false, vim.api.nvim_buf_is_valid(editor))
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal e'
          local unchanged = vim.api.nvim_get_current_buf()
          vim.cmd 'q'
          h.wait_until(function()
            return not vim.api.nvim_buf_is_valid(unchanged)
          end, 'unchanged :q should be a no-op')
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal e'
          local discard = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_lines(discard, 0, 0, false, { '# intentional discard' })
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':q!<CR>', true, false, true), 'xt', false)
          h.wait_until(function()
            return not vim.api.nvim_buf_is_valid(discard)
          end, ':q! should discard', 3000)
          h.eq(1, writes)
          vim.api.nvim_set_current_win(win)
          vim.cmd 'normal e'
          local external = vim.api.nvim_get_current_buf()
          local external_lines = vim.api.nvim_buf_get_lines(external, 0, -1, false)
          for i, line in ipairs(external_lines) do
            external_lines[i] = line:gsub('"changed"', '"external"')
          end
          vim.api.nvim_buf_set_lines(external, 0, -1, false, external_lines)
          vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
          h.wait_until(function()
            return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'diff'
          end, 'external window close did not open review', 3000)
          vim.cmd 'normal q'
          h.wait_until(function()
            return vim.api.nvim_get_current_buf() == external
          end)
          vim.cmd 'normal ZQ'
          h.wait_until(function()
            return not vim.api.nvim_buf_is_valid(external)
          end)
          state.activate(state.win_layouts[win])
          view.shutdown(state.current_layout)
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end)
      end, debug.traceback)
      for key, value in pairs(original) do
        api[key] = value
      end
      if not ok then
        error(err)
      end
    end,
  },
}
