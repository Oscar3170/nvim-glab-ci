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
local pipeline_view = require 'glab-ci.views.pipeline'
local log_view = require 'glab-ci.views.log'

-- Bootstrap the bottom-panel layout. The current window (whatever
-- the user had before `:GlabCI`) is left untouched: we only open a
-- `:botright split` below it for the list view. That same window is then
-- shared across the whole drill-down — `views/pipeline.open` swaps the
-- pipeline buffer in for the list buffer on the first `<CR>`, and
-- `views/log.open` swaps in the log buffer on a job's `<CR>`.
local function bootstrap_layout()
  -- `botright split` opens a horizontal split with the new window at
  -- the very bottom (full width). The original current window is
  -- resized automatically by Neovim's `splitbelow` logic.
  vim.cmd 'botright split'
  local layout_win = vim.api.nvim_get_current_win()
  local list_buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_win_set_buf(layout_win, list_buf)
  -- Explicit height: with default `equalalways` the split would be
  -- 50/50 (PLAN §4's warning applies to this bottom-panel layout too,
  -- review 3.1). Size the list panel to ~40 % of the screen height and
  -- pin it so later window events can't re-equalize it.
  vim.wo[layout_win].winfixheight = true
  vim.api.nvim_win_set_height(layout_win, math.max(10, math.floor(vim.o.lines * 0.4)))

  state.layout_open = true
  list_view.open(list_buf, layout_win)

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
  local function teardown()
    if torn_down then
      return
    end
    torn_down = true

    -- Capture references before reset_layout clears them. Some can be nil
    -- if the user pressed `q` at the list level before ever opening a
    -- pipeline.
    local layout_win = state.list_win
    local list_buf = state.list_buf
    local pipeline_buf = state.pipeline_buf
    local log_buf = state.log_buf

    -- Stop both refresh timers explicitly. The per-buffer BufDelete
    -- handlers in views/list.lua and views/pipeline.lua will run again
    -- after the wipe, but those are idempotent.
    state.stop_timer(list_buf)
    state.stop_timer(pipeline_buf)

    -- Kill any in-flight `glab ci trace` stream. The trace may still be
    -- streaming for a running job, so SIGTERM the subprocess here before
    -- the buffers go away. `log_view.shutdown` also bumps the stream's
    -- generation counter so any in-flight libuv callbacks bail out
    -- harmlessly when they fire.
    log_view.shutdown()

    -- Wipe + close everything synchronously-safe: defer the window close
    -- and the buffer deletes via vim.schedule. Doing either from inside
    -- the BufWipeout autocmd of another buffer can deadlock
    -- `nvim_buf_delete` on certain timing paths (re-entering the
    -- buffer/window-management code while list_buf's wipe is still on the
    -- stack). The scheduled callbacks fire after nvim_buf_delete on
    -- list_buf returns.
    vim.schedule(function()
      if layout_win and vim.api.nvim_win_is_valid(layout_win) then
        pcall(vim.api.nvim_win_close, layout_win, true)
      end
      state.delete_buf(list_buf)
      state.delete_buf(pipeline_buf)
      state.delete_buf(log_buf)
    end)

    state.reset_layout()
  end

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = list_buf,
    group = state.augroup,
    once = true,
    callback = teardown,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(layout_win),
    group = state.augroup,
    once = true,
    callback = teardown,
  })
end

-- Open the pipeline list view. Reuses the existing layout if one is
-- already open (dropping back to the list level if the user left a
-- pipeline / log open, then focusing the list window). Otherwise
-- bootstraps a fresh layout.
function M.list()
  highlights.setup()
  if state.layout_open and state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
    -- Re-invoking `:GlabCI` means "show me the list": if the window is
    -- currently showing a pipeline or log (a deeper drill-down level),
    -- swap the list buffer back in first.
    if state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf) and vim.api.nvim_win_get_buf(state.list_win) ~= state.list_buf then
      pipeline_view.back_to_list()
    end
    vim.api.nvim_set_current_win(state.list_win)
    return
  end
  -- Defensive: state says layout is open but the window is gone — reset
  -- and rebuild to avoid a half-torn-down state.
  if state.layout_open then
    state.reset_layout()
  end
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
