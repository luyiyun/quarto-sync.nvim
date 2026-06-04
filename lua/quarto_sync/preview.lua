local config = require("quarto_sync.config")
local devlog = require("quarto_sync.devlog")
local extension = require("quarto_sync.extension")
local overlay = require("quarto_sync.overlay")
local server = require("quarto_sync.server")
local source_markers = require("quarto_sync.source_markers")
local transport = require("quarto_sync.transport")
local util = require("quarto_sync.util")

local uv = vim.uv or vim.loop

local M = {}
local SAVE_REFRESH_BROWSER_QUIET_MS = 1000

local state = {
  running = false,
  stopping = false,
  preview_job = nil,
  preview_url = nil,
  current_file = nil,
  shadow_file = nil,
  shadow_session = nil,
  project_root = nil,
  preview_mode = nil,
  overlay_root = nil,
  preview_target_path = nil,
  last_line = nil,
  last_file = nil,
  last_anchor = nil,
  last_sent_at = 0,
  last_browser_line = nil,
  suppress_cursor_until = 0,
  suppress_browser_until = 0,
  generation = 0,
}

local autocmd_group = nil
local write_autocmd = nil

local strip_ansi

local function log(event, details)
  devlog.log("preview: " .. event, details)
end

local function log_limited(key, event, details, interval_ms)
  devlog.log_limited("preview:" .. key, "preview: " .. event, details, interval_ms)
end

local function log_stream(stream, lines)
  if type(lines) ~= "table" then
    return
  end

  for _, line in ipairs(lines) do
    if line and line ~= "" then
      log("quarto " .. stream, strip_ansi(line))
    end
  end
end

local function config_summary(opts)
  return {
    host = opts.host,
    port = opts.port,
    quarto_cmd = opts.quarto_cmd,
    browser_cmd = opts.browser_cmd,
    open_browser = opts.open_browser,
    preview_mode = opts.preview_mode,
    sync_on_cursor_move = opts.sync_on_cursor_move,
    sync_from_browser = opts.sync_from_browser,
    debounce_ms = opts.debounce_ms,
  }
end

strip_ansi = function(text)
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

local function append_url_path(url, path)
  if not path or path == "" then
    return url
  end

  local base, suffix = url:match("^([^?#]*)(.*)$")
  if not base then
    return url
  end
  if base:match("%.html$") then
    return url
  end

  return base:gsub("/+$", "") .. "/" .. path:gsub("^/+", "") .. (suffix or "")
end

local function open_browser(url)
  local opts = config.get()
  if not opts.open_browser then
    log("open browser skipped", { reason = "open_browser disabled", url = url })
    return
  end

  if opts.browser_cmd then
    if type(opts.browser_cmd) == "table" then
      local cmd = vim.deepcopy(opts.browser_cmd)
      table.insert(cmd, url)
      local job = vim.fn.jobstart(cmd, { detach = true })
      log("open browser command", { cmd = cmd, job = job })
    else
      local cmd = { opts.browser_cmd, url }
      local job = vim.fn.jobstart(cmd, { detach = true })
      log("open browser command", { cmd = cmd, job = job })
    end
    return
  end

  if vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, url)
    if ok then
      log("open browser vim.ui.open", { url = url })
      return
    end
    log("open browser vim.ui.open failed", { url = url })
  end

  if vim.fn.has("mac") == 1 then
    local job = vim.fn.jobstart({ "open", url }, { detach = true })
    log("open browser macOS open", { url = url, job = job })
  elseif vim.fn.executable("xdg-open") == 1 then
    local job = vim.fn.jobstart({ "xdg-open", url }, { detach = true })
    log("open browser xdg-open", { url = url, job = job })
  else
    log("open browser unavailable", { url = url })
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
      local raw_url = url
      url = append_url_path(url, state.preview_target_path)
      url = append_query_param(url, "qsyncPort", config.get().port)
      state.preview_url = url
      log("preview url detected", { raw_url = raw_url, url = url })
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
    log("stopping preview job", { job = job })
    pcall(vim.fn.jobstop, job)
  else
    log("no preview job to stop")
  end
end

local function clear_write_autocmd()
  if write_autocmd then
    log("clearing shadow refresh autocmd", { autocmd = write_autocmd })
    pcall(vim.api.nvim_del_autocmd, write_autocmd)
    write_autocmd = nil
  end
end

local function cleanup_shadow()
  log("cleanup shadow", {
    shadow_file = state.shadow_file,
    overlay_root = state.overlay_root,
    preview_target_path = state.preview_target_path,
  })
  clear_write_autocmd()
  if state.shadow_session then
    source_markers.cleanup_shadow(state.shadow_session)
  end
  state.shadow_session = nil
  state.shadow_file = nil
  state.overlay_root = nil
  state.preview_target_path = nil
end

