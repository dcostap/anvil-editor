local core = require "core"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local panes = require "core.panes"
local poi = require "core.poi"
local test = require "core.test"

test.describe("Remote POI navigation", function()
  test.it("advances a hidden source without previewing or focusing it", function()
    local source = TextView(Buffer())
    source.buffer:insert(1, 1, "first\nsecond\n")
    source.remote_poi_source = true
    local opened, previewed
    source.get_points_of_interest = function()
      return {
        { line = 1, col = 1, activate = function(_, point, opts)
          opened = { line = point.line, pane = opts.pane }
          return true
        end },
        { line = 2, col = 1, activate = function(_, point, opts)
          opened = { line = point.line, pane = opts.pane }
          return true
        end },
      }
    end
    source.preview_point_of_interest = function() previewed = true end
    local project = {}
    local focused = core.active_view
    test.ok(poi.set_remote_source(source, { project = project }))
    test.ok(poi.navigate_remote(1, { project = project }))
    test.equal(opened.line, 1)
    test.equal(opened.pane, panes.active())
    test.equal(core.active_view, focused)
    test.equal(previewed, nil)
    test.ok(poi.navigate_remote(1, { project = project }))
    test.equal(opened.line, 2)
    test.equal(source.buffer:get_selection(), 2)
    poi.clear_remote_source(source, project)
    source.buffer:on_close()
  end)

  test.it("requires explicit remote support and isolates Projects", function()
    local source = TextView(Buffer())
    local first, second = {}, {}
    test.equal(poi.set_remote_source(source, { project = first }), false)
    source.remote_poi_source = true
    test.ok(poi.set_remote_source(source, { project = first }))
    test.equal(poi.get_remote_source(first), source)
    test.equal(poi.get_remote_source(second), nil)
    poi.clear_remote_source(source, first)
    test.equal(poi.get_remote_source(first), nil)
    source.buffer:on_close()
  end)

  test.it("previews local navigation without activating the POI", function()
    local source = TextView(Buffer())
    source.buffer:insert(1, 1, "first\nsecond\n")
    local previewed, activated
    source.get_points_of_interest = function()
      return {{ line = 2, col = 1, activate = function() activated = true end }}
    end
    source.preview_point_of_interest = function(_, point) previewed = point.line end
    source.buffer:set_selection(1, 1)
    test.ok(poi.navigate(source, 1))
    test.equal(previewed, 2)
    test.equal(activated, nil)
    source.buffer:on_close()
  end)
end)
