local config = require("quarto_sync.config")
local devlog = require("quarto_sync.devlog")
local util = require("quarto_sync.util")

local M = {}

local uv = vim.uv or vim.loop

local state = {
  running = false,
  host = nil,
  port = nil,
  server = nil,
  connections = {},
  clients = {},
  last_payload = nil,
  last_scroll_payload = nil,
  scroll_handler = nil,
}

local status_text = {
  [200] = "OK",
  [204] = "No Content",
  [400] = "Bad Request",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [500] = "Internal Server Error",
}

local function log(event, details)
  devlog.log("server: " .. event, details)
end

local function close_client(client)
  local was_connection = state.connections[client] ~= nil
  local was_sse_client = state.clients[client] ~= nil
  state.connections[client] = nil
  state.clients[client] = nil
  if client and not client:is_closing() then
    log("client closing", { client = tostring(client), connection = was_connection, sse = was_sse_client })
    client:close()
  end
end

local function write_response(client, status, headers, body, keep_open)
  body = body or ""
  headers = vim.tbl_extend("force", {
    ["Access-Control-Allow-Origin"] = "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type",
    ["Content-Length"] = tostring(#body),
  }, headers or {})

  local lines = { ("HTTP/1.1 %d %s"):format(status, status_text[status] or "OK") }
  for key, value in pairs(headers) do
    table.insert(lines, key .. ": " .. value)
  end
  table.insert(lines, "")
  table.insert(lines, body)

  client:write(table.concat(lines, "\r\n"), function()
    if not keep_open then
      close_client(client)
    end
  end)
end

local function write_json(client, status, value)
  write_response(client, status, { ["Content-Type"] = "application/json" }, util.json_encode(value))
end

local function parse_request(raw)
  local header_text, body = raw:match("^(.-)\r\n\r\n(.*)$")
  if not header_text then
    return nil
  end

  local request_line = header_text:match("([^\r\n]+)")
  local method, target = request_line:match("^(%S+)%s+(%S+)")
  local headers = {}

  for line in header_text:gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key then
      headers[key:lower()] = value
    end
  end

  return {
    method = method,
    target = target,
    path = (target or ""):gsub("%?.*$", ""),
    headers = headers,
    body = body or "",
  }
end

local function headers_complete(raw)
  return raw:find("\r\n\r\n", 1, true) ~= nil
end

local function expected_length(raw)
  local header_text = raw:match("^(.-)\r\n\r\n")
  if not header_text then
    return nil
  end
  local content_length = header_text:lower():match("\r\ncontent%-length:%s*(%d+)")
  return tonumber(content_length) or 0
end

local function request_complete(raw)
  if not headers_complete(raw) then
    return false
  end
  local header_end = raw:find("\r\n\r\n", 1, true)
  local body_len = #raw - header_end - 3
  return body_len >= expected_length(raw)
end

function M.broadcast(payload)
  state.last_payload = payload

  log("broadcast cursor", { clients = vim.tbl_count(state.clients), payload = payload })
  local data = ("event: cursor\ndata: %s\n\n"):format(util.json_encode(payload))
  for client in pairs(state.clients) do
    if client:is_closing() then
      state.clients[client] = nil
      log("drop closed client before broadcast", { client = tostring(client) })
    else
      client:write(data, function(err)
        if err then
          log("broadcast write failed", { client = tostring(client), err = tostring(err) })
          close_client(client)
        end
      end)
    end
  end
end

function M.set_scroll_handler(handler)
  if handler ~= nil and type(handler) ~= "function" then
    log("scroll handler rejected", { handler_type = type(handler) })
    return false
  end
  state.scroll_handler = handler
  log("scroll handler " .. (handler and "set" or "cleared"))
  return true
end

local function handle_browser_scroll(payload)
  state.last_scroll_payload = payload
  if not state.scroll_handler then
    log("browser scroll ignored", { reason = "no scroll handler", payload = payload })
    return false
  end

  log("browser scroll scheduled", { payload = payload })
  vim.schedule(function()
    if state.scroll_handler then
      local ok, err = pcall(state.scroll_handler, payload)
      if not ok then
        log("browser scroll handler failed", { err = tostring(err), payload = payload })
        util.notify("Browser scroll sync failed: " .. tostring(err), vim.log.levels.WARN)
      else
        log("browser scroll handler complete", { payload = payload })
      end
    end
  end)
  return true
end

local function handle_events(client)
  local headers = {
    ["Content-Type"] = "text/event-stream",
    ["Cache-Control"] = "no-cache",
    ["Connection"] = "keep-alive",
    ["X-Accel-Buffering"] = "no",
  }
  state.clients[client] = true
  log("events client connected", { client = tostring(client), clients = vim.tbl_count(state.clients) })

  local body = ": quarto-sync connected\n\n"
  headers["Content-Length"] = nil

  local lines = { "HTTP/1.1 200 OK" }
  for key, value in pairs(vim.tbl_extend("force", {
    ["Access-Control-Allow-Origin"] = "*",
    ["Content-Type"] = headers["Content-Type"],
    ["Cache-Control"] = headers["Cache-Control"],
    ["Connection"] = headers["Connection"],
    ["X-Accel-Buffering"] = headers["X-Accel-Buffering"],
  }, {})) do
    table.insert(lines, key .. ": " .. value)
  end
  table.insert(lines, "")
  table.insert(lines, body)

  client:write(table.concat(lines, "\r\n"))
  pcall(function()
    client:read_stop()
  end)

  if state.last_payload then
    vim.defer_fn(function()
      if state.clients[client] and not client:is_closing() then
        log("replay last cursor payload", { client = tostring(client), payload = state.last_payload })
        client:write(("event: cursor\ndata: %s\n\n"):format(util.json_encode(state.last_payload)))
      end
    end, 25)
  end
end

local function handle_request(client, request)
  log("request", { method = request.method, path = request.path })
  if request.method == "OPTIONS" then
    write_response(client, 204, nil, "")
    return
  end

  if request.path == "/health" then
    write_json(client, 200, {
      ok = true,
      service = "quarto-sync.nvim",
      port = state.port,
      clients = vim.tbl_count(state.clients),
    })
    return
  end

  if request.path == "/events" then
    if request.method ~= "GET" then
      log("request rejected", { path = request.path, method = request.method, reason = "GET required" })
      write_json(client, 405, { error = "GET required" })
      return
    end
    handle_events(client)
    return
  end

  if request.path == "/cursor" then
    if request.method ~= "POST" then
      log("request rejected", { path = request.path, method = request.method, reason = "POST required" })
      write_json(client, 405, { error = "POST required" })
      return
    end

    local ok, payload = pcall(util.json_decode, request.body)
    if not ok or type(payload) ~= "table" then
      log("cursor payload rejected", { body = request.body })
      write_json(client, 400, { error = "invalid JSON payload" })
      return
    end

    log("cursor payload received", payload)
    M.broadcast(payload)
    write_json(client, 200, { ok = true })
    return
  end

  if request.path == "/scroll" then
    if request.method ~= "POST" then
      log("request rejected", { path = request.path, method = request.method, reason = "POST required" })
      write_json(client, 405, { error = "POST required" })
      return
    end

    local ok, payload = pcall(util.json_decode, request.body)
    if not ok or type(payload) ~= "table" then
      log("scroll payload rejected", { body = request.body })
      write_json(client, 400, { error = "invalid JSON payload" })
      return
    end

    log("scroll payload received", payload)
    write_json(client, 200, { ok = true, handled = handle_browser_scroll(payload) })
    return
  end

  log("request rejected", { path = request.path, method = request.method, reason = "not found" })
  write_json(client, 404, { error = "not found" })
end

local function handle_client(client)
  local buffer = ""

  client:read_start(function(err, chunk)
    if err or not chunk then
      log("client read ended", { client = tostring(client), err = tostring(err) })
      close_client(client)
      return
    end

    buffer = buffer .. chunk
    if not request_complete(buffer) then
      return
    end

    local request = parse_request(buffer)
    if not request then
      log("request parse failed", { raw = buffer })
      write_json(client, 400, { error = "invalid HTTP request" })
      return
    end

    handle_request(client, request)
  end)
end

function M.start(opts)
  opts = vim.tbl_extend("force", config.get(), opts or {})
  log("start requested", { host = opts.host, port = opts.port })
  if state.running and state.port == opts.port and state.host == opts.host then
    log("start reused existing server", { host = state.host, port = state.port })
    return true
  end
  if state.running then
    log("start stopping existing server", { host = state.host, port = state.port })
    M.stop()
  end

  local server = uv.new_tcp()
  local bind_ok, bind_result, bind_err = pcall(function()
    return server:bind(opts.host, opts.port)
  end)
  if not bind_ok or bind_result == nil then
    log("bind failed", { host = opts.host, port = opts.port, err = tostring(bind_err or bind_result) })
    util.notify(
      ("Could not bind sync server on %s:%s: %s"):format(opts.host, opts.port, tostring(bind_err or bind_result)),
      vim.log.levels.ERROR
    )
    pcall(function()
      server:close()
    end)
    return false
  end
  log("bind complete", { host = opts.host, port = opts.port })

  local listen_ok, listen_result, listen_err = pcall(function()
    return server:listen(128, function(err)
      if err then
        log("listen callback error", { err = err })
        util.notify("Sync server error: " .. err, vim.log.levels.ERROR)
        return
      end

      local client = uv.new_tcp()
      local accept_ok, accept_err = server:accept(client)
      if accept_ok == nil then
        log("accept failed", { err = tostring(accept_err) })
        util.notify("Could not accept sync client: " .. tostring(accept_err), vim.log.levels.WARN)
        if not client:is_closing() then
          client:close()
        end
        return
      end
      state.connections[client] = true
      log("client accepted", { client = tostring(client), connections = vim.tbl_count(state.connections) })
      handle_client(client)
    end)
  end)

  if not listen_ok or listen_result == nil then
    log("listen failed", { host = opts.host, port = opts.port, err = tostring(listen_err or listen_result) })
    util.notify(
      ("Could not start sync server on %s:%s: %s"):format(opts.host, opts.port, tostring(listen_err or listen_result)),
      vim.log.levels.ERROR
    )
    pcall(function()
      server:close()
    end)
    return false
  end

  state.running = true
  state.host = opts.host
  state.port = opts.port
  state.server = server
  state.connections = {}
  state.clients = {}
  log("start complete", { host = state.host, port = state.port })
  return true
end

function M.stop()
  log("stop requested", {
    running = state.running,
    host = state.host,
    port = state.port,
    connections = vim.tbl_count(state.connections),
    clients = vim.tbl_count(state.clients),
  })
  for client in pairs(state.connections) do
    close_client(client)
  end
  state.connections = {}

  for client in pairs(state.clients) do
    close_client(client)
  end
  state.clients = {}

  if state.server and not state.server:is_closing() then
    state.server:close()
  end

  state.running = false
  state.server = nil
  state.host = nil
  state.port = nil
  log("stop complete")
end

function M.is_running()
  return state.running
end

function M.status()
  return {
    running = state.running,
    host = state.host,
    port = state.port,
    clients = vim.tbl_count(state.clients),
    last_payload = state.last_payload,
    last_scroll_payload = state.last_scroll_payload,
  }
end

return M
