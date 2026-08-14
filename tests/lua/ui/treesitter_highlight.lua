local core = require "core"
local command = require "core.command"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"
local tokenizer = require "core.tokenizer"
local treesitter = require "core.treesitter"
local intelligence = require "core.language_intelligence"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function c_buffer(text)
  local buffer = Buffer()
  set_text(buffer, text or "int main(void) { return 0; }")
  buffer:set_filename("ui_tree_sitter.c", "ui_tree_sitter.c")
  return buffer
end

local function cpp_buffer(text)
  local buffer = Buffer()
  set_text(buffer, text or "namespace demo { class Box {}; } int main() { auto value = demo::Box{}; return 0; }")
  buffer:set_filename("ui_tree_sitter.cpp", "ui_tree_sitter.cpp")
  return buffer
end

local function odin_buffer(text)
  local buffer = Buffer()
  set_text(buffer, text or "package demo\n\nmain :: proc() {\n  value := 42\n}\n")
  buffer:set_filename("ui_tree_sitter.odin", "ui_tree_sitter.odin")
  return buffer
end

local function kotlin_buffer(text)
  local buffer = Buffer()
  set_text(buffer, text or "package demo\n\nclass Box(val value: Int) {\n  fun doubled(): Int = value * 2\n}\n")
  buffer:set_filename("ui_tree_sitter.kt", "ui_tree_sitter.kt")
  return buffer
end

