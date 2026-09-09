# Tests

`make test` runs the headless Neovim unit suite in `tests/unit/`. The tests mock `vim.system`, so they neither require nor invoke `glab` and never access GitLab.

Test files mirror their production module paths. For example, tests for `lua/glab-ci/logfmt.lua` belong in `tests/unit/glab-ci/logfmt_spec.lua`.

`tests/fixtures/` is for deterministic API and trace samples. `tests/e2e/` is intentionally separate and excluded from the default suite: future end-to-end tests can put real `glab` and GitLab-project setup there without making the mocked unit suite network-dependent.
