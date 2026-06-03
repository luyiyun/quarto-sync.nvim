local uv = vim.uv or vim.loop

local M = {}

local BUFFER_NAME = "quarto-sync://preview-dev"

local state = {
  enabled = false,
  bufnr = nil,
  session_id = 0,
  limited = {},
}

local function valid_buffer(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function log_windows(bufnr)
  local wins = {}
  if not valid_buffer(bufnr) then
    return wins
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      table.insert(wins, win)
    end
  end
  return wins
end

local function configure_buffer(bufnr)
  pcall(vim.api.nvim_buf_set_name, bufnr, BUFFER_NAME)
  pcall(vim.api.nvim_buf_set_option, bufnr, "buftype", "nofile")
  pcall(vim.api.nvim_buf_set_option, bufnr, "bufhidden", "hide")
  pcall(vim.api.nvim_buf_set_option, bufnr, "swapfile", false)
  pcall(vim.api.nvim_buf_set_option, bufnr, "modifiable", false)
  pcall(vim.api.nvim_buf_set_option, bufnr, "filetype", "quarto_sync_log")
end

local function ensure_buffer()
  if valid_buffer(state.bufnr) then
    return state.bufnr
  end

  local existing = vim.fn.bufnr(BUFFER_NAME)
  if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
    state.bufnr = existing
    configure_buffer(existing)
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  state.bufnr = bufnr
  configure_buffer(bufnr)
  return bufnr
end

local function configure_window(win)
  pcall(vim.api.nvim_win_set_option, win, "wrap", false)
  pcall(vim.api.nvim_win_set_option, win, "number", false)
  pcall(vim.api.nvim_win_set_option, win, "relativenumber", false)
  pcall(vim.api.nvim_win_set_height, win, 12)
end

local function scroll_to_bottom(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, win in ipairs(log_windows(bufnr)) do
    pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
  end
end

local function set_modifiable(bufnr, value)
  pcall(vim.api.nvim_buf_set_option, bufnr, "modifiable", value)
end

local function replace_lines(lines)
  local bufnr = ensure_buffer()
  set_modifiable(bufnr, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_modifiable(bufnr, false)
  scroll_to_bottom(bufnr)
end

local function append_lines(lines)
  if #lines == 0 then
    return
  end

  local bufnr = ensure_buffer()
  set_modifiable(bufnr, true)

  local existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #existing == 1 and existing[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
  end

  set_modifiable(bufnr, false)
  scroll_to_bottom(bufnr)
end

local function stringify(value)
  if value == nil then
    return nil
  end

  if type(value) == "string" then
    return value
  end

  if type(value) == "table" then
    local ok, encoded = pcall(function()
      if vim.json and vim.json.encode then
        return vim.json.encode(value)
      end
      return vim.fn.json_encode(value)
    end)
    if ok and encoded then
      return encoded
    end
  end

  local ok, inspected = pcall(vim.inspect, value)
  if ok then
    return inspected:gsub("\n%s*", " ")
  end
  return tostring(value)
end

local function timestamp()
  return ("%s.%03d"):format(os.date("%H:%M:%S"), uv.now() % 1000)
end

local function format_line(event, details)
  local line = ("[%s] %s"):format(timestamp(), tostring(event))
  local rendered = stringify(details)
  if rendered and rendered ~= "" then
    line = line .. " " .. rendered
  end
  return line
end

function M.open()
  local previous_win = vim.api.nvim_get_current_win()
  local bufnr = ensure_buffer()
  local wins = log_windows(bufnr)

  if #wins == 0 then
    vim.cmd("botright 12split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    configure_window(win)
  else
    for _, win in ipairs(wins) do
      configure_window(win)
    end
  end

  scroll_to_bottom(bufnr)
  if previous_win and vim.api.nvim_win_is_valid(previous_win) then
    pcall(vim.api.nvim_set_current_win, previous_win)
  end
  return bufnr
end

function M.start(opts)
  opts = opts or {}
  state.enabled = true
  state.session_id = state.session_id + 1
  state.limited = {}
  M.open()

  replace_lines({
    "quarto-sync.nvim preview dev log",
    "started: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "current file: " .. tostring(opts.file or "none"),
    "config: " .. tostring(stringify(opts.config or {}) or "{}"),
    "",
  })

  M.log("devlog: session started")
  return state.bufnr
end

function M.stop()
  if not state.enabled then
    return
  end
  M.log("devlog: session stopped")
  state.enabled = false
end

function M.is_enabled()
  return state.enabled
end

function M.log(event, details)
  if not state.enabled then
    return
  end

  local session_id = state.session_id
  local line = format_line(event, details)
  local function write()
    if session_id == state.session_id then
      append_lines({ line })
    end
  end

  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(write)
  else
    write()
  end
end

function M.log_limited(key, event, details, interval_ms)
  if not state.enabled then
    return
  end

  interval_ms = interval_ms or 1000
  local now = uv.now()
  local last = state.limited[key]
  if last and now - last < interval_ms then
    return
  end

  state.limited[key] = now
  M.log(event, details)
end

function M.get_bufnr()
  return valid_buffer(state.bufnr) and state.bufnr or nil
end

return M