local function setup_shadow_refresh()
  clear_write_autocmd()
  write_autocmd = vim.api.nvim_create_autocmd("BufWritePost", {
    group = autocmd_group,
    callback = function(args)
      local file = util.normalize(args.file)
      if state.shadow_session and state.current_file and file == state.current_file then
        state.suppress_browser_until = uv.now() + SAVE_REFRESH_BROWSER_QUIET_MS
        log("shadow refresh requested", {
          file = file,
          suppress_browser_until = state.suppress_browser_until,
        })
        source_markers.refresh_shadow(state.shadow_session)
      end
    end,
  })
  log("shadow refresh autocmd created", { autocmd = write_autocmd })
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

local function inspect_project(opts, project_root)
  if not project_root or project_root == "" then
    log("inspect project skipped", { reason = "missing project root" })
    return nil
  end

  log("inspect project", { cmd = { opts.quarto_cmd, "inspect", project_root } })
  local output = vim.fn.system({ opts.quarto_cmd, "inspect", project_root })
  if vim.v.shell_error ~= 0 then
    log("inspect project failed", { shell_error = vim.v.shell_error, output = output })
    return nil
  end

  local ok, decoded = pcall(util.json_decode, output)
  if not ok then
    log("inspect project decode failed", { output = output })
    return nil
  end
  local project = decoded and decoded.config and decoded.config.project
  log("inspect project complete", {
    project_type = project and project.type or nil,
    output_dir = project and project["output-dir"] or nil,
  })
  return decoded
end

local function project_type(info)
  return info
    and info.config
    and info.config.project
    and info.config.project.type
end

local function project_output_dir(info)
  return info
    and info.config
    and info.config.project
    and info.config.project["output-dir"]
end

local function resolve_preview_mode(opts, project_info)
  local mode = opts.preview_mode or "auto"
  if mode == "document" or mode == "website" then
    return mode
  end
  if mode ~= "auto" then
    util.notify("Unknown quarto-sync preview_mode `" .. tostring(mode) .. "`, falling back to auto.", vim.log.levels.WARN)
  end
  return project_type(project_info) == "website" and "website" or "document"
end

local function create_preview_session(file, project_root, preview_mode, project_info)
  if preview_mode == "website" then
    return overlay.create(file, project_root, {
      output_dir = project_output_dir(project_info),
    })
  end

  return source_markers.create_shadow(file, project_root, {
    mode = "document",
  })
end

local function preview_command(opts, preview_mode, shadow_session, filter_path)
  if preview_mode == "website" then
    return { opts.quarto_cmd, "preview", shadow_session.overlay_root, "--no-browser", "--lua-filter", filter_path },
      shadow_session.overlay_root
  end

  return { opts.quarto_cmd, "preview", shadow_session.path, "--no-browser", "--lua-filter", filter_path },
    shadow_session.project_root
end

