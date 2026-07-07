local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local Doc = require "core.doc"
local test = require "core.test"
local treesitter = require "core.treesitter"
local intelligence = require "core.language_intelligence"
local registry = require "core.treesitter.registry"
local native = require "treesitter"
local ts_highlight = require "core.treesitter.highlight"
local symbol_index = require "core.treesitter.symbol_index"
local worker_pool = require "core.worker_pool"

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

local function seed_ready_symbol_index(root, names)
  local index = symbol_index.status(root)
  index.status = "ready"
  index.symbol_status = "ready"
  index.usage_status = "ready"
  index.finished_at = system.get_time()
  index.aggregate_dirty = false
  index.symbols = {}
  for i, name in ipairs(names or {}) do
    index.symbols[#index.symbols + 1] = {
      name = name,
      text = name,
      kind = "class",
      path = common.normalize_path(root .. PATHSEP .. name .. ".kt"),
      file = name .. ".kt",
      relpath = name .. ".kt",
      start_line = i,
      start_col = 1,
    }
  end
  return index
end

local function seed_ready_usage_index(root, name, usages)
  local index = seed_ready_symbol_index(root, {})
  index.usages_by_name = { [name] = {} }
  for i, usage in ipairs(usages or {}) do
    local path = common.normalize_path(root .. PATHSEP .. (usage.file or ("Usage" .. tostring(i) .. ".kt")))
    index.usages_by_name[name][#index.usages_by_name[name] + 1] = common.merge({
      name = name,
      text = name,
      kind = "usage",
      path = path,
      file = usage.file or ("Usage" .. tostring(i) .. ".kt"),
      relpath = usage.file or ("Usage" .. tostring(i) .. ".kt"),
      start_line = usage.start_line or i,
      start_col = usage.start_col or 1,
      capture = usage.capture or "usage",
      is_declaration = usage.is_declaration or false,
    }, usage)
  end
  index.usage_count = #index.usages_by_name[name]
  return index
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

local function kotlin_doc(text, filename)
  local doc = Doc()
  set_text(doc, text or "package demo\n\nclass Box(val value: Int) {\n  fun doubled(): Int = value * 2\n}\n")
  doc:set_filename(filename or "example.kt", filename or "example.kt")
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

local function wait_workspace_usages(name, opts, timeout)
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
    results, reason, status = symbol_index.workspace_usages(name, call_opts)
    if status == "fresh" or status == "stale" then return results, reason, status end
    coroutine.yield(0.03)
  until system.get_time() >= deadline
  return results, reason, status
end

local function wait_workspace_references(name, opts, timeout)
  return wait_workspace_usages(name, opts, timeout)
end

