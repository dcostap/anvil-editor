local core = require "core"
local panes = require "core.panes"
local style = require "core.style"
local test = require "core.test"
local View = require "core.view"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local FileView = View:extend()
function FileView:new(path)
  FileView.super.new(self)
  self.path = path
end

local function same_rgb(a, b)
  return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

test.describe("Fuzzy Searcher Pane markers", function()
  test.before_each(function(context)
    context.set_active_view = core.set_active_view
    panes.reset_for_tests()
    core.set_active_view = function(view) core.active_view = view end
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.reset_for_tests()
    core.set_active_view = context.set_active_view
  end)

  test.it("shows each current Pane number before an open file result", function()
    local shared_path = system.absolute_path("fuzzy-pane-marker-shared.lua")
    local other_path = system.absolute_path("fuzzy-pane-marker-other.lua")
    local one = panes.create { factory = function() return FileView(shared_path) end }
    local two = panes.split(one, "right", { factory = function() return FileView(other_path) end })
    local three = panes.split(two, "right", { factory = function() return FileView(shared_path) end })
    local other_number = tostring(panes.number(two))
    local shared_numbers = tostring(panes.number(one)) .. "·" .. tostring(panes.number(three))
    local shared_compact = tostring(panes.number(one)) .. "+"
    local picker = fuzzy_searcher.open_static_results("Files", {
      { kind = "file", file = shared_path, label = shared_path, match_spans = {} },
      { kind = "path", file = other_path, abs_path = other_path, label = other_path, match_spans = {} },
    })
    picker.position.x, picker.position.y = 0, 0
    picker.size.x, picker.size.y = 900, 500
    picker:update()

    local markers = {}
    local draw_text = renderer.draw_text
    local draw_text_known_bounds = renderer.draw_text_known_bounds
    local draw_rect = renderer.draw_rect
    local set_clip_rect = renderer.set_clip_rect
    renderer.draw_text = function(font, text, x, y, color)
      if text:match("^%d") and same_rgb(color, style.titlebar_pane_number) then
        markers[text] = { font = font, text = text, x = x, color = color }
      end
      return x + font:get_width(text)
    end
    renderer.draw_text_known_bounds = function() end
    renderer.draw_rect = function() end
    renderer.set_clip_rect = function() end
    local drawn, draw_error = pcall(function() picker:draw() end)
    renderer.draw_text = draw_text
    renderer.draw_text_known_bounds = draw_text_known_bounds
    renderer.draw_rect = draw_rect
    renderer.set_clip_rect = set_clip_rect

    test.ok(drawn, draw_error)
    local marker_names = {}
    for text in pairs(markers) do marker_names[#marker_names+1] = text end
    table.sort(marker_names)
    test.ok(markers[shared_numbers] or markers[shared_compact],
      "drawn Pane markers: " .. table.concat(marker_names, ", "))
    test.not_nil(markers[other_number])
    test.ok(same_rgb(markers[other_number].color, style.titlebar_pane_number))
    test.ok(markers[other_number].font:get_size() < style.font:get_size())
  end)
end)
