local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local style = require "core.style"
local tab = require "core.tab"
local test = require "core.test"

local function describe_file(path)
  local buffer = Buffer()
  buffer.abs_filename = path
  return tab.describe({ id = 1, current_view = Editor(buffer) })
end

-- The texts that a Tab draws, from left to right.
local function drawn(item, width, opts)
  local draw_text, texts = renderer.draw_text, {}
  renderer.draw_text = function(font, text, x)
    texts[#texts + 1] = text
    return x + font:get_width(text)
  end
  local ok, err = pcall(tab.draw, item, 0, 0, width, 28 * SCALE, opts)
  renderer.draw_text = draw_text
  if not ok then error(err, 0) end
  return texts
end

-- Seam: the Tab item that the Title Bar and the Project Sidebar draw.
test.describe("File Tabs", function()
  test.it("shows the file type icon for a plain text file", function()
    local path = USERDIR .. PATHSEP .. "main.odin"
    test.same(describe_file(path).icon, { kind = "file", path = path })
  end)

  test.it("shows a file icon for an Untitled Buffer", function()
    local item = tab.describe({ id = 1, current_view = Editor(Buffer()) })
    test.equal(item.icon and item.icon.kind, "file")
  end)

  test.it("names the file's folder relative to the Project root", function()
    local root = core.root_project().path
    local nested = describe_file(table.concat({ root, "odin_core", "testing", "doc.odin" }, PATHSEP))
    test.equal(nested.dir, "odin_core" .. PATHSEP .. "testing" .. PATHSEP)
    test.equal(describe_file(root .. PATHSEP .. "main.odin").dir, nil)
  end)

  test.it("cuts leading folders before the name when space is short", function()
    local sep = PATHSEP
    local item = { id = 1, name = "doc.odin", dir = "odin_core" .. sep .. "testing" .. sep }
    local opts = { name_color = style.text, dir = true }
    local font = style.font
    local full = font:get_width(item.dir .. item.name)
    test.same(drawn(item, full + 4, opts), { item.dir, "doc.odin" })
    local short = "\u{2026}" .. sep .. "testing" .. sep
    test.same(drawn(item, font:get_width(short .. item.name) + 1, opts), { short, "doc.odin" })
    test.same(drawn(item, font:get_width(item.name) + 1, opts), { "doc.odin" })
    test.same(drawn(item, full + 4, { name_color = style.text }), { "doc.odin" })
  end)
end)
