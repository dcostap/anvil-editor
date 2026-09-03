local Buffer = require "core.buffer"
local test = require "core.test"
local treesitter = require "core.treesitter"
local registry = require "core.treesitter.registry"
local native = require "treesitter"
local highlight = require "core.treesitter.highlight"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function source_buffer(filename, text)
  local buffer = Buffer()
  set_text(buffer, text)
  buffer:set_filename(filename, filename)
  return buffer
end

local function wait_ready(buffer)
  local deadline = system.get_time() + 3
  while system.get_time() < deadline do
    treesitter.poll_buffer(buffer)
    if buffer.treesitter and buffer.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function token_type(tokens, needle)
  for i = 1, #tokens, 2 do
    if tokens[i + 1] and tokens[i + 1]:find(needle, 1, true) then return tokens[i] end
  end
end

local function find_symbol(symbols, name, kind)
  for _, symbol in ipairs(symbols or {}) do
    if symbol.name == name and symbol.kind == kind then return symbol end
  end
end

test.describe("JavaScript and TypeScript Tree-sitter support", function()
  test.it("registers JavaScript, JSX, TypeScript, and TSX files", function()
    registry.reload()
    for _, expected in ipairs {
      { file = "example.js", id = "javascript", grammar = "javascript" },
      { file = "example.jsx", id = "javascript", grammar = "javascript" },
      { file = "example.mjs", id = "javascript", grammar = "javascript" },
      { file = "example.cjs", id = "javascript", grammar = "javascript" },
      { file = "example.ts", id = "typescript", grammar = "typescript" },
      { file = "example.mts", id = "typescript", grammar = "typescript" },
      { file = "example.cts", id = "typescript", grammar = "typescript" },
      { file = "example.tsx", id = "tsx", grammar = "tsx" },
    } do
      local config = test.not_nil(registry.get(expected.file, ""))
      test.equal(config.id, expected.id)
      test.equal(config.grammar, expected.grammar)
      test.ok(config.query_sources.highlights)
      test.ok(config.query_sources.outline)
      test.ok(config.query_sources.locals)
      test.ok(native.has_language(expected.grammar))
    end
  end)

  test.it("highlights and outlines JavaScript", function()
    local buffer = source_buffer("example.js", [[export class Counter {
  increment(value) { return value + 1; }
}
export function createCounter() { return new Counter(); }
]])
    test.ok(wait_ready(buffer))
    test.equal(buffer.treesitter.language_id, "javascript")
    test.equal(token_type(highlight.line_tokens(buffer, 2), "increment"), "function.method")
    local symbols = treesitter.get_buffer_outline(buffer)
    test.ok(find_symbol(symbols, "Counter", "class"))
    test.ok(find_symbol(symbols, "increment", "method"))
    test.ok(find_symbol(symbols, "createCounter", "function"))
    buffer:on_close()
  end)

  test.it("highlights and outlines TypeScript", function()
    local buffer = source_buffer("example.ts", [[interface Named { name: string }
export class Person implements Named {
  constructor(public name: string) {}
  greet(message: string): string { return message + this.name; }
}
]])
    test.ok(wait_ready(buffer))
    test.equal(buffer.treesitter.language_id, "typescript")
    test.equal(token_type(highlight.line_tokens(buffer, 4), "greet"), "function.method")
    local symbols = treesitter.get_buffer_outline(buffer)
    test.ok(find_symbol(symbols, "Named", "interface"))
    test.ok(find_symbol(symbols, "Person", "class"))
    test.ok(find_symbol(symbols, "greet", "method"))
    buffer:on_close()
  end)

  test.it("highlights JSX in TSX", function()
    local buffer = source_buffer("example.tsx", [[export function Greeting(props: { name: string }) {
  return <div className="greeting">Hello {props.name}</div>;
}
]])
    test.ok(wait_ready(buffer))
    test.equal(buffer.treesitter.language_id, "tsx")
    test.equal(token_type(highlight.line_tokens(buffer, 2), "div"), "tag")
    test.ok(find_symbol(treesitter.get_buffer_outline(buffer), "Greeting", "function"))
    buffer:on_close()
  end)
end)
