local net = require "net"
local test = require "core.test"

-- Seam: the public nonblocking network API used by local control clients.
test.describe("Local network server", function()
  test.it("creates a private directory for local server credentials", function()
    local path = USERDIR .. "/private-control"
    test.ok(net.private_directory(path))
    test.ok(net.private_directory(path))
    test.ok(test.remove_tree(path))
  end)
  test.it("accepts a client without blocking and closes explicitly", function()
    local token = net.random_token()
    test.ok(token:match("^[0-9a-f]+$") and #token >= 64)
    test.not_equal(token, net.random_token())
    local address = assert(net.resolve_address("127.0.0.1"))
    test.equal(address:wait_until_resolved(5000), "success")
    local server, port
    for i = 1, 100 do
      port = 49152 + (tonumber(token:sub(1, 4), 16) + i) % 16384
      server = net.create_server(address, port)
      if server then break end
    end
    test.ok(server)
    test.is_nil(server:accept())
    local client = assert(net.open_tcp(address, port))
    test.equal(client:wait_until_connected(5000), "success")
    local peer
    local deadline = system.get_time() + 10
    repeat
      peer = server:accept()
      if not peer then coroutine.yield() end
    until peer or system.get_time() >= deadline
    test.ok(peer)
    test.ok(client:write("hello"))
    local text = ""
    repeat
      text = text .. assert(peer:read(32))
      if text ~= "hello" then coroutine.yield() end
    until text == "hello" or system.get_time() >= deadline
    test.equal(text, "hello")
    peer:close()
    client:close()
    server:close()
    server:close()
  end)
end)
