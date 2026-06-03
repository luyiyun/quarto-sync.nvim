local devlog = require("quarto_sync.devlog")
local server = require("quarto_sync.server")

local M = {}

function M.send(payload)
  if not server.is_running() then
    devlog.log("transport: send skipped", { reason = "server not running", payload = payload })
    return false
  end
  devlog.log("transport: send", payload)
  server.broadcast(payload)
  return true
end

return M