local function wait_ready(buffer, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_buffer(buffer)
    if buffer.treesitter and buffer.treesitter.status == "ready" then return true end
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

test.describe("Tree-sitter TextView highlighting", function()
  test.it("TextView draw uses Tree-sitter C render tokens when ready", function()
    local buffer = c_buffer("int main(void) { return VALUE; }")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = buffer.highlighter:get_render_line(1)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), buffer.lines[1]:sub(1, -2))
    buffer:on_close()
  end)

  test.it("TextView draw uses Tree-sitter C++ render tokens when ready", function()
    local buffer = cpp_buffer("namespace demo { class Box {}; }\nint main() { auto value = demo::Box{}; return 0; }")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = buffer.highlighter:get_render_line(1)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), buffer.lines[1]:sub(1, -2))
    buffer:on_close()
  end)

  test.it("TextView draw uses Tree-sitter Odin render tokens when ready", function()
    local buffer = odin_buffer("package demo\n\nmain :: proc() {\n  value := 42\n}")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = buffer.highlighter:get_render_line(3)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(3, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), buffer.lines[3]:sub(1, -2))
    buffer:on_close()
  end)

  test.it("keeps Odin delimiter-heavy text aligned with its caret column", function()
    local prefix = "main :: proc()" .. string.rep(":", 28) .. "sdf- ds f-as d-f sd- -sa d-f -"
    local text = prefix .. "{"
    local buffer = odin_buffer(text)
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 2000, 240
    view:set_wrapping_enabled(false)
    view.__test_force_known_bounds = true

    local drawn_brace_x
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    local function record_brace(font, chunk, x, opts)
      local brace = chunk:find("{", 1, true)
      if brace then
        drawn_brace_x = x + font:get_width(chunk:sub(1, brace - 1), opts)
      end
    end
    renderer.draw_text = function(font, chunk, x, _, _, opts)
      record_brace(font, chunk, x, opts)
      return x + font:get_width(chunk, opts)
    end
    renderer.draw_text_known_bounds = function(font, chunk, x, _, _, _, w, _, _, opts)
      record_brace(font, chunk, x, opts)
      return x + w
    end

    local ok, err = pcall(function()
      view:draw_line_text(1, 0, 0)
    end)
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    if not ok then
      buffer:on_close()
      error(err, 0)
    end

    test.not_nil(drawn_brace_x)
    test.equal(drawn_brace_x, view:get_col_x_offset(1, #prefix + 1))
    buffer:on_close()
  end)

  test.it("TextView draw uses Tree-sitter Kotlin render tokens when ready", function()
    local buffer = kotlin_buffer("package demo\n\nclass Box(val value: Int) {\n  fun doubled(): Int = value * 2\n}")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = buffer.highlighter:get_render_line(3)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(3, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), buffer.lines[3]:sub(1, -2))
    buffer:on_close()
  end)

  test.it("TextView draw falls back before Tree-sitter is ready", function()
    local buffer = c_buffer("int main(void) { return VALUE; }")
    local render_line = buffer.highlighter:get_render_line(1)
    test.equal(render_line.source, "tokenizer")
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    buffer:on_close()
  end)

  test.it("current buffer outline reads the active TextView buffer", function()
    local buffer = cpp_buffer([[namespace demo {
class MenuGui {
public:
  void draw_settings() { }
};
}]])
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    local symbols = treesitter.get_current_buffer_outline()
    local names = {}
    for _, symbol in ipairs(symbols) do names[#names + 1] = symbol.name .. ":" .. symbol.kind end
    test.ok(table.concat(names, "|"):find("demo:namespace", 1, true))
    test.ok(table.concat(names, "|"):find("MenuGui:class", 1, true))
    test.ok(table.concat(names, "|"):find("draw_settings:method", 1, true))
    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("local Tree-sitter fallback commands select definitions and references", function()
    local buffer = c_buffer([[int first(void) {
  int value = 1;
  return value;
}
int second(void) {
  int value = 2;
  return value;
}]])
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    local ref_col = assert(buffer.lines[7]:find("value", 1, true))
    view:set_selection_state({ selections = { 7, ref_col, 7, ref_col }, last_selection = 1 })

    test.ok(command.perform("tree-sitter:go-to-local-definition"))
    local state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "value")
    local line1 = select(1, buffer:get_selection(true))
    test.equal(line1, 6)

    view:set_selection_state({ selections = { 7, ref_col, 7, ref_col }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:select-local-references"))
    state = view:get_selection_state()
    test.equal(#state.selections / 4, 2)
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "value\nvalue")

    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("Tree-sitter commands no-op cleanly when language intelligence provider is unavailable", function()
    local buffer = cpp_buffer("int helper() { return 1; }\nint main() { return helper(); }")
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 2, 5, 2, 5 }, last_selection = 1 })
    intelligence.without_provider("treesitter", function()
      test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    end)
    local state = view:get_selection_state()
    test.same(state.selections, { 2, 5, 2, 5 })
    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("local Tree-sitter fallback command gracefully no-ops without ready locals", function()
    local buffer = Buffer()
    set_text(buffer, "plain text")
    buffer:set_filename("plain.txt", "plain.txt")
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 1, 2, 1, 2 }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:go-to-local-definition"))
    local state = view:get_selection_state()
    test.same(state.selections, { 1, 2, 1, 2 })
    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("symbol navigation commands select stable symbol name ranges", function()
    local buffer = cpp_buffer([[namespace demo {
class MenuGui {
public:
  void draw_settings() { int local = 1; }
};
}
int helper() { return 1; }
int main() { return helper(); }]])
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 4, 35, 4, 35 }, last_selection = 1 })

    test.ok(command.perform("tree-sitter:go-to-enclosing-symbol"))
    local state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "draw_settings")

    test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "helper")

    test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "main")

    test.ok(command.perform("tree-sitter:go-to-previous-symbol"))
    state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "helper")

    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("symbol navigation shows Status Bar feedback at directional boundaries", function()
    local buffer = cpp_buffer([[int first() { return 1; }
int second() { return 2; }]])
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)

    local first_col = assert(buffer.lines[1]:find("first", 1, true))
    view:set_selection_state({ selections = { 1, first_col, 1, first_col }, last_selection = 1 })
    local messages = capture_status_messages(function()
      test.ok(command.perform("tree-sitter:go-to-previous-symbol"))
    end)
    test.equal(messages[#messages].text, "No previous symbol")
    local state = view:get_selection_state()
    test.same(state.selections, { 1, first_col, 1, first_col })

    local second_col = assert(buffer.lines[2]:find("second", 1, true))
    view:set_selection_state({ selections = { 2, second_col, 2, second_col }, last_selection = 1 })
    messages = capture_status_messages(function()
      test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    end)
    test.equal(messages[#messages].text, "No next symbol")
    state = view:get_selection_state()
    test.same(state.selections, { 2, second_col, 2, second_col })

    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("symbol navigation command gracefully no-ops without ready Tree-sitter", function()
    local buffer = Buffer()
    set_text(buffer, "plain text")
    buffer:set_filename("plain.txt", "plain.txt")
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 1, 2, 1, 2 }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:go-to-next-symbol"))
    local state = view:get_selection_state()
    test.same(state.selections, { 1, 2, 1, 2 })
    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("commands expand and shrink selection by Tree-sitter node", function()
    local buffer = cpp_buffer("int main() { return 0; }")
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    local col = assert(buffer.lines[1]:find("main", 1, true))
    view:set_selection_state({ selections = { 1, col, 1, col }, last_selection = 1 })

    test.ok(command.perform("tree-sitter:expand-selection"))
    local state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "main")

    test.ok(command.perform("tree-sitter:expand-selection"))
    state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.ok(#buffer:get_selection_text() > #"main")
    test.ok(buffer:get_selection_text():find("main", 1, true))

    test.ok(command.perform("tree-sitter:shrink-selection"))
    state = view:get_selection_state()
    buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
    test.equal(buffer:get_selection_text(), "main")

    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("expand selection selects block contents before block delimiters", function()
    local source = table.concat({
      "int main() {",
      "  int x = 1;",
      "  return x;",
      "}",
    }, "\n")
    local buffer = cpp_buffer(source)
    test.ok(wait_ready(buffer))
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    local line = 3
    local col = assert(buffer.lines[line]:find("x", 1, true))
    view:set_selection_state({ selections = { line, col, line, col }, last_selection = 1 })

    local seen_content_at, seen_full_at
    for i = 1, 12 do
      test.ok(command.perform("tree-sitter:expand-selection"))
      local state = view:get_selection_state()
      buffer:set_selection_list(state.selections, state.last_selection, { sanitized = true })
      local text = buffer:get_selection_text()
      if text == "\n  int x = 1;\n  return x;\n" then seen_content_at = seen_content_at or i end
      if text == "{\n  int x = 1;\n  return x;\n}" then seen_full_at = seen_full_at or i end
      if seen_content_at and seen_full_at then break end
    end

    test.not_nil(seen_content_at)
    test.not_nil(seen_full_at)
    test.ok(seen_content_at < seen_full_at)

    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("expand selection command gracefully no-ops without ready Tree-sitter", function()
    local buffer = Buffer()
    set_text(buffer, "plain text")
    buffer:set_filename("plain.txt", "plain.txt")
    local previous = core.active_view
    local view = TextView(buffer)
    core.set_active_view(view)
    view:set_selection_state({ selections = { 1, 2, 1, 2 }, last_selection = 1 })
    test.ok(command.perform("tree-sitter:expand-selection"))
    local state = view:get_selection_state()
    test.same(state.selections, { 1, 2, 1, 2 })
    if previous then core.set_active_view(previous) end
    buffer:on_close()
  end)

  test.it("TextView measurement uses render token iterator", function()
    local buffer = Buffer()
    set_text(buffer, "abc")
    local view = TextView(buffer)
    local render_calls = 0
    local legacy_calls = 0
    buffer.highlighter.each_render_token = function(_, line, scol)
      render_calls = render_calls + 1
      return tokenizer.each_token({ "normal", "abc\n" }, scol)
    end
    buffer.highlighter.each_token = function(_, line, scol)
      legacy_calls = legacy_calls + 1
      return tokenizer.each_token({ "normal", "abc\n" }, scol)
    end
    view:get_col_x_offset(1, 3)
    view:get_x_offset_col(1, 1)
    test.ok(render_calls >= 2)
    test.equal(legacy_calls, 0)
    buffer:on_close()
  end)
end)
