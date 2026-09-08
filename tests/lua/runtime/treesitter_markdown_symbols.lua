local Buffer = require "core.buffer"
local test = require "core.test"
local treesitter = require "core.treesitter"
local registry = require "core.treesitter.registry"
local native_pool = require "worker_pool_native"

local source = "# Title #\n\n## Café\n\nUnderlined\n----------\n\n```md\n# Not a heading\n```\n\n    # Also not a heading\n"

local function check_symbols(symbols)
  test.equal(#symbols, 3)
  for i, expected in ipairs { { "Title", 1, 3 }, { "Café", 3, 4 }, { "Underlined", 5, 1 } } do
    test.equal(symbols[i].name, expected[1])
    test.equal(symbols[i].kind, "heading")
    test.equal(symbols[i].name_range.start.line, expected[2])
    test.equal(symbols[i].name_range.start.col, expected[3])
  end
end

test.describe("Markdown heading symbols", function()
  test.it("finds real headings in the current Buffer and updates after edits", function()
    local buffer = Buffer()
    buffer:insert(1, 1, source)
    buffer:set_filename("headings.md", "headings.md")
    local function wait_ready()
      for _ = 1, 300 do
        treesitter.poll_buffer(buffer)
        if buffer.treesitter and buffer.treesitter.status == "ready" then return end
        coroutine.yield(0.01)
      end
      test.ok(false, "Markdown symbol parser did not become ready")
    end
    wait_ready()
    check_symbols(treesitter.get_buffer_outline(buffer))
    buffer:insert(1, 3, "New ")
    wait_ready()
    test.equal(treesitter.get_buffer_outline(buffer)[1].name, "New Title")
    buffer:on_close()
  end)

  test.it("extracts heading records for Project Symbol Search", function()
    registry.reload()
    local language = test.not_nil(registry.get("headings.markdown", ""))
    test.equal(registry.get("headings.mdown", "").id, language.id)
    local pool = native_pool.new({ name = "markdown-symbols", worker_count = 1 })
    local handle, err = pool:submit({
      kind = "treesitter_index_text", language = language.grammar,
      path = "headings.markdown", relpath = "headings.markdown", text = source,
      outline_query = language.query_sources.outline,
      compact_project_records = true,
    })
    test.not_nil(handle, err)
    local result, failure
    for _ = 1, 300 do
      for _, message in ipairs(pool:drain({ max_messages = 64 })) do
        if message.type == "result" then result = message.result end
        if message.type == "error" then failure = message.error end
      end
      if result or failure then break end
      coroutine.yield(0.01)
    end
    pool:shutdown({ cancel_running = true })
    test.not_nil(result, failure)
    check_symbols(result:symbols({ offset = 1, limit = 100 }))
  end)
end)
