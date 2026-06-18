local test = require "core.test"
local lsp_json = require "core.lsp.json"
local jsonrpc = require "core.lsp.jsonrpc"

local function feed_all(parser, chunks)
  local out = {}
  for _, chunk in ipairs(chunks) do
    local messages, err = parser:feed(chunk)
    test.not_nil(messages, err)
    for _, message in ipairs(messages) do
      out[#out + 1] = message
    end
  end
  return out
end

test.describe("core.lsp.jsonrpc", function()
  test.test("encodes Content-Length using body byte length", function()
    local message = jsonrpc.notification("$/logTrace", { message = "é" })
    local framed = jsonrpc.encode(message)
    local header, body = framed:match("^(.-)\r\n\r\n(.*)$")
    test.not_nil(header)
    local length = tonumber(header:match("Content%-Length:%s*(%d+)"))
    test.equal(length, #body)
  end)

  test.test("parses partial header and body chunks", function()
    local framed = jsonrpc.encode(jsonrpc.notification("test/notify", lsp_json.array({})))
    local parser = jsonrpc.new_parser()
    local messages = feed_all(parser, {
      framed:sub(1, 5),
      framed:sub(6, 17),
      framed:sub(18, #framed - 2),
      framed:sub(#framed - 1),
    })
    test.equal(#messages, 1)
    test.equal(messages[1].kind, "notification")
    test.equal(messages[1].method, "test/notify")
    test.ok(lsp_json.is_array(messages[1].params))
  end)

  test.test("parses multiple messages from one chunk", function()
    local chunk = jsonrpc.encode(jsonrpc.notification("one"))
      .. jsonrpc.encode(jsonrpc.request("server-id", "two", { value = 1 }))
    local messages = test.not_nil(jsonrpc.new_parser():feed(chunk))
    test.equal(#messages, 2)
    test.equal(messages[1].kind, "notification")
    test.equal(messages[1].method, "one")
    test.equal(messages[2].kind, "request")
    test.equal(messages[2].id, "server-id")
    test.equal(type(messages[2].id), "string")
  end)

  test.test("normalizes null response results", function()
    local messages = test.not_nil(jsonrpc.new_parser():feed(
      jsonrpc.encode(jsonrpc.response(3, lsp_json.null))))
    test.equal(messages[1].kind, "response")
    test.equal(messages[1].id, 3)
    test.ok(lsp_json.is_null(messages[1].result))
  end)

  test.test("rejects malformed headers", function()
    local parser = jsonrpc.new_parser()
    local messages, err = parser:feed("Content-Type: application/vscode-jsonrpc\r\n\r\n{}")
    test.is_nil(messages)
    test.contains(err, "missing Content-Length")
    test.ok(parser:is_failed())
  end)

  test.test("rejects headers and bodies above configured limits", function()
    local parser = jsonrpc.new_parser({ max_header_bytes = 4 })
    local messages, err = parser:feed("Content-Length: 2")
    test.is_nil(messages)
    test.contains(err, "header exceeds")

    parser = jsonrpc.new_parser({ max_body_bytes = 2 })
    messages, err = parser:feed("Content-Length: 3\r\n\r\n{} ")
    test.is_nil(messages)
    test.contains(err, "body exceeds")
  end)

  test.test("rejects malformed JSON bodies", function()
    local parser = jsonrpc.new_parser()
    local messages, err = parser:feed("Content-Length: 1\r\n\r\n{")
    test.is_nil(messages)
    test.contains(err, "invalid JSON body")
  end)

  test.test("dispatches responses by request id", function()
    local tracker = jsonrpc.new_request_tracker()
    local called = false
    local id = tracker:register("workspace/symbol", function(result, err_obj, entry)
      called = true
      test.is_nil(err_obj)
      test.equal(entry.method, "workspace/symbol")
      test.equal(result.value, 42)
    end)
    local ok = test.not_nil(tracker:dispatch_response({
      kind = "response",
      id = id,
      result = { value = 42 },
    }))
    test.equal(ok, true)
    test.ok(called)
    test.equal(tracker:pending_count(), 0)
  end)
end)
