if vim.g.loaded_glab_ci then
  return
end
vim.g.loaded_glab_ci = true

require('glab-ci').setup()
