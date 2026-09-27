local registry = require "core.treesitter.registry"
local native_pool = require "worker_pool_native"
local test = require "core.test"

local function symbols_for(id, source)
  local language = test.not_nil(registry.get_by_id(id))
  local pool = native_pool.new({ name = "symbol-coverage-" .. id, worker_count = 1 })
  local handle, err = pool:submit({
    kind = "treesitter_index_text",
    language = language.grammar,
    path = "coverage." .. id,
    relpath = "coverage." .. id,
    text = source,
    outline_query = language.query_sources.outline,
    compact_project_records = true,
  })
  test.not_nil(handle, err)
  local result, failure
  for _ = 1, 500 do
    for _, message in ipairs(pool:drain({ max_messages = 64 })) do
      if message.type == "result" then result = message.result end
      if message.type == "error" then failure = message.error end
    end
    if result or failure then break end
    coroutine.yield(0.01)
  end
  pool:shutdown({ cancel_running = true })
  test.not_nil(result, failure)
  return result:symbols({ offset = 1, limit = 100 })
end

local function has_symbol(symbols, name, kind)
  for _, symbol in ipairs(symbols) do
    if symbol.name == name and symbol.kind == kind then return true end
  end
  return false
end

local function count_name(symbols, name)
  local count = 0
  for _, symbol in ipairs(symbols) do
    if symbol.name == name then count = count + 1 end
  end
  return count
end

test.describe("Tree-sitter language Project symbols", function()
  test.it("indexes C declarations without pointer-depth limits", function()
    local symbols = symbols_for("c", [[
int*** deep_global;
typedef int*** DeepType;
struct Box { int*** deep_field; int (*callback)(int); };
int api(int value);
#define LIMIT 123
int use(void) { int*** local_value; return LIMIT; }
]])
    for _, expected in ipairs({
      { "deep_global", "variable" }, { "DeepType", "type" }, { "Box", "struct" },
      { "deep_field", "field" }, { "callback", "field" },
      { "api", "function" }, { "LIMIT", "macro" },
    }) do
      test.ok(has_symbol(symbols, expected[1], expected[2]), "C misses " .. expected[1])
    end
    test.ok(not has_symbol(symbols, "local_value", "variable"), "C indexes a local")
  end)

  test.it("indexes C++ declarations in namespaces and nested declarators", function()
    local symbols = symbols_for("cpp", [[
namespace demo { int*** deep_global; }
typedef int*** DeepType;
class Box { TShape*** shapes; int (*callback)(int); void reset(); };
int*** top_global;
int use() { int*** local_value; return 0; }
]])
    for _, expected in ipairs({
      { "demo", "namespace" }, { "deep_global", "variable" }, { "DeepType", "type" },
      { "Box", "class" }, { "shapes", "field" },
      { "callback", "field" }, { "reset", "method" },
      { "top_global", "variable" },
    }) do
      test.ok(has_symbol(symbols, expected[1], expected[2]), "C++ misses " .. expected[1])
    end
    test.ok(not has_symbol(symbols, "local_value", "variable"), "C++ indexes a local")
  end)

  test.it("indexes JavaScript-family variables and members without local variables", function()
    for _, id in ipairs({ "javascript", "typescript", "tsx" }) do
      local source = [[
const total = 1;
let first = 2, second = 3;
const maker = () => 1;
export const exported = 4;
export const handler = () => 1;
class Box { value = 1; method() { const local = 1; return total; } }
function outer() { function nested() {} return nested(); }
]]
      local symbols = symbols_for(id, source)
      for _, name in ipairs({ "total", "first", "second", "exported" }) do
        test.ok(has_symbol(symbols, name, "variable"), id .. " misses " .. name)
      end
      test.ok(has_symbol(symbols, "maker", "function"), id .. " misses maker")
      test.equal(count_name(symbols, "maker"), 1, id .. " lists maker twice")
      test.ok(has_symbol(symbols, "handler", "function"), id .. " misses exported handler")
      test.equal(count_name(symbols, "handler"), 1, id .. " lists handler twice")
      test.ok(has_symbol(symbols, "Box", "class"), id .. " misses Box")
      test.ok(has_symbol(symbols, "value", "field"), id .. " misses Box.value")
      test.ok(has_symbol(symbols, "method", "method"), id .. " misses Box.method")
      test.ok(not has_symbol(symbols, "local", "variable"), id .. " indexes a local")
      test.ok(not has_symbol(symbols, "nested", "function"), id .. " indexes a nested function")
    end
  end)

  test.it("indexes TypeScript-family enum members and interface fields", function()
    for _, id in ipairs({ "typescript", "tsx" }) do
      local symbols = symbols_for(id, [[
enum Mode { First, Second = 2 }
interface Spec { value: number; compute(): void }
]])
      test.ok(has_symbol(symbols, "Mode", "enum"), id .. " misses Mode")
      test.ok(has_symbol(symbols, "First", "enum_member"), id .. " misses Mode.First")
      test.ok(has_symbol(symbols, "Second", "enum_member"), id .. " misses Mode.Second")
      test.ok(has_symbol(symbols, "value", "field"), id .. " misses Spec.value")
    end
  end)

  test.it("indexes Odin file variables but not procedure variables", function()
    local symbols = symbols_for("odin", [[
package demo
global_value := 1
main :: proc() {
  local_value := 2
  _ = global_value + local_value
}
]])
    test.ok(has_symbol(symbols, "global_value", "variable"), "missing file variable")
    test.ok(not has_symbol(symbols, "local_value", "variable"), "indexed procedure variable")
  end)
end)
