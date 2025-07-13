---@brief TCP server implementation using vim.loop
local client_manager = require("claudecode.server.client")
local utils = require("claudecode.server.utils")

local M = {}

---@class TCPServer
---@field server table The vim.loop TCP server handle
---@field port number The port the server is listening on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table Table of connected clients (client_id -> WebSocketClient)
---@field on_message function Callback for WebSocket messages
---@field on_connect function Callback for new connections
---@field on_disconnect function Callback for client disconnections
---@field on_error fun(err_msg: string) Callback for errors

---@brief Find an available port by attempting to bind
---@param min_port number Minimum port to try
---@param max_port number Maximum port to try
---@return number|nil port Available port number, or nil if none found
function M.find_available_port(min_port, max_port)
  if min_port > max_port then
    return nil -- Or handle error appropriately
  end

  local ports = {}
  for i = min_port, max_port do
    table.insert(ports, i)
  end

  -- Shuffle the ports
  utils.shuffle_array(ports)

  -- Try to bind to a port from the shuffled list
  for _, port in ipairs(ports) do
    local test_server = vim.loop.new_tcp()
    local success = test_server:bind("127.0.0.1", port)
    test_server:close()

    if success then
      return port
    end
  end

  return nil
end

---@brief Create and start a TCP server
---@param config table Server configuration
---@param callbacks table Callback functions
---@param auth_token string|nil Authentication token for validating connections
---@return TCPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, callbacks, auth_token)
  local port = M.find_available_port(config.port_range.min, config.port_range.max)
  if not port then
    return nil, "No available ports in range " .. config.port_range.min .. "-" .. config.port_range.max
  end

  local tcp_server = vim.loop.new_tcp()
  if not tcp_server then
    return nil, "Failed to create TCP server"
  end

  -- Create server object
  local server = {
    server = tcp_server,
    port = port,
    auth_token = auth_token,
    clients = {},
    on_message = callbacks.on_message or function() end,
    on_connect = callbacks.on_connect or function() end,
    on_disconnect = callbacks.on_disconnect or function() end,
    on_error = callbacks.on_error or function() end,
  }

  local bind_success, bind_err = tcp_server:bind("127.0.0.1", port)
  if not bind_success then
    tcp_server:close()
    return nil, "Failed to bind to port " .. port .. ": " .. (bind_err or "unknown error")
  end

  -- Start listening
  local listen_success, listen_err = tcp_server:listen(128, function(err)
    if err then
      callbacks.on_error("Listen error: " .. err)
      return
    end

    M._handle_new_connection(server)
  end)

  if not listen_success then
    tcp_server:close()
    return nil, "Failed to listen on port " .. port .. ": " .. (listen_err or "unknown error")
  end

  return server, nil
end

---@brief Handle a new client connection
---@param server TCPServer The server object
function M._handle_new_connection(server)
  local client_tcp = vim.loop.new_tcp()
  if not client_tcp then
    server.on_error("Failed to create client TCP handle")
    return
  end

  local accept_success, accept_err = server.server:accept(client_tcp)
  if not accept_success then
    server.on_error("Failed to accept connection: " .. (accept_err or "unknown error"))
    client_tcp:close()
    return
  end

  -- Check if this might be a reconnecting zombie client
  -- We'll determine this during handshake based on auth token
  -- For now, create a new client
  local client = client_manager.create_client(client_tcp)
  
  -- Store reference to server for potential zombie lookup
  client._server_ref = server
  
  server.clients[client.id] = client

  -- Set up data handler
  client_tcp:read_start(function(err, data)
    if err then
      server.on_error("Client read error: " .. err)
      M._remove_client(server, client)
      return
    end

    if not data then
      -- EOF - client disconnected
      M._remove_client(server, client)
      return
    end

    -- Process incoming data
    client_manager.process_data(client, data, function(cl, message)
      server.on_message(cl, message)
    end, function(cl, code, reason)
      server.on_disconnect(cl, code, reason)
      M._remove_client(server, cl)
    end, function(cl, error_msg)
      server.on_error("Client " .. cl.id .. " error: " .. error_msg)
      M._remove_client(server, cl)
    end, server.auth_token)
  end)

  -- Notify about new connection
  server.on_connect(client)
end

---@brief Remove a client from the server
---@param server TCPServer The server object
---@param client WebSocketClient The client to remove
function M._remove_client(server, client)
  if server.clients[client.id] then
    server.clients[client.id] = nil

    if not client.tcp_handle:is_closing() then
      client.tcp_handle:close()
    end
  end
end

