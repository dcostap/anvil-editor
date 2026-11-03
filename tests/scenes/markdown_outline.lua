-- Measure section changes through the final Heading Outline draw, not only document scrolling.
local config = require "core.config"
local outline = require "core.markdown.heading_outline"
local style = require "core.style"
local gallery = require "scenes.markdown_gallery"
local support = require "scenes.support"
local scene = {}

-- Observe the rendered marker through the renderer boundary. No animation fields or rates are read.
-- The extra layout query is measurement overhead, shared by all runs of this scene.
function scene.observe(view)
  local probe = {}
  local draw = outline.draw
  local rounded
  local function observe_marker(x, y, w, h, radius, color)
    probe.marker_y, probe.marker_h, probe.marker_alpha = y, h, color[4] or 255
    return rounded(x, y, w, h, radius, color)
  end
  outline.draw = function(active)
    if active ~= view then return draw(active) end
    probe.layout = outline.layout(view)
    probe.marker_y, probe.marker_h, probe.marker_alpha = nil, nil, nil
    rounded = renderer.draw_rounded_rect
    renderer.draw_rounded_rect = observe_marker
    local ok, err = pcall(draw, active)
    renderer.draw_rounded_rect = rounded
    if not ok then error(err, 0) end
  end
  function probe:ready(line)
    local layout = self.layout
    local entry = layout and layout.entries[layout.current or 0]
    if not entry or (line and entry.line ~= line) or not self.marker_y then return false end
    return entry.y >= layout.y and entry.y + entry.h <= layout.y + layout.h
      and math.abs(layout.offset - layout.offset_target) < 0.5
      and math.abs(self.marker_y + self.marker_h / 2 - (entry.y + entry.h / 2)) <= 1
      and self.marker_alpha == (style.accent[4] or 255)
  end
  function probe:close() outline.draw = draw end
  return probe
end

function scene.setup(context)
  config.transitions = true
  config.disabled_transitions.markdown_heading_outline = nil
  local view = gallery.setup(context)
  context.probe = scene.observe(view)
  return view
end

function scene.ready(context)
  if not gallery.ready(context) or not context.probe:ready() then return false end
  local layout = context.probe.layout
  assert(layout.content_h > layout.h, "the outline must scroll")
  context.heading_count = #layout.entries
  return true
end

function scene.action_name(context)
  return context.settings.mode == "outline-click" and "click" or "section"
end

function scene.dispatch(context, index)
  local view = context.view
  local layout = assert(context.probe.layout, "the outline did not draw")
  local current = assert(layout.current, "the outline has no current section")
  local target
  if context.settings.mode == "outline-click" then
    -- Walk forward and backward through visible rows while the long list scrolls.
    target = current + (index % 12 < 6 and 1 or -1)
  else
    -- Mix adjacent sections with distant jumps and reversals across the complete gallery.
    local phase = (index - 1) % 4
    target = phase == 0 and current + 1 or phase == 1 and math.floor(#layout.entries * 0.75)
      or phase == 2 and current - 1 or math.floor(#layout.entries * 0.25)
  end
  local entry = assert(layout.entries[target], "the target heading is missing")
  context.expected_line = entry.line
  context.probe.layout = nil -- A previous draw cannot complete this action.
  if context.settings.mode == "outline-click" then
    assert(entry.y >= layout.y and entry.y + entry.h <= layout.y + layout.h,
      "the clicked heading must be visible")
    local x, y = entry.x + entry.w / 2, entry.y + entry.h / 2
    assert(view:on_mouse_pressed("left", x, y, 1), "the outline did not accept the click")
    view:on_mouse_released("left", x, y)
  else
    view:with_selection_state(function() view.buffer:set_selection(entry.line, entry.col) end)
    view:scroll_to_line(entry.line, false, false, { top_margin = view:get_line_height() })
  end
  assert((view.buffer:get_selection()) == entry.line, "the caret did not reach the requested heading")
end

function scene.action_ready(context)
  return (context.view.buffer:get_selection()) == context.expected_line
    and support.scroll_settled(context.view), "line=" .. context.expected_line
end

function scene.action_drawn(context)
  return context.probe:ready(context.expected_line)
end

function scene.state(context)
  return {
    lines = #context.view.buffer.lines,
    headings = context.heading_count,
    line = (context.view.buffer:get_selection()),
    outline_settled = context.probe:ready(context.expected_line),
  }
end

return scene
