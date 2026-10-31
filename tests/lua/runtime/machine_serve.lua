local common = require "core.common"
local json = require "core.json"
local machine = require "machine"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local net = require "net"
local test = require "core.test"

-- Seam: `anvil serve` as a separate process, reached only through its discovery file and the Machine protocol.
test.describe("Machine server", function()
  local function write_file(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
  end

  local function start_server(context)
    local discovery
    context.server, discovery = machine_server.start(context.user, { context.project })
    return discovery
  end

  local function stop_server(context)
    machine_server.stop(context.server)
    context.server = nil
  end

  local function connect(server)
    local address = assert(net.resolve_address("127.0.0.1"))
    test.equal(address:wait_until_resolved(5000), "success")
    local socket = assert(net.open_tcp(address, server.port))
    test.equal(socket:wait_until_connected(5000), "success")
    return {socket = socket, decoder = machine.decoder(), next_id = 1}
  end

  -- Returns the reply's JSON and bytes, or nil when the server closes the connection.
  local function call(client, method, params)
    local id = client.next_id
    client.next_id = id + 1
    test.ok(client.socket:write(machine.frame("request", id, json.encode({method = method, params = params}))))
    local deadline = system.get_time() + 10
    while system.get_time() < deadline do
      local kind, reply_id, body, bytes = client.decoder:next()
      if kind then
        test.equal(kind, "reply")
        test.equal(reply_id, id)
        return json.decode(body), bytes
      end
      local chunk = client.socket:read(65536)
      if not chunk then return nil end
      if chunk == "" then coroutine.yield(0.01) else client.decoder:feed(chunk) end
    end
    error("The Machine server did not reply to " .. method)
  end

  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "machine-serve-" .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.user = context.root .. PATHSEP .. "user"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    test.ok(common.mkdirp(context.project))
    write_file(context.project .. PATHSEP .. "notes.md", "# Notes\n")
    write_file(context.root .. PATHSEP .. "secret.txt", "secret\n")
    context.discovery = start_server(context)
  end)

  test.after_each(function(context)
    stop_server(context)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("reads a Project file after hello with the server's token", function(context)
    local client = connect(context.discovery)
    local hello = call(client, "hello", {protocol = 1, token = context.discovery.token})
    test.equal(hello.result.protocol, 1)
    local listed = false
    for _, feature in ipairs(hello.result.features) do listed = listed or feature == "files.read" end
    test.ok(listed)

    local path = context.project .. PATHSEP .. "notes.md"
    local reply, bytes = call(client, "files.read", {path = path})
    test.equal(bytes, "# Notes\n")
    test.equal(reply.result.size, #"# Notes\n")
    local first = reply.result.version
    test.equal(call(client, "files.read", {path = path}).result.version, first)

    write_file(path, "# Notes\nChanged on the Machine.\n")
    reply, bytes = call(client, "files.read", {path = path})
    test.equal(bytes, "# Notes\nChanged on the Machine.\n")
    test.not_equal(reply.result.version, first)
    client.socket:close()
  end)

  test.it("refuses a client without the server's token", function(context)
    local client = connect(context.discovery)
    local reply = call(client, "files.read", {path = context.project .. PATHSEP .. "notes.md"})
    test.equal(reply.error.code, "unauthorized")
    test.is_nil(call(client, "hello", {protocol = 1, token = context.discovery.token}))
    client.socket:close()

    client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, token = string.rep("0", 64)}).error.code, "unauthorized")
    test.is_nil(call(client, "hello", {protocol = 1, token = context.discovery.token}))
    client.socket:close()
  end)

  test.it("refuses a client with another protocol version", function(context)
    local client = connect(context.discovery)
    local reply = call(client, "hello", {protocol = 999, token = context.discovery.token})
    test.equal(reply.error.code, "protocol")
    test.equal(reply.error.protocol, 1)
    client.socket:close()
  end)

  test.it("reads no file outside its Projects", function(context)
    local client = connect(context.discovery)
    call(client, "hello", {protocol = 1, token = context.discovery.token})
    for _, path in ipairs {
      context.root .. PATHSEP .. "secret.txt",
      context.project .. PATHSEP .. ".." .. PATHSEP .. "secret.txt",
      context.project .. "-other" .. PATHSEP .. "notes.md",
    } do
      local reply, bytes = call(client, "files.read", {path = path})
      test.equal(reply.error.code, "outside_project", path)
      test.equal(bytes, "")
    end
    test.equal(call(client, "files.read", {path = "notes.md"}).error.code, "invalid_path")
    test.equal(call(client, "files.read", {path = context.project .. PATHSEP .. "missing.md"}).error.code, "not_found")
    test.equal(call(client, "files.read", {path = context.project}).error.code, "not_a_file")
    client.socket:close()
  end)

  test.it("keeps its Machine ID across restarts and starts a new epoch", function(context)
    local client = connect(context.discovery)
    local first = call(client, "hello", {protocol = 1, token = context.discovery.token}).result
    client.socket:close()
    stop_server(context)

    context.discovery = start_server(context)
    client = connect(context.discovery)
    local second = call(client, "hello", {protocol = 1, token = context.discovery.token}).result
    client.socket:close()
    test.ok(type(first.machine) == "string" and #first.machine > 0)
    test.equal(second.machine, first.machine)
    test.not_equal(second.epoch, first.epoch)
  end)

  local function owner(context)
    local client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, token = context.discovery.token}).result.level, "full")
    return client
  end

  -- Returns the new device's credentials, from a connection that stays open.
  local function pair(context, level)
    local code = call(owner(context), "pairing.start", {level = level}).result.code
    local client = connect(context.discovery)
    local hello = call(client, "hello", {protocol = 1, pair = code, name = "Laptop"}).result
    test.equal(hello.level, level)
    return hello.device, client, code
  end

  test.it("pairs a device with a one-time code, and the device logs in with its own token", function(context)
    local device, client, code = pair(context, "full")
    local path = context.project .. PATHSEP .. "notes.md"
    local _, bytes = call(client, "files.read", {path = path})
    test.equal(bytes, "# Notes\n")
    client.socket:close()

    client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, pair = code, name = "Again"}).error.code, "unauthorized")
    client.socket:close()
    client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, device = device.id, token = string.rep("0", 64)}).error.code,
      "unauthorized")
    client.socket:close()

    stop_server(context)
    context.discovery = start_server(context)
    client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, device = device.id, token = device.token}).result.level, "full")
    _, bytes = call(client, "files.read", {path = path})
    test.equal(bytes, "# Notes\n")
    client.socket:close()
  end)

  test.it("lets a View device read but not write or pair", function(context)
    local _, client = pair(context, "view")
    local path = context.project .. PATHSEP .. "notes.md"
    local reply = call(client, "files.read", {path = path})
    test.equal(call(client, "files.write", {path = path, base = reply.result.version}).error.code, "forbidden")
    test.equal(call(client, "pairing.start", {level = "view"}).error.code, "forbidden")
    client.socket:close()
    local file = io.open(path, "rb")
    test.equal(file:read("*a"), "# Notes\n")
    file:close()
  end)

  test.it("ends a pairing code after five wrong attempts", function(context)
    local code = call(owner(context), "pairing.start", {level = "full"}).result.code
    local wrong = code == "000000" and "111111" or "000000"
    for _ = 1, 5 do
      local client = connect(context.discovery)
      test.equal(call(client, "hello", {protocol = 1, pair = wrong, name = "Guess"}).error.code, "unauthorized")
      client.socket:close()
    end
    local client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, pair = code, name = "Laptop"}).error.code, "unauthorized")
    client.socket:close()
  end)

  test.it("closes the connections of a revoked device at once", function(context)
    local device, client = pair(context, "full")
    local admin = owner(context)
    local listed = call(admin, "devices.list", {}).result.devices
    test.equal(#listed, 1)
    test.equal(listed[1].name, "Laptop")
    test.is_nil(listed[1].token)
    test.ok(call(admin, "devices.revoke", {device = device.id}).result)
    test.is_nil(call(client, "files.read", {path = context.project .. PATHSEP .. "notes.md"}))
    test.equal(#call(admin, "devices.list", {}).result.devices, 0)

    client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, device = device.id, token = device.token}).error.code,
      "unauthorized")
    client.socket:close()
  end)

  test.it("listens on the port that --port names", function(context)
    stop_server(context)
    local port = 49152 + tonumber(net.random_token():sub(1, 4), 16) % 16000
    context.server, context.discovery = machine_server.start(context.user, { "--port", tostring(port), context.project })
    test.equal(context.discovery.port, port)
    owner(context).socket:close()
  end)
end)
