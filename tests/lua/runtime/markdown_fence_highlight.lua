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
    local ready_line
    service:add_listener(listener, function(_, line1, line2, reason)
      if reason == "ready" then ready_line = { line1, line2 } end
    end)
    test.equal(service:get_diagnostics().lines_tokenized, 0)
    local entry, reason = service:line_tokens(node, 2, 100)
    test.is_nil(entry)
    test.equal(reason, "pending")
    test.equal(service:get_diagnostics().lines_tokenized, 0)

    local deadline = system.get_time() + 5
    repeat
      entry = service:peek_line_tokens(node, 2)
      if entry then break end
      coroutine.yield(0)
    until system.get_time() >= deadline
    entry = test.not_nil(entry)
    test.same(ready_line, { 2, 2 })

    local by_text = {}
    for _, token_type, text in tokenizer.each_token(entry.tokens) do
      local value = text:match("^%s*(.-)%s*$")
      if value ~= "" then by_text[value] = token_type end
    end
    test.equal(by_text.const, "keyword")
    test.equal(by_text.value, "symbol")
    test.equal(by_text["="], "operator")
    test.equal(by_text["1"], "number")

    service:remove_listener(listener)
    test.equal(service:get_diagnostics().cached_lines, 0)
    service:close("test")
    markdown_model.close(doc, "test")
  end)
end)
