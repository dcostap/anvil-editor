local Doc = require "core.doc"
local test = require "core.test"
local treesitter = require "core.treesitter"
local registry = require "core.treesitter.registry"
local native = require "treesitter"

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function wait_ready(doc, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_doc(doc)
    if doc.treesitter and doc.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function wait_native_poll(state, generation, timeout)
  local deadline = system.get_time() + (timeout or 3)
  local last_status, last_changed, last_stale
  while system.get_time() < deadline do
    last_status, last_changed, last_stale = state:poll(generation)
    if last_changed or last_stale or last_status == "ready" or last_status == "failed" then
      return last_status, last_changed, last_stale
    end
    coroutine.yield(0.01)
  end
  return last_status, last_changed, last_stale
end

local function c_doc(text, filename)
  local doc = Doc()
  set_text(doc, text or "int main(void) { return 0; }")
  doc:set_filename(filename or "example.c", filename or "example.c")
  return doc
end

test.describe("core.treesitter phase 3 document integration", function()
  test.it("registry loads C config", function()
    registry.reload()
    local config = registry.get("example.c", "")
    test.ok(config)
    test.equal(config.id, "c")
    test.equal(config.grammar, "c")
  end)

  test.it("C file/document attaches state", function()
    local doc = c_doc()
    test.ok(doc.treesitter)
    test.equal(doc.treesitter.language_id, "c")
    test.ok(doc.treesitter.native)
    doc:on_close()
  end)

  test.it("unsupported file does not attach", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("notes.txt", "notes.txt")
    test.equal(doc.treesitter, nil)
    doc:on_close()
  end)

  test.it("binary doc disables Tree-sitter", function()
    local doc = Doc()
    set_text(doc, "int main(void) { return 0; }")
    doc.binary = true
    doc.clean_lines = {}
    doc:set_filename("binary.c", "binary.c")
    test.ok(doc.treesitter)
    test.equal(doc.treesitter.status, "disabled")
    test.equal(doc.treesitter.reason, "binary")
    test.equal(doc.treesitter.native, nil)
    doc:on_close()
  end)

  test.it("parse completion reaches ready", function()
    local doc = c_doc("int value(void) { return 42; }")
    test.ok(wait_ready(doc))
    test.equal(doc.treesitter.status, "ready")
    test.equal(doc.treesitter.tree_generation, doc.treesitter.generation)
    doc:on_close()
  end)

  test.it("stale result discarded after generation mismatch", function()
    local state = assert(native.new_document_state("c", { parse_timeout_ms = 5000 }))
    assert(state:schedule_parse({ "int stale(void) { return 1; }\n" }, 1, nil))
    local status, changed, stale = wait_native_poll(state, 2)
    test.equal(stale, true)
    test.equal(changed, false)
    test.ok(status == "queued" or status == "parsing" or status == "idle")
    state:close()
  end)

  test.it("single edit keeps stale/incremental path valid", function()
    local doc = c_doc("int value(void) { return 1; }")
    test.ok(wait_ready(doc))
    local before_generation = doc.treesitter.generation
    doc:apply_edits({
      { line1 = 1, col1 = 26, line2 = 1, col2 = 27, text = "2" },
    }, { type = "replace" })
    test.ok(doc.treesitter.stale_renderable)
    test.equal(doc.treesitter.stale_unrenderable, false)
    test.equal(doc.treesitter.generation, before_generation + 1)
    test.ok(wait_ready(doc))
    test.equal(doc.treesitter.stale_renderable, false)
    test.equal(doc.treesitter.tree_generation, doc.treesitter.generation)
    doc:on_close()
  end)

  test.it("batch edit marks stale-unrenderable/full parse path", function()
    local doc = c_doc("int a(void) { return 1; }\nint b(void) { return 2; }")
    test.ok(wait_ready(doc))
    doc:apply_edits({
      { line1 = 1, col1 = 22, line2 = 1, col2 = 23, text = "3" },
      { line1 = 2, col1 = 22, line2 = 2, col2 = 23, text = "4" },
    }, { type = "batch" })
    test.equal(doc.treesitter.stale_renderable, false)
    test.ok(doc.treesitter.stale_unrenderable)
    test.ok(wait_ready(doc))
    test.equal(doc.treesitter.stale_unrenderable, false)
    doc:on_close()
  end)

  test.it("close cancels and late completions are ignored", function()
    local doc = c_doc("int close_me(void) { return 0; }")
    test.ok(doc.treesitter and doc.treesitter.native)
    doc:on_close()
    test.equal(doc.treesitter, nil)
    treesitter.poll_all()
    test.equal(doc.treesitter, nil)
  end)
end)
