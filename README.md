# nvim-glab-ci

A native Neovim UI for GitLab CI pipelines, backed by the [`glab`](https://gitlab.com/gitlab-org/cli) CLI.

`:GlabCI` opens a bottom panel with a pipeline list. Select a pipeline to view its jobs, then select a job to stream and inspect its trace. The original editing window remains untouched.

## Requirements

- Neovim 0.10 or newer
- `glab` authenticated in the GitLab project you are editing

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

- `:GlabCI` — open or focus the pipeline list
- Pipeline list: `<CR>` opens a pipeline; `r` refreshes; `f` filters by branch; `c` clears the filter; `q` closes
- Pipeline jobs: `<CR>` opens a log; `r` refreshes; `R` retries; `T` triggers manual jobs; `C` cancels running/pending jobs; `q` / `<Esc>` returns to the list
- Job logs: `f` toggles follow mode; `r` re-fetches; `t`, `d`, `o`, `T`, and `i` control timestamp and stream-prefix display; `q` / `<Esc>` returns to the jobs

## Development

```sh
make test
make format-check
```

Unit tests use mocked `vim.system` responses and never contact GitLab or invoke `glab`. They live under `tests/unit/`, mirroring the Lua module path. `tests/e2e/` is reserved for future tests that exercise a real `glab` binary and GitLab project; those tests are intentionally not part of `make test`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
