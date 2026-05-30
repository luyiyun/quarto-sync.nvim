local config = require("quarto_sync.config")

local M = {}

local did_setup = false

local function create_command(name, callback, opts)
  if vim.fn.exists(":" .. name) == 0 then
    vim.api.nvim_create_user_command(name, callback, opts or {})
  end
end

function M.setup(opts)
  config.setup(opts)

  if did_setup then
    return
  end
  did_setup = true

  require("quarto_sync.preview").setup_autocmds()

  create_command("QSyncPreview", function()
    require("quarto_sync.preview").preview()
  end, {})

  create_command("QSyncStop", function()
    require("quarto_sync.preview").stop()
  end, {})

  create_command("QSyncRestart", function()
    require("quarto_sync.preview").restart()
  end, {})

  create_command("QSyncInstallExtension", function(command)
    require("quarto_sync.extension").install({ bang = command.bang })
  end, { bang = true })

  create_command("QSyncStatus", function()
    require("quarto_sync.preview").status()
  end, {})
end

function M.preview()
  return require("quarto_sync.preview").preview()
end

function M.stop()
  return require("quarto_sync.preview").stop()
end

function M.restart()
  return require("quarto_sync.preview").restart()
end

function M.status()
  return require("quarto_sync.preview").status()
end

function M.install_extension(opts)
  return require("quarto_sync.extension").install(opts)
end

return M
