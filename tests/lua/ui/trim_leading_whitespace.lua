local core = require "core"
local command = require "core.command"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

require "plugins.trimwhitespace"
require "core.commands.text"

test.describe("Trim leading whitespace", function()
  test.it("trims every line, preserves other whitespace, and supports undo", function()
    local previous = core.active_view
    local buffer = Buffer()
    local view = TextView(buffer)
    local source = "  first  \n\t second\t\n \t\n\nlast"
    buffer:insert(1, 1, source)
    core.set_active_view(view)
    view:with_selection_state(function()
      buffer:set_selection(1, 4)
    end)
    local ok, err = pcall(function()
      test.ok(command.perform("editor:trim_leading_whitespace"))
      test.equal(table.concat(buffer.lines), "first  \nsecond\t\n\n\nlast\n")
      test.same(view:get_selection_state().selections, { 1, 2, 1, 2 })
      test.ok(command.perform("core:undo"))
      test.equal(table.concat(buffer.lines), source .. "\n")
      test.same(view:get_selection_state().selections, { 1, 4, 1, 4 })
    end)
    if previous then core.set_active_view(previous) end
    buffer:on_close()
    if not ok then error(err, 0) end
  end)
end)
