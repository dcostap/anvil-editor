local Buffer = require "core.buffer"
local model = require "core.markdown.model"
local native_pool = require "worker_pool_native"
local queries = require "core.markdown.queries"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function buffer_with(text)
  local buffer = Buffer("incremental.md", "incremental.md", true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  return buffer
end

local function ready(instance)
  local deadline = system.get_time() + 30
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function identified_nodes(instance, count)
  local result, reason = instance:nodes_for_lines(1, count)
  test.not_nil(result, reason)
  test.ok(not result.truncated)
  local seen = {}
  for _, node in ipairs(result) do
    test.not_nil(node.id)
    test.ok(not seen[node.id], "duplicate semantic identity: " .. tostring(node.id))
    seen[node.id] = true
  end
  return result
end

local function nodes(instance, count)
  local result = identified_nodes(instance, count)
  -- Identities belong to one model. Source ranges and semantic content must agree.
  for _, node in ipairs(result) do node.id = nil end
  return result
end

local function compare(buffer, instance, label)
  ready(instance)
  test.equal(instance.published_revision, buffer.text_revision, label)
  local text = buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
  local fresh_buffer = buffer_with(text)
  local fresh = model.get(fresh_buffer)
  ready(fresh)
  local actual, expected = nodes(instance, #buffer.lines), nodes(fresh, #fresh_buffer.lines)
  test.equal(#actual, #expected, label)
  for index = 1, #actual do test.same(actual[index], expected[index], label .. " node " .. index) end
  test.same(instance:footnote_definitions(), fresh:footnote_definitions(), label)
  test.same(instance:footnote_lines(), fresh:footnote_lines(), label)
  test.same(instance:headings(), fresh:headings(), label .. " headings")
  model.close(fresh_buffer, "test")
end

local function replace(buffer, old, new)
  local text = table.concat(buffer.lines)
  local first = test.not_nil(text:find(old, 1, true), old)
  local line1, col1 = buffer:position_offset(1, 1, first - 1)
  local line2, col2 = buffer:position_offset(line1, col1, #old)
  buffer:clear_undo_redo()
  buffer:apply_edits({ { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = new } })
end

local function sequence(label, text, edits)
  test.it(label, function()
    local buffer = buffer_with(text)
    local instance = model.get(buffer)
    compare(buffer, instance, label .. " initial")
    for index, edit in ipairs(edits) do
      replace(buffer, edit[1], edit[2])
      compare(buffer, instance, label .. " step " .. index)
    end
    model.close(buffer, "test")
  end)
end

local function raw_sequence(label, texts)
  test.it(label, function()
    local previous
    for index, text in ipairs(texts) do
      -- Buffer keeps a final newline. Use raw worker input to test actual EOF bytes.
      local spec = { text = text, outline_query = queries.block, usage_query = queries.inline }
      local fresh = test.not_nil(native_pool.markdown_parse_now(spec, 5000))
      spec.previous_result = previous
      local current = test.not_nil(native_pool.markdown_parse_now(spec, 5000))
      local function semantic(result)
        local list = result:semantic_nodes_for_lines("both", 1, 100)
        test.ok(not list.truncated)
        local seen = {}
        for _, node in ipairs(list) do
          test.ok(not seen[node.id], "duplicate raw identity")
          seen[node.id] = true
          node.id = nil
        end
        return list
      end
      test.same(semantic(current), semantic(fresh), label .. " step " .. index)
      test.same(current:markdown_headings(), fresh:markdown_headings(), label .. " headings " .. index)
      fresh:close()
      if previous then previous:close() end
      previous = current
    end
    previous:close()
  end)
end

test.describe("Markdown incremental semantic publication", function()
  sequence("matches Setext conversions in both directions", "Title\n\nBody\n", {
    { "Title\n\n", "Title\n---\n" }, { "Title\n---\n", "Title\n\n" },
    { "Title\n\n", "Title\n===\n" }, { "Title\n===\n", "Title\n\n" },
  })
  for _, above in ipairs({ true, false }) do
    local reference = "[label][ref]\n"
    local definition = "[ref]: target\n\n"
    local text = above and ("\n" .. reference) or (reference .. "\n")
    local defined = above and (definition .. reference) or (reference .. "\n" .. definition)
    sequence("matches reference definitions " .. (above and "above" or "below") .. " unchanged labels", text, {
      { text, defined }, { defined, text }, { text, defined }, { defined, text },
    })
  end
  sequence("matches headings through renames, inserts, Setext conversions, and deletes",
    "# One\n\nBody *text*.\n\n## Two ##\n\nTail.\n", {
      { "# One", "# One renamed" }, { "Body", "### Added\n\nBody" },
      { "## Two ##\n", "Two\n---\n" }, { "Two\n---\n", "Two\n\n" },
      { "### Added\n\n", "" }, { "# One renamed\n\n", "" },
    })
  sequence("matches paragraph merges and splits", "First *one*.\n\nSecond **two**.\n", {
    { "\n\n", "\n" }, { "\nSecond", "\n\nSecond" },
  })
  for _, prefix in ipairs({ "- item\n", "> quote\n", "```lua\n" }) do
    local text = "Unchanged *text* and [link](target).\n\nTail `code`.\n"
    local opened = prefix .. text
    local closed = prefix .. (prefix == "```lua\n" and "```\n\n" or "\n") .. text
    sequence("matches container boundaries for " .. prefix:match("[^\n]+"), text, {
      { text, opened }, { opened, closed }, { closed, text },
    })
  end
  for _, span in ipairs({ "*word*", "[label](target)", "`code`" }) do
    -- Each paragraph is one inline region. Edit both exact byte boundaries.
    sequence("matches inline region edges for " .. span, span .. "\n\nTail **stable**.\n", {
      { span, "x" .. span }, { "x" .. span, span },
      { span, span .. "x" }, { span .. "x", span },
      { span, span:sub(2) }, { span:sub(2), span },
      { span, span:sub(1, -2) }, { span:sub(1, -2), span },
    })
  end
  sequence("matches raw CRLF edits", "First *one*.\r\n\r\nTail **two**.\r\n", {
    { "First", "First longer" }, { "\r\n\r\n", "\r\n" },
    { "\r\nTail", "\r\n\r\nTail" }, { "two", "three" },
  })
  sequence("matches EOF deletion and typing into an empty buffer", "*First*\n\nTail `code`", {
    { "Tail `code`", "Tail `code`\n" }, { "Tail `code`\n", "Tail `code`" },
    { "*First*\n\nTail `code`", "" }, { "", "Typed **text**" },
    { "Typed **text**", "" }, { "", "[link](target)\n" },
  })
  raw_sequence("matches raw CRLF and EOF bytes", {
    "*First*\r\n\r\nTail `code`\r\n", "Long *First*\r\n\r\nTail `code`\r\n",
    "Long *First*\r\n\r\nTail `code`", "Long *First*\r\n\r\nTail `code`\r\n",
    "", "*Typed*", "*Typed*\n", "*Typed*", "", "[link](target)",
  })
  sequence("matches UTF-8 byte width changes beside unchanged regions", "a\n\nStable *word*.\n", {
    { "a\n", "é\n" }, { "é\n", "€\n" }, { "€\n", "😀\n" },
    { "😀\n", "a\n" },
  })

  test.it("submits a parse of a long note without a Lua copy of its text", function()
    local paragraphs = {}
    for index = 1, 4000 do paragraphs[index] = "## Part " .. index .. "\n\nSome *body* text for part " .. index .. ".\n" end
    local buffer = buffer_with(table.concat(paragraphs, "\n"))
    local instance = model.get(buffer)
    ready(instance)
    local bytes = 0
    for _, line in ipairs(buffer.lines) do bytes = bytes + #line end
    buffer:insert(2, 1, "New line.\n")
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    test.ok(instance:submit("test"))
    local allocated = (collectgarbage("count") - before) * 1024
    collectgarbage("restart")
    test.ok(allocated < bytes / 8,
      string.format("submitting allocated %d bytes for a note of %d bytes", allocated, bytes))
    ready(instance)
    local fresh_buffer = buffer_with(table.concat(buffer.lines))
    local fresh = model.get(fresh_buffer)
    ready(fresh)
    test.equal(#instance:headings(), 4000 * 7)
    test.same(instance:headings(), fresh:headings())
    model.close(fresh_buffer, "test")
    model.close(buffer, "test")
  end)

  test.it("reuses unchanged block captures with the Markdown block query", function()
    local spec = { text = "# One\n\nBody *text*.\n\n## Two\n\nTail.\n",
      outline_query = queries.block, usage_query = queries.inline }
    local first = test.not_nil(native_pool.markdown_parse_now(spec, 5000))
    spec.text, spec.previous_result = spec.text .. "\nMore.\n", first
    local second = test.not_nil(native_pool.markdown_parse_now(spec, 5000))
    test.ok(second:summary().metrics.reused_block_captures > 0)
    first:close()
    second:close()
  end)

  test.it("keeps identities with their nodes across edits and shifts", function()
    local buffer = buffer_with("**one**\n\n**two**\n\n**end**\n")
    local instance = model.get(buffer)
    ready(instance)
    local before = identified_nodes(instance, #buffer.lines)
    local function with_text(list, text)
      for _, node in ipairs(list) do
        local source = node.source
        if buffer:get_text(source.line1, source.col1, source.line2, source.col2) == text then return node end
      end
      test.ok(false, "missing node: " .. text)
    end
    -- Native reconciliation matches capture kind and mapped source range, not text.
    -- A source edit can keep its own identity. It must not take another node's identity.
    -- Source positions alone do not identify nodes across model publications.
    local stable = with_text(before, "**two**")
    local tail = with_text(before, "**end**")
    for _, edit in ipairs({
      { "**one**", "**add**\n\n**one**" },
      { "one", "changed longer" }, { "**changed longer**", "**new**\n\n**one**" },
    }) do
      replace(buffer, edit[1], edit[2])
      ready(instance)
      local after = identified_nodes(instance, #buffer.lines)
      local current_text = edit[2]:find("add", 1, true) and "**add**"
        or edit[2]:find("new", 1, true) and "**new**" or "**changed longer**"
      local current = with_text(after, current_text)
      test.ok(current.id ~= stable.id and current.id ~= tail.id, "changed node took an unrelated identity")
      test.equal(with_text(after, "**two**").id, stable.id, "unchanged strong identity")
      test.equal(with_text(after, "**end**").id, tail.id, "unchanged tail identity")
      compare(buffer, instance, "identity edit")
    end
    model.close(buffer, "test")
  end)

  test.it("matches a full parse through text edits, block changes, deletes, and undo", function()
    local buffer = buffer_with(table.concat({
      "---", "title: Note", "---", "", "# Heading", "",
      "First **bold** and *word* with [[Note]] and ==light==.", "",
      "- one", "- two", "", "> quote", "> tail", "",
      "| A | B |", "| - | - |", "| a | b |", "",
      "```lua", "local x = 1", "```", "",
      "Footnote[^a] and #tag.", "", "[^a]: Definition", "",
      "Last **span**.",
    }, "\n"))
    local instance = model.get(buffer)
    compare(buffer, instance, "initial")
    local edits = {
      { "*word*", "*words*" },
      { "First **bold**", "First\n**bold**" },
      { "- one\n- two", "- one\n\n- two" },
      { "> quote\n> tail", "> quote\ntail" },
      { "| - | - |", "| -- | -- |" },
      { "| a | b |", "| α longer | b |" },
      { "| α longer | b |", "| α longer | **b** |" },
      { "```lua", "``lua" },
      { "``lua", "```lua" },
      { "title: Note\n---", "title: Note\n--" },
      { "title: Note\n--", "title: Note\n---" },
      { "[^a]: Definition", "[^a]: Changed **definition**" },
      { "- two\n\n> quote\ntail\n\n| A | B |", "Joined" },
    }
    for index, edit in ipairs(edits) do
      replace(buffer, edit[1], edit[2])
      compare(buffer, instance, "edit " .. index)
    end
    buffer:undo()
    compare(buffer, instance, "undo across blocks")
    model.close(buffer, "test")
  end)
end)