---@brief Send a message to a specific client
---@param server TCPServer The server object
---@param client_id string The client ID
---@param message string The message to send
---@param callback function|nil Optional callback
function M.send_to_client(server, client_id, message, callback)
  local client = server.clients[client_id]
  if not client then
    if callback then
      callback("Client not found: " .. client_id)
    end
    return
  end

  client_manager.send_message(client, message, callback)
end

---@brief Broadcast a message to all connected clients
---@param server TCPServer The server object
---@param message string The message to broadcast
function M.broadcast(server, message)
  for _, client in pairs(server.clients) do
    client_manager.send_message(client, message)
  end
end

---@brief Get the number of connected clients
---@param server TCPServer The server object
---@return number count Number of connected clients
function M.get_client_count(server)
  local count = 0
  for _ in pairs(server.clients) do
    count = count + 1
  end
  return count
end

---@brief Get information about all clients
---@param server TCPServer The server object
---@return table clients Array of client information
function M.get_clients_info(server)
  local clients = {}
  for _, client in pairs(server.clients) do
    table.insert(clients, client_manager.get_client_info(client))
  end
  return clients
end

---@brief Close a specific client connection
---@param server TCPServer The server object
---@param client_id string The client ID
---@param code number|nil Close code
---@param reason string|nil Close reason
function M.close_client(server, client_id, code, reason)
  local client = server.clients[client_id]
  if client then
    client_manager.close_client(client, code, reason)
  end
end

---@brief Stop the TCP server
---@param server TCPServer The server object
function M.stop_server(server)
  -- Close all clients
  for _, client in pairs(server.clients) do
    client_manager.close_client(client, 1001, "Server shutting down")
  end

  -- Clear clients
  server.clients = {}

  -- Close server
  if server.server and not server.server:is_closing() then
    server.server:close()
  end
end

---@brief Start a periodic ping task to keep connections alive
---@param server TCPServer The server object
---@param interval number Ping interval in milliseconds (default: 30000)
---@return table timer The timer handle
function M.start_ping_timer(server, interval)
  interval = interval or 30000 -- 30 seconds

  local timer = vim.loop.new_timer()
  timer:start(interval, interval, function()
    -- Track clients to clean up (to avoid modifying table while iterating)
    local clients_to_clean = {}
    
    for client_id, client in pairs(server.clients) do
      if client.state == "connected" then
        -- Get config values
        local config = require("claudecode.config").config
        local reconnection_enabled = config.reconnection and config.reconnection.enabled
        local ping_timeout = config.reconnection and config.reconnection.ping_timeout or interval * 2
        local grace_multiplier = config.reconnection and config.reconnection.sleep_grace_multiplier or 4
        
        -- Check if client is alive
        if client_manager.is_client_alive(client, ping_timeout) then
          client_manager.send_ping(client, "ping")
        else
          if reconnection_enabled then
            -- Check for possible sleep/wake event
            local time_since_last_pong = vim.loop.now() - client.last_pong
            if time_since_last_pong > interval * grace_multiplier then
              -- Likely a sleep/wake event - give grace period
              server.on_error("Client " .. client.id .. " appears unresponsive (possible sleep/wake), moving to zombie state")
              client_manager.make_zombie(client)
            else
              -- Normal timeout - move to zombie state
              server.on_error("Client " .. client.id .. " connection timeout, moving to zombie state")
              client_manager.make_zombie(client)
            end
          else
            -- Original behavior - close connection
            server.on_error("Client " .. client.id .. " appears dead, closing")
            client_manager.close_client(client, 1006, "Connection timeout")
            M._remove_client(server, client)
          end
        end
      elseif client.state == "zombie" then
        -- Check if zombie has expired
        local config = require("claudecode.config").config
        local zombie_timeout = config.reconnection and config.reconnection.zombie_timeout or 300000
        if client_manager.is_zombie_expired(client, zombie_timeout) then
          server.on_error("Zombie client " .. client.id .. " expired, removing")
          table.insert(clients_to_clean, client_id)
        end
      end
    end
    
    -- Clean up expired zombies
    for _, client_id in ipairs(clients_to_clean) do
      server.clients[client_id] = nil
    end
  end)

  return timer
end

---@brief Find a zombie client by auth token
---@param server TCPServer The server object
---@param auth_token string The authentication token
---@return WebSocketClient|nil client The zombie client if found
function M._find_zombie_by_auth(server, auth_token)
  if not auth_token then
    return nil
  end
  
  for _, client in pairs(server.clients) do
    if client.state == "zombie" and client.auth_token == auth_token then
      return client
    end
  end
  
  return nil
end

return M
