local test = require "core.test"
local Doc = require "core.doc"
local DocView = require "core.docview"
local sticky_scroll = require "plugins.sticky_scroll"

local function make_view(text)
  local doc = Doc("sticky.md", "sticky.md", true)
  doc:insert(1, 1, text)
  local view = DocView(doc)
  view.position.x, view.position.y = 10, 20
  view.size.x, view.size.y = 500, 240
  view:set_wrapping_enabled(false)
  return view, doc
end

test.describe("sticky scroll", function()
  test.it("uses cleaned UTF-8 text when measuring indentation in binary-marked documents", function()
    local invalid_surrogate = "\237\160\128"
    local line = "  " .. invalid_surrogate .. "heading\n"
    local clean_line = line:uclean("\26", true)
    local doc = {
      binary = true,
      lines = { line },
      clean_lines = { clean_line },
      get_utf8_line = function(self, idx)
        if self.binary and self.clean_lines[idx] then return self.clean_lines[idx] end
        return self.lines[idx]
      end,
    }

    test.ok(sticky_scroll.get_level_from_indent(doc, 1) >= 0)
  end)

  test.it("uses current Markdown hierarchy while its async model rebuilds", function()
    local lines = { "# Parent", "## Child" }
    for i = 3, 24 do lines[i] = "paragraph " .. i end
    local view = make_view(table.concat(lines, "\n"))
    local data = sticky_scroll.managed_docviews[view]
    data.syntax = view.doc.syntax
    data.sticky_scroll_last_change_id = view.doc:get_change_id()
    data.sticky_scroll_model_ready = false
    data.sticky_scroll_model_building = true
    data.sticky_scroll_cache = {}
    data.sticky_scroll_level_cache = {}
    view.scroll.y = view:get_visual_row_y_offset(14)
    view.scroll.to.y = view.scroll.y

    view:update()
    test.ok(#data.sticky_lines > 0)
  end)

  test.it("lays out sticky Markdown headings with their visual row heights", function()
    local view = make_view("# Parent\n## Child\nbody")
    local base = view:get_line_height()
    view:add_visual_metric_provider("sticky-test", {
      line_height = function(_, _, line)
        if line == 1 then return base * 2 end
        if line == 2 then return base * 3 end
      end,
    })

    local layout = sticky_scroll.get_sticky_layout(view, { 2, 1 }, 3)
    test.equal(#layout, 2)
    test.equal(layout[1].line, 1)
    test.equal(layout[1].y, view.position.y)
    test.equal(layout[1].height, base * 2)
    test.equal(layout[2].line, 2)
    test.equal(layout[2].y, view.position.y + base * 2)
    test.equal(layout[2].height, base * 3)
  end)
end)
