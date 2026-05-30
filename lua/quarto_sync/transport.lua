local server = require("quarto_sync.server")

local M = {}

function M.send(payload)
  if not server.is_running() then
    return false
  end
  server.broadcast(payload)
  return true
end

return M
