# nvim-glab-ci

A native Neovim UI for GitLab CI pipelines, backed by the [`glab`](https://gitlab.com/gitlab-org/cli) CLI.

`:GlabCI` opens a bottom panel with a pipeline list. Select a pipeline to view its jobs, then select a job to stream and inspect its trace. The original editing window remains untouched.

## Requirements

- Neovim 0.10 or newer
- `glab` authenticated in the GitLab project you are editing
- `yq` v4 for variable **editing** (viewing does not use yq)

## Installation

### lazy.nvim

Configure `GlabCI` as a command trigger to defer loading the plugin until its first use:

```lua
{
  'oscar3170/nvim-glab-ci',
  cmd = 'GlabCI',
}
```

`lazy.nvim` loads the plugin before replaying the command, so no `config` or `setup()` callback is needed.

### vim.pack

`vim.pack` is available in Neovim 0.12+. Load the plugin during startup so it can register `:GlabCI`:

```lua
vim.pack.add({
  { src = 'https://github.com/oscar3170/nvim-glab-ci', name = 'nvim-glab-ci' },
})
```

## Usage

- `:GlabCI` — open a new pipeline-list panel (multiple panels can follow jobs concurrently; `<C-w>=` equalizes them). Panels showing the same list or pipeline share one buffer and refresh cycle.
- Pipeline list: `<CR>` opens a pipeline; `v` opens the project's CI/CD variables; `r` refreshes; `f` filters by branch; `c` clears the filter; `q` closes
- Pipeline jobs: `<CR>` opens logs for jobs that have run; `r` refreshes; `R` retries; `T` triggers manual jobs; `C` cancels running/pending/created jobs; `q` / `<Esc>` returns to the list
- Job logs: a sticky one-row winbar shows job status and identity while the trace scrolls. `H` toggles compact/detailed, width-aware header content that always remains one row; `f` toggles follow mode; `r` re-fetches; `t`, `d`, `o`, `T`, and `i` control timestamp and stream-prefix display; `q` / `<Esc>` returns to the jobs

### CI/CD variables

`v` opens variables for the current `glab` project (not the selected pipeline). Project variables appear first; `<leader>G` toggles variables from every ancestor group, nearest first.

| Key | Action |
| --- | --- |
| `r` | Refresh without clearing or partially replacing an existing table |
| `<leader>G` | Include/hide ancestor groups (off on entry) |
| `td` | Show/hide descriptions (shown on entry) |
| `th` | Reveal/hide previews for all rows (hidden on entry); hiding also collapses expansions |
| `<CR>` | Expand/collapse the selected row's complete value |
| `e` / `E` | Edit one / every currently displayed record in a YAML split |
| `%` / `g%` | Create in project / choose an ancestor group and create |
| `D` | Confirm and review deletion of the selected record (the **only** delete path) |
| `U` | Choose an in-session pre-update version and review restoration |
| `<leader>?` | Toggle dismissible help (`q`/`<Esc>` also dismiss) |
| `q` / `<Esc>` | Return to pipelines |

Icons (Nerd Font required): `󰈔` = file variable; `󰌾` = protected; `󰈉` = masked (muted) or hidden (accent). Group paths remain visible as source labels even without a Nerd Font. Without Nerd Fonts, set `vim.g.glab_ci_ascii_icons = true` for `F`/`P`/`M`/`H` markers. **All** previews start hidden, regardless of GitLab flags. `unavailable` means the API did not provide a value, not that it is empty. Each project/group section has independently aligned key, icon, scope, description and value columns; a long key in one owner does not affect another. Keys appear at the left edge; `*` scopes are dimmed. Descriptions start shown and reserve at least 20% of usable text width (window width minus gutters and one safety column, rounded up), including empty descriptions. Revealed previews also reserve at least 20%; hidden previews reserve only their marker (or `unavailable`). Remaining space goes to keys first, then longer descriptions, then value previews. Exceptionally narrow windows omit icons, shorten scopes and reduce description/value floors as needed without overflowing. `td`, `th` and resizing immediately reflow columns; toggle settings are private to each panel. On a narrow window, moving the cursor onto a truncated key overlays its full name across the other columns (up to the visible window width); the underlying row and value stay unchanged. GitLab limits project and group variable keys to 255 characters ([project API](https://docs.gitlab.com/api/project_level_variables/), [group API](https://docs.gitlab.com/api/group_level_variables/)). Previews are truncated; expanded values have no indentation and use Neovim's soft wrapping. Only actual newlines in a value create new buffer lines.

Editing opens an in-memory YAML buffer below the panel, with a virtual `glab://` name and no disk pathname. Edit `variables:` entries; `owner`, `key` and `original_environment_scope` are read-only for existing records. Change `environment_scope` explicitly to rename a scope; use `%`/`g%` for new keys and `D` for deletion. Removing an entry from `E` or adding a new one there is rejected before any writes. `value` is the last field in each entry. A value containing newlines uses `value: |-`; `trailing_newlines: N` (immediately before `value`) restores stripped final newlines exactly. Values with CR/control bytes use quoted, escaped YAML instead. An unavailable `value: null` must be replaced explicitly before an update. Comments, order and scalar quoting alone never write to GitLab.

Close the split with `:q`, `ZZ`, or a window-close command to validate and open a **full-value diff** (control bytes are escaped as `\xNN`); `y` in the diff confirms, `q`/`<Esc>` cancels and reopens your text. `:w` alone never submits or writes a file. While an edit or review is open, `q`/`<Esc>` in the variables panel returns focus to it instead of closing the panel or discarding text. Close the editor first, or use `:q!` entered on Neovim's command line (or `ZQ` in the YAML buffer) to discard explicitly. A programmatic `vim.cmd('q!')` cannot be distinguished by `QuitPre` on some Neovim versions and may instead open the review; cancel it to return to the editor. Unchanged close is a no-op. On validation, permission, conflict or API errors the editor reopens with its original text and a nonsecret error comment. Updates to multiple records are sequential, **not transactional**: a failure lists successfully applied identities; retries skip already-applied values. Group scope editing may require GitLab Premium/Ultimate.

Values and diff buffers can contain secrets. They have no disk pathname, swapfile, persistent undo or modelines, are wiped when dismissed, and submitted values go through process stdin rather than command arguments. Previous update snapshots (up to three per identity) live only in Lua memory until Neovim exits; deleted records have no restore history. Explicit yanks, in-process memory inspection and external Neovim plugins are outside this guarantee. Avoid exporting editor/diff buffers or enabling plugins that persist buffer contents.

## Development

```sh
make test
make format-check
```

Unit tests mock GitLab/`glab` calls and never contact GitLab; YAML round-trip tests invoke the installed `yq` v4. They live under `tests/unit/`, mirroring the Lua module path. `tests/e2e/` is reserved for future tests that exercise a real `glab` binary and GitLab project; those tests are intentionally not part of `make test`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
