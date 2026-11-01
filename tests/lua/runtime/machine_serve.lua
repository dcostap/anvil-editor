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

  -- Sends requests without a wait for replies, and gives their IDs.
  local function send(client, requests)
    local frames, ids = {}, {}
    for i, request in ipairs(requests) do
      ids[i] = client.next_id
      frames[i] = machine.frame("request", client.next_id, json.encode({method = request[1], params = request[2]}))
      client.next_id = client.next_id + 1
    end
    test.ok(client.socket:write(table.concat(frames)))
    return ids
  end

  -- Reads replies until each ID has one, or the time ends. Gives the replies by ID.
  local function replies(client, ids, seconds)
    local got, missing = {}, #ids
    local deadline = system.get_time() + seconds
    while missing > 0 and system.get_time() < deadline do
      local kind, reply_id, body = client.decoder:next()
      if kind then
        if not got[reply_id] then missing = missing - 1 end
        got[reply_id] = json.decode(body)
      else
        local chunk = client.socket:read(1024 * 1024)
        if not chunk then break end
        if chunk == "" then coroutine.yield(0.01) else client.decoder:feed(chunk) end
      end
    end
    return got, missing
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
    machine_server.stop(context.restore_anvil)
    machine_server.stop(context.waiting)
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

    -- Incomplete JSON gets no reply, and the server goes on with other clients.
    client = connect(context.discovery)
    test.ok(client.socket:write(machine.frame("request", 1, "[")))
    coroutine.yield(1)
    local other = connect(context.discovery)
    test.equal(call(other, "hello", {protocol = 1, token = context.discovery.token}).result.protocol, 1)
    other.socket:close()
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
  local function pair(context, level, name)
    local code = call(owner(context), "pairing.start", {level = level}).result.code
    local client = connect(context.discovery)
    local hello = call(client, "hello", {protocol = 1, pair = code, name = name or "Laptop"}).result
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
    test.equal(call(client, "hello", {protocol = 1, pair = code, name = "Again"}).error.code, "pairing_ended")
    client.socket:close()
    client = connect(context.discovery)
    test.equal(call(client, "hello", {protocol = 1, device = device.id, token = string.rep("0", 64)}).error.code,
      "unauthorized")
    client.socket:close()

    -- A device name is text, also when it looks like the JSON encoder's raw-number marker.
    pair(context, "view", json.number_flag .. "]")
    stop_server(context)
    context.discovery = start_server(context)
    local names = {}
    for _, listed in ipairs(call(owner(context), "devices.list", {}).result.devices) do names[#names + 1] = listed.name end
    test.same(names, {"Laptop", json.number_flag .. "]"})
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
    test.equal(call(client, "files.delete", {paths = {path}}).error.code, "forbidden")
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
    test.equal(call(client, "hello", {protocol = 1, pair = code, name = "Laptop"}).error.code, "pairing_ended")
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

  -- Runs `anvil machine ...` for this test's user folder. Returns its exit code and output.
  local function machine_command(context, ...)
    local proc = assert(process.start({ EXEFILE, "machine", ... }, {
      stdin = process.REDIRECT_DISCARD, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_PIPE,
      env = { ANVIL_USERDIR = context.user },
    }))
    local code = proc:wait(30000, 0.01)
    return code, (proc:read_stdout(65536) or "") .. (proc:read_stderr(65536) or "")
  end

  test.it("makes pairing codes and revokes devices from the command line", function(context)
    local code, output = machine_command(context, "code", "view")
    test.equal(code, 0, output)
    local pairing = output:match("Pairing code: (%d+)")
    test.ok(pairing, output)
    local client = connect(context.discovery)
    local hello = call(client, "hello", {protocol = 1, pair = pairing, name = "Phone"}).result
    test.equal(hello.level, "view")

    code, output = machine_command(context, "devices")
    test.equal(code, 0, output)
    test.ok(output:find(hello.device.id, 1, true) and output:find("Phone", 1, true), output)
    test.equal(machine_command(context, "revoke", hello.device.id), 0)
    test.is_nil(call(client, "files.read", {path = context.project .. PATHSEP .. "notes.md"}))
    test.equal(machine_command(context, "revoke", hello.device.id), 1)
  end)

  test.it("listens on the port that --port names", function(context)
    stop_server(context)
    -- Windows reserves whole port ranges, so the test uses a port that it can open.
    local address = assert(net.resolve_address("127.0.0.1"))
    test.equal(address:wait_until_resolved(5000), "success")
    local start, port = tonumber(net.random_token():sub(1, 4), 16)
    for i = 1, 128 do
      local candidate = 49152 + (start + i * 127) % 16384
      local probe = net.create_server(address, candidate)
      if probe then
        probe:close()
        port = candidate
        break
      end
    end
    test.ok(port, "No free port")
    context.server, context.discovery = machine_server.start(context.user, { "--port", tostring(port), context.project })
    test.equal(context.discovery.port, port)
    owner(context).socket:close()
  end)

  local function sorted(list)
    table.sort(list)
    return list
  end

  test.it("lists a Project's files and folders with its ignore rules, and reports changes", function(context)
    local function path(...) return table.concat({context.project, ...}, PATHSEP) end
    test.ok(common.mkdirp(path("sub")))
    test.ok(common.mkdirp(path("empty")))
    test.ok(common.mkdirp(path("build")))
    write_file(path("sub", "a.txt"), "a\n")
    write_file(path("build", "out.txt"), "out\n")
    write_file(path(".ignore"), "build/\n")
    local client = owner(context)

    local reply, bytes = call(client, "files.list", {root = context.project})
    local names = {}
    for name in (bytes .. "\0"):gmatch("(.-)%z") do names[#names + 1] = name end
    local found_files = {table.unpack(names, 1, reply.result.files)}
    local found_folders = {table.unpack(names, reply.result.files + 1)}
    test.same(sorted(found_files), {"notes.md", "sub" .. PATHSEP .. "a.txt"})
    -- As in a local Project, an ignored folder shows, but its files do not.
    test.same(sorted(found_folders), {"build", "empty", "sub"})
    test.equal(call(client, "files.list", {root = path("sub")}).error.code, "not_a_project")

    write_file(path("sub", "new.md"), "new\n")
    -- The watcher can report the folder in one batch and the file in the next.
    local since, listed, seen = reply.result.changes, false, {}
    local deadline = system.get_time() + 20
    while not listed and system.get_time() < deadline do
      local changed = call(client, "files.changes", {root = context.project, since = since}).result
      test.ok(changed.sequence > since)
      since = changed.sequence
      for _, name in ipairs(changed.paths) do
        seen[#seen + 1] = name
        listed = listed or name == "sub" .. PATHSEP .. "new.md"
      end
    end
    test.ok(listed, table.concat(seen, ", "))
  end)

  test.it("makes, moves, copies and deletes files in its Projects only", function(context)
    local function path(...) return table.concat({context.project, ...}, PATHSEP) end
    local client = owner(context)
    test.same(call(client, "files.mkdir", {path = path("a", "b")}).result, {})
    test.same(call(client, "files.move", {from = path("notes.md"), to = path("a", "b", "moved.md")}).result, {})
    test.same(call(client, "files.copy", {from = path("a"), to = path("copy")}).result, {})
    local file = assert(io.open(path("copy", "b", "moved.md"), "rb"))
    test.equal(file:read("*a"), "# Notes\n")
    file:close()
    test.equal(call(client, "files.copy", {from = path("a"), to = path("copy")}).error.code, "change_failed")
    test.equal(call(client, "files.copy", {from = path("a"), to = path("a", "b", "c")}).error.code, "change_failed")
    test.same(call(client, "files.delete", {paths = {path("a"), path("missing.md")}}).result, {})
    test.is_nil(system.get_file_info(path("a")))
    test.equal(call(client, "files.delete", {paths = {context.project}}).error.code, "project_root")
    test.equal(call(client, "files.move", {from = path("copy"), to = context.root .. PATHSEP .. "out"}).error.code,
      "outside_project")
    test.ok(system.get_file_info(path("copy", "b", "moved.md")))

    -- A change cannot take another Project with its parent folder.
    test.ok(common.mkdirp(path("group", "inner")))
    stop_server(context)
    context.server, context.discovery = machine_server.start(context.user, { context.project, path("group", "inner") })
    client = owner(context)
    test.equal(call(client, "files.delete", {paths = {path("group")}}).error.code, "project_root")
    test.equal(call(client, "files.move", {from = path("group"), to = path("moved")}).error.code, "project_root")
    test.ok(system.get_file_info(path("group", "inner")))
  end)

  test.it("stats many paths and lists a folder in one request each", function(context)
    test.ok(common.mkdirp(context.project .. PATHSEP .. "sub"))
    local client = owner(context)
    local notes = context.project .. PATHSEP .. "notes.md"
    local reply, bytes = call(client, "files.stat",
      {paths = {notes, context.project .. PATHSEP .. "missing.md", context.project .. PATHSEP .. "sub"}})
    test.equal(reply.result.count, 3)
    local stats = json.decode(bytes)
    test.equal(stats[1].type, "file")
    test.equal(stats[1].size, #"# Notes\n")
    test.equal(stats[2], false)
    test.equal(stats[3].type, "dir")
    test.equal(call(client, "files.stat", {paths = {notes, context.root .. PATHSEP .. "secret.txt"}}).error.code,
      "outside_project")

    local entries
    reply, bytes = call(client, "files.list_dir", {path = context.project})
    entries = json.decode(bytes)
    local kinds = {}
    for _, entry in ipairs(entries) do kinds[entry.name] = entry.type end
    test.same(kinds, {["notes.md"] = "file", sub = "dir"})
    test.equal(call(client, "files.list_dir", {path = context.root}).error.code, "outside_project")
  end)

  test.it("searches a Project's text with ripgrep, and refuses other options and paths outside its Projects", function(context)
    test.ok(common.mkdirp(context.project .. PATHSEP .. "sub"))
    write_file(context.project .. PATHSEP .. "sub" .. PATHSEP .. "plan.md", "one\nfind the needle\n")
    local client = owner(context)
    local function search(args)
      local reply = call(client, "search.start", {args = args, cwd = context.project})
      if reply.error then return nil, reply.error.code end
      local output = {}
      repeat
        local read, bytes = call(client, "search.read", {id = reply.result.id})
        output[#output + 1] = bytes
      until read.result.done
      return table.concat(output)
    end

    local found = search({"any program", "--line-number", "--column", "--no-heading", "--with-filename", "--color",
      "never", "-F", "-e", "needle", "."})
    test.ok(found:find("plan.md:2:10:find the needle", 1, true), found)
    local _, code = search({"rg", "--pre", "cmd", "-e", "needle", "."})
    test.equal(code, "invalid_request")
    _, code = search({"rg", "-e", "needle", "--", context.root .. PATHSEP .. "user"})
    test.equal(code, "outside_project")
    _, code = search({"rg", "-e", "needle", ".."})
    test.equal(code, "outside_project")
    -- Windows reads a path that starts with a separator from the drive's root, not from the folder.
    _, code = search({"rg", "-e", "secret", "--", ((context.root .. PATHSEP .. "secret.txt"):gsub("^%a:", ""))})
    test.equal(code, "invalid_path")
    _, code = search({"rg", "-e", "secret", string.rep(".." .. PATHSEP, 64)})
    test.ok(code, "A path above the drive's root was accepted")
    test.ok(search({"rg", "-F", "-e", "needle", "."}):find("needle", 1, true), "The server stopped after a bad path")

    -- A reply holds a bounded part of one long line, whatever --max-columns the Client gives.
    write_file(context.project .. PATHSEP .. "long.txt", "needle" .. string.rep("x", 3 * 1024 * 1024) .. "\n")
    for _, columns in ipairs {{}, {"--max-columns", "0"}, {"--max-columns", "99999999"}} do
      local args = {"rg", "-F", "-e", "needle"}
      for _, arg in ipairs(columns) do args[#args + 1] = arg end
      args[#args + 1] = "long.txt"
      found = search(args)
      test.ok(#found < 1024 * 1024, "A reply held " .. #found .. " bytes")
    end

    -- A search that a newer search pushes out answers its waiting read.
    local first = call(client, "search.start", {args = {"rg", "-e", "needle", "."}, cwd = context.project})
    call(client, "search.cancel", {id = first.result.id})
    local requests = {{"search.start", {args = {"rg", "-e", "needle", "."}, cwd = context.project}},
      {"search.read", {id = tostring(tonumber(first.result.id) + 1)}}}
    for _ = 1, 16 do requests[#requests + 1] = requests[1] end
    local _, missing = replies(client, send(client, requests), 10)
    test.equal(missing, 0, "A read of a removed search got no reply")
  end)

  test.it("answers each request that arrived while a Client did not read its replies", function(context)
    write_file(context.project .. PATHSEP .. "large.bin", string.rep("x", 2 * 1024 * 1024))
    local client = owner(context)
    local requests = {}
    for i = 1, 48 do requests[i] = {"files.read", {path = context.project .. PATHSEP .. "large.bin"}} end
    local ids = send(client, requests)
    coroutine.yield(1)
    local _, missing = replies(client, ids, 20)
    test.equal(missing, 0, "Requests after the stall got no reply")
  end)

  test.it("keeps its credentials out of a Project that holds its user folder", function(context)
    stop_server(context)
    -- A ripgrep glob reads [ ] { } as patterns. The user folder's name must still match only itself.
    local user = context.root .. PATHSEP .. "user[1]{a}"
    test.ok(common.mkdirp(user))
    context.server, context.discovery = machine_server.start(user, { context.root })
    local client = owner(context)
    local discovery = machine_server.discovery_path(user)
    test.equal(call(client, "files.read", {path = discovery}).error.code, "private")
    test.equal(call(client, "files.copy", {from = discovery, to = context.root .. PATHSEP .. "copy.json"}).error.code,
      "private")
    local reply = call(client, "search.start", {args = {"rg", "-F", "-e", context.discovery.token, "."}, cwd = context.root})
    local output = {}
    repeat
      local read, bytes = call(client, "search.read", {id = reply.result.id})
      output[#output + 1] = bytes
    until read.result.done
    test.equal(table.concat(output), "")

    -- A search from a subfolder cannot name the folder above it, where the credentials are.
    local sub = context.root .. PATHSEP .. "sub"
    test.ok(common.mkdirp(sub))
    reply = call(client, "search.start", {args = {"rg", "-F", "-e", context.discovery.token, context.root}, cwd = sub})
    output = {}
    while reply.result do
      local read, bytes = call(client, "search.read", {id = reply.result.id})
      output[#output + 1] = bytes
      if read.result.done then break end
    end
    test.equal(table.concat(output), "")
    client.socket:close()
  end)

  local function write_sidebar(context, ...)
    local recents = {}
    for i, path in ipairs({...}) do recents[i] = string.format("%q", path) end
    write_file(context.user .. PATHSEP .. "appstate.lua", "return { recents = { " .. table.concat(recents, ", ") .. " } }\n")
  end

  test.it("serves the Projects of its user folder's Sidebar without a Project list", function(context)
    stop_server(context)
    local scratch, other = context.user .. PATHSEP .. "scratch", context.root .. PATHSEP .. "other"
    test.ok(common.mkdirp(scratch))
    test.ok(common.mkdirp(other))
    write_file(other .. PATHSEP .. "todo.md", "- [ ] Todo\n")
    write_sidebar(context, context.project, context.root .. PATHSEP .. "missing")
    context.server, context.discovery = machine_server.start(context.user, {})
    local client = owner(context)

    test.same(call(client, "projects.list", {}).result.projects,
      {{path = scratch, scratch = true}, {path = context.project}})
    local _, bytes = call(client, "files.read", {path = context.project .. PATHSEP .. "notes.md"})
    test.equal(bytes, "# Notes\n")
    test.equal(call(client, "files.read", {path = other .. PATHSEP .. "todo.md"}).error.code, "outside_project")

    write_sidebar(context, other, context.project)
    test.same(call(client, "projects.list", {}).result.projects,
      {{path = scratch, scratch = true}, {path = other}, {path = context.project}})
    _, bytes = call(client, "files.read", {path = other .. PATHSEP .. "todo.md"})
    test.equal(bytes, "- [ ] Todo\n")
  end)

  test.it("runs one server for each user folder, and an Anvil's server ends with its Anvil", function(context)
    local second = machine_server.spawn(context.user, {})
    test.equal(second:wait(10000, 0.01), 1)

    -- A server of another user folder stands for the Anvil that owns the next server.
    local anvil = machine_server.start(context.root .. PATHSEP .. "anvil-user", {})
    context.restore_anvil = anvil
    local waiting = machine_server.spawn(context.user, {"--owner", tostring(anvil:pid()), context.project})
    context.waiting = waiting
    local deadline = system.get_time() + 1.5
    while system.get_time() < deadline do coroutine.yield(0.05) end
    test.ok(waiting:running())

    stop_server(context)
    context.discovery = machine_server.wait_discovery(context.user, waiting)
    owner(context).socket:close()

    machine_server.stop(anvil)
    test.equal(waiting:wait(10000, 0.01), 0)
  end)
end)
