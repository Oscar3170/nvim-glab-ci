-- Highlight groups for the GlabCI plugin.
--
-- Status colors are a single source of truth shared by every renderer
-- (list, pipeline, ANSI log). Phase 2 added `GlabDim` (for `allow_failure`
-- jobs) and a glyph table the pipeline view uses for the per-job status
-- icon. Phase 4 extends this with the ANSI SGR -> hl-group mappings used by
-- the log view: `GlabBold`, `GlabUnderline`, `GlabDim`, the 8 base colors
-- (`GlabBlack`/`GlabRed`/...) and their bright variants (`GlabBrightRed`/...).
-- See PLAN-glab-nativization.md §9.
local M = {}

-- Pipeline statuses: highlight group + foreground color (GitLab-style).
M.STATUSES = {
  success = { hl = 'GlabSuccess', fg = '#2e7d32' },
  failed = { hl = 'GlabFailed', fg = '#c91c00' },
  running = { hl = 'GlabRunning', fg = '#1976d2' },
  pending = { hl = 'GlabPending', fg = '#f9a825' },
  canceled = { hl = 'GlabCanceled', fg = '#757575' },
  skipped = { hl = 'GlabSkipped', fg = '#757575' },
  created = { hl = 'GlabCreated', fg = '#9e9e9e' },
  manual = { hl = 'GlabManual', fg = '#9e9e9e' },
}

-- Status glyphs used by the pipeline detail view. Glyphs match the glab
-- CLI's own TUI so the UI is recognisable. `created` falls back to the
-- same glyph as `manual` since both are "not yet run" states.
M.STATUS_GLYPH = {
  success = '✓',
  failed = '✘',
  running = '⟳',
  pending = '◌',
  manual = '◌',
  canceled = '⊘',
  skipped = '»',
  created = '◌',
}

-- ANSI SGR -> hl group table. Used by `ansi.lua` to map SGR codes (set
-- via `\x1b[<n>m`) to extmark hl groups. Two flavors per color: the base
-- 30-37 ("GlabRed", "GlabGreen", ...) and the bright 90-97 variants
-- ("GlabBrightRed", ...). Bold, underline and dim (faint) are their own
-- groups so they layer cleanly. See PLAN-glab-nativization.md §9.
-- Log-prefix highlight groups (see views/log.lua): the stream type
-- character (`O`/`E`) and the light-grey `00` (job-control) content.
-- The stream *number* (e.g. `00`) stays the default Normal fg, so it needs
-- no group here.
M.GlabLogO = 'GlabLogO' -- dark blue, stdout stream indicator
M.GlabLogE = 'GlabLogE' -- red, stderr stream type
M.GlabLogControl = 'GlabLogControl' -- light grey, `00` job-control content
M.GlabLogSection = 'GlabLogSection' -- teal, `00O+` section content
M.GlabLogCmd = 'GlabLogCmd' -- green, `01O $ …` command lines

M.ANSI_HL = {
  [0] = nil,
  [1] = 'GlabBold',
  [2] = 'GlabDim',
  [4] = 'GlabUnderline',
  [22] = nil,
  [24] = nil,
  [30] = 'GlabBlack',
  [31] = 'GlabRed',
  [32] = 'GlabGreen',
  [33] = 'GlabYellow',
  [34] = 'GlabBlue',
  [35] = 'GlabMagenta',
  [36] = 'GlabCyan',
  [37] = 'GlabWhite',
  [90] = 'GlabBrightBlack',
  [91] = 'GlabBrightRed',
  [92] = 'GlabBrightGreen',
  [93] = 'GlabBrightYellow',
  [94] = 'GlabBrightBlue',
  [95] = 'GlabBrightMagenta',
  [96] = 'GlabBrightCyan',
  [97] = 'GlabBrightWhite',
}

local setup_done = false

