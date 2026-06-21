local test = require "core.test"
local lsp_json = require "core.lsp.json"
local jsonrpc = require "core.lsp.jsonrpc"
local client = require "core.lsp.client"
local fake_transport = dofile("tests/fixtures/lsp/fake_transport.lua")

test.describe("core.lsp.client Phase 8.1 dispatch", function()
  test.test("advertises work-done progress support", function()
    local fake = fake_transport.new()
    local c = client.new(fake)
    local params = c:initialize_params({})
    test.equal(params.capabilities.window.workDoneProgress, true)
  end)

  test.test("sends outbound requests with monotonic numeric ids", function()
    local fake = fake_transport.new()
    local c = client.new(fake)
    local id = test.not_nil(c:send_request("test/request", { value = true }))
    test.equal(id, 1)
    local messages = test.not_nil(fake:written_messages())
    test.equal(#messages, 1)
    test.equal(messages[1].kind, "request")
    test.equal(messages[1].id, 1)
    test.equal(type(messages[1].id), "number")
    test.equal(messages[1].method, "test/request")
  end)

  test.test("dispatches responses to pending request callbacks", function()
    local fake = fake_transport.new()
    local c = client.new(fake)
    local callback_result
    local id = c:send_request("test/request", nil, function(result, err_obj)
      test.is_nil(err_obj)
      callback_result = result.answer
    end)
    fake:push_message(jsonrpc.response(id, { answer = 42 }))
    test.equal(c:read_once(), 1)
    test.equal(c:process_all(), 1)
    test.equal(callback_result, 42)
    test.equal(c:pending_count(), 0)
  end)

  test.test("responds to server requests preserving string id type", function()
    local fake = fake_transport.new()
    local c = client.new(fake)
    c:on_request("workspace/configuration", function(params, message)
      test.equal(message.id, "server-request-1")
      test.equal(type(message.id), "string")
      test.ok(lsp_json.is_array(params.items))
      return lsp_json.array({})
    end)

    fake:push_message(jsonrpc.request("server-request-1", "workspace/configuration", {
      items = lsp_json.array({}),
    }))
    test.equal(c:read_once(), 1)
    test.equal(c:process_all(), 1)

    local responses = test.not_nil(fake:written_messages())
    test.equal(#responses, 1)
    test.equal(responses[1].kind, "response")
    test.equal(responses[1].id, "server-request-1")
    test.equal(type(responses[1].id), "string")
    test.ok(lsp_json.is_array(responses[1].result))
  end)

  test.test("unknown server requests receive MethodNotFound", function()
    local fake = fake_transport.new()
    local c = client.new(fake)
    fake:push_message(jsonrpc.request(9, "unknown/request"))
    test.equal(c:read_once(), 1)
    test.equal(c:process_all(), 1)
    local responses = test.not_nil(fake:written_messages())
    test.equal(responses[1].kind, "response")
    test.equal(responses[1].id, 9)
    test.equal(responses[1].error.code, jsonrpc.ERROR_METHOD_NOT_FOUND)
  end)

  test.test("write failures mark the client failed", function()
    local fake = fake_transport.new({ write_error = "pipe error" })
    local c = client.new(fake)
    local ok, err = c:send_notification("initialized", {})
    test.is_nil(ok)
    test.contains(err, "pipe error")
    test.ok(c.failed)
  end)

  test.test("tracks server work-done progress notifications", function()
    local fake = fake_transport.new()
    local c = client.new(fake)
    fake:push_message(jsonrpc.notification("$/progress", {
      token = "index",
      value = { kind = "begin", title = "Indexing", message = "project", percentage = 25 },
    }))
    test.equal(c:read_once(), 1)
    test.equal(c:process_all(), 1)
    local label = test.not_nil(c:active_progress_label())
    test.contains(label, "Indexing")
    test.contains(label, "25%")

    fake:push_message(jsonrpc.notification("$/progress", {
      token = "index",
      value = { kind = "end" },
    }))
    test.equal(c:read_once(), 1)
    test.equal(c:process_all(), 1)
    test.is_nil(c:active_progress_label())
  end)

  test.test("fails safely when incoming queue limit is exceeded", function()
    local fake = fake_transport.new()
    fake:push_chunk(jsonrpc.encode(jsonrpc.notification("one"))
      .. jsonrpc.encode(jsonrpc.notification("two")))
    local c = client.new(fake, { incoming_queue = { max_messages = 1 } })
    local ok, err = c:read_once()
    test.is_nil(ok)
    test.contains(err, "incoming queue full")
    test.ok(c.failed)
  end)
end)
