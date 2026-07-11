local common = require "core.common"
local registry = require "core.treesitter.registry"
local records = require "core.treesitter.project_index_records"
local native_pool = require "worker_pool_native"
local test = require "core.test"

local cases = {
  {
    language = "c",
    filename = "contract.c",
    source = "struct Outer { int value; };\r\nstatic int helper(int value) { return value + 1; }\r\nint main(void) { return helper(2); }\r\n",
    symbols = {
      { "Outer", "struct", nil, "struct Outer", { 8, 12 }, { 1, 1, 1, 28 }, { 1, 8, 1, 13 }, nil, 0, {} },
      { "helper", "function", "(int value)", "static int helper(int value)", { 12, 17 }, { 2, 1, 2, 51 }, { 2, 12, 2, 18 }, nil, 0, {} },
      { "main", "function", "(void)", "int main(void)", { 5, 8 }, { 3, 1, 3, 37 }, { 3, 5, 3, 9 }, nil, 0, {} },
    },
    usages = {
      { "helper", "definition.function", true, { 2, 12, 2, 18 }, "static int helper(int value) { return value + 1; }" },
      { "value", "definition.parameter", true, { 2, 23, 2, 28 }, "static int helper(int value) { return value + 1; }" },
      { "value", "reference", false, { 2, 39, 2, 44 }, "static int helper(int value) { return value + 1; }" },
      { "main", "definition.function", true, { 3, 5, 3, 9 }, "int main(void) { return helper(2); }" },
      { "helper", "reference", false, { 3, 25, 3, 31 }, "int main(void) { return helper(2); }" },
    },
  },
  {
    language = "cpp",
    filename = "contract.cpp",
    source = "namespace café {\nclass Box {\npublic:\n  int value() const { return 1; }\n};\n}\nint use_box() { return café::Box{}.value(); }",
    symbols = {
      { "café", "namespace", nil, "namespace café", { 11, 15 }, { 1, 1, 6, 2 }, { 1, 11, 1, 16 }, nil, 0, { 2 } },
      { "Box", "class", nil, "class Box", { 7, 9 }, { 2, 1, 5, 2 }, { 2, 7, 2, 10 }, "café", 1, { 3 } },
      { "value", "method", "()", "int value() const", { 5, 9 }, { 4, 3, 4, 34 }, { 4, 7, 4, 12 }, "Box", 2, {} },
      { "use_box", "function", "()", "int use_box()", { 5, 11 }, { 7, 1, 7, 47 }, { 7, 5, 7, 12 }, nil, 0, {} },
    },
    usages = {
      { "value", "definition.method", true, { 4, 7, 4, 12 }, "  int value() const { return 1; }" },
      { "use_box", "definition.function", true, { 7, 5, 7, 12 }, "int use_box() { return café::Box{}.value(); }" },
      { "value", "reference", false, { 7, 37, 7, 42 }, "int use_box() { return café::Box{}.value(); }" },
    },
  },
  {
    language = "odin",
    filename = "contract.odin",
    source = "package contract\n\nPoint :: struct {\n  x: int,\n}\n\nmake_point :: proc(value: int) -> Point {\n  return Point{x = value}\n}\n",
    symbols = {
      { "contract", "module", nil, "package contract", { 9, 16 }, { 1, 1, 1, 17 }, { 1, 9, 1, 17 }, nil, 0, {} },
      { "Point", "struct", nil, "Point :: struct", { 1, 5 }, { 3, 1, 5, 2 }, { 3, 1, 3, 6 }, nil, 0, {} },
      { "make_point", "function", "(value: int) -> Point", "make_point :: proc(value: int) -> Point", { 1, 10 }, { 7, 1, 9, 2 }, { 7, 1, 7, 11 }, nil, 0, {} },
    },
    usages = {
      { "contract", "definition.namespace", true, { 1, 9, 1, 17 }, "package contract" },
      { "Point", "definition.type", true, { 3, 1, 3, 6 }, "Point :: struct {" },
      { "x", "definition.field", true, { 4, 3, 4, 4 }, "  x: int," },
      { "int", "reference", false, { 4, 6, 4, 9 }, "  x: int," },
      { "make_point", "definition.function", true, { 7, 1, 7, 11 }, "make_point :: proc(value: int) -> Point {" },
      { "value", "definition.parameter", true, { 7, 20, 7, 25 }, "make_point :: proc(value: int) -> Point {" },
      { "int", "reference", false, { 7, 27, 7, 30 }, "make_point :: proc(value: int) -> Point {" },
      { "Point", "reference", false, { 7, 35, 7, 40 }, "make_point :: proc(value: int) -> Point {" },
      { "Point", "reference", false, { 8, 10, 8, 15 }, "  return Point{x = value}" },
      { "x", "reference", false, { 8, 16, 8, 17 }, "  return Point{x = value}" },
      { "value", "reference", false, { 8, 20, 8, 25 }, "  return Point{x = value}" },
    },
  },
  {
    language = "kotlin",
    filename = "contract.kt",
    source = "package contract\n\nclass Box(val value: Int) {\n  fun doubled(): Int = value * 2\n}\n\nfun broken(value: Int): Int {\n  return value +\n",
    symbols = {
      { "Box", "class", nil, "class Box(val value: Int)", { 7, 9 }, { 3, 1, 5, 2 }, { 3, 7, 3, 10 }, nil, 0, { 2 } },
      { "doubled", "function", "()", "fun doubled(): Int = value * 2", { 5, 11 }, { 4, 3, 4, 33 }, { 4, 7, 4, 14 }, "Box", 1, {} },
    },
    usages = {
      { "contract", "definition.namespace", true, { 1, 9, 1, 17 }, "package contract" },
      { "Box", "definition.type", true, { 3, 7, 3, 10 }, "class Box(val value: Int) {" },
      { "value", "definition.parameter", true, { 3, 15, 3, 20 }, "class Box(val value: Int) {" },
      { "Int", "usage", false, { 3, 22, 3, 25 }, "class Box(val value: Int) {" },
      { "doubled", "definition.function", true, { 4, 7, 4, 14 }, "  fun doubled(): Int = value * 2" },
      { "Int", "usage", false, { 4, 18, 4, 21 }, "  fun doubled(): Int = value * 2" },
      { "value", "usage", false, { 4, 24, 4, 29 }, "  fun doubled(): Int = value * 2" },
      { "broken", "usage", false, { 7, 5, 7, 11 }, "fun broken(value: Int): Int {" },
      { "value", "definition.parameter", true, { 7, 12, 7, 17 }, "fun broken(value: Int): Int {" },
      { "Int", "usage", false, { 7, 19, 7, 22 }, "fun broken(value: Int): Int {" },
      { "Int", "usage", false, { 7, 25, 7, 28 }, "fun broken(value: Int): Int {" },
      { "value", "usage", false, { 8, 10, 8, 15 }, "  return value +" },
    },
  },
  {
    language = "c",
    filename = "malformed.c",
    source = "int valid(void) { return 1; }\nint broken( {\n  return valid();\n",
    symbols = {
      { "valid", "function", "(void)", "int valid(void)", { 5, 9 }, { 1, 1, 1, 30 }, { 1, 5, 1, 10 }, nil, 0, {} },
    },
    usages = {
      { "valid", "definition.function", true, { 1, 5, 1, 10 }, "int valid(void) { return 1; }" },
      { "broken", "reference", false, { 2, 5, 2, 11 }, "int broken( {" },
      { "valid", "reference", false, { 3, 10, 3, 15 }, "  return valid();" },
    },
  },
}

