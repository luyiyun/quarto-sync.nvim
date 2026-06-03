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

function M.relative_path(path, root)
  path = M.normalize(path)
  root = M.normalize(root)
  if not path or not root then
    return nil
  end

  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  if path:sub(1, #root) ~= root then
    return nil
  end

  local relative = path:sub(#root + 1)
  return relative ~= "" and relative or nil
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

function M.display_math_label(line)
  local text = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return text:match("^%$%$%s+%{[^}]*#(eq%-[%w%._:%-]+)[^}]*%}$")
end

function M.is_display_math_delimiter(line)
  local text = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "$$" then
    return true
  end

  return M.display_math_label(text) ~= nil
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

local function normalize_label(label)
  if not label or label == "" then
    return nil
  end

  label = label:gsub("^['\"]", ""):gsub("['\"},%]]+$", "")
  return label ~= "" and label or nil
end

local function extract_label(line)
  line = line or ""
  return normalize_label(line:match("label%s*[:=]%s*['\"]?([%w%._:%-]+)"))
    or normalize_label(line:match("[{,%s]#([%w%._:%-]+)"))
end

local function find_fenced_block(lines, target_line)
  local active = nil

  for index = 1, #lines do
    local line = lines[index] or ""
    local fence, rest = line:match("^%s*([`~][`~][`~]+)(.*)$")

    if fence then
      local char = fence:sub(1, 1)
      if active and active.char == char and #fence >= active.len then
        active.finish = index
        if index >= target_line then
          return active
        end
        active = nil
      elseif not active then
        active = {
          start = index,
          finish = nil,
          char = char,
          len = #fence,
          opener = line,
          rest = rest or "",
        }
      end
    end

    if index >= target_line then
      return active
    end
  end

  return active
end

local function fenced_block_anchor(lines, target_line)
  local block = find_fenced_block(lines, target_line)
  if not block then
    return nil
  end

  local anchor = extract_label(block.opener) or extract_label(block.rest)
  if anchor then
    return anchor
  end

  local finish = block.finish or #lines
  for index = block.start + 1, math.min(finish - 1, block.start + 25) do
    if not M.is_display_math_delimiter(lines[index]) then
      anchor = extract_label(lines[index])
    end
    if anchor then
      return anchor
    end
  end

  return nil
end

local function fence_info(line)
  local fence = (line or ""):match("^%s*([`~][`~][`~]+)")
  if not fence then
    return nil
  end
  return fence:sub(1, 1), #fence
end

local function display_math_anchor(lines, target_line, start_line)
  local active_fence = nil
  local math_start = nil
  local math_anchor = nil

  for index = start_line or 1, #lines do
    local line = lines[index] or ""
    local trimmed = line:gsub("^%s+", "")
    local fence_char, fence_len = fence_info(line)

    if active_fence then
      if fence_char == active_fence.char and fence_len >= active_fence.len then
        active_fence = nil
      end
    elseif fence_char then
      active_fence = {
        char = fence_char,
        len = fence_len,
      }
    elseif math_start then
      if M.is_display_math_delimiter(trimmed) then
        local anchor = M.display_math_label(trimmed) or math_anchor
        if target_line >= math_start and target_line <= index then
          return anchor
        end
        math_start = nil
        math_anchor = nil
      end
    elseif M.is_display_math_delimiter(trimmed) then
      math_start = index
      math_anchor = M.display_math_label(trimmed)
    end

    if index > target_line and not math_start then
      return nil
    end
  end

  return nil
end

local function starts_table(lines, index)
  local line = lines[index] or ""
  local next_line = lines[index + 1] or ""
  return line:find("|", 1, true) ~= nil and next_line:match("^%s*|?%s*:?-+:?%s*|")
end

function M.approximate_block_index(bufnr, target_line)
  return M.cursor_context(bufnr, target_line).source_index
end

function M.cursor_context(bufnr, target_line)
  bufnr = bufnr or 0
  target_line = math.max(1, target_line or 1)

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok or not lines then
    return {
      source_index = 1,
      block_index = 1,
      anchor = nil,
    }
  end

  local start_line = strip_yaml_front_matter(lines)
  local count = 0
  local previous_blank = true
  local active_fence = nil
  local in_math = false
  local in_table = false
  local list_active = false
  local quote_active = false
  local force_next_block = false
  local equation_anchor = display_math_anchor(lines, target_line, start_line)

  for index = start_line, math.min(#lines, target_line) do
    local line = lines[index] or ""
    local trimmed = line:gsub("^%s+", "")
    local fence_char, fence_len = fence_info(line)
    local closing_div = trimmed:match("^:::+%s*$") ~= nil
    local force_block = false

    if active_fence then
      if fence_char == active_fence.char and fence_len >= active_fence.len then
        active_fence = nil
      end
      previous_blank = false
    elseif in_math then
      if M.is_display_math_delimiter(trimmed) then
        in_math = false
        force_next_block = true
      end
      previous_blank = false
    elseif is_blank(line) then
      previous_blank = true
      list_active = false
      quote_active = false
      in_table = false
    elseif fence_char then
      force_next_block = false
      count = count + 1
      active_fence = {
        char = fence_char,
        len = fence_len,
      }
      previous_blank = false
      list_active = false
      quote_active = false
      in_table = false
    elseif M.is_display_math_delimiter(trimmed) then
      force_block = force_next_block
      force_next_block = false
      if previous_blank or force_block then
        count = count + 1
      end
      in_math = true
      previous_blank = false
      list_active = false
      quote_active = false
      in_table = false
    elseif trimmed:match("^#+%s+") then
      force_next_block = false
      count = count + 1
      previous_blank = false
      list_active = false
      quote_active = false
      in_table = false
    elseif starts_table(lines, index) then
      force_block = force_next_block
      force_next_block = false
      if not in_table or force_block then
        count = count + 1
      end
      previous_blank = false
      list_active = false
      quote_active = false
      in_table = true
    elseif trimmed:match("^[-*+]%s+") or trimmed:match("^%d+[.)]%s+") then
      force_block = force_next_block
      force_next_block = false
      if previous_blank or not list_active or force_block then
        count = count + 1
      end
      previous_blank = false
      list_active = true
      quote_active = false
      in_table = false
    elseif trimmed:match("^>") then
      force_block = force_next_block
      force_next_block = false
      if previous_blank or not quote_active or force_block then
        count = count + 1
      end
      previous_blank = false
      list_active = false
      quote_active = true
      in_table = false
    elseif trimmed:match("^:::+") and not closing_div then
      force_next_block = false
      previous_blank = true
      list_active = false
      quote_active = false
      in_table = false
    elseif previous_blank or force_next_block then
      count = count + 1
      force_next_block = false
      previous_blank = false
      list_active = false
      quote_active = false
      in_table = false
    else
      force_next_block = false
      previous_blank = false
    end
  end

  local index = math.max(1, count)
  return {
    source_index = index,
    block_index = index,
    anchor = equation_anchor or fenced_block_anchor(lines, target_line),
  }
end

return M
