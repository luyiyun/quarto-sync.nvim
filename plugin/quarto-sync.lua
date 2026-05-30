if vim.g.loaded_quarto_sync_nvim == 1 then
  return
end
vim.g.loaded_quarto_sync_nvim = 1

require("quarto_sync").setup()
