local h = require 'helpers'
local v = require 'variables_helpers'
local project = {
  id = 17,
  host = 'gitlab.example',
  path_with_namespace = 'team/platform/app',
  namespace = { full_path = 'team/platform' },
}
local function row(key, scope, desc)
  return { key = key, environment_scope = scope, description = desc, value = string.rep('v', 200), variable_type = 'file', protected = true, masked = true }
end
local function field(text, width)
  if #text > width then
    text = text:sub(1, width - 1) .. '…'
  end
  return text .. string.rep(' ', width - vim.fn.strdisplaywidth(text))
end
return {
  {
    name = '80/100/120 column owner tables reflow all td/th combinations independently',
    run = function()
      local fixtures = {
        ['team/platform/app'] = { row('S', '*', ''), row(string.rep('P', 67), 'prod', string.rep('d', 30)) },
        ['team/platform'] = { row('G', '*', ''), row(string.rep('A', 255), 'environment-scope-long', string.rep('g', 100)) },
        team = { row('T', '*', ''), row(string.rep('B', 7), 'stage', string.rep('z', 90)) },
      }
      v.with_panel(project, function(owner, cb)
        cb(vim.deepcopy(fixtures[owner.path]))
      end, function(win, buf, resize)
        v.groups()
        local hover = vim.api.nvim_get_namespaces().glab_ci_variables_key_hover
        local descriptions, revealed = true, false
        for _, width in ipairs { 80, 100, 120 } do
          local W = resize(width)
          h.eq(width - 1, W)
          for _, flags in ipairs { { true, false }, { false, false }, { false, true }, { true, true } } do
            if descriptions ~= flags[1] then
              v.keys 'td'
              descriptions = flags[1]
            end
            if revealed ~= flags[2] then
              v.keys 'th'
              revealed = flags[2]
            end
            local expected = {}
            local starts = {}
            for i, path in ipairs { 'team/platform/app', 'team/platform', 'team' } do
              if i > 1 then
                expected[#expected + 1] = ''
                expected[#expected + 1] = path
              end
              local scope = ({ 4, math.min(18, math.floor(W * 0.16)), 5 })[i]
              local desc = descriptions and math.ceil(W * 0.20) or 0
              local value = revealed and math.ceil(W * 0.20) or 6
              local keymax = ({ 67, 255, 7 })[i]
              local separators = descriptions and 5 or 4
              local key = math.min(keymax, W - 3 - scope - desc - value - separators)
              local spare = W - key - 3 - scope - desc - value - separators
              if descriptions then
                local add = math.min(spare, math.max(0, ({ 30, 100, 90 })[i] - desc))
                desc, spare = desc + add, spare - add
                h.truthy(desc >= math.ceil(W * 0.20))
              end
              if revealed then
                value = value + spare
                h.truthy(value >= math.ceil(W * 0.20))
              end
              starts[i] = key + 5 -- scope starts in display cells, zero-based
              for _, r in ipairs(fixtures[path]) do
                local line = field(r.key, key) .. ' FPM ' .. field(r.environment_scope, scope)
                if descriptions then
                  line = line .. ' ' .. field(r.description, desc)
                end
                line = line .. '  ' .. (revealed and field(r.value, value) or '••••••')
                expected[#expected + 1] = line
                h.truthy(vim.fn.strdisplaywidth(line) <= W)
              end
            end
            h.eq(expected, v.lines(buf), string.format('width=%d td=%s th=%s', width, descriptions, revealed))
            h.truthy(starts[2] ~= starts[3]) -- no cross-owner alignment
            -- Hover never modifies buffer contents or leaks the hidden preview.
            vim.api.nvim_win_set_cursor(win, { 6, 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
            local marks = vim.api.nvim_buf_get_extmarks(buf, hover, 0, -1, { details = true })
            h.eq(1, #marks)
            h.eq(string.rep('A', W - 1) .. '…', marks[1][4].virt_text[1][1])
            h.eq(expected, v.lines(buf))
            vim.api.nvim_win_set_cursor(win, { 4, 0 })
            vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
            h.eq(0, #vim.api.nvim_buf_get_extmarks(buf, hover, 0, -1, {}))
            -- Removing the long group key must not affect either other owner.
            local before = v.lines(buf)
            local long = table.remove(fixtures['team/platform'], 2)
            v.keys 'r'
            local after = v.lines(buf)
            h.eq({ before[1], before[2] }, { after[1], after[2] })
            h.eq({ before[9], before[10] }, { after[8], after[9] })
            fixtures['team/platform'][2] = long
            v.keys 'r'
            h.eq(before, v.lines(buf))
          end
        end
        -- CR targets a group record despite differently sized sections.
        vim.api.nvim_win_set_cursor(win, { 6, 0 })
        v.keys '<CR>'
        h.eq(string.rep('v', 200), v.lines(buf)[7])
        v.keys 'th'
        h.eq(10, #v.lines(buf)) -- hiding collapses expanded values; no trailing separator
        local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
        for _, map in ipairs(maps) do
          h.truthy(map.lhs ~= 'H')
        end
      end)
    end,
  },
  {
    name = 'narrow layout reduces percentage floors deterministically and hidden unavailable reserves only its marker',
    run = function()
      local records = { row(string.rep('K', 67), 'production-scope', string.rep('d', 90)) }
      v.with_panel(project, function(_, cb)
        cb(vim.deepcopy(records))
      end, function(_, buf, resize)
        v.keys 'th'
        for _, fixture in ipairs {
          { 22, 'KKK… pr… dddd…  vvvv…' },
          { 12, '… … d…  vv…' },
          { 7, 'K…  v…' },
          { 4, 'KK…' },
          { 2, '…' },
        } do
          local W = resize(fixture[1])
          h.eq({ fixture[2] }, v.lines(buf))
          h.truthy(vim.fn.strdisplaywidth(fixture[2]) <= W)
        end
        records = { row('S', '*', ''), row(string.rep('K', 67), 'prod', string.rep('d', 30)) }
        records[2].value = vim.NIL
        records[1].value = 'PRIVATE\n' .. string.rep('secret', 1000)
        resize(100)
        v.keys 'th' -- hidden; secret length must not affect allocation
        v.keys 'r'
        local lines = v.lines(buf)
        h.eq(field('S', 56) .. ' FPM ' .. field('*', 4) .. ' ' .. string.rep(' ', 20) .. '  ••••••', lines[1])
        h.eq(field(records[2].key, 56) .. ' FPM prod ' .. field(records[2].description, 20) .. '  unavailable', lines[2])
        h.eq(false, table.concat(lines):find('PRIVATE', 1, true) ~= nil)
        v.keys 'td' -- no description column or separator; the full key now fits
        h.eq(field(records[2].key, 67) .. ' FPM prod  unavailable', v.lines(buf)[2])
      end)
    end,
  },
  {
    name = 'section separators do not add a final blank row or remove real expanded value newlines',
    run = function()
      v.with_panel(project, function(owner, cb)
        local r = row('S', '*', '')
        r.value = owner.path .. '\n'
        cb { r }
      end, function(win, buf, resize)
        resize(100)
        local preview = v.lines(buf)[1]
        h.eq({ preview }, v.lines(buf))
        v.keys '<CR>'
        h.eq({ preview, 'team/platform/app', '' }, v.lines(buf)) -- actual trailing value newline
        v.keys '<CR>'
        h.eq({ preview }, v.lines(buf))
        v.groups()
        h.eq({ preview, '', 'team/platform', preview, '', 'team', preview }, v.lines(buf))
        vim.api.nvim_win_set_cursor(win, { 7, 0 })
        v.keys '<CR>'
        h.eq({ 'team', '' }, vim.api.nvim_buf_get_lines(buf, 7, -1, false))
        v.keys '<CR>'
        h.eq(preview, v.lines(buf)[#v.lines(buf)])
      end)
    end,
  },
  {
    name = 'variables help documents the toggles and adaptive floors in a narrow wrapped popup',
    run = function()
      v.with_panel(project, function(_, cb)
        cb { row('S', '*', '') }
      end, function(win)
        vim.o.columns = 32
        v.keys((vim.g.mapleader or '\\') .. '?')
        local helpwin, helpbuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        h.truthy(helpwin ~= win)
        h.truthy(vim.api.nvim_win_get_width(helpwin) <= 28)
        h.eq(true, vim.wo[helpwin].wrap)
        local text = table.concat(v.lines(helpbuf), '\n')
        for _, expected in ipairs {
          'td toggle descriptions (initially shown)',
          'th toggle previews (initially hidden)',
          '20% each',
          'keep rows until every owner succeeds',
        } do
          h.truthy(text:find(expected, 1, true))
        end
        h.eq(false, text:find('H reveal', 1, true) ~= nil)
        v.keys 'G' -- wrapped help remains scrollable
        h.eq(#v.lines(helpbuf), vim.api.nvim_win_get_cursor(helpwin)[1])
        v.keys 'q'
        h.eq(false, vim.api.nvim_buf_is_valid(helpbuf))
        h.eq(win, vim.api.nvim_get_current_win())
      end)
    end,
  },
  {
    name = 'UTF-8 columns use display cells but icon and scope extmarks use byte offsets',
    run = function()
      local fixtures = { row('界é', '*', '描述'), row(string.rep('界', 100), 'prod', '长描述') }
      v.with_panel(project, function(_, cb)
        cb(vim.deepcopy(fixtures))
      end, function(win, buf, resize)
        vim.g.glab_ci_ascii_icons = false
        local W = resize(80)
        local lines = v.lines(buf)
        local keyw = W - 3 - 4 - math.ceil(W * 0.20) - 6 - 5
        local prefix = fixtures[1].key .. string.rep(' ', keyw - 3) .. ' '
        local ns = vim.api.nvim_get_namespaces().glab_ci_variables
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { 0, 0 }, { 0, -1 }, { details = true })
        local expected = { GlabVarKey = { 0, #fixtures[1].key }, GlabVarScopeDefault = { #prefix + #'󰈔󰌾󰈉' + 1, #prefix + #'󰈔󰌾󰈉' + 2 } }
        local icons = { '󰈔', '󰌾', '󰈉' }
        local at = #prefix
        for _, mark in ipairs(marks) do
          local group = mark[4].hl_group
          if expected[group] then
            h.eq(expected[group], { mark[3], mark[4].end_col })
            expected[group] = nil
          elseif group == 'GlabVarIcon' then
            local glyph = table.remove(icons, 1)
            h.eq({ at, at + #glyph }, { mark[3], mark[4].end_col })
            at = at + #glyph
          end
        end
        h.eq({}, expected)
        h.eq({}, icons)
        h.eq('界é', lines[1]:sub(1, #'界é'))
        for _, width in ipairs { 80, 100, 120, 22, 12, 6, 3, 2, 1 } do
          W = resize(width)
          for _, keys in ipairs { 'td', 'th', 'td', 'th' } do
            v.keys(keys)
            for _, line in ipairs(v.lines(buf)) do
              h.truthy(vim.fn.strdisplaywidth(line) <= W, 'overflow at width ' .. width)
            end
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
              h.truthy(mark[4].end_col <= #v.lines(buf)[mark[2] + 1])
            end
          end
        end
      end)
    end,
  },
}
