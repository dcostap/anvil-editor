local common = require "core.common"
local Doc = require "core.doc"
local test = require "core.test"
local treesitter = require "core.treesitter"
local intelligence = require "core.language_intelligence"
local registry = require "core.treesitter.registry"
local native = require "treesitter"
local ts_highlight = require "core.treesitter.highlight"
local symbol_index = require "core.treesitter.symbol_index"

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

local function find_symbol(symbols, name, kind)
  for _, symbol in ipairs(symbols or {}) do
    if symbol.name == name and (not kind or symbol.kind == kind) then return symbol end
  end
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

local function odin_doc(text, filename)
  local doc = Doc()
  set_text(doc, text or "package demo\n\nmain :: proc() {\n  value := 42\n}\n")
  doc:set_filename(filename or "example.odin", filename or "example.odin")
  return doc
end

local function write_cpp_repro_file(filename)
  local fp = assert(io.open(filename, "wb"))
  fp:write((cpp_repro_text:gsub("\n", "\r\n")))
  fp:close()
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function write_file(path, text)
  local fp = test.not_nil(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
  return path
end

local function wait_workspace_symbols(query, opts, timeout)
  local deadline = system.get_time() + (timeout or 5)
  local results, reason, status
  opts = opts or {}
  local first = true
  repeat
    local call_opts = opts
    if opts.force and not first then
      call_opts = common.merge(opts, { force = false })
    end
    first = false
    results, reason, status = symbol_index.workspace_symbols(query, call_opts)
    if status == "fresh" or status == "stale" then return results, reason, status end
    coroutine.yield(0.03)
  until system.get_time() >= deadline
  return results, reason, status
end

test.describe("core.treesitter phase 3 document integration", function()
  test.it("registry loads C and C++ configs and highlight queries", function()
    registry.reload()
    local config = registry.get("example.c", "")
    test.ok(config)
    test.equal(config.id, "c")
    test.equal(config.grammar, "c")
    test.ok(config.query_sources.highlights)
    test.ok(config.query_sources.outline)
    test.ok(config.query_sources.locals)

    config = registry.get("example.cpp", "")
    test.ok(config)
    test.equal(config.id, "cpp")
    test.equal(config.grammar, "cpp")
    test.ok(config.query_sources.highlights)
    test.ok(config.query_sources.outline)
    test.ok(config.query_sources.locals)
    test.ok(native.has_language("cpp"))

    config = registry.get("example.odin", "")
    test.ok(config)
    test.equal(config.id, "odin")
    test.equal(config.grammar, "odin")
    test.ok(config.query_sources.highlights)
    test.ok(config.query_sources.outline)
    test.ok(config.query_sources.locals)
    test.ok(native.has_language("odin"))
  end)

  test.it("Tree-sitter registers as a language intelligence provider", function()
    local provider = intelligence.get_provider("treesitter")
    test.ok(provider)
    test.equal(provider.kind, "syntactic-local-fallback")
    test.ok(provider.document_outline)
    test.ok(provider.node_ranges)
    test.ok(provider.fold_target)
    test.ok(provider.local_definition)
  end)

  test.it("language intelligence abstraction no-provider paths fall back cleanly", function()
    local doc = c_doc("int main(void) { return 0; }")
    test.ok(wait_ready(doc))
    intelligence.without_provider("treesitter", function()
      local symbols, reason = intelligence.document_outline(doc)
      test.equal(#symbols, 0)
      test.equal(reason, "no-provider")
      local tokens
      tokens, reason = intelligence.render_tokens(doc, 1)
      test.equal(tokens, nil)
      test.equal(reason, "no-provider")
      local ok
      ok, reason = intelligence.goto_next_symbol(doc)
      test.equal(ok, false)
      test.equal(reason, "no-provider")
    end)
    doc:on_close()
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

    doc = odin_doc()
    test.ok(doc.treesitter)
    test.equal(doc.treesitter.language_id, "odin")
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

  test.it("Odin highlighting and outline use bundled Tree-sitter queries", function()
    local doc = odin_doc([[package demo

Point :: struct {
  x: int,
  y: int,
}

main :: proc() {
  value := 42
  return
}
]])
    test.ok(wait_ready(doc))
    local tokens = ts_highlight.line_tokens(doc, 8)
    test.equal(token_type_for_text(tokens, "main"), "function")
    test.equal(token_type_for_text(tokens, "proc"), "keyword.function")

    local symbols = treesitter.get_document_outline(doc)
    test.ok(find_symbol(symbols, "demo", "module"))
    test.ok(find_symbol(symbols, "Point", "struct"))
    local main_symbol = find_symbol(symbols, "main", "function")
    test.ok(main_symbol)
    test.equal(main_symbol.signature, "()")
    test.equal(main_symbol.declaration, "main :: proc()")
    test.same(main_symbol.declaration_name_span, { 1, 4 })
    doc:on_close()
  end)

  test.it("Tree-sitter symbol index returns Project and current Document symbols", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-index-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    write_file(root .. PATHSEP .. "main.odin", [[package demo

main :: proc() {
  value := 1
}
]])
    write_file(root .. PATHSEP .. "player.odin", [[package demo

Player :: struct {
  x: int,
}

spawn_player :: proc() -> Player {
  return {}
}
]])

    local results, _reason, status = wait_workspace_symbols("player", { root = root, limit = 10 })
    test.equal(status, "fresh")
    test.ok(find_symbol(results, "Player", "struct"))
    test.ok(find_symbol(results, "spawn_player", "function"))

    write_file(root .. PATHSEP .. "late.odin", [[package demo

late_symbol :: proc() {}
]])
    results, _reason, status = wait_workspace_symbols("late", { root = root, limit = 10, force = true })
    test.equal(status, "fresh")
    test.ok(find_symbol(results, "late_symbol", "function"))

    os.remove(root .. PATHSEP .. "player.odin")
    results, _reason, status = wait_workspace_symbols("Player", { root = root, limit = 10, force = true })
    test.equal(status, "fresh")
    test.equal(find_symbol(results, "Player", "struct"), nil)

    local doc = odin_doc([[package demo

helper :: proc() {}
main :: proc() {}
]], root .. PATHSEP .. "current.odin")
    test.ok(wait_ready(doc))
    results = symbol_index.current_document_symbols(doc, "help", { root = root, limit = 10 })
    test.ok(find_symbol(results, "helper", "function"))
    test.equal(find_symbol(results, "main", "function"), nil)
    doc:on_close()
    common.rm(root, true)
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

  test.it("document outline is available through language intelligence", function()
    local doc = c_doc("int helper(void) { return 1; }")
    test.ok(wait_ready(doc))
    local symbols = intelligence.document_outline(doc)
    test.ok(#symbols >= 1)
    test.equal(symbols[1].name, "helper")
    doc:on_close()
  end)

  test.it("document outline gracefully returns empty when unsupported or unready", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("notes.txt", "notes.txt")
    local symbols, reason = treesitter.get_document_outline(doc)
    test.equal(#symbols, 0)
    test.equal(reason, "unsupported")
    doc:on_close()

    doc = c_doc("int main(void) { return 0; }")
    symbols, reason = treesitter.get_document_outline(doc)
    test.equal(#symbols, 0)
    test.equal(reason, "not-ready")
    doc:on_close()
  end)

  test.it("document outline gracefully returns empty when outline query is missing", function()
    local doc = c_doc("int main(void) { return 0; }")
    test.ok(wait_ready(doc))
    doc.treesitter.queries.outline = nil
    local symbols, reason = treesitter.get_document_outline(doc)
    test.equal(#symbols, 0)
    test.equal(reason, "missing-query")
    doc:on_close()
  end)

  test.it("C document outline returns sorted symbols with ranges", function()
    local doc = c_doc([[struct Point { int x; int y; };
enum Color { RED, BLUE };
static int helper(void) { return 1; }
int main(void) { return helper(); }]])
    test.ok(wait_ready(doc))
    local symbols = treesitter.get_document_outline(doc)
    test.ok(#symbols >= 4)
    test.same({ symbols[1].name, symbols[1].kind }, { "Point", "struct" })
    test.same({ symbols[2].name, symbols[2].kind }, { "Color", "enum" })
    test.same({ symbols[3].name, symbols[3].kind }, { "helper", "function" })
    test.same({ symbols[4].name, symbols[4].kind }, { "main", "function" })
    local main = find_symbol(symbols, "main", "function")
    test.ok(main)
    test.equal(main.start_line, 4)
    test.ok(main.end_line >= main.start_line)
    test.ok(main.range and main.range.start and main.range["end"])
    test.ok(main.name_range and main.name_range.start)
    test.equal(main.signature, "(void)")
    test.equal(main.declaration, "int main(void)")
    test.same(main.declaration_name_span, { 5, 8 })
    doc:on_close()
  end)

  test.it("C++ document outline includes straightforward parent nesting", function()
    local doc = cpp_doc([[namespace demo {
class MenuGui {
public:
  void draw_settings() { }
};
}
int main() { return 0; }]])
    test.ok(wait_ready(doc))
    local symbols = treesitter.get_document_outline(doc)
    local namespace = find_symbol(symbols, "demo", "namespace")
    local class = find_symbol(symbols, "MenuGui", "class")
    local method = find_symbol(symbols, "draw_settings", "method")
    local main = find_symbol(symbols, "main", "function")
    test.ok(namespace)
    test.ok(class)
    test.ok(method)
    test.ok(main)
    test.equal(class.parent, namespace.index)
    test.equal(method.parent, class.index)
    test.equal(main.parent, nil)
    test.ok(#namespace.children >= 1)
    test.ok(#class.children >= 1)
    doc:on_close()
  end)

  test.it("symbol navigation API uses outline symbols", function()
    local doc = cpp_doc([[namespace demo {
class MenuGui {
public:
  void draw_settings() { int local = 1; }
};
}
int helper() { return 1; }
int main() { return helper(); }]])
    test.ok(wait_ready(doc))

    local enclosing = treesitter.get_enclosing_symbol(doc, 4, 27)
    test.ok(enclosing)
    test.same({ enclosing.name, enclosing.kind }, { "draw_settings", "method" })

    local first = treesitter.get_next_symbol(doc, 1, 1)
    test.ok(first)
    test.same({ first.name, first.kind }, { "demo", "namespace" })

    local next_after_method = treesitter.get_next_symbol(doc, 4, 8)
    test.ok(next_after_method)
    test.same({ next_after_method.name, next_after_method.kind }, { "helper", "function" })

    local previous_from_main = treesitter.get_previous_symbol(doc, 8, 5)
    test.ok(previous_from_main)
    test.same({ previous_from_main.name, previous_from_main.kind }, { "helper", "function" })
    doc:on_close()
  end)

  test.it("symbol navigation API gracefully returns nil without outline data", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("notes.txt", "notes.txt")
    local symbol, reason = treesitter.get_next_symbol(doc, 1, 1)
    test.equal(symbol, nil)
    test.equal(reason, "unsupported")
    doc:on_close()

    doc = c_doc("int main(void) { return 0; }")
    test.ok(wait_ready(doc))
    doc.treesitter.queries.outline = nil
    symbol, reason = treesitter.get_enclosing_symbol(doc, 1, 5)
    test.equal(symbol, nil)
    test.equal(reason, "missing-query")
    doc:on_close()
  end)

  test.it("local Tree-sitter fallback finds current-document definitions and references", function()
    local doc = c_doc([[int first(void) {
  int value = 1;
  return value;
}
int second(void) {
  int value = 2;
  return value;
}]])
    test.ok(wait_ready(doc))
    local ref_col = assert(doc.lines[7]:find("value", 1, true))
    local definition = treesitter.get_local_definition(doc, 7, ref_col)
    test.ok(definition)
    test.equal(definition.name, "value")
    test.equal(definition.kind, "var")
    test.equal(definition.start_line, 6)
    test.ok(definition.local_tree_sitter_fallback)

    local refs = treesitter.get_local_references(doc, 7, ref_col)
    test.equal(#refs, 2)
    test.equal(refs[1].start_line, 6)
    test.equal(refs[2].start_line, 7)
    for _, ref in ipairs(refs) do
      test.equal(ref.name, "value")
      test.ok(ref.local_tree_sitter_fallback)
    end
    doc:on_close()
  end)

  test.it("local Tree-sitter fallback handles C++ parameters", function()
    local doc = cpp_doc([[int add(int amount) {
  return amount;
}]])
    test.ok(wait_ready(doc))
    local ref_col = assert(doc.lines[2]:find("amount", 1, true))
    local definition = treesitter.get_local_declaration(doc, 2, ref_col)
    test.ok(definition)
    test.equal(definition.name, "amount")
    test.equal(definition.kind, "parameter")
    test.equal(definition.start_line, 1)
    local refs = treesitter.get_local_references(doc, 2, ref_col)
    test.equal(#refs, 2)
    doc:on_close()
  end)

  test.it("visible Tree-sitter document symbols exclude other functions and later locals", function()
    local doc = c_doc([[int first(void) {
  int first_value = 1;
  return first_value;
}
int second(void) {
  int visible_value = 2;
  visible_value;
  int future_value = 3;
}]])
    test.ok(wait_ready(doc))
    local cursor_col = #(doc.lines[7] or "")
    local visible = treesitter.locals.get_visible_document_symbols(doc, 7, cursor_col)
    local names = {}
    for _, symbol in ipairs(visible or {}) do names[symbol.name] = symbol end
    test.ok(names.visible_value)
    test.equal(names.visible_value.kind, "var")
    test.is_nil(names.first_value)
    test.is_nil(names.future_value)
    doc:on_close()
  end)

  test.it("local Tree-sitter fallback gracefully returns empty without locals query", function()
    local doc = c_doc("int main(void) { return 0; }")
    test.ok(wait_ready(doc))
    doc.treesitter.queries.locals = nil
    local definition, reason = treesitter.get_local_definition(doc, 1, 5)
    test.equal(definition, nil)
    test.equal(reason, "missing-query")
    local refs
    refs, reason = treesitter.get_local_references(doc, 1, 5)
    test.equal(#refs, 0)
    test.equal(reason, "missing-query")
    doc:on_close()
  end)

  test.it("node range API returns syntax ancestry and graceful fallbacks", function()
    local doc = Doc()
    set_text(doc, "plain text")
    doc:set_filename("notes.txt", "notes.txt")
    local ranges, reason = treesitter.get_node_ranges(doc, 1, 1)
    test.equal(#ranges, 0)
    test.equal(reason, "unsupported")
    doc:on_close()

    doc = c_doc("int main(void) { return 0; }")
    ranges, reason = treesitter.get_node_ranges(doc, 1, 5)
    test.equal(#ranges, 0)
    test.equal(reason, "not-ready")
    test.ok(wait_ready(doc))
    ranges = treesitter.get_node_ranges(doc, 1, 5)
    test.ok(#ranges >= 2)
    test.equal(ranges[1].type, "identifier")
    test.equal(doc:get_text(ranges[1].start_line, ranges[1].start_col, ranges[1].end_line, ranges[1].end_col), "main")
    test.ok(ranges[#ranges].start_byte <= ranges[1].start_byte)
    test.ok(ranges[#ranges].end_byte >= ranges[1].end_byte)
    doc:on_close()
  end)

  test.it("Fold Target API returns a syntax-aware multi-line ancestor", function()
    local doc = c_doc("int main(void) {\n  return 0;\n}\n")
    test.ok(wait_ready(doc))
    local target = treesitter.get_fold_target(doc, 1, 5)
    test.ok(target ~= nil, "expected syntax-aware Fold Target")
    test.equal(target.kind, "syntax")
    test.equal(target.line1, 1)
    test.equal(target.line2, 3)
    test.equal(target.metadata.provider, "treesitter")
    doc:on_close()
  end)

  test.it("Fold Target API treats leading indentation as the current syntax line", function()
    local doc = c_doc("int main(void) {\n  if (x) {\n    y();\n  }\n}\n")
    test.ok(wait_ready(doc))
    local target = treesitter.get_fold_target(doc, 2, 1)
    test.ok(target ~= nil, "expected syntax-aware Fold Target")
    test.equal(target.line1, 2)
    test.equal(target.line2, 4)
    doc:on_close()
  end)

  test.it("Fold Target API skips Tree-sitter error recovery nodes", function()
    local doc = c_doc("int main(void) {\n  if (x) {\n    y();\n")
    test.ok(wait_ready(doc))
    local target = treesitter.get_fold_target(doc, 3, 5)
    test.ok(target == nil or target.metadata.node_type ~= "ERROR", "expected Fold Target to reject ERROR nodes")
    doc:on_close()
  end)

  test.it("syntax selection helpers keep UTF-8 byte boundaries", function()
    local doc = c_doc([[const char *s = "hé";]])
    test.ok(wait_ready(doc))
    local line = doc.lines[1]
    local utf8_start = assert(line:find("é", 1, true))
    local invalid_col = utf8_start + 1
    local ranges = treesitter.get_node_ranges(doc, 1, invalid_col, 1, invalid_col)
    test.ok(#ranges > 0)
    for _, range in ipairs(ranges) do
      local start_byte = doc.lines[range.start_line]:byte(range.start_col)
      local end_byte = doc.lines[range.end_line]:byte(range.end_col)
      test.ok(not (start_byte and start_byte >= 0x80 and start_byte <= 0xbf))
      test.ok(not (end_byte and end_byte >= 0x80 and end_byte <= 0xbf))
    end
    doc:on_close()
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
    test.equal(token_type_for_text(line.tokens, "main"), "function.declaration")
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
    test.equal(token_type_for_text(line1.tokens, "demo"), "type.namespace")
    test.equal(token_type_for_text(line1.tokens, "class"), "keyword")
    test.equal(token_type_for_text(line1.tokens, "Box"), "type.class")
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
