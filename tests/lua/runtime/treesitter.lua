local Doc = require "core.doc"
local test = require "core.test"
local treesitter = require "core.treesitter"
local registry = require "core.treesitter.registry"
local native = require "treesitter"
local ts_highlight = require "core.treesitter.highlight"

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

local function token_type_for_text(tokens, needle)
  for i = 1, #tokens, 2 do
    local token_type, text = tokens[i], tokens[i + 1]
    local start = text and text:find(needle, 1, true)
    if start then return token_type end
  end
end

local function all_tokens_normal(tokens)
  for i = 1, #tokens, 2 do
    if tokens[i] ~= "normal" and tokens[i + 1] ~= "" then return false end
  end
  return true
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

local cpp_repro_text = [[/**
 * Representative C++ menu fixture.
 * Leading block comments must be captured by Tree-sitter.
 */

#define COBJMACROS
#include <windows.h>
#include <d3d11.h>

namespace demo {
class MenuGui {
public:
  void draw_settings();
};
}

static void apply_theme(void)
{
  demo::MenuGui menu;
  int visible_count = 1;
  (void)menu;
  (void)visible_count;
}
]]

local function cpp_doc(text, filename)
  local doc = Doc()
  set_text(doc, text or "namespace demo { class Box {}; } int main() { auto value = demo::Box{}; return 0; }")
  doc:set_filename(filename or "example.cpp", filename or "example.cpp")
  return doc
end

local function write_cpp_repro_file(filename)
  local fp = assert(io.open(filename, "wb"))
  fp:write((cpp_repro_text:gsub("\n", "\r\n")))
  fp:close()
end

