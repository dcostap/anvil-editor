local core = require "core"
local command = require "core.command"
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

test.describe("Markdown image embed at a line end", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.transitions = config.transitions
    context.load_image = canvas.load_image
    config.markdown_live_editor = true
    config.transitions = false
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
  end)

  test.after_each(function(context)
    if context.view then context.view:release_owned_features("test") end
    if context.image_path then os.remove(context.image_path) end
    canvas.load_image = context.load_image
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.transitions = context.transitions
  end)

  test.it("keeps the caret after the line's end when End reveals a wrapping embed", function(context)
    local image_path = USERDIR .. PATHSEP .. "markdown-image-line-end-" .. system.get_process_id() .. ".png"
    context.image_path = image_path
    local file = test.not_nil(io.open(image_path, "wb"))
    file:write("png")
    file:close()
    local filename = image_path:match("[^/\\]+$")
    local buffer = Buffer(image_path .. ".md", image_path .. ".md", true)
    local prose = "Screenshot of the production dashboard "
    local text = prose .. "![[" .. filename .. "|Shot]]"
    buffer:insert(1, 1, text .. "\nnext\n")
    local view = Editor(buffer)
    context.view = view
    view:set_wrapping_enabled(true)
    core.active_view = view
    buffer:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    ready(buffer)
    -- The rendered line, with the embed's short label, fits on one row. Its revealed source does not.
    local font = view:get_font()
    view.size.x = view:get_gutter_width() + font:get_width(prose) + font:get_width(filename) / 2
    view.size.y = 500
    wrapping.complete_async_reconstruction(view)
    view:update()
    buffer:set_selection(1, 1)
    view:update()
    local _, rows = view:get_line_render_position_rows(1)
    test.equal(#test.not_nil(rows), 1, "the rendered line must fit on one row")

    core.active_view = view
    test.ok(command.perform("core:move_to_end_of_line", view))
    view:update()
    wrapping.complete_async_reconstruction(view)
    view:update()
    local line, col = buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, #text + 1)
    _, rows = view:get_line_render_position_rows(1)
    test.ok(#test.not_nil(rows) > 1, "the revealed embed must wrap")
    -- The caret stays with the line's last character instead of the row the reveal emptied.
    local last_x, last_y = view:get_line_screen_position(1, #text)
    local caret_x, caret_y = view:get_line_screen_position(1, #text + 1)
    test.equal(caret_y, last_y, "the caret stayed on a row the revealed source left")
    test.ok(caret_x > last_x, "the caret is not after the revealed source")
  end)
end)