local function wait_async_request(request, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    worker_pool.system():drain({ max_ms = 5, max_messages = 64 })
    if request.done then return request end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  worker_pool.system():drain({ max_ms = 5, max_messages = 64 })
  return request
end

local function wait_index_ready(root, timeout)
  local deadline = system.get_time() + (timeout or 5)
  local status
  repeat
    status = symbol_index.status(root)
    if status.status == "ready" then return status end
    coroutine.yield(0.03)
  until system.get_time() >= deadline
  return status
end

local function wait_symbol_ready_before_usages(root, timeout)
  local deadline = system.get_time() + (timeout or 5)
  local status
  repeat
    status = symbol_index.status(root)
    if status.symbol_status == "ready" and status.usage_status ~= "ready" then return status end
    if status.status == "ready" then return status end
    coroutine.yield(0)
  until system.get_time() >= deadline
  return status
end

test.describe("core.treesitter phase 3 document integration", function()
  test.it("registry loads bundled language configs and highlight queries", function()
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

    config = registry.get("example.kt", "")
    test.ok(config)
    test.equal(config.id, "kotlin")
    test.equal(config.grammar, "kotlin")
    test.ok(config.query_sources.highlights)
    test.ok(config.query_sources.outline)
    test.ok(config.query_sources.locals)
    test.ok(native.has_language("kotlin"))

    config = registry.get("script.kts", "")
    test.ok(config)
    test.equal(config.id, "kotlin")
  end)

  test.it("native index_text parses and queries without document state service", function()
    local result, err = native.index_text({
      language = "c",
      lines = { "int main(void) { return 0; }\n" },
      outline_query = "(identifier) @id",
      parse_timeout_ms = 750,
      query_timeout_ms = 20,
      match_limit = 1000,
      max_captures = 1000,
    })
    test.not_nil(result, err)
    test.equal(result.language, "c")
    test.ok(result.byte_len > 0)
    test.not_nil(result.metrics)
    test.equal(result.metrics.parse_count, 1)
    test.ok(result.metrics.parse_ms >= 0)
    test.ok(result.metrics.outline_query_ms >= 0)
    test.ok(result.outline.capture_count > 0)
    local saw_main = false
    for _, capture in ipairs(result.outline.captures) do
      if capture.capture == "id" and capture.start_line == 1 then
        saw_main = true
        break
      end
    end
    test.ok(saw_main)
  end)

  test.it("native index_text keeps outline results when usage query fails", function()
    local result, err = native.index_text({
      language = "c",
      lines = { "int main(void) { return 0; }\n" },
      outline_query = "(identifier) @id",
      usage_query = "((invalid",
      parse_timeout_ms = 750,
      query_timeout_ms = 20,
      usage_query_timeout_ms = 20,
      match_limit = 1000,
      max_captures = 1000,
      usage_max_captures = 1000,
    })
    test.not_nil(result, err)
    test.equal(result.metrics.parse_count, 1)
    test.equal(result.outline.status, "ready")
    test.ok(result.outline.capture_count > 0)
    test.equal(result.usage.status, "failed")
    test.ok(result.usage.error ~= nil)
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

  test.it("bundled Tree-sitter file/documents attach state", function()
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

    doc = kotlin_doc()
    test.ok(doc.treesitter)
    test.equal(doc.treesitter.language_id, "kotlin")
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

  test.it("Kotlin highlighting and outline use bundled Tree-sitter queries", function()
    local doc = kotlin_doc([[package demo

class Box(val value: Int) {
  fun doubled(): Int = value * 2
}

val answer = Box(21).doubled()
]])
    test.ok(wait_ready(doc))
    local tokens = ts_highlight.line_tokens(doc, 4)
    test.equal(token_type_for_text(tokens, "fun"), "keyword.function")
    test.equal(token_type_for_text(tokens, "doubled"), "function")

    local symbols = treesitter.get_document_outline(doc)
    test.ok(find_symbol(symbols, "Box", "class"))
    local doubled_symbol = find_symbol(symbols, "doubled", "function")
    test.ok(doubled_symbol)
    test.equal(doubled_symbol.signature, "()")
    test.ok(find_symbol(symbols, "answer", "variable"))
    doc:on_close()
  end)

  test.it("Tree-sitter workspace references return global syntactic matches", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-reference-index-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    mkdir(root .. PATHSEP .. "src")
    write_file(root .. PATHSEP .. "src" .. PATHSEP .. "Model.kt", [[package demo

class TargetThing(val value: Int)

fun create(): TargetThing = TargetThing(1)
]])
    write_file(root .. PATHSEP .. "src" .. PATHSEP .. "Use.kt", [[package demo

fun use(item: TargetThing): Int {
  val next = TargetThing(item.value)
  return next.value
}
]])
    write_file(root .. PATHSEP .. "src" .. PATHSEP .. "Notes.txt", [[TargetThing in text should not count]])

    local symbols, symbol_reason, symbol_status = wait_workspace_symbols("TargetThing", {
      root = root,
      force = true,
      limit = 20,
    })
    test.equal(symbol_status, "fresh", symbol_reason)
    test.ok(find_symbol(symbols, "TargetThing", "class"))

    local refs, reason, status = wait_workspace_usages("TargetThing", {
      root = root,
      include_declaration = true,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.ok(refs)
    test.equal(#refs, 5)
    local files = {}
    for _, ref in ipairs(refs) do
      files[ref.relpath] = (files[ref.relpath] or 0) + 1
      test.equal(ref.name, "TargetThing")
      test.equal(ref.language_id, "kotlin")
    end
    test.equal(files["src/Model.kt"], 3)
    test.equal(files["src/Use.kt"], 2)

    refs, reason, status = wait_workspace_usages("TargetThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 4)
    for _, ref in ipairs(refs) do
      test.not_ok(ref.is_declaration)
    end
  end)

  test.it("Tree-sitter Project search includes External and Vendored Project Directories", function()
    symbol_index.reset_for_tests()
    local original_projects = core.projects
    local root = USERDIR .. PATHSEP .. "treesitter-project-paths-root-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local external = USERDIR .. PATHSEP .. "treesitter-project-paths-external-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    mkdir(external)
    mkdir(root .. PATHSEP .. "src" .. PATHSEP .. "vendor" .. PATHSEP .. "library1")
    mkdir(root .. PATHSEP .. "generated")
    write_file(root .. PATHSEP .. "Root.kt", [[package demo

class RootThing
]])
    write_file(external .. PATHSEP .. "External.kt", [[package demo

class ExternalThing
]])
    write_file(root .. PATHSEP .. "src" .. PATHSEP .. "vendor" .. PATHSEP .. "library1" .. PATHSEP .. "Vendor.kt", [[package demo

class VendorThing
]])
    write_file(root .. PATHSEP .. "generated" .. PATHSEP .. "Excluded.kt", [[package demo

class ExcludedThing
]])

    core.projects = { Project(root) }
    project_paths.load_workspace_state(nil)
    project_paths.configure_project {
      external = {
        { path = external, label = "external-src" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
      excluded = {
        { path = "generated", label = "generated" },
      },
    }

    symbol_index.ensure_scan(root, { force = true, refresh_after_seconds = 0 })
    symbol_index.ensure_scan(external, { force = true, refresh_after_seconds = 0 })
    test.equal(wait_index_ready(root, 8).status, "ready")
    test.equal(wait_index_ready(external, 8).status, "ready")
    local symbols, reason, status = wait_workspace_symbols("Thing", { limit = 20, refresh_after_seconds = 0 }, 8)
    local external_symbols, external_reason, external_status = wait_workspace_symbols("ExternalThing", {
      root = external,
      limit = 20,
      refresh_after_seconds = 0,
    }, 8)
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "RootThing", "class"))
    local external_symbol = find_symbol(external_symbols, "ExternalThing", "class")
    test.equal(external_status, "fresh", external_reason)
    test.ok(external_symbol)
    test.ok(
      external_symbol.file == "external-src" .. PATHSEP .. "External.kt"
      or external_symbol.file == "External.kt",
      "unexpected external display path: " .. tostring(external_symbol.file)
    )
    local vendor_symbol = find_symbol(symbols, "VendorThing", "class")
    test.ok(vendor_symbol)
    test.ok(
      vendor_symbol.file == "library1" .. PATHSEP .. "Vendor.kt"
      or vendor_symbol.file == "src/vendor/library1/Vendor.kt"
      or vendor_symbol.file == "src" .. PATHSEP .. "vendor" .. PATHSEP .. "library1" .. PATHSEP .. "Vendor.kt",
      "unexpected vendored display path: " .. tostring(vendor_symbol.file)
    )
    project_paths.configure_project {}
    core.projects = original_projects
    common.rm(root, true)
    common.rm(external, true)
  end)

  test.it("Tree-sitter workspace symbol queries cache combined Project symbol metadata", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-cache-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_symbol_index(root, { "CachedThing", "CachedOther" })

    local symbols, reason, status = symbol_index.workspace_symbols("CachedThing", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "CachedThing", "class"))
    test.equal((index.diagnostics.ui or {}).combined_symbols_cache_misses or 0, 0)

    symbols, reason, status = symbol_index.workspace_symbols("Cached", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "CachedOther", "class"))
    test.equal((index.diagnostics.ui or {}).combined_symbols_cache_hits or 0, 0)
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace symbol async query matches small snapshot results", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-async-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_symbol_index(root, { "AsyncThing", "AsyncOther", "Different" })
    index.watch_running = true
    local query_artifact_dir = root .. "-query-artifacts"

    local sync_symbols, sync_reason, sync_status = symbol_index.workspace_symbols("Async", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(sync_status, "fresh", sync_reason)

    local request, reason, status = symbol_index.workspace_symbols_async("Async", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
      query_artifact_dir = query_artifact_dir,
    })
    test.equal(status, "pending", reason)
    test.not_nil(request)
    wait_async_request(request)
    test.equal(request.status, "fresh", request.reason)
    test.equal(#(request.results or {}), #(sync_symbols or {}), common.serialize({ async = request.results, sync = sync_symbols }))
    for i, symbol in ipairs(sync_symbols or {}) do
      test.equal(request.results[i] and request.results[i].name, symbol.name)
    end
    test.ok(find_symbol(request.results, "AsyncThing", "class"), common.serialize({ results = request.results, diagnostics = request.diagnostics, reason = request.reason }))
    test.ok(find_symbol(request.results, "AsyncOther", "class"))
    test.not_ok(find_symbol(request.results, "Different", "class"))
    for _, name in ipairs(system.list_dir(query_artifact_dir) or {}) do
      test.ok(not name:match("%.lua$"), "query artifact was not cleaned up: " .. tostring(name))
    end
    common.rm(root, true)
    common.rm(query_artifact_dir, true)
  end)

  test.it("Tree-sitter workspace symbol async query rejects stale snapshots", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-async-stale-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    seed_ready_symbol_index(root, { "StaleAsyncThing" })

    local request, reason, status = symbol_index.workspace_symbols_async("StaleAsync", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(status, "pending", reason)
    test.not_nil(request)
    symbol_index.invalidate(root)
    wait_async_request(request)
    test.equal(request.status, "stale-cancelled", request.reason)
    test.is_nil(request.results)
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace symbol async query rejects generation changes while index remains active", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-async-active-stale-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_symbol_index(root, { "ActiveStaleAsyncThing" })
    index.watch_running = true

    local request, reason, status = symbol_index.workspace_symbols_async("ActiveStaleAsync", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(status, "pending", reason)
    test.not_nil(request)
    index.generation = index.generation + 1
    index.status = "indexing"
    wait_async_request(request)
    test.equal(request.status, "stale-cancelled", request.reason)
    test.is_nil(request.results)
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace usage async query filters declarations from small snapshots", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-usage-async-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_usage_index(root, "AsyncUsageThing", {
      { file = "Decl.kt", is_declaration = true, capture = "definition.class" },
      { file = "UseA.kt", start_line = 3 },
      { file = "UseB.kt", start_line = 5 },
    })
    index.watch_running = true
    local query_artifact_dir = root .. "-usage-query-artifacts"

    local request, reason, status = symbol_index.workspace_usages_async("AsyncUsageThing", {
      root = root,
      include_declaration = false,
      limit = 10,
      refresh_after_seconds = 0,
      query_artifact_dir = query_artifact_dir,
    })
    test.equal(status, "pending", reason)
    test.not_nil(request)
    wait_async_request(request)
    test.equal(request.status, "fresh", request.reason)
    test.equal(#(request.results or {}), 2, common.serialize(request.results))
    for _, usage in ipairs(request.results or {}) do test.not_ok(usage.is_declaration) end
    for _, name in ipairs(system.list_dir(query_artifact_dir) or {}) do
      test.ok(not name:match("%.lua$"), "query artifact was not cleaned up: " .. tostring(name))
    end
    common.rm(root, true)
    common.rm(query_artifact_dir, true)
  end)

  test.it("Tree-sitter workspace usage async query uses persistent artifacts for oversized snapshots", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-usage-async-large-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_usage_index(root, "LargeUsageThing", {
      { file = "UseA.kt" },
      { file = "UseB.kt" },
      { file = "UseC.kt" },
    })
    index.watch_running = true
    local query_artifact_dir = root .. "-persistent-usage-query-artifacts"

    local request, reason, status = symbol_index.workspace_usages_async("LargeUsageThing", {
      root = root,
      max_snapshot_usages = 2,
      refresh_after_seconds = 0,
      query_artifact_dir = query_artifact_dir,
    })
    test.equal(status, "pending", reason)
    test.not_nil(request)
    wait_async_request(request)
    test.equal(request.status, "fresh", request.reason)
    test.equal(#(request.results or {}), 3, common.serialize(request.results))
    local request_index = request.meta and request.meta.index or index
    test.equal((request_index.diagnostics.ui or {}).persistent_usage_query_artifact_builds, 1)

    request, reason, status = symbol_index.workspace_usages_async("LargeUsageThing", {
      root = root,
      max_snapshot_usages = 2,
      include_declaration = false,
      refresh_after_seconds = 0,
      query_artifact_dir = query_artifact_dir,
    })
    test.equal(status, "pending", reason)
    wait_async_request(request)
    test.equal(request.status, "fresh", request.reason)
    test.equal((request_index.diagnostics.ui or {}).persistent_usage_query_artifact_hits, 1)
    common.rm(root, true)
    common.rm(query_artifact_dir, true)
  end)

  test.it("Tree-sitter workspace symbol sync query refuses oversized UI scans", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-sync-large-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    seed_ready_symbol_index(root, { "LargeOne", "LargeTwo", "LargeThree" })

    local symbols, reason, status = symbol_index.workspace_symbols("Large", {
      root = root,
      limit = 10,
      max_sync_query_items = 2,
      refresh_after_seconds = 0,
    })
    test.is_nil(symbols)
    test.equal(reason, "query-too-large")
    test.equal(status, "pending")
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace symbol async query uses persistent artifacts for oversized snapshots", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-async-large-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_symbol_index(root, { "LargeOne", "LargeTwo", "LargeThree" })
    index.watch_running = true
    local query_artifact_dir = root .. "-persistent-symbol-query-artifacts"

    local request, reason, status = symbol_index.workspace_symbols_async("Large", {
      root = root,
      limit = 10,
      max_snapshot_symbols = 2,
      refresh_after_seconds = 0,
      query_artifact_dir = query_artifact_dir,
    })
    test.equal(status, "pending", reason)
    test.not_nil(request)
    wait_async_request(request)
    test.equal(request.status, "fresh", request.reason)
    test.equal(#(request.results or {}), 3, common.serialize(request.results))
    local request_index = request.meta and request.meta.index or index
    test.equal((request_index.diagnostics.ui or {}).persistent_symbol_query_artifact_builds, 1)

    request, reason, status = symbol_index.workspace_symbols_async("Two", {
      root = root,
      limit = 10,
      max_snapshot_symbols = 2,
      refresh_after_seconds = 0,
      query_artifact_dir = query_artifact_dir,
    })
    test.equal(status, "pending", reason)
    wait_async_request(request)
    test.equal(request.status, "fresh", request.reason)
    test.ok(find_symbol(request.results, "LargeTwo", "class"))
    test.equal((request_index.diagnostics.ui or {}).persistent_symbol_query_artifact_hits, 1)
    common.rm(root, true)
    common.rm(query_artifact_dir, true)
  end)

  test.it("Tree-sitter workspace symbol cache invalidates when dirty open docs suppress disk symbols", function()
    symbol_index.reset_for_tests()
    local original_docs = core.docs
    local root = USERDIR .. PATHSEP .. "treesitter-symbol-dirty-cache-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local index = seed_ready_symbol_index(root, { "DirtyThing" })
    local symbol_path = common.normalize_path(root .. PATHSEP .. "DirtyThing.kt")

    local symbols, reason, status = symbol_index.workspace_symbols("DirtyThing", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "DirtyThing", "class"))
    test.equal((index.diagnostics.ui or {}).combined_symbols_cache_misses or 0, 0)

    core.docs = {
      {
        abs_filename = symbol_path,
        filename = symbol_path,
        lines = { "class DirtyThing\n" },
        is_dirty = function() return true end,
        on_close = function() end,
      },
    }
    symbols, reason, status = symbol_index.workspace_symbols("DirtyThing", {
      root = root,
      limit = 10,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.not_ok(find_symbol(symbols, "DirtyThing", "class"))
    test.equal((index.diagnostics.ui or {}).combined_symbols_cache_misses, 1)

    core.docs = original_docs
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace symbol queries do not refresh stale ready external roots by default", function()
    symbol_index.reset_for_tests()
    local original_projects = core.projects
    local root = USERDIR .. PATHSEP .. "treesitter-query-no-refresh-root-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local external = USERDIR .. PATHSEP .. "treesitter-query-no-refresh-external-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    mkdir(external)
    core.projects = { Project(root) }
    project_paths.load_workspace_state(nil)
    project_paths.configure_project {
      external = {
        { path = external, label = "external-src" },
      },
    }
    seed_ready_symbol_index(root, { "RootThing" })
    local external_index = seed_ready_symbol_index(external, { "ExternalThing" })
    external_index.finished_at = system.get_time() - 100000
    local external_generation = external_index.generation

    local symbols, reason, status = symbol_index.workspace_symbols("ExternalThing", {
      limit = 20,
      allow_stale = true,
    })
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "ExternalThing", "class"))
    test.equal(external_index.status, "ready")
    test.equal(external_index.generation, external_generation)

    project_paths.configure_project {}
    core.projects = original_projects
    common.rm(root, true)
    common.rm(external, true)
  end)

  test.it("Tree-sitter workspace symbols include extra open Project roots", function()
    symbol_index.reset_for_tests()
    local original_projects = core.projects
    local root = USERDIR .. PATHSEP .. "treesitter-open-project-root-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local external = USERDIR .. PATHSEP .. "treesitter-open-project-external-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    mkdir(external)
    core.projects = { Project(root), Project(external) }
    project_paths.load_workspace_state(nil)
    project_paths.configure_project {}
    seed_ready_symbol_index(root, { "RootThing" })
    seed_ready_symbol_index(external, { "ExternalOpenProjectThing" })

    local symbols, reason, status = symbol_index.workspace_symbols("ExternalOpenProjectThing", {
      limit = 20,
      allow_stale = true,
    })
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "ExternalOpenProjectThing", "class"))
    local resolved = project_paths.resolve(external .. PATHSEP .. "ExternalOpenProjectThing.kt")
    test.not_nil(resolved)
    test.equal(resolved.entry.path, common.normalize_path(external))

    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    core.projects = original_projects
    common.rm(root, true)
    common.rm(external, true)
  end)

  test.it("Tree-sitter workspace symbols can use autocomplete Project Path roots", function()
    symbol_index.reset_for_tests()
    local original_projects = core.projects
    local root = USERDIR .. PATHSEP .. "treesitter-autocomplete-roots-root-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local external = USERDIR .. PATHSEP .. "treesitter-autocomplete-roots-external-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    mkdir(external)
    mkdir(root .. PATHSEP .. "vendor")
    core.projects = { Project(root) }
    project_paths.load_workspace_state(nil)
    project_paths.configure_project {
      external = {
        { path = external, label = "external-src", autocomplete = false },
      },
      vendored = {
        { path = "vendor", label = "vendor", symbols = true, autocomplete = false },
      },
    }
    local root_index = seed_ready_symbol_index(root, { "RootThing" })
    root_index.symbols[#root_index.symbols + 1] = {
      name = "VendorThing",
      text = "VendorThing",
      kind = "class",
      path = common.normalize_path(root .. PATHSEP .. "vendor" .. PATHSEP .. "VendorThing.kt"),
      file = "vendor" .. PATHSEP .. "VendorThing.kt",
      relpath = "vendor" .. PATHSEP .. "VendorThing.kt",
      start_line = 10,
      start_col = 1,
    }
    seed_ready_symbol_index(external, { "ExternalThing" })

    local symbols, reason, status = symbol_index.workspace_symbols("ExternalThing", {
      kind = "autocomplete",
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.not_ok(find_symbol(symbols, "ExternalThing", "class"))

    symbols, reason, status = symbol_index.workspace_symbols("VendorThing", {
      kind = "autocomplete",
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.not_ok(find_symbol(symbols, "VendorThing", "class"))

    symbols, reason, status = symbol_index.workspace_symbols("VendorThing", {
      kind = "symbols",
      root = root,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.ok(find_symbol(symbols, "VendorThing", "class"))

    project_paths.configure_project {}
    core.projects = original_projects
    common.rm(root, true)
    common.rm(external, true)
  end)

  test.it("Tree-sitter Project indexing can start eagerly before symbol or usage queries", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-eager-usage-index-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    write_file(root .. PATHSEP .. "Model.kt", [[package demo

class EagerThing

fun make(): EagerThing = EagerThing()
]])

    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    local status = wait_index_ready(root)
    test.equal(status.status, "ready")
    test.equal(status.symbol_status, "ready")
    test.equal(status.usage_status, "ready")
    local symbols, symbol_reason, symbol_status = symbol_index.workspace_symbols("EagerThing", {
      root = root,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(symbol_status, "fresh", symbol_reason)
    test.ok(find_symbol(symbols, "EagerThing", "class"))
    test.not_nil(status.diagnostics)
    test.not_nil(status.diagnostics.phases)
    test.not_nil(status.diagnostics.phases.symbols)
    test.not_nil(status.diagnostics.phases.usages)
    test.ok((status.diagnostics.phases.symbols.worker.parse_calls or 0) >= 1)
    test.ok((status.diagnostics.phases.usages.worker.parse_calls or 0) >= 1)

    local refs, reason, usage_status = wait_workspace_usages("EagerThing", {
      root = root,
      include_declaration = false,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(usage_status, "fresh", reason)
    test.equal(#refs, 2)
    common.rm(root, true)
  end)

  test.it("Tree-sitter Project chunk adoption debounces aggregate rebuilds", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-aggregate-debounce-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    for i = 1, 5 do
      write_file(root .. PATHSEP .. string.format("Model%d.kt", i), string.format([[package demo

class DebouncedThing%d

fun make%d(): DebouncedThing%d = DebouncedThing%d()
]], i, i, i, i))
    end

    symbol_index.ensure_scan(root, { force = true, refresh_after_seconds = 0, chunk_files = 1 })
    local status = wait_index_ready(root)
    local ui = status.diagnostics and status.diagnostics.ui or {}
    test.ok((ui.chunks_adopted or 0) >= 2, common.serialize(ui))
    test.ok((ui.aggregate_rebuilds or 0) < (ui.chunks_adopted or 0), common.serialize(ui))
    status.aggregate_dirty = true
    local dirty_symbols, dirty_reason, dirty_status = symbol_index.workspace_symbols("DebouncedThing1", {
      root = root,
      refresh_after_seconds = 0,
    })
    test.is_nil(dirty_symbols)
    test.equal(dirty_status, "pending", dirty_reason)
    test.equal(dirty_reason, "aggregate-dirty")
    test.equal(status.aggregate_dirty, true)
    test.equal(((status.diagnostics and status.diagnostics.ui and status.diagnostics.ui.direct_symbol_queries) or 0), 0)
    common.rm(root, true)
  end)

  test.it("Tree-sitter Project indexing shards file batches across scheduler jobs", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-sharded-index-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    for i = 1, 6 do
      write_file(root .. PATHSEP .. string.format("Model%d.kt", i), string.format([[package demo

class ShardedThing%d

fun make%d(): ShardedThing%d = ShardedThing%d()
]], i, i, i, i))
    end

    local artifact_dir = root .. "-artifacts"
    local index = symbol_index.status(root)
    index.project_usage_cap = 4
    symbol_index.ensure_scan(root, {
      force = true,
      refresh_after_seconds = 0,
      batch_files = 1,
      max_running_index_shards = 2,
      shard_usage_budget = 2,
      artifact_dir = artifact_dir,
    })
    local status = wait_index_ready(root)
    test.equal(status.status, "ready")
    test.equal(status.symbol_status, "ready")
    test.equal(status.usage_status, "ready")

    local symbols, reason, symbol_status = symbol_index.workspace_symbols("ShardedThing", {
      root = root,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(symbol_status, "fresh", reason)
    for i = 1, 6 do
      test.ok(find_symbol(symbols, "ShardedThing" .. i, "class"), "missing ShardedThing" .. tostring(i))
    end

    local phases = status.diagnostics and status.diagnostics.phases or {}
    test.ok(((phases.symbols and phases.symbols.worker and phases.symbols.worker.coordinator_jobs) or 0) >= 1, common.serialize(phases.symbols))
    test.ok(((phases.symbols and phases.symbols.worker and phases.symbols.worker.shard_jobs) or 0) >= 6, common.serialize(phases.symbols))
    test.equal(phases.symbols.worker.files_scanned, 6)
    test.ok(((phases.usages and phases.usages.worker and phases.usages.worker.shard_jobs) or 0) >= 6, common.serialize(phases.usages))
    test.equal(phases.usages.worker.files_scanned, 6)
    test.ok(((phases.usages.worker.artifacts_sent or 0) > 0), common.serialize(phases.usages.worker))
    test.ok(((phases.symbols.worker.aggregate_jobs or 0) > 0), common.serialize(phases.symbols.worker))
    test.ok(((phases.usages.worker.aggregate_jobs or 0) > 0), common.serialize(phases.usages.worker))
    test.equal(((status.diagnostics and status.diagnostics.ui and status.diagnostics.ui.aggregate_rebuilds) or 0), 0)
    test.ok(((status.diagnostics and status.diagnostics.ui and status.diagnostics.ui.artifacts_loaded) or 0) > 0, common.serialize(status.diagnostics and status.diagnostics.ui))
    for _, name in ipairs(system.list_dir(artifact_dir) or {}) do
      test.ok(not name:match("%.lua$"), "artifact was not cleaned up: " .. tostring(name))
    end
    test.ok((status.usage_count or 0) <= 4, "usage cap exceeded: " .. tostring(status.usage_count))
    test.ok(status.usage_truncated)
    common.rm(root, true)
    common.rm(artifact_dir, true)
  end)

  test.it("Tree-sitter Project sharded usage budgets return unused reservations to later batches", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-shard-budget-return-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    for i = 1, 4 do
      write_file(root .. PATHSEP .. string.format("Model%d.kt", i), string.format([[package demo

class BudgetReturnThing%d

fun make%d(): BudgetReturnThing%d = BudgetReturnThing%d()
]], i, i, i, i))
    end

    local index = symbol_index.status(root)
    index.project_usage_cap = 200
    symbol_index.ensure_scan(root, {
      force = true,
      refresh_after_seconds = 0,
      batch_files = 1,
      max_running_index_shards = 1,
      shard_usage_budget = 80,
    })
    local status = wait_index_ready(root)
    test.equal(status.status, "ready")

    local refs, reason, usage_status = symbol_index.workspace_usages("BudgetReturnThing4", {
      root = root,
      include_declaration = false,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(usage_status, "fresh", reason)
    test.equal(#refs, 2)
    test.not_ok(symbol_index.status(root).usage_truncated)
    common.rm(root, true)
  end)

  test.it("Tree-sitter Project chunk adoption caches per-file Project path metadata", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-metadata-cache-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local lines = { "package demo", "", "class CachedMetaThing", "" }
    for i = 1, 60 do
      lines[#lines + 1] = string.format("fun make%d(): CachedMetaThing = CachedMetaThing()", i)
    end
    write_file(root .. PATHSEP .. "Model.kt", table.concat(lines, "\n"))

    local original_resolve = project_paths.resolve
    local original_display_path = project_paths.display_path
    local resolve_calls = 0
    local display_calls = 0
    project_paths.resolve = function(...)
      resolve_calls = resolve_calls + 1
      return original_resolve(...)
    end
    project_paths.display_path = function(...)
      display_calls = display_calls + 1
      return original_display_path(...)
    end

    local ok, err = pcall(function()
      symbol_index.ensure_scan(root, { force = true, refresh_after_seconds = 0, chunk_files = 1 })
      local status = wait_index_ready(root)
      test.equal(status.status, "ready")
    end)
    project_paths.resolve = original_resolve
    project_paths.display_path = original_display_path
    if not ok then error(err) end

    test.ok(resolve_calls <= 12, "expected per-file metadata cache, got resolve_calls=" .. tostring(resolve_calls))
    test.ok(display_calls <= 4, "expected per-file metadata cache, got display_calls=" .. tostring(display_calls))
    common.rm(root, true)
  end)

  test.it("Tree-sitter Project symbols become fresh before usage indexing finishes", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-decoupled-symbol-status-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    write_file(root .. PATHSEP .. "Model.kt", [[package demo

class ReadyBeforeUsages

fun make(): ReadyBeforeUsages = ReadyBeforeUsages()
]])

    symbol_index.start_project_indexing({ root = root, reason = "test", refresh_after_seconds = 0 })
    local status = wait_symbol_ready_before_usages(root)
    test.equal(status.symbol_status, "ready")
    test.equal(status.usage_status, "indexing")

    local symbols, reason, symbol_status = symbol_index.workspace_symbols("ReadyBeforeUsages", {
      root = root,
      limit = 20,
    })
    test.equal(symbol_status, "fresh", reason)
    test.ok(find_symbol(symbols, "ReadyBeforeUsages", "class"))

    status = wait_index_ready(root)
    test.equal(status.status, "ready")
    test.equal(status.usage_status, "ready")
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace usages reparse cap-skipped files when budget is available", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-usage-cap-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    write_file(root .. PATHSEP .. "A.kt", [[package demo

class AThing

fun makeA(): AThing = AThing()
]])
    write_file(root .. PATHSEP .. "B.kt", [[package demo

class BThing

fun makeB(): BThing = BThing()
]])
    local index = symbol_index.status(root)
    index.project_usage_cap = 1

    local refs, reason, status = wait_workspace_usages("BThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)
    test.ok(symbol_index.status(root).usage_truncated)

    os.remove(root .. PATHSEP .. "A.kt")
    index.project_usage_cap = 20
    refs, reason, status = wait_workspace_usages("BThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)
    common.rm(root, true)
  end)

  test.it("Tree-sitter targeted file reindex updates disk-backed Project usages", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-targeted-reindex-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local path = root .. PATHSEP .. "Model.kt"
    write_file(path, [[package demo

class OldDiskThing

fun make(): OldDiskThing = OldDiskThing()
]])

    local refs, reason, status = wait_workspace_usages("OldDiskThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    write_file(path, [[package demo

class NewDiskThing

fun make(): NewDiskThing = NewDiskThing()
]])
    local changed
    changed, reason = symbol_index.reindex_file(path, { force = true, reason = "test" })
    test.ok(changed, reason)

    refs, reason, status = wait_workspace_usages("OldDiskThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)

    refs, reason, status = wait_workspace_usages("NewDiskThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    os.remove(path)
    changed, reason = symbol_index.reindex_file(path, { force = true, reason = "delete" })
    test.ok(changed, reason)
    refs, reason, status = wait_workspace_usages("NewDiskThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)
    common.rm(root, true)
  end)

  test.it("Tree-sitter async targeted file reindex uses worker-backed single-file refresh", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-async-targeted-reindex-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local path = root .. PATHSEP .. "Model.kt"
    write_file(path, [[package demo

class AsyncOldThing

fun make(): AsyncOldThing = AsyncOldThing()
]])

    local refs, reason, status = wait_workspace_usages("AsyncOldThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    write_file(path, [[package demo

class AsyncNewThing

fun make(): AsyncNewThing = AsyncNewThing()
]])
    local matched
    matched, reason = symbol_index.reindex_file(path, { force = true, reason = "async-test" })
    test.ok(matched, reason)

    refs, reason, status = wait_workspace_usages("AsyncNewThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    }, 8)
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    refs, reason, status = wait_workspace_usages("AsyncOldThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)
    local index = symbol_index.status(root)
    test.not_nil(index and index.diagnostics and index.diagnostics.phases and index.diagnostics.phases.targeted)
    test.equal(index.diagnostics.phases.targeted.worker.native_index_jobs, 1)
    test.ok(((index.diagnostics and index.diagnostics.ui and index.diagnostics.ui.incremental_aggregate_updates) or 0) >= 1)
    test.equal(((index.diagnostics and index.diagnostics.ui and index.diagnostics.ui.aggregate_rebuilds) or 0), 0)

    common.rm(root, true)
  end)

  test.it("Tree-sitter directory dirty marking refreshes direct changed files", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-directory-dirty-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    write_file(root .. PATHSEP .. "Changed.kt", [[package demo

class BeforeWatchThing

fun make(): BeforeWatchThing = BeforeWatchThing()
]])
    write_file(root .. PATHSEP .. "Removed.kt", [[package demo

class RemovedWatchThing

fun make(): RemovedWatchThing = RemovedWatchThing()
]])

    local refs, reason, status = wait_workspace_usages("BeforeWatchThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    write_file(root .. PATHSEP .. "Changed.kt", [[package demo

class AfterWatchThing

fun make(): AfterWatchThing = AfterWatchThing()
]])
    write_file(root .. PATHSEP .. "Added.kt", [[package demo

class AddedWatchThing

fun make(): AddedWatchThing = AddedWatchThing()
]])
    os.remove(root .. PATHSEP .. "Removed.kt")

    local changed
    changed, reason = symbol_index.mark_directory_dirty(root, "test-watch")
    test.ok(changed, reason)

    refs, reason, status = wait_workspace_usages("BeforeWatchThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)

    refs, reason, status = wait_workspace_usages("AfterWatchThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    refs, reason, status = wait_workspace_usages("AddedWatchThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    refs, reason, status = wait_workspace_usages("RemovedWatchThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)
    common.rm(root, true)
  end)

  test.it("Tree-sitter async directory dirty marking uses targeted worker refresh", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-async-directory-dirty-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local src = mkdir(root .. PATHSEP .. "src")
    write_file(src .. PATHSEP .. "Changed.kt", [[package demo

class AsyncBeforeDirThing

fun make(): AsyncBeforeDirThing = AsyncBeforeDirThing()
]])
    write_file(src .. PATHSEP .. "Removed.kt", [[package demo

class AsyncRemovedDirThing

fun make(): AsyncRemovedDirThing = AsyncRemovedDirThing()
]])

    local refs, reason, status = wait_workspace_usages("AsyncBeforeDirThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    write_file(src .. PATHSEP .. "Changed.kt", [[package demo

class AsyncAfterDirThing

fun make(): AsyncAfterDirThing = AsyncAfterDirThing()
]])
    write_file(src .. PATHSEP .. "Added.kt", [[package demo

class AsyncAddedDirThing

fun make(): AsyncAddedDirThing = AsyncAddedDirThing()
]])
    os.remove(src .. PATHSEP .. "Removed.kt")

    local changed
    changed, reason = symbol_index.mark_directory_dirty(src, "async-dir-test")
    test.ok(changed, reason)

    refs, reason, status = wait_workspace_usages("AsyncAfterDirThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    }, 8)
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    refs, reason, status = wait_workspace_usages("AsyncAddedDirThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    refs, reason, status = wait_workspace_usages("AsyncBeforeDirThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)

    refs, reason, status = wait_workspace_usages("AsyncRemovedDirThing", {
      root = root,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)
    local index = symbol_index.status(root)
    test.not_nil(index and index.diagnostics and index.diagnostics.phases and index.diagnostics.phases["targeted-directory"])
    test.ok((index.diagnostics.phases["targeted-directory"].worker.native_index_jobs or 0) >= 2)
    test.ok((index.diagnostics.phases["targeted-directory"].worker.aggregate_jobs or 0) >= 1)
    test.equal(((index.diagnostics and index.diagnostics.ui and index.diagnostics.ui.aggregate_rebuilds) or 0), 0)

    common.rm(root, true)
  end)

  test.it("Tree-sitter Project watcher refreshes nested external file changes", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-project-watch-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    mkdir(root .. PATHSEP .. "src")
    write_file(root .. PATHSEP .. "src" .. PATHSEP .. "Watched.kt", [[package demo

class InitialWatchedThing

fun make(): InitialWatchedThing = InitialWatchedThing()
]])

    symbol_index.start_project_indexing({ root = root, reason = "test-watch", refresh_after_seconds = 0 })
    local status = wait_index_ready(root)
    test.equal(status.status, "ready")

    write_file(root .. PATHSEP .. "src" .. PATHSEP .. "Added.kt", [[package demo

class AddedByWatcherThing

fun make(): AddedByWatcherThing = AddedByWatcherThing()
]])

    local deadline = system.get_time() + 5
    local refs, reason, usage_status
    repeat
      refs, reason, usage_status = symbol_index.workspace_usages("AddedByWatcherThing", {
        root = root,
        include_declaration = false,
        limit = 20,
        refresh_after_seconds = 1000,
      })
      if refs and #refs == 2 then break end
      coroutine.yield(0.05)
    until system.get_time() >= deadline
    test.equal(usage_status, "fresh", reason)
    test.equal(#(refs or {}), 2)

    symbol_index.reset_for_tests()
    common.rm(root, true)
  end)

  test.it("Tree-sitter workspace usages use live Document overlays without poisoning disk index", function()
    symbol_index.reset_for_tests()
    local root = USERDIR .. PATHSEP .. "treesitter-live-usage-index-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    mkdir(root)
    local path = root .. PATHSEP .. "Model.kt"
    write_file(path, [[package demo

class OldThing

fun make(): OldThing = OldThing()
]])

    local refs, reason, status = wait_workspace_usages("OldThing", {
      root = root,
      force = true,
      include_declaration = false,
      limit = 20,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    local doc = kotlin_doc([[package demo

class NewThing

fun make(): NewThing = NewThing()
]], path)
    test.ok(wait_ready(doc, 10))

    refs, reason, status = wait_workspace_usages("OldThing", {
      root = root,
      include_declaration = false,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)

    refs, reason, status = wait_workspace_usages("NewThing", {
      root = root,
      include_declaration = false,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    doc:on_close()
    refs, reason, status = wait_workspace_usages("OldThing", {
      root = root,
      include_declaration = false,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 2)

    refs, reason, status = wait_workspace_usages("NewThing", {
      root = root,
      include_declaration = false,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    test.equal(#refs, 0)
    common.rm(root, true)
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
    test.equal(wait_index_ready(root).status, "ready")

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
