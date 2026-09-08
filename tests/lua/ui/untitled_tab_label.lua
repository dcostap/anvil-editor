local Buffer = require "core.buffer"
local Editor = require "core.editor"
local test = require "core.test"
require "plugins.untitled_tabs"

local function untitled()
  local buffer = Buffer(nil, nil, true)
  buffer.intellij_untitled = true
  buffer.intellij_untitled_name = "Untitled-1"
  return buffer, Editor(buffer)
end

test.describe("Untitled Tab labels", function()
  test.it("marks nonempty text, including whitespace, as dirty", function()
    local buffer, view = untitled()
    test.equal(view:get_name(), "Untitled-1")
    buffer:insert(1, 1, " ")
    test.equal(view:get_name(), "Untitled-1*")
    buffer:remove(1, 1, 1, 2)
    test.equal(view:get_name(), "Untitled-1")
    buffer:insert(1, 1, "\n")
    test.equal(view:get_name(), "Untitled-1*")
    buffer:remove(1, 1, 2, 1)
    test.equal(view:get_name(), "Untitled-1")
  end)

  test.it("reads a large buffer label without allocating a buffer-sized copy", function()
    local buffer, view = untitled()
    local text = string.rep(string.rep("x", 8192) .. "\n", 128)
    buffer:insert(1, 1, text)
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    local ok, name = pcall(view.get_name, view)
    local allocated = collectgarbage("count") - before
    collectgarbage("restart")
    test.ok(ok, name)
    test.equal(name, "Untitled-1*")
    test.ok(allocated < #text / 1024,
      "Reading a Tab label allocated at least one full buffer: " .. allocated .. " KB")
  end)
end)
