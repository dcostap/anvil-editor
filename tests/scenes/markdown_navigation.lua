-- Navigation in one wrapped Markdown Pane. Fixture setup is outside measurement.
local core = require "core"
local command = require "core.command"
local panes = require "core.panes"
local gallery = require "scenes.markdown_gallery"
local support = require "scenes.support"
local scene = {}

local actions = {
  { "history-back", "core:navigate_back", "far_line" },
  { "history-forward", "core:navigate_forward", "line" },
  { "paragraph-previous", "editor:move_caret_previous_paragraph", "previous_line" },
  { "paragraph-next", "editor:move_caret_next_paragraph", "line" },
  { "burst-down", "core:move_to_next_line" },
  { "burst-up", "core:move_to_previous_line" },
}

local function action(index)
  return actions[(index - 1) % #actions + 1]
end

local function selection(view)
  return view.buffer:get_selection()
end

local function target_visible(context)
  local view = context.view
  local y, height, suppressed = view:get_position_highlight_geometry(
    context.expected_line, context.expected_col, false)
  return not suppressed and y >= view.position.y and y + height <= view.position.y + view.size.y
end

local function movement_key(name)
  for _, key in ipairs(require("core.keymap").get_bindings(name) or {}) do
    if not key:find("+", 1, true) then return key end
  end
  error("Navigation scene needs an unmodified binding for " .. name)
end

local function generate(context)
  local file = assert(io.open(context.path(context.settings.note), "wb"))
  -- Twenty lines per section. The blank lines at offsets 2 and 5 bound one paragraph.
  local section = {
    "## Equipment section", "",
    "A **formatted paragraph** with *emphasis*, `inline code`, and [a link](https://example.invalid). "
      .. "Check the equipment before changing its operating mode. Repeat the inspection after each change. "
      .. "The operator records the result in the production log. Café, almacén, producción.",
    "Keep the previous result until the new inspection ends.", "",
    "- First item with **important text**", "- Second item with `code`", "",
    "> A quote with *emphasis* and more words.", "",
    "| Name | Value |", "| --- | --- |", "| Supply | Ready |", "",
    "```lua", "local ready = true", "```", "",
    "The last paragraph ends this section.", "",
  }
  local text = table.concat(section, "\n") .. "\n"
  file:write(text:rep(90))
  file:close()
end

function scene.setup(context)
  if context.settings.generate then generate(context) end
  local view = gallery.setup(context)
  context.serial = 0
  context.revision = view.buffer.text_revision
  context.keys = { movement_key("core:move_to_next_line"), movement_key("core:move_to_previous_line") }
  local draw, draw_line_text = view.draw, view.draw_line_text
  view.draw = function(self, ...)
    context.drawn_serial = nil
    return draw(self, ...)
  end
  view.draw_line_text = function(self, line, ...)
    local result = draw_line_text(self, line, ...)
    if line == context.expected_line and target_visible(context) then context.drawn_serial = context.serial end
    return result
  end
  return view
end

function scene.ready(context)
  if not gallery.ready(context) then return false end
  if not context.history_ready then
    local view = context.view
    local pane = assert(panes.pane_for_view(view))
    assert(#panes.ordered() == 1, "navigation scene needs one Pane")
    for _, key in ipairs { "far_line", "line", "previous_line" } do
      local line = context.settings[key]
      assert(view.buffer.lines[line] == "\n", "navigation target must be a fixture paragraph boundary: " .. key)
    end
    -- Save two places without drawing the distant one. Its first measured visit can build new rows.
    for _, line in ipairs { context.settings.far_line, context.settings.line } do
      view:with_selection_state(function() view.buffer:set_selection(line, 1) end)
      view:scroll_to_line(line, false, true)
      panes.record_location(pane)
    end
    context.history_ready = true
    core.log_quiet("Navigation scene ready: lines=%d near=%d far=%d burst=%d",
      #view.buffer.lines, context.settings.line, context.settings.far_line, context.settings.burst_count)
    return false
  end
  return support.scroll_settled(context.view)
end

function scene.action_name(context, index)
  local name = action(index)[1]
  return name .. (index <= #actions and "-first" or "-return")
end

function scene.dispatch(context, index)
  local view, step = context.view, action(index)
  assert(core.active_view == view, "navigation scene lost input focus")
  context.serial = context.serial + 1
  context.drawn_serial = nil
  local before_line, before_col = selection(view)
  if step[3] then
    context.expected_line, context.expected_col = context.settings[step[3]], 1
    assert(command.perform(step[2]), "navigation command was not handled: " .. step[2])
  else
    local down = step[1] == "burst-down"
    local key = context.keys[down and 1 or 2]
    -- Exercise keymap predicates and handlers, not OS input delivery.
    for _ = 1, context.settings.burst_count do
      assert(core.on_event("keypressed", key), "navigation key was not handled")
      core.on_event("keyreleased", key)
    end
    local line, col = selection(view)
    local direction = down and 1 or -1
    assert((line - before_line) * direction > 0
      or line == before_line and (col - before_col) * direction > 0,
      "navigation burst did not move in the requested direction")
    context.expected_line, context.expected_col = line, col
  end
  local line, col = selection(view)
  assert(line == context.expected_line and col == context.expected_col, "navigation reached the wrong destination")
  assert(line ~= before_line or col ~= before_col, "navigation did not move")
  assert(view.buffer.text_revision == context.revision, "navigation edited the Buffer")
end

function scene.action_ready(context)
  local view = context.view
  assert(core.active_view == view, "navigation changed input focus")
  assert(view:is_wrapping_enabled() and view.__markdown_live_attached,
    "navigation lost wrapped Markdown Live Preview")
  local line, col = selection(view)
  assert(line == context.expected_line and col == context.expected_col, "navigation lost its destination")
  if view.__async_wrap_reconstruction or not support.scroll_settled(view) then return false end
  if not target_visible(context) then return false end
  return true, string.format("line=%d col=%d", line, col)
end

function scene.action_drawn(context)
  return context.drawn_serial == context.serial
end

scene.action_visible = scene.action_drawn

function scene.state(context)
  assert(context.view.buffer.text_revision == context.revision, "navigation edited the Buffer")
  assert(context.drawn_serial == context.serial, "navigation destination did not draw")
  assert(#panes.ordered() == 1, "navigation changed the Pane count")
  return { lines = #context.view.buffer.lines, line = selection(context.view),
    actions = context.serial, panes = #panes.ordered() }
end

return scene
