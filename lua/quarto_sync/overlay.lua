local source_markers = require("quarto_sync.source_markers")
local util = require("quarto_sync.util")

local uv = vim.uv or vim.loop

local M = {}

local function path_has_prefix(path, prefix)
  if not path or not prefix or prefix == "" then
    return false
  end
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

local function should_skip(relative_path, protected_paths)
  for protected in pairs(protected_paths) do
    if path_has_prefix(relative_path, protected) then
      return true
    end
  end
  return false
end

local function should_recurse(relative_path, target_path, protected_paths)
  if path_has_prefix(target_path, relative_path) then
    return true
  end

  for protected in pairs(protected_paths) do
    if path_has_prefix(protected, relative_path) then
      return true
    end
  end

  return false
end

local function symlink(source, target)
  local ok, result = pcall(uv.fs_symlink, source, target, { dir = util.dir_exists(source) })
  if ok and (result == true or util.file_exists(target) or util.dir_exists(target)) then
    return true
  end

  local output = vim.fn.system({ "ln", "-s", source, target })
  if vim.v.shell_error == 0 then
    return true
  end

  return false, tostring(result or output)
end

local function populate(source_dir, target_dir, target_path, protected_paths, base_relative)
  vim.fn.mkdir(target_dir, "p")
  base_relative = base_relative or ""

  for _, name in ipairs(vim.fn.readdir(source_dir)) do
    local source_path = util.path_join(source_dir, name)
    local target_entry = util.path_join(target_dir, name)
    local relative_path = base_relative ~= "" and util.path_join(base_relative, name) or name

    if relative_path == target_path then
      -- The active document is written as an instrumented real file below.
    elseif should_skip(relative_path, protected_paths) then
      -- Generated project state stays inside the overlay instead of the source project.
    elseif util.dir_exists(source_path) and should_recurse(relative_path, target_path, protected_paths) then
      populate(source_path, target_entry, target_path, protected_paths, relative_path)
    else
      local ok, err = symlink(source_path, target_entry)
      if not ok then
        error(("Could not symlink %s to %s: %s"):format(source_path, target_entry, tostring(err)))
      end
    end
  end
end

local function protected_paths(opts)
  local paths = {
    [".quarto"] = true,
  }

  local output_dir = opts and opts.output_dir or "_site"
  if type(output_dir) == "string" and output_dir ~= "" then
    paths[output_dir:gsub("^/+", ""):gsub("/+$", "")] = true
  end

  return paths
end

function M.html_path_for_qmd(relative_path)
  return (relative_path or ""):gsub("%.qmd$", ".html")
end

function M.create(original_file, project_root, opts)
  opts = opts or {}
  original_file = util.normalize(original_file)
  project_root = util.normalize(project_root)
  local relative_path = util.relative_path(original_file, project_root)
  if not relative_path then
    util.notify("Could not map source file into Quarto project: " .. tostring(original_file), vim.log.levels.ERROR)
    return nil
  end

  local root = util.path_join("/tmp", ("quarto-sync-%s-%s"):format(vim.fn.getpid(), tostring(uv.hrtime())))
  local ok, err = pcall(function()
    populate(project_root, root, relative_path, protected_paths(opts))
  end)
  if not ok then
    pcall(vim.fn.delete, root, "rf")
    util.notify("Could not create Quarto sync overlay: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end

  local session = source_markers.create_shadow(original_file, project_root, {
    path = util.path_join(root, relative_path),
    overlay_root = root,
    preview_path = M.html_path_for_qmd(relative_path),
    mode = "website",
  })
  if not session then
    pcall(vim.fn.delete, root, "rf")
    return nil
  end

  session.relative_path = relative_path
  return session
end

function M._protected_paths(opts)
  return protected_paths(opts)
end

return M
