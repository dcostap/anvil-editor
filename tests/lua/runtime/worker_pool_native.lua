local test = require "core.test"
local native_pool = require "worker_pool_native"

local function drain_until(pool, predicate, limit)
  limit = limit or 1000
  for _ = 1, limit do
    for _, message in ipairs(pool:drain({ max_messages = 64 })) do
      if predicate(message) then return true end
    end
    coroutine.yield(0.001)
  end
  for _, message in ipairs(pool:drain({ max_messages = 64 })) do
    if predicate(message) then return true end
  end
  return false
end

test.describe("worker_pool_native", function()
  local pools = {}

  local function new_pool(name, workers)
    local pool = native_pool.new({ name = name, worker_count = workers or 1 })
    pools[#pools + 1] = pool
    return pool
  end

  test.after_each(function()
    for i = #pools, 1, -1 do
      pools[i]:shutdown({ cancel_running = true })
      pools[i] = nil
    end
  end)

  test.test("delivers results and terminal status", function()
    local pool = new_pool("lua-native-submit", 1)
    local handle = pool:submit({ kind = "test_echo", value = "hello" })
    test.not_nil(handle)
    local value
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then value = message.value end
      return message.type == "final"
    end))
    test.equal(value, "hello")
    test.equal(pool:status(handle).status, "complete")
  end)

  test.test("running cancellation reaches native job", function()
    local pool = new_pool("lua-native-cancel", 1)
    local handle = pool:submit({ kind = "test_count", count = 1000, sleep_ms = 1 })
    test.ok(drain_until(pool, function(message) return message.type == "progress" and message.index >= 2 end))
    test.ok(pool:cancel(handle))
    test.ok(drain_until(pool, function(message) return message.type == "cancelled" end))
    test.equal(pool:status(handle).status, "cancelled")
  end)

  test.test("Markdown jobs honor shared cancel tokens without semantic queries", function()
    local pool = new_pool("lua-native-markdown-cancel", 1)
    local token = native_pool.new_cancel_token()
    local handle = pool:submit({
      kind = "markdown_parse",
      text = string.rep("# Heading with **bold** text\n", 30000),
      cancel_token = token:name(),
      parse_timeout_ms = 5000,
    })
    test.not_nil(handle)
    token:cancel()
    test.ok(drain_until(pool, function(message) return message.type == "cancelled" end, 5000))
    test.equal(pool:status(handle).status, "cancelled")
  end)

  test.test("cancel tokens can be opened by name across Lua states", function()
    local token = native_pool.new_cancel_token()
    local name = token:name()
    test.ok(name ~= "")
    local opened = native_pool.open_cancel_token(name)
    test.equal(opened:cancelled(), false)
    token:cancel()
    test.equal(opened:cancelled(), true)
  end)

  test.test("drain respects message count budget", function()
    local pool = new_pool("lua-native-drain-budget", 1)
    pool:submit({ kind = "test_count", count = 10, sleep_ms = 0 })
    test.ok(drain_until(pool, function(message) return message.type == "progress" end))
    local messages = pool:drain({ max_messages = 2 })
    test.ok(#messages <= 2)
  end)

  test.test("Tree-sitter index job returns bounded result handle", function()
    local pool = new_pool("lua-native-treesitter-index", 1)
    local handle = pool:submit({
      kind = "treesitter_index_text",
      language = "c",
      text = "int add(int a, int b) { return a + b; }\n",
      outline_query = "(function_definition) @definition.function",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    })
    test.not_nil(handle)
    local result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then result = message.result end
      return message.type == "final"
    end))
    test.not_nil(result)
    local summary = result:summary()
    test.equal(summary.language, "c")
    test.equal(summary.outline.status, "ready")
    test.ok(summary.outline.capture_count >= 1)
    local captures = result:captures("outline", { offset = 1, limit = 1 })
    test.equal(#captures, 1)
    test.equal(captures[1].capture, "definition.function")
    test.equal(captures.total, summary.outline.capture_count)
    test.ok(captures.next_offset >= 2)
  end)

  test.test("Markdown job publishes block and inline captures from one composite parse", function()
    local pool = new_pool("lua-native-markdown-parse", 1)
    local handle = pool:submit({
      kind = "markdown_parse",
      text = "# Heading\n\nFirst *span*.\nSecond **span**.\n",
      outline_query = "(atx_heading) @heading",
      usage_query = "[(emphasis) (strong_emphasis)] @span",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      usage_query_timeout_ms = 100,
      max_captures = 100,
      usage_max_captures = 100,
    })
    test.not_nil(handle)
    local result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then result = message.result end
      return message.type == "final"
    end))
    test.not_nil(result)
    local summary = result:summary()
    test.equal(summary.language, "markdown")
    test.equal(summary.outline.status, "ready")
    test.equal(summary.usage.status, "ready")
    test.equal(summary.outline.capture_count, 1)
    test.equal(summary.usage.capture_count, 2)
    local following_line = result:captures_for_lines("outline", 2, 2)
    test.equal(#following_line, 0)
    local first_line = result:captures_for_lines("usage", 3, 3)
    test.equal(#first_line, 1)
    test.equal(first_line[1].capture, "span")
    test.equal(first_line.truncated, false)
  end)
end)
