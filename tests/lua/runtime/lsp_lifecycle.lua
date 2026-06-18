local test = require "core.test"
local client = require "core.lsp.client"
local jsonrpc = require "core.lsp.jsonrpc"

local fake_server_path = "tests/fixtures/lsp/fake_server.lua"

local function fake_command()
  return { EXEFILE, "run", fake_server_path }
end

local function fake_options(mode, extra)
  local options = extra or {}
  options.env = { ANVIL_LSP_FAKE_SERVER_MODE = mode }
  return options
end

local function cleanup(c)
  if c and c.state ~= "exited" then
    c:shutdown(0.5, 0.01)
  end
end

local function pump_until(c, timeout, predicate)
  local start = system.get_time()
  while system.get_time() - start < timeout do
    if predicate() then return true end
    local ok, err = c:pump_once()
    if ok == nil and c.failed then return nil, err end
    if predicate() then return true end
    system.sleep(0.01)
  end
  return nil, "timeout"
end

test.describe("core.lsp.client lifecycle", function()
  test.test("initializes fake stdio server and reaches ready", function()
    local c, err = client.start(fake_command(), fake_options("lifecycle_success", {
      initialize_timeout = 3,
    }))
    test.not_nil(c, err)
    test.equal(c.state, "ready")
    test.not_nil(c.capabilities)
    test.equal(c.server_info.name, "anvil-fake-lsp")
    test.equal(c.position_encoding, "utf-16")
    test.contains(c.transport.stderr_tail, "truthful-capabilities=ok")
    cleanup(c)
  end)

  test.test("stores server capabilities and negotiated UTF-8 position encoding", function()
    local c, err = client.start(fake_command(), fake_options("lifecycle_utf8", {
      initialize_timeout = 3,
    }))
    test.not_nil(c, err)
    test.equal(c.state, "ready")
    test.equal(c.capabilities.positionEncoding, "utf-8")
    test.equal(c.position_encoding, "utf-8")
    cleanup(c)
  end)

  test.test("gracefully sends shutdown and exit", function()
    local c = test.not_nil(client.start(fake_command(), fake_options("lifecycle_success", {
      initialize_timeout = 3,
    })))
    test.equal(c.state, "ready")
    test.ok(c:shutdown(2, 0.01))
    test.equal(c.state, "exited")
    test.ok(c.exited)
    test.not_ok(c.transport:running())
    test.equal(c.exit_code, 0)
  end)

  test.test("handles server requests and noisy notifications safely", function()
    local c = test.not_nil(client.start(fake_command(), fake_options("server_requests", {
      initialize_timeout = 3,
    })))
    local ok, err = pump_until(c, 3, function()
      local tail = c.transport.stderr_tail or ""
      return tail:find("unknown-response-code=-32601", 1, true)
        and tail:find("apply-response-applied=false", 1, true)
        and tail:find("configuration-response=array", 1, true)
        and tail:find("register-response=ok", 1, true)
        and tail:find("progress-create-response=ok", 1, true)
    end)
    test.ok(ok, err)
    test.equal(c.state, "ready")
    cleanup(c)
  end)

  test.test("captures stderr tail with cap", function()
    local c = test.not_nil(client.start(fake_command(), fake_options("lifecycle_stderr", {
      initialize_timeout = 3,
      stderr_tail_limit = 128,
    })))
    test.ok(#c.transport.stderr_tail <= 128)
    test.contains(c.transport.stderr_tail, "stderr-tail-line")
    cleanup(c)
  end)

  test.test("initialize failure response fails safely", function()
    local c, err, partial = client.start(fake_command(), fake_options("initialize_error", {
      initialize_timeout = 3,
      scan = 0.01,
    }))
    test.is_nil(c)
    test.contains(err, "initialize failed")
    test.not_nil(partial)
    test.equal(partial.state, "failed")
    cleanup(partial)
  end)

  test.test("initialize timeout clears pending initialize request", function()
    local c = client.new(nil)
    local callback_error
    c:_set_state("initializing")
    c.requests:register("initialize", function(_result, err_obj)
      callback_error = err_obj
    end, { generation = c.generation })
    test.equal(c:pending_count(), 1)
    local ok, err = c:wait_until_ready(0.02, 0.005)
    test.is_nil(ok)
    test.contains(err, "initialize timeout")
    test.equal(c.state, "failed")
    test.equal(c:pending_count(), 0)
    test.not_nil(callback_error)
    test.contains(callback_error.message, "initialize timeout")
  end)

  test.test("failed client clears pending requests and invokes callbacks with errors", function()
    local c = client.new(nil)
    local callback_error
    c.requests:register("test/pending", function(_result, err_obj)
      callback_error = err_obj
    end)
    test.equal(c:pending_count(), 1)
    c:_fail("boom")
    test.equal(c:pending_count(), 0)
    test.not_nil(callback_error)
    test.equal(callback_error.code, jsonrpc.ERROR_INTERNAL_ERROR)
    test.contains(callback_error.message, "boom")
  end)

  test.test("server crash before initialize transitions to failed and clears pending initialize", function()
    local c, err, partial = client.start(fake_command(), fake_options("crash_before_initialize", {
      initialize_timeout = 2,
      scan = 0.01,
    }))
    test.is_nil(c)
    test.not_nil(partial)
    test.equal(partial.state, "failed")
    test.contains(err, "process exited")
    test.equal(partial:pending_count(), 0)
    cleanup(partial)
  end)

  test.test("stale generation initialize response cannot resurrect stopped client", function()
    local c = test.not_nil(client.start(fake_command(), fake_options("delayed_initialize", {
      wait = false,
      initialize_timeout = 3,
    })))
    test.equal(c.state, "initializing")
    c.generation = c.generation + 1
    c.requests.generation = c.generation
    c:_set_state("shutting_down")

    local ok = pump_until(c, 2, function()
      return c.pending_count and c:pending_count() == 0
    end)
    test.ok(ok)
    test.not_equal(c.state, "ready")
    c:shutdown(0.5, 0.01)
  end)

  test.test("generation check drops stale responses in request bookkeeping", function()
    local c = client.new(nil, { generation = 10 })
    local called = false
    local id = c.requests:register("initialize", function()
      called = true
    end, { generation = 10 })
    c.generation = 11
    local ok, err = c.requests:dispatch_response({
      kind = "response",
      id = id,
      result = {},
    }, c.generation)
    test.equal(ok, false)
    test.contains(err, "stale generation")
    test.not_ok(called)
  end)
end)
