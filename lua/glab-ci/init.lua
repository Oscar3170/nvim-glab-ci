-- Public API for the GlabCI plugin.
--
-- Layout (current): `:GlabCI` leaves the current window untouched and
-- opens a `:botright split` below it holding the pipeline list; the list
-- window is sized explicitly (~40 % of screen height) since `equalalways`
-- would otherwise force a 50/50 split. That single window hosts the whole
-- drill-down: selecting a pipeline (`views/pipeline.open`) swaps the list
-- buffer out for the pipeline/jobs buffer *in the same window*, and
-- opening a job (`views/log.open`) swaps in the log buffer. So the jobs
-- list replaces the pipeline list instead of opening a second pane to the
-- right (that Phase 5 side-by-side layout is gone). Each level's buffer is
-- `bufhidden=hide`, so `q` / `<Esc>` swaps the previous level back in.
--
-- Final layout, once a pipeline has been opened:
--
--     +---------------------------+
--     |  original current window  |  <- untouched, user keeps editing here
--     +---------------------------+
--     |  list | pipeline | log    |  <- bottom panel; one window, buffers
--     |       |  (jobs)  |        |     swapped in on drill-down
--     +---------------------------+
--
-- (Design history: the plan's original §4 sketch took over the current
-- window as the right pane with a `topleft vsplit` + placeholder, and Phase
-- 5 shipped a bottom panel vsplit into list + detail. Both are superseded
-- by the single-pane drill-down above.)
--
-- Public surface: `M.list()` — the single entry point. The Phase-1 PTY
-- fallback (`:GlabCI last` / `:GlabCI <args...>` via `open_terminal`) was
-- cut in Phase 5: the `:GlabCI` command always opens the list view.
local M = {}

local state = require 'glab-ci.state'
local highlights = require 'glab-ci.highlights'
local list_view = require 'glab-ci.views.list'
local log_view = require 'glab-ci.views.log'

