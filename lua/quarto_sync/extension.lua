local util = require("quarto_sync.util")

local M = {}

function M.source_dir()
  return util.path_join(util.plugin_root(), "_extensions", "quarto-sync")
end

function M.filter_path()
  return util.path_join(M.source_dir(), "quarto-sync.lua")
end

function M.target_dir(project_root)
  return util.path_join(project_root, "_extensions", "quarto-sync")
end

function M.is_installed(project_root)
  return util.dir_exists(M.target_dir(project_root))
end

local function copy_file(source, target)
  local data = vim.fn.readfile(source, "b")
  vim.fn.writefile(data, target, "b")
end

local function copy_dir(source, target)
  vim.fn.mkdir(target, "p")
  for _, name in ipairs(vim.fn.readdir(source)) do
    local source_path = util.path_join(source, name)
    local target_path = util.path_join(target, name)
    if util.dir_exists(source_path) then
      copy_dir(source_path, target_path)
    else
      copy_file(source_path, target_path)
    end
  end
end

function M.install(opts)
  opts = opts or {}

  local file = util.current_file()
  if not file then
    util.notify("Open a .qmd file before installing the Quarto extension.", vim.log.levels.ERROR)
    return false
  end

  local project_root = util.find_project_root(file)
  local source = M.source_dir()
  local target = M.target_dir(project_root)

  if not util.dir_exists(source) then
    util.notify("Could not find bundled extension at " .. source, vim.log.levels.ERROR)
    return false
  end

  if util.dir_exists(target) then
    if not opts.bang then
      util.notify("Extension already exists at " .. target .. ". Use :QSyncInstallExtension! to overwrite.", vim.log.levels.WARN)
      return false
    end
    local deleted = vim.fn.delete(target, "rf")
    if deleted ~= 0 then
      util.notify("Could not remove existing extension at " .. target, vim.log.levels.ERROR)
      return false
    end
  end

  vim.fn.mkdir(util.path_join(project_root, "_extensions"), "p")
  copy_dir(source, target)

  util.notify(
    "Installed quarto-sync extension to "
      .. target
      .. ". Add `filters: - quarto-sync` to _quarto.yml or the .qmd YAML front matter.",
    vim.log.levels.INFO
  )
  return true
end

return M
