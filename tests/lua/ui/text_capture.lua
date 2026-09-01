local Buffer = require "core.buffer"
local TextView = require "core.textview"
local View = require "core.view"
local command = require "core.command"
local core = require "core"
local panes = require "core.panes"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function buffer_text(buffer)
  return table.concat(buffer.lines)
end

test.describe("Text Capture", function()
  test.before_each(function()
    panes.reset_for_tests()
    panes.create { factory = function() return View() end }
  end)

  test.after_each(function(context)
    local picker = core.fuzzy_searcher_active_view
    if picker and picker.close then pcall(function() picker:close() end) end
    if context.preview_buffer then context.preview_buffer:on_close() end
    panes.reset_for_tests()
  end)

  test.it("captures the top Fuzzy Searcher with all loaded results", function(context)
    local picker = fuzzy_searcher.open_static_results("needle", {
      { kind = "file", label = "src/first.lua", file = "src/first.lua" },
      {
        kind = "grep", file = "src/second.lua", line = 8, col = 4,
        text = "second loaded result",
      },
      {
        kind = "path", path = "C:/Projects/third", label = "C:/Projects/third",
        is_folder = true, modified_label = "2 days ago",
      },
    }, { status = "3 loaded results" })
    picker.selected = 2
    picker.viewport_offset = 2
    picker.has_more = true
    local preview_buffer = Buffer()
    context.preview_buffer = preview_buffer
    preview_buffer:insert(1, 1, "preview first line\npreview second line\n")
    picker.preview_view = TextView(preview_buffer)

    test.ok(command.perform("core:open_text_capture"))

    test.is_nil(core.root_panel:modal_input_owner())
    local capture = panes.active().current_view
    test.ok(capture and capture:extends(TextView))
    test.ok(capture.buffer.read_only)
    local text = buffer_text(capture.buffer)
    test.contains(text, "Query: needle")
    test.contains(text, "Status: 3 loaded results")
    test.contains(text, "src/first.lua")
    test.contains(text, "src/second.lua:8:4")
    test.contains(text, "second loaded result")
    test.contains(text, "C:/Projects/third")
    test.contains(text, "More results: yes")
    test.contains(text, "Selected result: 2")
    test.contains(text, "preview first line")
    test.contains(text, "preview second line")
  end)
end)