local function flat_range(range)
  if not range then return nil end
  return { range.start.line, range.start.col, range["end"].line, range["end"].col }
end

local function extract(case)
  local language = test.not_nil(registry.get(case.filename, ""))
  local pool = native_pool.new({ name = "project-contract-" .. case.language, worker_count = 1 })
  local handle, submit_err = pool:submit({
    kind = "treesitter_index_text",
    language = language.grammar or language.id,
    path = case.filename,
    relpath = case.filename,
    text = case.source,
    outline_query = language.query_sources.outline,
    usage_query = language.query_sources.usages or language.query_sources.locals,
    capture_paging = false,
    line_range_lookup = false,
    compact_project_records = true,
    parse_timeout_ms = 1000,
    query_timeout_ms = 100,
    usage_query_timeout_ms = 100,
    match_limit = 50000,
    max_captures = 50000,
    usage_match_limit = 50000,
    usage_max_captures = 50000,
  })
  test.not_nil(handle, submit_err)
  local result, terminal_error
  for _ = 1, 5000 do
    for _, message in ipairs(pool:drain({ max_messages = 64 })) do
      if message.type == "result" then result = message.result end
      if message.type == "error" then terminal_error = message.error end
    end
    if result or terminal_error then break end
    coroutine.yield(0.001)
  end
  test.not_nil(result, terminal_error)
  local summary = result:summary()
  test.equal(summary.capabilities.compact_project_records, true)
  local function collect_pages(method)
    local out, offset, total = {}, 1
    repeat
      local page = result[method](result, { offset = offset, limit = 2 })
      total = page.total
      for _, record in ipairs(page) do out[#out + 1] = record end
      offset = page.next_offset
    until #out >= total
    test.equal(#out, total)
    return out
  end
  local symbols = collect_pages("symbols")
  local usages = collect_pages("usages")
  for _, symbol in ipairs(symbols) do
    if symbol.depth == 0 then
      test.equal(symbol.parent, nil)
    else
      test.ok(type(symbol.parent) == "number" and symbol.parent >= 1 and symbol.parent <= #symbols)
    end
  end
  local usage_count = #usages
  pool:shutdown({ cancel_running = true })
  local actual_symbols = {}
  for _, symbol in ipairs(symbols) do
    actual_symbols[#actual_symbols + 1] = {
      symbol.name, symbol.kind, symbol.signature, symbol.declaration,
      symbol.declaration_name_span, flat_range(symbol.range), flat_range(symbol.name_range),
      symbol.parent_name, symbol.depth, common.merge({}, symbol.children),
    }
  end
  local actual_usages = {}
  for _, usage in ipairs(usages) do
    actual_usages[#actual_usages + 1] = {
      usage.name, usage.capture, usage.is_declaration, flat_range(usage.range), usage.line_text,
    }
  end
  table.sort(actual_usages, function(a, b)
    if a[4][1] ~= b[4][1] then return a[4][1] < b[4][1] end
    if a[4][2] ~= b[4][2] then return a[4][2] < b[4][2] end
    return a[2] < b[2]
  end)
  return actual_symbols, actual_usages, usage_count
end

registry.reload()

test.describe("Tree-sitter Project index behavior contract", function()
  for _, case in ipairs(cases) do
    test.test("keeps reviewed " .. case.language .. " records for " .. case.filename, function()
      local symbols, usages, usage_count = extract(case)
      test.same(symbols, case.symbols, common.serialize(symbols))
      test.same(usages, case.usages, common.serialize(usages))
      test.equal(usage_count, #case.usages)
    end)
  end

  test.test("prefers declarations when duplicate usage captures share a range", function()
    local lines = { "target\n" }
    local range = { start_line = 1, start_col = 1, end_line = 1, end_col = 7, start_byte = 0, end_byte = 6 }
    local usages, count = records.usages_from_captures({
      common.merge({ capture = "reference" }, range),
      common.merge({ capture = "definition.function" }, range),
    }, "duplicate.c", "duplicate.c", lines, { id = "c" })
    test.equal(count, 1)
    test.equal(#usages.target, 1)
    test.equal(usages.target[1].capture, "definition.function")
    test.equal(usages.target[1].is_declaration, true)
  end)

  test.test("bounds very long declaration and line previews", function()
    local long_name = string.rep("n", 1200)
    local source = "int " .. long_name .. "(void) { return 0; }\n"
    local lines = records.lines_from_text(source)
    local symbol = records.symbols_from_captures({
      { capture = "outline.function", match_id = 1, start_line = 1, start_col = 1, end_line = 1, end_col = #source, start_byte = 0, end_byte = #source - 1 },
      { capture = "name", match_id = 1, start_line = 1, start_col = 5, end_line = 1, end_col = 5 + #long_name, start_byte = 4, end_byte = 4 + #long_name },
    }, lines)[1]
    test.ok(#symbol.declaration <= 1024)
    local usage = records.usage_from_capture("long.c", "long.c", lines, { id = "c" }, {
      capture = "reference", start_line = 1, start_col = 5, end_line = 1,
      end_col = 5 + #long_name, start_byte = 4, end_byte = 4 + #long_name,
    })
    test.ok(#usage.line_text <= 512)
  end)
end)
