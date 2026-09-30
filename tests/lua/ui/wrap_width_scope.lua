local test = require "core.test"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local centered = require "plugins.centered_editor"

test.it("keeps the centered lane stable inside its geometry scope", function()
  local cfg = config.plugins.centered_editor
  local previous = {}
  for key, value in pairs(cfg) do previous[key] = value end
  cfg.enabled, cfg.scale_width, cfg.pane_views_only = true, false, false
  cfg.min_margin, cfg.max_width = 40, 800
  local buffer = Buffer()
  buffer:insert(1, 1, "Some text that can wrap.\n")
  local view = Editor(buffer)
  view.size.x, view.size.y = 1200, 700
  local ok, err = pcall(function()
    test.ok(centered.should_center(view))
    local expected_x, expected_width = centered.get_lane_rect(view)
    local actual = centered.with_lane_geometry(view, function()
      return { centered.get_lane_rect(view) }
    end)
    test.same(actual, { expected_x, expected_width })
  end)
  for key in pairs(cfg) do cfg[key] = nil end
  for key, value in pairs(previous) do cfg[key] = value end
  view:on_close()
  if not ok then error(err, 0) end
end)