-- Bootstrap the bottom-panel layout. The current window (whatever
-- the user had before `:GlabCI`) is left untouched: we only open a
-- `:botright split` below it for the list view. That same window is then
-- shared across the whole drill-down — `views/pipeline.open` swaps the
-- pipeline buffer in for the list buffer on the first `<CR>`, and
-- `views/log.open` swaps in the log buffer on a job's `<CR>`.
local function bootstrap_layout()
  local layout = state.create_layout()
  -- `botright split` opens a horizontal split with the new window at
  -- the very bottom (full width). The original current window is
  -- resized automatically by Neovim's `splitbelow` logic.
  vim.cmd 'botright split'
  local layout_win = vim.api.nvim_get_current_win()
  local list_buf = state.acquire_shared_view('list', 'default')
  local new_list = not list_buf
  if new_list then
    list_buf = vim.api.nvim_create_buf(false, true)
    state.set_shared_view_buf('list', 'default', list_buf)
  end

  vim.api.nvim_win_set_buf(layout_win, list_buf)
  -- Give a fresh panel a useful initial height, but do not pin it: users
  -- expect <C-w>= to equalize this window with every other split.
  vim.api.nvim_win_set_height(layout_win, math.max(10, math.floor(vim.o.lines * 0.4)))

  state.layout_open = true
  state.register_win(layout, layout_win)
  state.list_buf = list_buf
  state.list_win = layout_win
  if new_list then
    list_view.open(list_buf, layout_win)
  end

  -- Teardown and its triggers. With the single-window drill-down there is
  -- no `right_win` to close; instead a fresh `:GlabCI` has to tear down
  -- whatever level the user left open. Two triggers funnel into the same
  -- `teardown()`: (1) `BufWipeout` on the list buffer — fires when the
  -- user presses `q` at the *list* level, which force-deletes list_buf;
  -- (2) `WinClosed` on the layout window — fires when the user closes the
  -- window (`:close` / `<C-w>c` / `:q`) at any level. The buffers are
  -- `bufhidden=hide` so swap-out keeps them alive for back-navigation,
  -- which is why (1) alone can't cover closing the window at a deeper
  -- level. `once = true` on each autocmd + the `torn_down` guard make
  -- teardown idempotent (e.g. `q` at the list level wipes list_buf and
  -- closes the window, firing both triggers).
  local torn_down = false
  local function teardown(immediate)
    state.activate(layout)
    if torn_down then
      return
    end
    torn_down = true

    -- Capture references before reset_layout clears them. Some can be nil
    -- if the user pressed `q` at the list level before ever opening a
    -- pipeline.
    local layout_win = state.list_win
    -- Wiping the list buffer from Neovim's final tab window replaces its
    -- buffer but cannot close that window. Remember this at teardown time:
    -- a deferred callback may otherwise run after another split is opened
    -- and accidentally close the user's replacement window.
    local keep_layout_win = layout_win
      and vim.api.nvim_win_is_valid(layout_win)
      and #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(layout_win)) == 1
    local list_buf = state.list_buf
    local pipeline_buf = state.pipeline_buf
    local log_buf = state.log_buf

    -- Shared list/pipeline buffers keep polling until their final panel is
    -- closed. The private log stream always belongs only to this layout.
    local delete_list = state.release_shared_view(layout, 'list')
    local delete_pipeline = state.release_shared_view(layout, 'pipeline')
    if delete_list then
      state.stop_timer(list_buf)
    end
    if delete_pipeline then
      state.stop_timer(pipeline_buf)
    end

    -- Kill any in-flight `glab ci trace` stream. The trace may still be
    -- streaming for a running job, so SIGTERM the subprocess here before
    -- the buffers go away. `log_view.shutdown` also bumps the stream's
    -- generation counter so any in-flight libuv callbacks bail out
    -- harmlessly when they fire.
    log_view.shutdown()
    require('glab-ci.views.variables').shutdown(layout)

    local function close_and_delete()
      if not keep_layout_win and layout_win and vim.api.nvim_win_is_valid(layout_win) then
        pcall(vim.api.nvim_win_close, layout_win, true)
      end
      if delete_list then
        state.delete_buf(list_buf)
      end
      if delete_pipeline then
        state.delete_buf(pipeline_buf)
      end
      state.delete_buf(log_buf)
    end

    -- BufWipeout may be on the stack, so defer window and buffer management
    -- from autocmd-triggered teardown. A final-window `q` first replaces
    -- the panel buffer and calls this directly, where synchronous cleanup
    -- avoids leaving a stale named buffer before a new `:GlabCI` invocation.
    if immediate then
      close_and_delete()
    else
      vim.schedule(close_and_delete)
    end

    state.reset_layout()
  end

  state.set_layout_teardown(layout, teardown)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = list_buf,
    group = state.augroup,
    once = true,
    callback = function()
      teardown()
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(layout_win),
    group = state.augroup,
    once = true,
    callback = function()
      teardown()
    end,
  })
end

-- Open a fresh pipeline-list panel. Each invocation is independent, so two
-- running jobs can be followed concurrently in separate windows.
function M.list()
  highlights.setup()
  bootstrap_layout()
end

-- Entry point for the `:GlabCI` command (and any external callers).
-- Phase 5 cut the `last` / arbitrary-args PTY passthrough: every
-- invocation opens the list view.
function M.run()
  M.list()
end

local configured = false

--- Register the `:GlabCI` command.
---
--- This is safe to call repeatedly, which lets users call `setup()` from
--- their plugin-manager configuration even though `plugin/glab-ci.lua`
--- registers the command eagerly for direct runtimepath users.
function M.setup()
  if configured then
    return
  end
  vim.api.nvim_create_user_command('GlabCI', function(opts)
    M.run(opts.fargs)
  end, { nargs = '*', desc = 'Open the GlabCI pipeline list' })
  configured = true
end

return M
