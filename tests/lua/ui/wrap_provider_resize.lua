local Buffer = require "core.buffer"
local TextView = require "core.textview"
local wrapping = require "core.linewrapping"
local test = require "core.test"

test.it("publishes provider changes at the current viewport width", function()
  local buffer = Buffer()
  buffer:insert(1, 1, string.rep("words ", 50) .. "\n")
  local view = TextView(buffer)
  view.size.x, view.size.y = 500, 400
  view:add_line_render_provider("resize", {
    render_line = function(_, owner, line)
      return { fragments = {
        { source_col1 = 1, source_col2 = #buffer.lines[line],
          text = buffer.lines[line]:gsub("\n$", ""), font = owner:get_font() },
      } }
    end,
  })
  view:set_wrapping_enabled(true)
  wrapping.complete_async_reconstruction(view)
  local before = view:get_visual_row_count_for_line(1)
  view.size.x = 250
  view:invalidate_line_render("resize", nil, nil, { defer_wrapped_reconstruction = true })
  wrapping.complete_async_reconstruction(view)
  local after = view:get_visual_row_count_for_line(1)
  view:on_close()
  test.ok(after > before, "provider publication kept the old viewport width")
end)
