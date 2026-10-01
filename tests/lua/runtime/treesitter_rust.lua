local Buffer = require "core.buffer"
local test = require "core.test"
local treesitter = require "core.treesitter"
local registry = require "core.treesitter.registry"
local highlight = require "core.treesitter.highlight"
local native_pool = require "worker_pool_native"

local source = [[pub mod geometry {
  pub struct Point<T> { pub x: T, pub y: T }
  pub struct Pair(pub i32, pub i32);
  pub struct Unit;
  pub union Bits { pub integer: u32, pub float: f32 }
  pub enum Color { Red, Rgb { value: u32 }, Indexed(u8) }
  pub trait Measure {
    type Output;
    const SCALE: i32;
    fn measure(&self) -> i32;
    fn twice(&self) -> i32 { self.measure() * 2 }
  }
  impl<T> Point<T> {
    pub fn new(x: T, y: T) -> Self { Self { x, y } }
  }
  impl Measure for Point<i32> {
    type Output = i32;
    const SCALE: i32 = 1;
    fn measure(&self) -> i32 { self.x }
  }
  pub type Coordinate = i32;
  pub const ORIGIN: i32 = 0;
  pub static TOTAL: i32 = 1;
  macro_rules! identity { ($value:expr) => { $value }; }
  pub fn distance(point: Point<i32>) -> i32 {
    let local_value = point.measure();
    struct LocalType;
    fn local_function() {}
    const LOCAL_CONST: i32 = 2;
    local_value + ORIGIN
  }
  unsafe extern "C" { fn foreign_function(value: i32) -> i32; }
}
mod external;
pub async fn run() {}
]]

local expected = {
  { "geometry", "module" },
  { "Point", "struct", "geometry" },
  { "x", "field", "Point" }, { "y", "field", "Point" },
  { "Pair", "struct", "geometry" }, { "Unit", "struct", "geometry" },
  { "Bits", "union", "geometry" },
  { "integer", "field", "Bits" }, { "float", "field", "Bits" },
  { "Color", "enum", "geometry" },
  { "Red", "enum_member", "Color" }, { "Rgb", "enum_member", "Color" },
  { "value", "field", "Rgb" }, { "Indexed", "enum_member", "Color" },
  { "Measure", "interface", "geometry" },
  { "Output", "type", "Measure" }, { "SCALE", "constant", "Measure" },
  { "measure", "method", "Measure" }, { "twice", "method", "Measure" },
  { "Point", "impl", "geometry" }, { "new", "method", "Point" },
  { "Point", "impl", "geometry" },
  { "Output", "type", "Point" }, { "SCALE", "constant", "Point" },
  { "measure", "method", "Point" },
  { "Coordinate", "type", "geometry" }, { "ORIGIN", "constant", "geometry" },
  { "TOTAL", "variable", "geometry" }, { "identity", "macro", "geometry" },
  { "distance", "function", "geometry" },
  { "foreign_function", "function", "geometry" },
  { "external", "module" }, { "run", "function" },
}

local function symbol_names(symbols)
  local out = {}
  for _, symbol in ipairs(symbols) do
    out[#out + 1] = { symbol.name, symbol.kind, symbol.parent_name }
  end
  return out
end

local function token_type(tokens, needle)
  for i = 1, #tokens, 2 do
    if tokens[i + 1]:find(needle, 1, true) then return tokens[i] end
  end
end

local function buffer_outline(text)
  local buffer = Buffer()
  buffer:insert(1, 1, text)
  buffer:set_filename("example.rs", "example.rs")
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    treesitter.poll_buffer(buffer)
    if buffer.treesitter and buffer.treesitter.status == "ready" then
      return buffer, treesitter.get_buffer_outline(buffer)
    end
    coroutine.yield(0.01)
  end
  buffer:on_close()
  error("Rust Buffer did not become ready")
end

test.describe("Rust Tree-sitter support", function()
  test.it("detects Rust files and loads the native grammar", function()
    registry.reload()
    local language = test.not_nil(registry.get("example.rs", ""))
    test.equal(language.id, "rust")
    test.ok(require("treesitter").has_language("rust"))
    test.equal(require("core.syntax").get("example.rs", "").name, "Rust")
  end)

  test.it("offers the bundled Rust Language Mode for an Untitled Buffer", function()
    require "plugins.anvil_language_rust"
    local buffer = Buffer()
    local changed, err = require("core.language_mode").set_buffer_mode(buffer, "Rust", { persist = false })
    test.ok(changed, err)
    test.equal(buffer.syntax.name, "Rust")
    test.equal(test.not_nil(buffer.treesitter).language_id, "rust")
    buffer:on_close()
  end)

  test.it("outlines Rust declarations without local names and highlights source", function()
    local buffer, symbols = buffer_outline(source)
    test.same(symbol_names(symbols), expected)
    test.equal(symbols[21].signature, "(x: T, y: T) -> Self")
    test.equal(token_type(highlight.line_tokens(buffer, 14), "new"), "function.method")
    test.equal(token_type(highlight.line_tokens(buffer, 1), "mod"), "keyword")
    test.equal(token_type(highlight.line_tokens(buffer, 2), "Point"), "type")
    buffer:on_close()
  end)

  test.it("indexes the same Rust symbols and separates usage from declaration", function()
    local language = test.not_nil(registry.get("example.rs", ""))
    local pool = native_pool.new({ name = "rust-project-test", worker_count = 1 })
    local handle, err = pool:submit({
      kind = "treesitter_index_text", language = "rust", path = "example.rs",
      relpath = "example.rs", text = source,
      outline_query = language.query_sources.outline,
      usage_query = language.query_sources.usages,
      compact_project_records = true,
      parse_timeout_ms = 1000, query_timeout_ms = 100, usage_query_timeout_ms = 100,
    })
    test.not_nil(handle, err)
    local result, failure
    local deadline = system.get_time() + 5
    while system.get_time() < deadline do
      for _, message in ipairs(pool:drain({ max_messages = 64 })) do
        if message.type == "result" then result = message.result end
        if message.type == "error" then failure = message.error end
      end
      if result or failure then break end
      coroutine.yield(0.01)
    end
    pool:shutdown({ cancel_running = true })
    test.not_nil(result, failure)
    test.same(symbol_names(result:symbols({ limit = 100 })), expected)
    local usages = result:usages({ limit = 1000 })
    local declaration, reference, local_declaration, local_reference
    for _, usage in ipairs(usages) do
      if usage.name == "ORIGIN" then
        if usage.is_declaration then declaration = usage else reference = usage end
      elseif usage.name == "local_value" then
        if usage.is_declaration then local_declaration = usage else local_reference = usage end
      end
    end
    test.equal(test.not_nil(declaration).range.start.line, 22)
    test.equal(test.not_nil(reference).range.start.line, 30)
    test.equal(test.not_nil(local_declaration).range.start.line, 26)
    test.equal(test.not_nil(local_reference).range.start.line, 30)
  end)

  test.it("keeps valid symbols before an incomplete Rust declaration", function()
    local buffer, symbols = buffer_outline("pub fn valid() {}\npub fn broken(\n")
    test.same(symbol_names(symbols), { { "valid", "function" } })
    buffer:on_close()
  end)
end)
