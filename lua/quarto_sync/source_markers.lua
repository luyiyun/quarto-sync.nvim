local util = require("quarto_sync.util")

local M = {}

local function marker(line_number)
  return ('<div class="qsync-source-marker" data-qsync-source-line="%d"></div>'):format(line_number)
end

local function is_blank(line)
  return (line or ""):match("^%s*$") ~= nil
end

local function trimmed(line)
  return (line or ""):gsub("^%s+", "")
end

local function fence_info(line)
  local fence = trimmed(line):match("^([`~][`~][`~]+)")
  if not fence then
    return nil
  end
  return fence:sub(1, 1), #fence
end

local function starts_table(lines, index)
  local line = lines[index] or ""
  local next_line = lines[index + 1] or ""
  return line:find("|", 1, true) ~= nil and next_line:match("^%s*|?%s*:?-+:?%s*|") ~= nil
end

local function is_list_item(line)
  local text = trimmed(line)
  return text:match("^[-*+]%s+") ~= nil or text:match("^%d+[.)]%s+") ~= nil
end

local function is_div_open(line)
  local text = trimmed(line)
  return text:match("^:::+") ~= nil and text:match("^:::+%s*$") == nil
end

local function should_mark_paragraph(lines, index)
  local line = lines[index] or ""
  if is_blank(line) then
    return false
  end

  local previous = lines[index - 1] or ""
  return is_blank(previous)
end

function M.instrument_lines(lines)
  local output = {}
  local in_yaml = false
  local in_fence = false
  local fence_char = nil
  local fence_len = 0
  local in_math = false
  local in_table = false
  local list_active = false
  local quote_active = false

  for index, line in ipairs(lines) do
    local text = trimmed(line)
    local char, len = fence_info(line)

    if index == 1 and line == "---" then
      in_yaml = true
      table.insert(output, line)
    elseif in_yaml then
      table.insert(output, line)
      if index > 1 and (line == "---" or line == "...") then
        in_yaml = false
      end
    elseif in_fence then
      table.insert(output, line)
      if char == fence_char and len >= fence_len then
        in_fence = false
      end
    elseif in_math then
      table.insert(output, line)
      if text:match("^%$%$%s*$") then
        in_math = false
      end
    elseif in_table and not is_blank(line) then
      table.insert(output, line)
    else
      if is_blank(line) then
        table.insert(output, line)
        in_table = false
        list_active = false
        quote_active = false
      elseif char then
        table.insert(output, marker(index))
        table.insert(output, line)
        in_fence = true
        fence_char = char
        fence_len = len
        list_active = false
        quote_active = false
        in_table = false
      elseif text:match("^%$%$%s*$") then
        table.insert(output, marker(index))
        table.insert(output, line)
        in_math = true
        list_active = false
        quote_active = false
        in_table = false
      elseif starts_table(lines, index) then
        table.insert(output, marker(index))
        table.insert(output, line)
        in_table = true
        list_active = false
        quote_active = false
      elseif text:match("^#+%s+") or is_div_open(line) then
        table.insert(output, marker(index))
        table.insert(output, line)
        list_active = false
        quote_active = false
        in_table = false
      elseif is_list_item(line) then
        if not list_active then
          table.insert(output, marker(index))
        end
        table.insert(output, line)
        list_active = true
        quote_active = false
        in_table = false
      elseif text:match("^>") then
        if not quote_active then
          table.insert(output, marker(index))
        end
        table.insert(output, line)
        list_active = false
        quote_active = true
        in_table = false
      elseif should_mark_paragraph(lines, index) then
        table.insert(output, marker(index))
        table.insert(output, line)
        list_active = false
        quote_active = false
        in_table = false
      else
        table.insert(output, line)
        in_table = false
      end
    end
  end

  return output
end

function M.shadow_path(original_file)
  local dir = util.dirname(original_file)
  local stem = vim.fn.fnamemodify(original_file, ":t:r")
  return util.path_join(dir, (".qsync-%s-%s.qmd"):format(stem, vim.fn.getpid()))
end

function M.refresh_shadow(session)
  if not session or not session.original_file or not session.path then
    return false
  end

  local ok, lines = pcall(vim.fn.readfile, session.original_file)
  if not ok or not lines then
    util.notify("Could not read source file for sync markers: " .. tostring(session.original_file), vim.log.levels.ERROR)
    return false
  end

  local instrumented = M.instrument_lines(lines)
  local write_ok, write_err = pcall(vim.fn.writefile, instrumented, session.path)
  if not write_ok or write_err ~= 0 then
    util.notify("Could not write sync shadow file: " .. tostring(session.path), vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.create_shadow(original_file, project_root)
  original_file = util.normalize(original_file)
  local session = {
    original_file = original_file,
    project_root = project_root,
    path = M.shadow_path(original_file),
  }

  if not M.refresh_shadow(session) then
    return nil
  end

  return session
end

function M.cleanup_shadow(session)
  if not session or not session.path then
    return
  end
  if util.file_exists(session.path) then
    pcall(vim.fn.delete, session.path)
  end
end

return M
