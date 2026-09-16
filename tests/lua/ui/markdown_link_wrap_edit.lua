local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(buffer)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function positions(view, label)
  local first = test.not_nil(view.buffer.lines[1]:find(label, 1, true))
  local result = {}
  for col = first, first + #label do
    local x, y = view:get_line_screen_position(1, col)
    result[#result + 1] = { x, y }
  end
  return result
end

test.describe("Markdown link wrapping during edits", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.transitions = config.transitions
    config.markdown_live_editor = true
    config.transitions = false
  end)

  test.after_each(function(context)
    if context.view then context.view:release_owned_features("test") end
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.transitions = context.transitions
  end)

  for _, kind in ipairs({ "wiki", "markdown" }) do
    test.it("keeps wrapped " .. kind .. " labels in place when preceding text changes", function(context)
      local label = "Comparison of consumption and actual hours against the planned hours"
      local link = kind == "wiki" and "[[Report#" .. label .. "]]"
        or "[" .. label .. "](https://example.com/report)"
      local filename = "link-wrap-edit-" .. kind .. ".md"
      local buffer = Buffer(filename, filename, true)
      buffer:insert(1, 1, "- [ ] Priority: compare consumption " .. link .. "\n")
      local view = Editor(buffer)
      context.view = view
      view.size.x, view.size.y = 500, 500
      view:set_wrapping_enabled(true)
      core.set_active_view(view)
      buffer:set_selection(1, 15)
      markdown.live_render.refresh_view(view)
      ready(buffer)
      wrapping.complete_async_reconstruction(view)
      view:update()
      test.ok(view:get_visual_row_count_for_line(1) > 1, "the link must wrap")

      for _, text in ipairs({ "a", "longer ", "" }) do
        if text == "" then
          buffer:remove(1, 15, 1, 18)
        else
          view:on_text_input(text)
        end
        test.equal(model.peek(buffer).status, "pending")
        view:update()
        local pending = positions(view, label)
        ready(buffer)
        wrapping.complete_async_reconstruction(view)
        view:update()
        test.same(positions(view, label), pending,
          "parser publication moved an unchanged link label")
      end
    end)
  end
end)
