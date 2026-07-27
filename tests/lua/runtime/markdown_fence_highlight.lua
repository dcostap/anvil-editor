local Doc = require "core.doc"
local fence_highlight = require "core.markdown.fence_highlight"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local tokenizer = require "core.tokenizer"
local worker_pool = require "core.worker_pool"

local function wait_status(instance, wanted, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == wanted then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == wanted
end

local function make_doc(text)
  local doc = Doc("fence-service.md", "fence-service.md", true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  return doc
end

local function wait_entry(service, node, line, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local entry = service:peek_line_tokens(node, line)
    if entry then return entry end
    coroutine.yield(0)
  until system.get_time() >= deadline
end

local function types_by_text(entry)
  local by_text = {}
  for _, token_type, text in tokenizer.each_token(entry.tokens) do
    local value = text:match("^%s*(.-)%s*$")
    if value ~= "" then by_text[value] = token_type end
  end
  return by_text
end

test.describe("Markdown fenced-code highlighting", function()
  test.it("shares lazy Document-scoped token work", function()
    local doc = make_doc("```js\nconst value = 1\n```\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(2))
    local service = fence_highlight.get(doc)
    test.equal(fence_highlight.get(doc), service)
    service:reconcile(model)

    local listener = {}
    local second_listener = {}
    local ready_line
    service:add_listener(listener, function(_, line1, line2, reason)
      if reason == "ready" then ready_line = { line1, line2 } end
    end)
    service:add_listener(second_listener, function() end)
    test.equal(service:get_diagnostics().lines_tokenized, 0)
    local entry, reason = service:line_tokens(node, 2, 100)
    test.is_nil(entry)
    test.equal(reason, "pending")
    test.equal(service:get_diagnostics().lines_tokenized, 0)

    entry = test.not_nil(wait_entry(service, node, 2))
    test.same(ready_line, { 2, 2 })

    local by_text = types_by_text(entry)
    test.equal(by_text.const, "keyword")
    test.equal(by_text.value, "symbol")
    test.equal(by_text["="], "operator")
    test.equal(by_text["1"], "number")

    service:remove_listener(listener)
    test.ok(service:get_diagnostics().cached_lines > 0)
    service:remove_listener(second_listener)
    test.equal(service:get_diagnostics().cached_lines, 0)
    service:close("test")
    markdown_model.close(doc, "test")
  end)

  test.it("immediately hides a stale multiline suffix after a body edit", function()
    local doc = make_doc("```lua\n--[[\ninside\n]]\n```\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(3))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)

    test.is_nil(service:line_tokens(node, 3, 100))
    local before = test.not_nil(wait_entry(service, node, 3))
    test.equal(types_by_text(before).inside, "comment")

    doc:remove(2, 1, 2, 5)
    test.is_nil(service:peek_line_tokens(node, 3))
    test.is_nil(service:line_tokens(node, 3, 100))
    local after = test.not_nil(wait_entry(service, node, 3))
    test.not_equal(types_by_text(after).inside, "comment")

    service:remove_listener(listener)
    service:close("test")
    markdown_model.close(doc, "test")
  end)

  test.it("invalidates warm tokens when the tokenizer backend changes", function()
    local doc = make_doc("```js\nconst value = 1\n```\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(2))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)
    test.is_nil(service:line_tokens(node, 2, 100))
    test.not_nil(wait_entry(service, node, 2))

    local original = tokenizer.is_using_native()
    local ok, err = pcall(function()
      tokenizer.set_use_native(not original)
      test.is_nil(service:peek_line_tokens(node, 2))
      test.is_nil(service:line_tokens(node, 2, 100))
      test.not_nil(wait_entry(service, node, 2))
    end)
    tokenizer.set_use_native(original)
    if not ok then error(err, 0) end

    service:remove_listener(listener)
    service:close("test")
    markdown_model.close(doc, "test")
  end)

  test.it("retains shifted blocks and reuses a converged suffix", function()
    local doc = make_doc(
      "intro\n```lua\nlocal a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 4\n```\n"
    )
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(6))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)
    test.is_nil(service:line_tokens(node, 6, 100))
    test.not_nil(wait_entry(service, node, 6))
    local tokenized = service:get_diagnostics().lines_tokenized

    doc:insert(1, 1, "# heading\n")
    test.not_nil(service:peek_line_tokens(node, 7))
    test.equal(service:get_diagnostics().lines_tokenized, tokenized)
    test.ok(wait_status(model, "ready"), model.reason)
    service:reconcile(model)
    node = test.not_nil(model:fenced_node_for_line(7))
    test.not_nil(service:line_tokens(node, 7, 100))

    doc:remove(5, 7, 5, 8)
    doc:insert(5, 7, "renamed")
    test.is_nil(service:peek_line_tokens(node, 7))
    test.is_nil(service:line_tokens(node, 7, 100))
    test.not_nil(wait_entry(service, node, 7))
    test.ok(service:get_diagnostics().lines_reused >= 1)
    test.ok(service:get_diagnostics().convergence_stops >= 1)

    service:remove_listener(listener)
    service:close("test")
    markdown_model.close(doc, "test")
  end)

  test.it("keeps warm body tokens when only trailing info metadata changes", function()
    local doc = make_doc("```lua title=before\nlocal value = 1\n```\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(2))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)
    test.is_nil(service:line_tokens(node, 2, 100))
    test.not_nil(wait_entry(service, node, 2))
    local tokenized = service:get_diagnostics().lines_tokenized

    doc:remove(1, 14, 1, 20)
    doc:insert(1, 14, "after")
    test.is_nil(service:peek_line_tokens(node, 2))
    test.ok(wait_status(model, "ready"), model.reason)
    service:reconcile(model)
    node = test.not_nil(model:fenced_node_for_line(2))
    test.not_nil(service:line_tokens(node, 2, 100))
    test.equal(service:get_diagnostics().lines_tokenized, tokenized)

    service:remove_listener(listener)
    service:close("test")
    markdown_model.close(doc, "test")
  end)

  test.it("cancels queued work when the Document closes", function()
    local lines = { "```lua" }
    for index = 1, 1000 do lines[#lines + 1] = "local value" .. index .. " = " .. index end
    lines[#lines + 1] = "```"
    local doc = make_doc(table.concat(lines, "\n") .. "\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(1001))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)
    test.is_nil(service:line_tokens(node, 1001, 100))

    doc:on_close()
    test.equal(service:get_diagnostics().closed, true)
    for _ = 1, 3 do coroutine.yield(0) end
    test.equal(service:get_diagnostics().cached_lines, 0)
  end)

  test.it("maps structural unsafe bounds to shifted suffix lines", function()
    local doc = make_doc("```lua\n--[[\ninside\n]]\n```\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(3))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)
    test.is_nil(service:line_tokens(node, 3, 100))
    test.not_nil(wait_entry(service, node, 3))

    doc:insert(2, 1, "one\ntwo\nthree\nfour\nfive\nsix\n")
    test.equal(service:is_line_unsafe(9), true)
    test.is_nil(service:peek_line_tokens(node, 9))

    service:remove_listener(listener)
    service:close("test")
    markdown_model.close(doc, "test")
  end)

  test.it("drops all states for a changed same-line-count snapshot", function()
    local doc = make_doc("```lua\nlocal start = 1\ninside\n]]\n```\n")
    local model = markdown_model.get(doc)
    test.ok(wait_status(model, "ready"), model.reason)
    local node = test.not_nil(model:fenced_node_for_line(3))
    local service = fence_highlight.get(doc)
    service:reconcile(model)
    local listener = {}
    service:add_listener(listener, function() end)
    test.is_nil(service:line_tokens(node, 3, 100))
    local before = test.not_nil(wait_entry(service, node, 3))
    test.not_equal(types_by_text(before).inside, "comment")

    local path = USERDIR .. PATHSEP .. "fence-reload-" .. system.get_process_id() .. ".md"
    local file = test.not_nil(io.open(path, "wb"))
    file:write("```lua\n--[[\ninside\n]]\n```\n")
    file:close()
    doc:load(path)
    test.is_nil(service:peek_line_tokens(node, 3))
    test.equal(service:is_line_unsafe(3), true)

    test.ok(wait_status(model, "ready"), model.reason)
    service:reconcile(model)
    node = test.not_nil(model:fenced_node_for_line(3))
    test.is_nil(service:line_tokens(node, 3, 100))
    local after = test.not_nil(wait_entry(service, node, 3))
    test.equal(types_by_text(after).inside, "comment")

    os.remove(path)
    service:remove_listener(listener)
    service:close("test")
    markdown_model.close(doc, "test")
  end)
end)
