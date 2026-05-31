local M = {}

M.defaults = {
  host = "127.0.0.1",
  port = 18787,
  quarto_cmd = "quarto",
  browser_cmd = nil,
  open_browser = true,
  sync_on_cursor_move = true,
  sync_from_browser = true,
  debounce_ms = 120,
  install_extension_if_missing = false,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
