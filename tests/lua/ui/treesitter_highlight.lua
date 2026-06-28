local core = require "core"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local tokenizer = require "core.tokenizer"
local treesitter = require "core.treesitter"
local intelligence = require "core.language_intelligence"

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

local function c_doc(text)
  local doc = Doc()
  set_text(doc, text or "int main(void) { return 0; }")
  doc:set_filename("ui_tree_sitter.c", "ui_tree_sitter.c")
  return doc
end

local function cpp_doc(text)
  local doc = Doc()
  set_text(doc, text or "namespace demo { class Box {}; } int main() { auto value = demo::Box{}; return 0; }")
  doc:set_filename("ui_tree_sitter.cpp", "ui_tree_sitter.cpp")
  return doc
end

local function odin_doc(text)
  local doc = Doc()
  set_text(doc, text or "package demo\n\nmain :: proc() {\n  value := 42\n}\n")
  doc:set_filename("ui_tree_sitter.odin", "ui_tree_sitter.odin")
  return doc
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

local function with_fake_draw_text(fn)
  local old_draw_text = renderer.draw_text
  local calls = {}
  renderer.draw_text = function(font, text, x, y, color, opts)
    calls[#calls + 1] = { text = text, x = x, y = y, color = color, opts = opts }
    return x + #tostring(text)
  end
  local ok, err = pcall(fn, calls)
  renderer.draw_text = old_draw_text
  if not ok then error(err) end
  return calls
end

local function capture_status_messages(fn)
  local old_show_message = core.status_bar.show_message
  local messages = {}
  core.status_bar.show_message = function(_, icon, color, text)
    messages[#messages + 1] = { icon = icon, color = color, text = text }
  end
  local ok, err = pcall(fn, messages)
  core.status_bar.show_message = old_show_message
  if not ok then error(err) end
  return messages
end

test.describe("Tree-sitter DocView highlighting", function()
  test.it("DocView draw uses Tree-sitter C render tokens when ready", function()
    local doc = c_doc("int main(void) { return VALUE; }")
    test.ok(wait_ready(doc))
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = doc.highlighter:get_render_line(1)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), doc.lines[1]:sub(1, -2))
    doc:on_close()
  end)

  test.it("DocView draw uses Tree-sitter C++ render tokens when ready", function()
    local doc = cpp_doc("namespace demo { class Box {}; }\nint main() { auto value = demo::Box{}; return 0; }")
    test.ok(wait_ready(doc))
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = doc.highlighter:get_render_line(1)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), doc.lines[1]:sub(1, -2))
    doc:on_close()
  end)

  test.it("DocView draw uses Tree-sitter Odin render tokens when ready", function()
    local doc = odin_doc("package demo\n\nmain :: proc() {\n  value := 42\n}")
    test.ok(wait_ready(doc))
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = doc.highlighter:get_render_line(3)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(3, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), doc.lines[3]:sub(1, -2))
    doc:on_close()
  end)

  test.it("DocView draw falls back before Tree-sitter is ready", function()
    local doc = c_doc("int main(void) { return VALUE; }")
    local render_line = doc.highlighter:get_render_line(1)
    test.equal(render_line.source, "tokenizer")
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    doc:on_close()
  end)

  test.it("current document outline reads the active DocView document", function()
    local doc = cpp_doc([[namespace demo {
class MenuGui {
public:
  void draw_settings() { }
};
}]])
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    local symbols = treesitter.get_current_document_outline()
    local names = {}
    for _, symbol in ipairs(symbols) do names[#names + 1] = symbol.name .. ":" .. symbol.kind end
    test.ok(table.concat(names, "|"):find("demo:namespace", 1, true))
    test.ok(table.concat(names, "|"):find("MenuGui:class", 1, true))
    test.ok(table.concat(names, "|"):find("draw_settings:method", 1, true))
    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("local Tree-sitter fallback commands select definitions and references", function()
    local doc = c_doc([[int first(void) {
  int value = 1;
  return value;
}
int second(void) {
  int value = 2;
  return value;
}]])
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    local ref_col = assert(doc.lines[7]:find("value", 1, true))
    view:set_selection_state({ selections = { 7, ref_col, 7, ref_col }, last_selection = 1 })

    test.ok(command.perform("tree-sitter:go-to-local-definition"))
    local state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "value")
    local line1 = select(1, doc:get_selection(true))
    test.equal(line1, 6)

    view:set_selection_state({ selections = { 7, ref_col, 7, ref_col }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:select-local-references"))
    state = view:get_selection_state()
    test.equal(#state.selections / 4, 2)
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "value\nvalue")

    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("Tree-sitter commands no-op cleanly when language intelligence provider is unavailable", function()
    local doc = cpp_doc("int helper() { return 1; }\nint main() { return helper(); }")
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 2, 5, 2, 5 }, last_selection = 1 })
    intelligence.without_provider("treesitter", function()
      test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    end)
    local state = view:get_selection_state()
    test.same(state.selections, { 2, 5, 2, 5 })
    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("local Tree-sitter fallback command gracefully no-ops without ready locals", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("plain.txt", "plain.txt")
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 1, 2, 1, 2 }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:go-to-local-definition"))
    local state = view:get_selection_state()
    test.same(state.selections, { 1, 2, 1, 2 })
    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("symbol navigation commands select stable symbol name ranges", function()
    local doc = cpp_doc([[namespace demo {
class MenuGui {
public:
  void draw_settings() { int local = 1; }
};
}
int helper() { return 1; }
int main() { return helper(); }]])
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 4, 35, 4, 35 }, last_selection = 1 })

    test.ok(command.perform("tree-sitter:go-to-enclosing-symbol"))
    local state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "draw_settings")

    test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "helper")

    test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "main")

    test.ok(command.perform("tree-sitter:go-to-previous-symbol"))
    state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "helper")

    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("symbol navigation shows Status Bar feedback at directional boundaries", function()
    local doc = cpp_doc([[int first() { return 1; }
int second() { return 2; }]])
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)

    local first_col = assert(doc.lines[1]:find("first", 1, true))
    view:set_selection_state({ selections = { 1, first_col, 1, first_col }, last_selection = 1 })
    local messages = capture_status_messages(function()
      test.ok(command.perform("tree-sitter:go-to-previous-symbol"))
    end)
    test.equal(messages[#messages].text, "No previous symbol")
    local state = view:get_selection_state()
    test.same(state.selections, { 1, first_col, 1, first_col })

    local second_col = assert(doc.lines[2]:find("second", 1, true))
    view:set_selection_state({ selections = { 2, second_col, 2, second_col }, last_selection = 1 })
    messages = capture_status_messages(function()
      test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    end)
    test.equal(messages[#messages].text, "No next symbol")
    state = view:get_selection_state()
    test.same(state.selections, { 2, second_col, 2, second_col })

    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("symbol navigation command gracefully no-ops without ready Tree-sitter", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("plain.txt", "plain.txt")
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 1, 2, 1, 2 }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    local state = view:get_selection_state()
    test.same(state.selections, { 1, 2, 1, 2 })
    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("commands expand and shrink selection by Tree-sitter node", function()
    local doc = cpp_doc("int main() { return 0; }")
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    local col = assert(doc.lines[1]:find("main", 1, true))
    view:set_selection_state({ selections = { 1, col, 1, col }, last_selection = 1 })

    test.ok(command.perform("tree-sitter:expand-selection"))
    local state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "main")

    test.ok(command.perform("tree-sitter:expand-selection"))
    state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.ok(#doc:get_selection_text() > #"main")
    test.ok(doc:get_selection_text():find("main", 1, true))

    test.ok(command.perform("tree-sitter:shrink-selection"))
    state = view:get_selection_state()
    doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(doc:get_selection_text(), "main")

    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("expand selection selects block contents before block delimiters", function()
    local source = table.concat({
      "int main() {",
      "  int x = 1;",
      "  return x;",
      "}",
    }, "\n")
    local doc = cpp_doc(source)
    test.ok(wait_ready(doc))
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    local line = 3
    local col = assert(doc.lines[line]:find("x", 1, true))
    view:set_selection_state({ selections = { line, col, line, col }, last_selection = 1 })

    local seen_content_at, seen_full_at
    for i = 1, 12 do
      test.ok(command.perform("tree-sitter:expand-selection"))
      local state = view:get_selection_state()
      doc:set_selection_list(state.selections, state.last_selection, { sanitized = true })
      local text = doc:get_selection_text()
      if text == "\n  int x = 1;\n  return x;\n" then seen_content_at = seen_content_at or i end
      if text == "{\n  int x = 1;\n  return x;\n}" then seen_full_at = seen_full_at or i end
      if seen_content_at and seen_full_at then break end
    end

    test.not_nil(seen_content_at)
    test.not_nil(seen_full_at)
    test.ok(seen_content_at < seen_full_at)

    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("expand selection command gracefully no-ops without ready Tree-sitter", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("plain.txt", "plain.txt")
    local previous = core.active_view
    local view = DocView(doc)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 1, 2, 1, 2 }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:expand-selection"))
    local state = view:get_selection_state()
    test.same(state.selections, { 1, 2, 1, 2 })
    if previous then core.set_active_view(previous) end
    doc:on_close()
  end)

  test.it("DocView measurement uses render token iterator", function()
    local doc = Doc()
    set_text(doc, "abc")
    local view = DocView(doc)
    local render_calls = 0
    local legacy_calls = 0
    doc.highlighter.each_render_token = function(_, line, scol)
      render_calls = render_calls + 1
      return tokenizer.each_token({ "normal", "abc\n" }, scol)
    end
    doc.highlighter.each_token = function(_, line, scol)
      legacy_calls = legacy_calls + 1
      return tokenizer.each_token({ "normal", "abc\n" }, scol)
    end
    view:get_col_x_offset(1, 3)
    view:get_x_offset_col(1, 1)
    test.ok(render_calls >= 2)
    test.equal(legacy_calls, 0)
    doc:on_close()
  end)
end)