test.describe("core.treesitter phase 3 document integration", function()
  test.it("registry loads C and C++ configs and highlight queries", function()
    registry.reload()
    local config = registry.get("example.c", "")
    test.ok(config)
    test.equal(config.id, "c")
    test.equal(config.grammar, "c")
    test.ok(config.query_sources.highlights)

    config = registry.get("example.cpp", "")
    test.ok(config)
    test.equal(config.id, "cpp")
    test.equal(config.grammar, "cpp")
    test.ok(config.query_sources.highlights)
    test.ok(native.has_language("cpp"))
  end)

  test.it("C and C++ file/documents attach state", function()
    local doc = c_doc()
    test.ok(doc.treesitter)
    test.equal(doc.treesitter.language_id, "c")
    test.ok(doc.treesitter.native)
    doc:on_close()

    doc = cpp_doc()
    test.ok(doc.treesitter)
    test.equal(doc.treesitter.language_id, "cpp")
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

  test.it("render line falls back to tokenizer while Tree-sitter is unready", function()
    local doc = c_doc("int main(void) { return VALUE; }")
    local line = doc.highlighter:get_render_line(1)
    test.equal(line.source, "tokenizer")
    doc:on_close()
  end)

  test.it("render line uses Tree-sitter C highlight tokens when ready", function()
    local doc = c_doc("int main(void) { return VALUE; }")
    test.ok(wait_ready(doc))
    local line = doc.highlighter:get_render_line(1)
    test.equal(line.source, "treesitter")
    test.equal(token_type_for_text(line.tokens, "int"), "type.builtin")
    test.equal(token_type_for_text(line.tokens, "main"), "function")
    test.equal(token_type_for_text(line.tokens, "return"), "keyword")
    test.equal(token_type_for_text(line.tokens, "VALUE"), "constant")
    doc:on_close()
  end)

  test.it("render line uses Tree-sitter C++ highlight tokens when ready", function()
    local doc = cpp_doc("namespace demo { class Box {}; }\nint main() { auto value = demo::Box{}; return 0; }")
    test.ok(wait_ready(doc))
    local line1 = doc.highlighter:get_render_line(1)
    local line2 = doc.highlighter:get_render_line(2)
    test.equal(line1.source, "treesitter")
    test.equal(line2.source, "treesitter")
    test.equal(token_type_for_text(line1.tokens, "namespace"), "keyword")
    test.equal(token_type_for_text(line1.tokens, "demo"), "namespace")
    test.equal(token_type_for_text(line1.tokens, "class"), "keyword")
    test.equal(token_type_for_text(line1.tokens, "Box"), "type")
    test.equal(token_type_for_text(line2.tokens, "auto"), "type.builtin")
    test.equal(token_type_for_text(line2.tokens, "return"), "keyword")
    doc:on_close()
  end)

  test.it("C++ service query captures comments after loading representative menu fixture from disk", function()
    local filename = "menu_gui_repro.cpp"
    write_cpp_repro_file(filename)
    local doc = Doc(filename, filename)
    test.ok(wait_ready(doc))
    local byte_len = 0
    for _, line in ipairs(doc.lines) do byte_len = byte_len + #line end
    local query = assert(native.compile_query("cpp", "comment-regression", "(comment) @comment"))
    local captures = assert(doc.treesitter.native:query_captures(query, 0, byte_len, {
      match_limit = 100000,
      max_captures = 100000,
      timeout_ms = 1000,
    }))
    test.ok(#captures > 0, "expected at least one C++ comment capture")
    test.equal(captures[1].capture, "comment")
    doc:on_close()
    os.remove(filename)
  end)

  test.it("C++ render tokens are not silently all-normal for representative menu fixture", function()
    local doc = cpp_doc(cpp_repro_text, "menu_gui_repro.cpp")
    test.ok(wait_ready(doc))
    local comment_line = doc.highlighter:get_render_line(1)
    test.equal(comment_line.source, "treesitter")
    test.equal(token_type_for_text(comment_line.tokens, "/**"), "comment")

    local define_line = doc.highlighter:get_render_line(6)
    local include_line = doc.highlighter:get_render_line(7)
    local function_line = doc.highlighter:get_render_line(17)
    test.equal(define_line.source, "treesitter")
    test.equal(include_line.source, "treesitter")
    test.equal(function_line.source, "treesitter")
    test.equal(all_tokens_normal(define_line.tokens), false)
    test.equal(all_tokens_normal(include_line.tokens), false)
    test.equal(all_tokens_normal(function_line.tokens), false)
    doc:on_close()
  end)

  test.it("stale-unrenderable documents fall back to tokenizer render tokens", function()
    local doc = c_doc("int value(void) { return 1; }")
    test.ok(wait_ready(doc))
    doc.treesitter.stale_unrenderable = true
    local line = doc.highlighter:get_render_line(1)
    test.equal(line.source, "tokenizer")
    doc:on_close()
  end)

  test.it("span resolver is deterministic for overlaps and priority", function()
    local tokens = ts_highlight.resolve_line_tokens("abcdef\n", 0, 7, {
      { capture = "variable", start_byte = 0, end_byte = 6, priority = 0, pattern_index = 0, capture_index = 0, order = 0 },
      { capture = "function.call", start_byte = 1, end_byte = 5, priority = 0, pattern_index = 1, capture_index = 0, order = 1 },
      { capture = "keyword", start_byte = 2, end_byte = 4, priority = 5, pattern_index = 0, capture_index = 0, order = 2 },
    })
    test.same(tokens, {
      "variable", "a",
      "function.call", "b",
      "keyword", "cd",
      "function.call", "e",
      "variable", "f",
      "normal", "\n",
    })
  end)

  test.it("query predicates and priority directives filter captures", function()
    local state = assert(native.new_document_state("c", { parse_timeout_ms = 5000 }))
    assert(state:schedule_parse({ "int ABC = 1; int value = 2;\n" }, 1, nil))
    local status = wait_native_poll(state, 1)
    test.equal(status, "ready")
    local query = assert(native.compile_query("c", "predicate-test", [[
      ((identifier) @constant (#match? @constant "^[A-Z]+$") (#set! priority 2))
      ((identifier) @variable (#not-match? @variable "^[A-Z]+$"))
      ((identifier) @constant (#eq? @constant "ABC"))
      ((identifier) @variable (#not-eq? @variable "ABC"))
      ((identifier) @constant (#any-of? @constant "ABC" "XYZ"))
      ((identifier) @variable (#not-any-of? @variable "ABC" "XYZ"))
    ]]))
    local captures = assert(state:query_captures(query, 0, #"int ABC = 1; int value = 2;\n", {
      match_limit = 128,
      max_captures = 128,
      timeout_ms = 100,
    }))
    local constants, variables, priority_constants = 0, 0, 0
    for _, capture in ipairs(captures) do
      if capture.capture == "constant" then
        constants = constants + 1
        if capture.priority == 2 then priority_constants = priority_constants + 1 end
      elseif capture.capture == "variable" then
        variables = variables + 1
      end
    end
    test.ok(constants >= 3)
    test.ok(variables >= 3)
    test.ok(priority_constants >= 1)
    state:close()
  end)
end)
