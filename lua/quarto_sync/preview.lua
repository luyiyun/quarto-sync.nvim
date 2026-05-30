local config = require("quarto_sync.config")
local extension = require("quarto_sync.extension")
local server = require("quarto_sync.server")
local transport = require("quarto_sync.transport")
local util = require("quarto_sync.util")

local uv = vim.uv or vim.loop

local M = {}

local state = {
  running = false,
  stopping = false,
  preview_job = nil,
  preview_url = nil,
  current_file = nil,
  project_root = nil,
  last_line = nil,
  last_file = nil,
  last_sent_at = 0,
  generation = 0,
}

local autocmd_group = nil

local function strip_ansi(text)
  return (text or ""):gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

local function extract_url(text)
  text = strip_ansi(text)
  return text:match("(https?://[%w%._~:/%?#%[%]@!$&'()*+,;=%%-]+)")
end

local function append_query_param(url, key, value)
  local base, fragment = url:match("^([^#]*)(#.*)$")
  if not base then
    base = url
    fragment = ""
  end

  local separator = base:find("?", 1, true) and "&" or "?"
  return base .. separator .. key .. "=" .. tostring(value) .. fragment
end

local function open_browser(url)
  local opts = config.get()
  if not opts.open_browser then
    return
  end

  if opts.browser_cmd then
    if type(opts.browser_cmd) == "table" then
      local cmd = vim.deepcopy(opts.browser_cmd)
      table.insert(cmd, url)
      vim.fn.jobstart(cmd, { detach = true })
    else
      vim.fn.jobstart({ opts.browser_cmd, url }, { detach = true })
    end
    return
  end

  if vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, url)
    if ok then
      return
    end
  end

  if vim.fn.has("mac") == 1 then
    vim.fn.jobstart({ "open", url }, { detach = true })
  elseif vim.fn.executable("xdg-open") == 1 then
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  else
    util.notify("Preview is available at " .. url, vim.log.levels.INFO)
  end
end

local function handle_preview_output(lines)
  if type(lines) ~= "table" then
    return
  end

  for _, line in ipairs(lines) do
    local url = extract_url(line)
    if url and not state.preview_url then
      url = append_query_param(url, "qsyncPort", config.get().port)
      state.preview_url = url
      util.notify("Quarto preview started: " .. url, vim.log.levels.INFO)
      open_browser(url)
      vim.defer_fn(function()
        M.sync_cursor({ force = true })
      end, 150)
      return
    end
  end
end

local function stop_preview_job()
  if state.preview_job then
    local job = state.preview_job
    state.preview_job = nil
    pcall(vim.fn.jobstop, job)
  end
end

local function should_sync_file(file)
  if not file or not util.is_qmd(file) then
    return false
  end
  if state.current_file and file == state.current_file then
    return true
  end
  return state.project_root ~= nil and util.path_starts_with(file, state.project_root)
end

function M.preview()
  local opts = config.get()
  local file = util.current_file()

  if not util.is_qmd(file) then
    util.notify(":QSyncPreview requires the current buffer to be a .qmd file.", vim.log.levels.ERROR)
    return false
  end

  local project_root = util.find_project_root(file)
  local filter_path = extension.filter_path()
  if not util.file_exists(filter_path) then
    util.notify("Could not find bundled Quarto sync filter at " .. filter_path, vim.log.levels.ERROR)
    return false
  end

  M.stop({ quiet = true })
  state.generation = state.generation + 1
  local generation = state.generation

  if not server.start(opts) then
    return false
  end

  state.running = true
  state.stopping = false
  state.preview_url = nil
  state.current_file = file
  state.project_root = project_root
  state.last_line = nil
  state.last_file = nil
  state.last_sent_at = 0

  local cmd = { opts.quarto_cmd, "preview", file, "--no-browser", "--lua-filter", filter_path }
  local job = vim.fn.jobstart(cmd, {
    cwd = project_root,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if generation ~= state.generation then
        return
      end
      handle_preview_output(data)
    end,
    on_stderr = function(_, data)
      if generation ~= state.generation then
        return
      end
      handle_preview_output(data)
    end,
    on_exit = function(_, code)
      if state.stopping or generation ~= state.generation then
        return
      end
      state.running = false
      server.stop()
      util.notify("Quarto preview exited with code " .. tostring(code), vim.log.levels.WARN)
    end,
  })

  if job <= 0 then
    state.running = false
    server.stop()
    util.notify("Could not start `quarto preview`. Check `quarto_cmd` and Quarto installation.", vim.log.levels.ERROR)
    return false
  end

  state.preview_job = job
  util.notify("Starting Quarto preview for " .. file, vim.log.levels.INFO)
  return true
end

function M.stop(opts)
  opts = opts or {}
  state.stopping = true
  state.generation = state.generation + 1
  stop_preview_job()
  server.stop()

  state.running = false
  state.preview_url = nil
  state.current_file = nil
  state.project_root = nil
  state.last_line = nil
  state.last_file = nil
  state.last_sent_at = 0

  if not opts.quiet then
    util.notify("Stopped quarto-sync preview.", vim.log.levels.INFO)
  end
end

function M.restart()
  M.stop({ quiet = true })
  vim.defer_fn(function()
    M.preview()
  end, 100)
end

function M.sync_cursor(opts)
  opts = opts or {}
  local cfg = config.get()
  if not cfg.sync_on_cursor_move and not opts.force then
    return false
  end
  if not state.running then
    return false
  end

  local file = util.current_file()
  if not should_sync_file(file) then
    return false
  end

  local now = uv.now()
  if not opts.force and now - state.last_sent_at < cfg.debounce_ms then
    return false
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local payload = {
    type = "cursor",
    file = file,
    line = line,
    block_index = util.approximate_block_index(0, line),
  }

  if transport.send(payload) then
    state.last_sent_at = now
    state.last_line = line
    state.last_file = file
    return true
  end

  return false
end

function M.setup_autocmds()
  autocmd_group = vim.api.nvim_create_augroup("quarto_sync_nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = autocmd_group,
    callback = function()
      require("quarto_sync.preview").sync_cursor()
    end,
  })
end

function M.status()
  local server_status = server.status()
  local lines = {
    "quarto-sync.nvim status",
    "preview: " .. (state.running and "running" or "stopped"),
    "server: " .. (server_status.running and "running" or "stopped"),
    "port: " .. tostring(server_status.port or config.get().port),
    "current file: " .. tostring(state.current_file or "none"),
    "project root: " .. tostring(state.project_root or "none"),
    "preview url: " .. tostring(state.preview_url or "none"),
    "last sync: " .. tostring(state.last_file or "none") .. ":" .. tostring(state.last_line or "none"),
    "clients: " .. tostring(server_status.clients or 0),
  }

  vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
end

function M.get_state()
  return vim.deepcopy(state)
end

return M
