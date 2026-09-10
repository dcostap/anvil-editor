local test = require "core.test"
local diffview = require "plugins.diffview"
local syntax = require "core.syntax"

require "plugins.language_lua"

test.it("highlights generated comparisons using their source paths without disk identities", function()
  local view = assert(diffview.open({
    contents = {
      diffview.content.text("local before = 1\n", { source_path = USERDIR .. "/before.lua" }),
      diffview.content.text("local after = 2\n", { source_path = USERDIR .. "/after.lua" }),
    },
    editable_policy = "read-only",
  }, true))
  local ok, failure = xpcall(function()
    for _, side in ipairs { view.buffer_view_a, view.buffer_view_b } do
      local buffer = side.buffer
      test.not_equal(buffer.syntax, syntax.plain_text_syntax)
      local keyword = false
      for _, kind, text in buffer.highlighter:each_token(1) do
        if text == "local" and kind ~= "normal" then keyword = true end
      end
      test.ok(keyword, "Lua keywords must receive syntax highlighting")
      test.equal(buffer.filename, nil)
      test.equal(buffer.abs_filename, nil)
      buffer:reset_syntax()
      test.not_equal(buffer.syntax, syntax.plain_text_syntax)
    end
  end, debug.traceback)
  view:on_close()
  if not ok then error(failure) end
end)

test.it("provides Kotlin syntax analysis for generated comparison content", function()
  local treesitter = require "core.treesitter"
  local view = assert(diffview.open({
    contents = {
      diffview.content.text("fun before(): Int = 1\n", { source_path = USERDIR .. "/before.kt" }),
      diffview.content.text("fun after(): Int = 2\n", { source_path = USERDIR .. "/after.kt" }),
    },
    editable_policy = "read-only",
  }, true))
  local ok, failure = xpcall(function()
    local buffer = view.buffer_view_b.buffer
    local deadline = system.get_time() + 5
    local found = false
    while not found and system.get_time() < deadline do
      treesitter.poll_buffer(buffer)
      for _, symbol in ipairs(treesitter.get_buffer_outline(buffer) or {}) do
        if symbol.name == "after" then found = true end
      end
      if not found then coroutine.yield(0.01) end
    end
    test.ok(found, "Kotlin comparison content must retain syntax analysis")
    test.equal(buffer.abs_filename, nil)
  end, debug.traceback)
  view:on_close()
  if not ok then error(failure) end
end)
