local config = require("quarto_sync.config")
local extension = require("quarto_sync.extension")
local server = require("quarto_sync.server")
local source_markers = require("quarto_sync.source_markers")
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
  shadow_file = nil,
  shadow_session = nil,
  project_root = nil,
  last_line = nil,
  last_file = nil,
  last_anchor = nil,
  last_sent_at = 0,
  last_browser_line = nil,
  suppress_cursor_until = 0,
  generation = 0,
}

local autocmd_group = nil
local write_autocmd = nil

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

local function clear_write_autocmd()
  if write_autocmd then
    pcall(vim.api.nvim_del_autocmd, write_autocmd)
    write_autocmd = nil
  end
end

local function cleanup_shadow()
  clear_write_autocmd()
  if state.shadow_session then
    source_markers.cleanup_shadow(state.shadow_session)
  end
  state.shadow_session = nil
  state.shadow_file = nil
end

local function setup_shadow_refresh()
  clear_write_autocmd()
  write_autocmd = vim.api.nvim_create_autocmd("BufWritePost", {
    group = autocmd_group,
    callback = function(args)
      local file = util.normalize(args.file)
      if state.shadow_session and state.current_file and file == state.current_file then
        source_markers.refresh_shadow(state.shadow_session)
      end
    end,
  })
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

local function line_from_payload(payload)
  local line = tonumber(payload and payload.line)
  if not line or line ~= line then
    return nil
  end
  return math.max(1, math.floor(line))
end

local function window_shows_file(win, file)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local bufnr = vim.api.nvim_win_get_buf(win)
  local name = util.normalize(vim.api.nvim_buf_get_name(bufnr))
  return name == file
end

local function source_window()
  if not state.current_file then
    return nil
  end

  local current_win = vim.api.nvim_get_current_win()
  if window_shows_file(current_win, state.current_file) then
    return current_win
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if window_shows_file(win, state.current_file) then
      return win
    end
  end

  return nil
end

local function center_source_window(win, line)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  line = math.min(math.max(1, line), math.max(1, line_count))

  state.suppress_cursor_until = uv.now() + math.max(config.get().debounce_ms, 250)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  state.last_browser_line = line
  return true
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

  local shadow_session = source_markers.create_shadow(file, project_root)
  if not shadow_session then
    return false
  end

  if not server.start(opts) then
    source_markers.cleanup_shadow(shadow_session)
    return false
  end
  server.set_scroll_handler(function(payload)
    require("quarto_sync.preview").sync_from_browser(payload)
  end)

  state.running = true
  state.stopping = false
  state.preview_url = nil
  state.current_file = file
  state.shadow_session = shadow_session
  state.shadow_file = shadow_session.path
  state.project_root = project_root
  state.last_line = nil
  state.last_file = nil
  state.last_anchor = nil
  state.last_sent_at = 0
  state.last_browser_line = nil
  state.suppress_cursor_until = 0

  setup_shadow_refresh()

  local cmd = { opts.quarto_cmd, "preview", shadow_session.path, "--no-browser", "--lua-filter", filter_path }
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
      server.set_scroll_handler(nil)
      server.stop()
      cleanup_shadow()
      util.notify("Quarto preview exited with code " .. tostring(code), vim.log.levels.WARN)
    end,
  })

  if job <= 0 then
    state.running = false
    server.set_scroll_handler(nil)
    server.stop()
    cleanup_shadow()
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
  server.set_scroll_handler(nil)
  server.stop()
  cleanup_shadow()

  state.running = false
  state.preview_url = nil
  state.current_file = nil
  state.project_root = nil
  state.last_line = nil
  state.last_file = nil
  state.last_anchor = nil
  state.last_sent_at = 0
  state.last_browser_line = nil
  state.suppress_cursor_until = 0

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

  local now = uv.now()
  if not opts.force and now < state.suppress_cursor_until then
    return false
  end

  local file = util.current_file()
  if not should_sync_file(file) then
    return false
  end

  if not opts.force and now - state.last_sent_at < cfg.debounce_ms then
    return false
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local context = util.cursor_context(0, line)
  local payload = {
    type = "cursor",
    file = file,
    line = line,
    source_index = context.source_index,
    block_index = context.block_index,
    anchor = context.anchor,
  }

  if transport.send(payload) then
    state.last_sent_at = now
    state.last_line = line
    state.last_file = file
    state.last_anchor = context.anchor
    return true
  end

  return false
end

function M.sync_from_browser(payload)
  local cfg = config.get()
  if not cfg.sync_from_browser or not state.running then
    return false
  end
  if type(payload) ~= "table" then
    return false
  end
  if payload.type and payload.type ~= "scroll" then
    return false
  end

  local line = line_from_payload(payload)
  local win = source_window()
  if not line or not win then
    return false
  end

  return center_source_window(win, line)
end

function M.setup_autocmds()
  autocmd_group = vim.api.nvim_create_augroup("quarto_sync_nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
    group = autocmd_group,
    callback = function()
      require("quarto_sync.preview").sync_cursor()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = autocmd_group,
    callback = function()
      require("quarto_sync.preview").stop({ quiet = true })
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
    "shadow file: " .. tostring(state.shadow_file or "none"),
    "project root: " .. tostring(state.project_root or "none"),
    "preview url: " .. tostring(state.preview_url or "none"),
    "last sync: " .. tostring(state.last_file or "none") .. ":" .. tostring(state.last_line or "none"),
    "last anchor: " .. tostring(state.last_anchor or "none"),
    "last browser sync line: " .. tostring(state.last_browser_line or "none"),
    "clients: " .. tostring(server_status.clients or 0),
  }

  vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
end

function M.get_state()
  return vim.deepcopy(state)
end

return M
