local Buffer = require "core.buffer"
local Editor = require "core.editor"
local tab = require "core.tab"
local test = require "core.test"

-- Seam: the Tab item that the Title Bar and the Project Sidebar draw.
test.describe("File Tab icons", function()
  test.it("shows the file type icon for a plain text file", function()
    local buffer = Buffer()
    buffer.abs_filename = USERDIR .. PATHSEP .. "main.odin"
    local item = tab.describe({ id = 1, current_view = Editor(buffer) })
    test.same(item.icon, { kind = "file", path = buffer.abs_filename })
  end)

  test.it("shows a file icon for an Untitled Buffer", function()
    local item = tab.describe({ id = 1, current_view = Editor(Buffer()) })
    test.equal(item.icon and item.icon.kind, "file")
  end)
end)