function M.preview(preview_opts)
  preview_opts = preview_opts or {}
  local opts = config.get()
  local file = util.current_file()

  log("start requested", { file = file, dev = preview_opts.dev, config = config_summary(opts) })
  if not util.is_qmd(file) then
    log("start failed", { reason = "current buffer is not .qmd", file = file })
    util.notify(":QSyncPreview requires the current buffer to be a .qmd file.", vim.log.levels.ERROR)
    return false
  end

  local project_root = util.find_project_root(file)
  local filter_path = extension.filter_path()
  log("resolved paths", { project_root = project_root, filter_path = filter_path })
  if not util.file_exists(filter_path) then
    log("start failed", { reason = "missing filter", filter_path = filter_path })
    util.notify("Could not find bundled Quarto sync filter at " .. filter_path, vim.log.levels.ERROR)
    return false
  end

  local project_info = nil
  if (opts.preview_mode or "auto") ~= "document" then
    project_info = inspect_project(opts, project_root)
  end
  local preview_mode = resolve_preview_mode(opts, project_info)
  log("preview mode resolved", { preview_mode = preview_mode, configured = opts.preview_mode })

  M.stop({ quiet = true, keep_devlog = true })
  state.generation = state.generation + 1
  local generation = state.generation

  local shadow_session = create_preview_session(file, project_root, preview_mode, project_info)
  if not shadow_session then
    log("start failed", { reason = "could not create preview session" })
    return false
  end
  log("preview session created", {
    mode = shadow_session.mode,
    path = shadow_session.path,
    overlay_root = shadow_session.overlay_root,
    preview_path = shadow_session.preview_path,
  })

  if not server.start(opts) then
    log("start failed", { reason = "server start failed" })
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
  state.preview_mode = preview_mode
  state.overlay_root = shadow_session.overlay_root
  state.preview_target_path = shadow_session.preview_path
  state.last_line = nil
  state.last_file = nil
  state.last_anchor = nil
  state.last_sent_at = 0
  state.last_browser_line = nil
  state.suppress_cursor_until = 0
  state.suppress_browser_until = 0

  setup_shadow_refresh()

  local cmd, cwd = preview_command(opts, preview_mode, shadow_session, filter_path)
  log("starting quarto job", { cmd = cmd, cwd = cwd, generation = generation })
  local job = vim.fn.jobstart(cmd, {
    cwd = cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if generation ~= state.generation then
        log("stdout ignored", { reason = "stale generation", generation = generation, current_generation = state.generation })
        return
      end
      log_stream("stdout", data)
      handle_preview_output(data)
    end,
    on_stderr = function(_, data)
      if generation ~= state.generation then
        log("stderr ignored", { reason = "stale generation", generation = generation, current_generation = state.generation })
        return
      end
      log_stream("stderr", data)
      handle_preview_output(data)
    end,
    on_exit = function(_, code)
      log("quarto job exit", {
        job = state.preview_job,
        code = code,
        stopping = state.stopping,
        generation = generation,
        current_generation = state.generation,
      })
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
    log("job start failed", { job = job, cmd = cmd, cwd = cwd })
    util.notify("Could not start `quarto preview`. Check `quarto_cmd` and Quarto installation.", vim.log.levels.ERROR)
    return false
  end

  state.preview_job = job
  log("preview running", { job = job, file = file, mode = preview_mode })
  util.notify("Starting Quarto preview for " .. file, vim.log.levels.INFO)
  return true
end

function M.preview_dev()
  local opts = config.get()
  local file = util.current_file()
  devlog.start({
    file = file,
    config = config_summary(opts),
  })
  log("preview dev requested", { file = file })
  return M.preview({ dev = true })
end

function M.stop(opts)
  opts = opts or {}
  local stop_devlog = devlog.is_enabled() and not opts.keep_devlog
  log("stop requested", {
    quiet = opts.quiet,
    keep_devlog = opts.keep_devlog,
    running = state.running,
    preview_job = state.preview_job,
  })
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
  state.preview_mode = nil
  state.overlay_root = nil
  state.preview_target_path = nil
  state.last_line = nil
  state.last_file = nil
  state.last_anchor = nil
  state.last_sent_at = 0
  state.last_browser_line = nil
  state.suppress_cursor_until = 0
  state.suppress_browser_until = 0

  if not opts.quiet then
    util.notify("Stopped quarto-sync preview.", vim.log.levels.INFO)
  end
  log("stop complete")
  if stop_devlog then
    devlog.stop()
  end
end

function M.restart()
  log("restart requested")
  M.stop({ quiet = true, keep_devlog = true })
  vim.defer_fn(function()
    M.preview()
  end, 100)
end

function M.sync_cursor(opts)
  opts = opts or {}
  local cfg = config.get()
  if not cfg.sync_on_cursor_move and not opts.force then
    log_limited("cursor-disabled", "cursor sync skipped", { reason = "sync_on_cursor_move disabled" })
    return false
  end
  if not state.running then
    log_limited("cursor-not-running", "cursor sync skipped", { reason = "preview not running" })
    return false
  end

  local now = uv.now()
  if not opts.force and now < state.suppress_cursor_until then
    log_limited("cursor-suppressed", "cursor sync skipped", {
      reason = "suppressed after browser sync",
      remaining_ms = state.suppress_cursor_until - now,
    })
    return false
  end

  local file = util.current_file()
  if not should_sync_file(file) then
    log_limited("cursor-file", "cursor sync skipped", {
      reason = "file is not sync target",
      file = file,
      current_file = state.current_file,
      project_root = state.project_root,
    })
    return false
  end

  if not opts.force and now - state.last_sent_at < cfg.debounce_ms then
    log_limited("cursor-debounce", "cursor sync skipped", {
      reason = "debounce",
      elapsed_ms = now - state.last_sent_at,
      debounce_ms = cfg.debounce_ms,
    })
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
    log("cursor sync sent", payload)
    return true
  end

  log("cursor sync failed", { reason = "transport send failed", payload = payload })
  return false
end

function M.sync_from_browser(payload)
  local cfg = config.get()
  if not cfg.sync_from_browser or not state.running then
    log("browser sync skipped", {
      reason = not cfg.sync_from_browser and "sync_from_browser disabled" or "preview not running",
      payload = payload,
    })
    return false
  end
  if type(payload) ~= "table" then
    log("browser sync skipped", { reason = "invalid payload", payload_type = type(payload) })
    return false
  end
  if payload.type and payload.type ~= "scroll" then
    log("browser sync skipped", { reason = "ignored payload type", payload = payload })
    return false
  end

  local now = uv.now()
  if now < state.suppress_browser_until and payload.manual ~= true then
    log("browser sync skipped", {
      reason = "suppressed during save refresh",
      remaining_ms = state.suppress_browser_until - now,
      payload = payload,
    })
    return false
  end

  local line = line_from_payload(payload)
  local win = source_window()
  if not line or not win then
    log("browser sync skipped", {
      reason = not line and "invalid line" or "source window not visible",
      payload = payload,
      current_file = state.current_file,
    })
    return false
  end

  local ok = center_source_window(win, line)
  log("browser sync applied", { line = line, win = win, ok = ok, payload = payload })
  return ok
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
    "preview mode: " .. tostring(state.preview_mode or "none"),
    "overlay root: " .. tostring(state.overlay_root or "none"),
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
