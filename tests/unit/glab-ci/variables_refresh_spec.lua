local h = require 'helpers'
local v = require 'variables_helpers'
local api = require 'glab-ci.variables_api'
local project = {
  id = 17,
  host = 'gitlab.example',
  path_with_namespace = 'team/platform/app',
  namespace = { full_path = 'team/platform' },
}
local function item(owner, version, key)
  return { key = key or 'KEEP', environment_scope = '*', value = version .. '-' .. owner.path .. '\nlast', description = '', raw = true }
end
local function delayed_panel(run)
  local delayed, requests = false, {}
  v.with_panel(project, function(owner, cb)
    if delayed then
      requests[#requests + 1] = { owner = owner, cb = cb }
    else
      cb { item(owner, 'old') }
    end
  end, function(win, buf, resize)
    resize(100)
    v.groups()
    delayed = true
    run(win, buf, requests)
  end)
end
local function pending(buf, old, group)
  local expected = vim.list_slice(old)
  expected[#expected + 1] = group and (' Loading variables for group ' .. group .. '…') or ' Loading variables…'
  h.eq(expected, v.lines(buf))
end
local function marks(buf)
  local ns = vim.api.nvim_get_namespaces().glab_ci_variables
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
  end
  return out
end
return {
  {
    name = 'refresh keeps actionable rows and highlights until an atomic commit, and preserves expanded selection',
    run = function()
      delayed_panel(function(win, buf, requests)
        vim.api.nvim_win_set_cursor(win, { 4, 3 })
        v.keys '<CR>'
        local old, oldmarks = v.lines(buf), marks(buf)
        v.keys 'r'
        v.keys 'r'
        h.eq(1, #requests)
        pending(buf, old)
        h.eq({ 4, 3 }, vim.api.nvim_win_get_cursor(win))
        local currentmarks = marks(buf)
        table.remove(currentmarks) -- only the loading indicator is added
        h.eq(oldmarks, currentmarks)
        local changed
        vim.api.nvim_buf_attach(buf, false, {
          on_lines = function(_, _, _, first, last, newlast)
            changed = { first, last, newlast }
          end,
        })
        requests[1].cb { item(requests[1].owner, 'new', 'ADDED'), item(requests[1].owner, 'new') }
        h.eq(2, #requests)
        h.eq({ #old, #old + 1, #old + 1 }, changed) -- only the loading row changed
        pending(buf, old, 'team/platform')
        v.keys '<CR>' -- pending actions still address the committed group
        v.keys '<CR>'
        h.eq('old-team/platform', v.lines(buf)[5])
        pending(buf, old, 'team/platform')
        requests[2].cb { item(requests[2].owner, 'new') }
        h.eq(3, #requests)
        h.eq({ #old, #old + 1, #old + 1 }, changed)
        pending(buf, old, 'team')
        requests[3].cb { item(requests[3].owner, 'new') }
        h.eq({ 5, 3 }, vim.api.nvim_win_get_cursor(win))
        h.eq('new-team/platform', v.lines(buf)[6])
        h.eq('last', v.lines(buf)[7])
        h.eq(false, vim.tbl_contains(v.lines(buf), ' Loading variables…'))
        v.keys '<CR>' -- selected group, not the newly inserted project row
        h.eq(false, vim.tbl_contains(v.lines(buf), 'new-team/platform'))
        v.keys '<CR>'
        h.eq('new-team/platform', v.lines(buf)[6])
        -- A failed owner never commits even the successful staged project.
        old = v.lines(buf)
        v.keys 'r'
        requests[4].cb { item(requests[4].owner, 'never-committed') }
        local failure = 'Denied\nwith\27 details ' .. string.rep('detail-', 45)
        requests[5].cb(nil, failure)
        local expected = vim.list_slice(old)
        expected[vim.fn.index(expected, 'team/platform') + 1] = 'team/platform ! ' .. failure:gsub('[%c\27]', ' ')
        h.eq(expected, v.lines(buf))
        h.eq(5, #requests) -- abort; final group is not requested
        h.eq({ 5, 3 }, vim.api.nvim_win_get_cursor(win))
        v.keys 'r'
        pending(buf, old) -- retry clears only the error
        for i = 6, 8 do
          requests[i].cb { item(requests[i].owner, 'retry') }
        end
        h.eq('retry-team/platform', v.lines(buf)[5])
        h.eq({ 4, 3 }, vim.api.nvim_win_get_cursor(win))
        -- Removed selection/expansion falls back to a surviving record.
        v.keys 'r'
        for i = 9, 11 do
          requests[i].cb { item(requests[i].owner, 'surviving', 'REPLACEMENT') }
        end
        h.eq(4, vim.api.nvim_win_get_cursor(win)[1]) -- surviving row at the prior position
        h.eq(false, vim.tbl_contains(v.lines(buf), 'retry-team/platform'))
        v.keys '<CR>'
        h.eq('surviving-team/platform', v.lines(buf)[5])
        v.keys '<CR>'
        -- Errors from the project itself also retain all committed owners.
        old = v.lines(buf)
        v.keys 'r'
        requests[12].cb(nil, 'Project denied')
        expected = vim.list_slice(old)
        expected[#expected + 1] = ' ! team/platform/app: Project denied'
        h.eq(expected, v.lines(buf))
      end)
    end,
  },
  {
    name = 'group visibility restarts a captured owner set and late callbacks cannot replace a newer panel',
    run = function()
      delayed_panel(function(win, buf, requests)
        local old = v.lines(buf)
        v.keys 'r'
        requests[1].cb { item(requests[1].owner, 'canceled') }
        v.groups() -- restart with project only; hide already committed groups
        h.eq(3, #requests)
        h.eq({ old[1], ' Loading variables…' }, v.lines(buf))
        requests[2].cb { item(requests[2].owner, 'late-group') }
        h.eq(3, #requests)
        h.eq({ old[1], ' Loading variables…' }, v.lines(buf))
        requests[3].cb { item(requests[3].owner, 'current') }
        h.eq({ old[1] }, v.lines(buf)) -- previews still hidden; no trailing blank
        v.keys '<CR>'
        h.eq('current-team/platform/app', v.lines(buf)[2])
        v.keys '<CR>'
        v.groups() -- restart with all ancestors
        requests[4].cb { item(requests[4].owner, 'all') }
        v.groups() -- cancel again while a group is pending
        requests[5].cb(nil, 'late failure')
        h.eq(false, table.concat(v.lines(buf), '\n'):find('late failure', 1, true) ~= nil)
        requests[6].cb { item(requests[6].owner, 'last') }
        v.keys 'r'
        local state = require 'glab-ci.state'
        local view = require 'glab-ci.views.variables'
        local layout = state.win_layouts[win]
        -- Return to the list before wiping, then open a fresh variables session.
        vim.api.nvim_win_set_buf(win, state.list_buf)
        view.shutdown(layout)
        h.eq(false, vim.api.nvim_buf_is_valid(buf))
        state.activate(layout)
        view.open()
        local fresh = vim.api.nvim_win_get_buf(win)
        h.eq({ ' Loading variables…' }, v.lines(fresh))
        requests[7].cb { item(requests[7].owner, 'dead-panel') }
        h.eq({ ' Loading variables…' }, v.lines(fresh))
        requests[8].cb { item(requests[8].owner, 'fresh') }
        v.keys '<CR>'
        h.eq('fresh-team/platform/app', v.lines(fresh)[2])
      end)
    end,
  },
  {
    name = 'a first group refresh failure gets a source header without discarding committed project rows',
    run = function()
      local path = 'tëam/' .. string.rep('nested/', 20) .. 'group'
      local namespace = { full_path = path }
      local source = vim.tbl_extend('force', project, { namespace = namespace })
      local requests, delayed = {}, false
      v.with_panel(source, function(owner, cb)
        if delayed then
          requests[#requests + 1] = { owner = owner, cb = cb }
        else
          cb { item(owner, 'committed') }
        end
      end, function(win, buf, resize)
        resize(80)
        local old = v.lines(buf)
        h.eq(1, #old) -- project-only view has no trailing separator
        delayed = true
        v.groups()
        requests[1].cb { item(requests[1].owner, 'staged') }
        pending(buf, old, path)
        local failure = 'Denied\nwith\27 details ' .. string.rep('detail-', 30)
        requests[2].cb(nil, failure)
        local error_header = path .. ' ! ' .. failure:gsub('[%c\27]', ' ')
        h.eq({ old[1], '', error_header }, v.lines(buf))
        h.eq(1, vim.api.nvim_win_get_cursor(win)[1])
        h.eq(true, vim.wo[win].wrap)
        local ns = vim.api.nvim_get_namespaces().glab_ci_variables
        local highlights = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { 2, 0 }, { 2, -1 }, { details = true })) do
          highlights[mark[4].hl_group] = { mark[3], mark[4].end_col }
        end
        h.eq({ GlabVarGroup = { 0, #path }, GlabVarError = { #path, #error_header } }, highlights)
        v.keys '<CR>' -- the retained project row is still actionable
        h.eq('committed-team/platform/app', v.lines(buf)[2])
        v.keys '<CR>'
        v.keys 'r'
        pending(buf, old) -- retry removes the transient failed group header
        requests[3].cb { item(requests[3].owner, 'retry') }
        pending(buf, old, path)
        v.groups() -- cancel all groups while their retry is pending
        requests[4].cb(nil, 'late error')
        requests[5].cb { item(requests[5].owner, 'retry') }
        h.eq(1, #v.lines(buf))
        h.eq(false, table.concat(v.lines(buf)):find('late error', 1, true) ~= nil)
      end)
    end,
  },
  {
    name = 'mutation-triggered refresh retains the snapshot through delayed owners and a failed refresh',
    run = function()
      local saved = { get = api.get, delete = api.delete, input = vim.ui.input }
      api.get = function(owner, _, _, cb)
        cb(item(owner, 'old'))
      end
      api.delete = function(_, _, _, cb)
        cb(true)
      end
      vim.ui.input = function(_, cb)
        cb 'team/platform/app / KEEP [*]'
      end
      local ok, err = xpcall(function()
        delayed_panel(function(win, buf, requests)
          local old = v.lines(buf)
          -- Even a pre-write refresh is invalidated when a write completes.
          v.keys 'r'
          v.keys 'D'
          h.eq('diff', vim.bo[vim.api.nvim_get_current_buf()].filetype)
          v.keys 'y'
          vim.api.nvim_set_current_win(win)
          h.eq(2, #requests)
          pending(buf, old)
          requests[1].cb { item(requests[1].owner, 'stale-pre-write') }
          pending(buf, old)
          requests[2].cb {}
          pending(buf, old, 'team/platform')
          requests[3].cb(nil, 'Group denied after deletion')
          local expected = vim.list_slice(old)
          expected[vim.fn.index(expected, 'team/platform') + 1] = 'team/platform ! Group denied after deletion'
          h.eq(expected, v.lines(buf))
          v.keys 'r'
          for i = 4, 6 do
            requests[i].cb {}
          end
          h.eq({ '   (no variables)', '', 'team/platform', '   (no variables)', '', 'team', '   (no variables)' }, v.lines(buf))
        end)
      end, debug.traceback)
      api.get, api.delete, vim.ui.input = saved.get, saved.delete, saved.input
      if not ok then
        error(err, 0)
      end
    end,
  },
}
