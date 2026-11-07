local command = require "core.command"
local common = require "core.common"
local dialog = require "core.ui.dialog"
local MachineClient = require "core.machine_client"
local access = require "core.machine_access"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local test = require "core.test"

-- Seam: the Machines Dialog against a real `anvil serve` for this user folder. The Dialog pairs this PC with its
-- own server, so one server plays both this PC and the other Machine. A fake Tailscale CLI stands in for
-- Tailscale, so the tests never change the PC's tailnet.
test.describe("Machines Dialog", function()
  local function wait_until(predicate, message)
    local deadline = system.get_time() + 20
    while system.get_time() < deadline do
      dialog.update()
      if predicate() then return end
      coroutine.yield(0.02)
    end
    test.fail(message)
  end

  local function call(client, method, params)
    local done, reply
    client:request(method, params, nil, function(...) done, reply = true, table.pack(...) end)
    wait_until(function() return done end, "No reply to " .. method)
    return table.unpack(reply, 1, reply.n)
  end

  local function type_into(open, field, text)
    open:focus(field)
    field:on_text(text)
  end

  local function open_dialog(name)
    test.ok(command.perform(name))
    local open = test.not_nil(dialog.current())
    wait_until(function() return open.owner and open.owner.state == "ready" end, "The Dialog did not connect")
    return open
  end

  test.before_each(function(context)
    context.run = access.run
    context.project = USERDIR .. PATHSEP .. "machine-dialog-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.project))
    context.server, context.discovery = machine_server.start(USERDIR, { context.project })
    context.owner = MachineClient.new(machine_server.discovery_path(USERDIR))
  end)

  test.after_each(function(context)
    access.run = context.run
    local open = dialog.current()
    if open then open:close() end
    context.owner:close()
    machine_server.stop(context.server)
    for _, path in ipairs({ context.project, USERDIR .. PATHSEP .. "machine", USERDIR .. PATHSEP .. "machines" }) do
      if system.get_file_info(path) then test.ok(test.remove_tree(path)) end
    end
  end)

  test.it("makes a pairing code that pairs a device, then revokes the device", function(context)
    access.run = function(_, on_done) on_done(nil, "missing") end
    local open = open_dialog("machine:manage")
    open.level_control:set_value("view")
    open.code_button:activate()
    wait_until(function() return open:active_code() ~= nil end, "No pairing code")
    local code = open:active_code().code

    local paired
    MachineClient.pair("127.0.0.1", context.discovery.port, code, "Phone", function(err) paired = err or true end)
    wait_until(function() return paired ~= nil end, "The pairing did not end")
    test.equal(paired, true)
    wait_until(function() return #open.device_list.rows == 1 end, "The paired device does not show")
    test.equal(open.device_list.rows[1].name, "Phone")
    test.equal(open.device_list.rows[1].level, "view")
    -- The code works one time, so it no longer shows.
    test.is_nil(open:active_code())

    open.device_list:select(1)
    open.revoke_button:activate()
    wait_until(function() return #open.device_list.rows == 0 end, "The revoked device still shows")
    local _, listed = call(context.owner, "devices.list", {})
    test.equal(#listed.devices, 0)
  end)

  test.it("shares this PC on the tailnet through Tailscale Serve, and stops", function(context)
    local port = context.discovery.port
    local forwarded, commands = false, {}
    access.run = function(args, on_done)
      local line = table.concat(args, " ")
      commands[#commands + 1] = line
      if line == "status --json" then
        on_done('{"BackendState": "Running", "Self": {"DNSName": "desk.tail1234.ts.net."}}')
      elseif line == "serve status --json" then
        on_done(forwarded and string.format('{"TCP": {"%d": {"TCPForward": "localhost:%d"}}}', port, port) or "{}")
      elseif line == string.format("serve --bg --tcp %d tcp://localhost:%d", port, port) then
        forwarded = true
        on_done("")
      elseif line == string.format("serve --tcp %d off", port) then
        forwarded = false
        on_done("")
      else
        on_done(nil, "unexpected command: " .. line)
      end
    end
    local open = open_dialog("machine:manage")
    wait_until(function() return open:access_text() == "Only this PC" end, "The Dialog does not show the access")

    open.access_button:activate()
    -- Other devices use this address to pair.
    wait_until(function() return open:access_text() == "desk.tail1234.ts.net:" .. port end, "Sharing did not turn on")
    test.ok(forwarded)
    open.access_button:activate()
    wait_until(function() return open:access_text() == "Only this PC" end, "Sharing did not stop")
    test.ok(not forwarded)
    for _, line in ipairs(commands) do test.is_nil(line:find("unexpected", 1, true), line) end
  end)

  test.it("pairs with a Machine from its address and code, then forgets it", function(context)
    access.run = function(_, on_done) on_done(nil, "missing") end
    wait_until(function() return context.owner.state == "ready" end, "The owner did not connect")
    local _, pairing = call(context.owner, "pairing.start", { level = "full" })

    local open = open_dialog("machine:pair")
    test.equal(open.focused, open.address_field)
    type_into(open, open.address_field, "127.0.0.1:" .. context.discovery.port)
    test.ok(open:confirm())
    test.equal(open.focused, open.code_field)
    type_into(open, open.code_field, pairing.code)
    test.ok(open:confirm())
    wait_until(function() return #open.machine_list.rows == 1 end, "The paired Machine does not show")
    local record = open.machine_list.rows[1]
    test.equal(record.host, "127.0.0.1")
    test.equal(record.port, context.discovery.port)
    wait_until(function() return open.clients[record.machine].state == "ready" end, "The Machine is not online")

    -- With Full control, Forget also removes this PC from the Machine's devices.
    open.machine_list:select(1)
    open.forget_button:activate()
    wait_until(function() return #open.machine_list.rows == 0 end, "The Machine still shows")
    test.equal(#MachineClient.records(), 0)
    local _, listed = call(context.owner, "devices.list", {})
    test.equal(#listed.devices, 0)
  end)
end)
