local M = {}

local uv = vim.uv or vim.loop

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "quarto-sync.nvim" })
  end)
end

function M.path_join(...)
  local parts = { ... }
  local path = table.concat(parts, "/")
  path = path:gsub("/+", "/")
  return path
end

function M.normalize(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

function M.current_file()
  local name = vim.api.nvim_buf_get_name(0)
  return M.normalize(name)
end

function M.dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

function M.file_exists(path)
  local stat = path and uv.fs_stat(path) or nil
  return stat ~= nil and stat.type == "file"
end

function M.dir_exists(path)
  local stat = path and uv.fs_stat(path) or nil
  return stat ~= nil and stat.type == "directory"
end

function M.is_qmd(path)
  return type(path) == "string" and path:match("%.qmd$") ~= nil
end

function M.path_starts_with(path, root)
  path = M.normalize(path)
  root = M.normalize(root)
  if not path or not root then
    return false
  end
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  return path == root:sub(1, -2) or path:sub(1, #root) == root
end

function M.find_project_root(file)
  local start = M.dirname(M.normalize(file))
  if not start or start == "" then
    return nil
  end

  local dir = start
  while dir and dir ~= "" do
    if M.file_exists(M.path_join(dir, "_quarto.yml")) or M.file_exists(M.path_join(dir, "_quarto.yaml")) then
      return dir
    end

    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  return start
end

function M.plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

function M.json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

function M.json_decode(value)
  if vim.json and vim.json.decode then
    return vim.json.decode(value)
  end
  return vim.fn.json_decode(value)
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function strip_yaml_front_matter(lines)
  if lines[1] ~= "---" then
    return 1
  end

  for index = 2, #lines do
    if lines[index] == "---" or lines[index] == "..." then
      return index + 1
    end
  end

  return 1
end

function M.approximate_block_index(bufnr, target_line)
  bufnr = bufnr or 0
  target_line = math.max(1, target_line or 1)

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, target_line, false)
  if not ok or not lines then
    return 1
  end

  local start_line = strip_yaml_front_matter(lines)
  local count = 0
  local previous_blank = true
  local in_code = false
  local list_active = false
  local quote_active = false

  for index = start_line, #lines do
    local line = lines[index] or ""
    local trimmed = line:gsub("^%s+", "")

    if is_blank(line) then
      previous_blank = true
      list_active = false
      quote_active = false
    elseif trimmed:match("^```") or trimmed:match("^~~~") then
      if not in_code then
        count = count + 1
      end
      in_code = not in_code
      previous_blank = false
      list_active = false
      quote_active = false
    elseif in_code then
      previous_blank = false
    elseif trimmed:match("^#+%s+") then
      count = count + 1
      previous_blank = false
      list_active = false
      quote_active = false
    elseif trimmed:match("^[-*+]%s+") or trimmed:match("^%d+[.)]%s+") then
      if previous_blank or not list_active then
        count = count + 1
      end
      previous_blank = false
      list_active = true
      quote_active = false
    elseif trimmed:match("^>") then
      if previous_blank or not quote_active then
        count = count + 1
      end
      previous_blank = false
      list_active = false
      quote_active = true
    elseif trimmed:match("^:::+") then
      count = count + 1
      previous_blank = false
      list_active = false
      quote_active = false
    elseif previous_blank then
      count = count + 1
      previous_blank = false
      list_active = false
      quote_active = false
    else
      previous_blank = false
    end
  end

  return math.max(1, count)
end

return M