-- ANSI colors per base / bright flavor. Each is a foreground hex; we use
-- the user's `Normal` fg as the implicit default (so "no SGR" lines
-- inherit the buffer's text color rather than forcing a specific one).
local ANSI_BASE_COLORS = {
  GlabBlack = '#3c3c3c',
  GlabRed = '#cc0000',
  GlabGreen = '#4e9a06',
  GlabYellow = '#c4a000',
  GlabBlue = '#3465a4',
  GlabMagenta = '#75507b',
  GlabCyan = '#06989a',
  GlabWhite = '#d3d7cf',
}

local ANSI_BRIGHT_COLORS = {
  GlabBrightBlack = '#8e8e8e',
  GlabBrightRed = '#ef2929',
  GlabBrightGreen = '#8ae234',
  GlabBrightYellow = '#fce94f',
  GlabBrightBlue = '#729fcf',
  GlabBrightMagenta = '#ad7fa8',
  GlabBrightCyan = '#34e2e2',
  GlabBrightWhite = '#eeeeec',
}

-- Idempotently create all highlight groups, and re-apply them on
-- ColorScheme (a new colorscheme may otherwise clear them).
function M.setup()
  if setup_done then
    return
  end
  for _, s in pairs(M.STATUSES) do
    vim.api.nvim_set_hl(0, s.hl, { fg = s.fg })
  end
  -- Dim color for `allow_failure` jobs, section dividers, and SGR faint
  -- (code 2). Linked to `Comment` so it follows whatever the user's
  -- colorscheme uses for muted text.
  vim.api.nvim_set_hl(0, 'GlabDim', { link = 'Comment' })
  for name, fg in pairs(ANSI_BASE_COLORS) do
    vim.api.nvim_set_hl(0, name, { fg = fg })
  end
  for name, fg in pairs(ANSI_BRIGHT_COLORS) do
    vim.api.nvim_set_hl(0, name, { fg = fg })
  end
  vim.api.nvim_set_hl(0, 'GlabBold', { bold = true })
  vim.api.nvim_set_hl(0, 'GlabUnderline', { underline = true })
  vim.api.nvim_set_hl(0, 'GlabLogO', { fg = '#4a7bb5' }) -- dark blue
  vim.api.nvim_set_hl(0, 'GlabLogE', { fg = '#ff5f56' }) -- red
  vim.api.nvim_set_hl(0, 'GlabLogControl', { fg = '#9e9e9e' }) -- light grey
  vim.api.nvim_set_hl(0, 'GlabLogSection', { fg = '#0ea5a4' }) -- teal
  vim.api.nvim_set_hl(0, 'GlabLogCmd', { fg = '#4e9a06' }) -- green
  vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      for _, s in pairs(M.STATUSES) do
        vim.api.nvim_set_hl(0, s.hl, { fg = s.fg })
      end
      vim.api.nvim_set_hl(0, 'GlabDim', { link = 'Comment' })
      for name, fg in pairs(ANSI_BASE_COLORS) do
        vim.api.nvim_set_hl(0, name, { fg = fg })
      end
      for name, fg in pairs(ANSI_BRIGHT_COLORS) do
        vim.api.nvim_set_hl(0, name, { fg = fg })
      end
      vim.api.nvim_set_hl(0, 'GlabBold', { bold = true })
      vim.api.nvim_set_hl(0, 'GlabUnderline', { underline = true })
      vim.api.nvim_set_hl(0, 'GlabLogO', { fg = '#4a7bb5' })
      vim.api.nvim_set_hl(0, 'GlabLogE', { fg = '#ff5f56' })
      vim.api.nvim_set_hl(0, 'GlabLogControl', { fg = '#9e9e9e' })
      vim.api.nvim_set_hl(0, 'GlabLogSection', { fg = '#0ea5a4' })
      vim.api.nvim_set_hl(0, 'GlabLogCmd', { fg = '#4e9a06' })
    end,
  })
  setup_done = true
end

return M
