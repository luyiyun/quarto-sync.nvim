local config = require("quarto_sync.config")
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
}

local status_text = {
  [200] = "OK",
  [204] = "No Content",
  [400] = "Bad Request",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [500] = "Internal Server Error",
}

local function close_client(client)
  state.connections[client] = nil
  state.clients[client] = nil
  if client and not client:is_closing() then
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

  local data = ("event: cursor\ndata: %s\n\n"):format(util.json_encode(payload))
  for client in pairs(state.clients) do
    if client:is_closing() then
      state.clients[client] = nil
    else
      client:write(data, function(err)
        if err then
          close_client(client)
        end
      end)
    end
  end
end

local function handle_events(client)
  local headers = {
    ["Content-Type"] = "text/event-stream",
    ["Cache-Control"] = "no-cache",
    ["Connection"] = "keep-alive",
    ["X-Accel-Buffering"] = "no",
  }
  state.clients[client] = true

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
        client:write(("event: cursor\ndata: %s\n\n"):format(util.json_encode(state.last_payload)))
      end
    end, 25)
  end
end

local function handle_request(client, request)
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
      write_json(client, 405, { error = "GET required" })
      return
    end
    handle_events(client)
    return
  end

  if request.path == "/cursor" then
    if request.method ~= "POST" then
      write_json(client, 405, { error = "POST required" })
      return
    end

    local ok, payload = pcall(util.json_decode, request.body)
    if not ok or type(payload) ~= "table" then
      write_json(client, 400, { error = "invalid JSON payload" })
      return
    end

    M.broadcast(payload)
    write_json(client, 200, { ok = true })
    return
  end

  write_json(client, 404, { error = "not found" })
end

local function handle_client(client)
  local buffer = ""

  client:read_start(function(err, chunk)
    if err or not chunk then
      close_client(client)
      return
    end

    buffer = buffer .. chunk
    if not request_complete(buffer) then
      return
    end

    local request = parse_request(buffer)
    if not request then
      write_json(client, 400, { error = "invalid HTTP request" })
      return
    end

    handle_request(client, request)
  end)
end

function M.start(opts)
  opts = vim.tbl_extend("force", config.get(), opts or {})
  if state.running and state.port == opts.port and state.host == opts.host then
    return true
  end
  if state.running then
    M.stop()
  end

  local server = uv.new_tcp()
  local bind_ok, bind_result, bind_err = pcall(function()
    return server:bind(opts.host, opts.port)
  end)
  if not bind_ok or bind_result == nil then
    util.notify(
      ("Could not bind sync server on %s:%s: %s"):format(opts.host, opts.port, tostring(bind_err or bind_result)),
      vim.log.levels.ERROR
    )
    pcall(function()
      server:close()
    end)
    return false
  end

  local listen_ok, listen_result, listen_err = pcall(function()
    return server:listen(128, function(err)
      if err then
        util.notify("Sync server error: " .. err, vim.log.levels.ERROR)
        return
      end

      local client = uv.new_tcp()
      local accept_ok, accept_err = server:accept(client)
      if accept_ok == nil then
        util.notify("Could not accept sync client: " .. tostring(accept_err), vim.log.levels.WARN)
        if not client:is_closing() then
          client:close()
        end
        return
      end
      state.connections[client] = true
      handle_client(client)
    end)
  end)

  if not listen_ok or listen_result == nil then
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
  return true
end

function M.stop()
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
  }
end

return M
