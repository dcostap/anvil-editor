local Buffer = require "core.buffer"
local common = require "core.common"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local linewrapping = require "core.linewrapping"
local worker_pool = require "core.worker_pool"
local test = require "core.test"
local renwindow = require "renwindow"

local function drawn_path_x(view, col)
  local drawn_x
  local draw_text = renderer.draw_text
  renderer.draw_text = function(font, text, x, y, color, opts)
    local first = text:find("C:/Projects/", 1, true)
    if first then
      drawn_x = x + font:get_width(text:sub(1, first - 1 + col - 8), opts)
    end
    return draw_text(font, text, x, y, color, opts)
  end
  local window = renwindow.create("Markdown inline positions", 1000, 400)
  renderer.begin_frame(window)
  local ok, err = pcall(function() view:draw_line_text(1, 0, 0) end)
  renderer.end_frame()
  renderer.draw_text = draw_text
  if not ok then error(err, 0) end
  return test.not_nil(drawn_x, "the path must be drawn")
end

local function wait_ready(view)
  local instance = model.peek(view.buffer)
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.01) end
  end
  test.equal(instance.status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
end

local function visible_text(view, line)
  local parts = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(line))) do
    if not fragment.hidden then parts[#parts + 1] = fragment.text or "" end
  end
  return table.concat(parts)
end

test.describe("Markdown inline positions", function()
  for _, wrapped in ipairs({ false, true }) do
    test.it("aligns prose and code after a task, wrapping=" .. tostring(wrapped), function()
      local name = "inline-after-task-" .. tostring(wrapped) .. ".md"
      local buffer = Buffer(name, name, true)
      buffer:insert(1, 1, "### 1. Stock company\n"
        .. "- [ ] DECIDE WHAT TO DO LOOKING AT EXISTING SAGE CODE\n"
        .. "TODO: `C:/Projects/GLP4/src/main/appi/almacen/AlmacenData.kt:48`\n")
      local view = Editor(buffer)
      view.size.x, view.size.y = 960, 400
      view:set_wrapping_enabled(wrapped)
      markdown.live_render.refresh_view(view)
      wait_ready(view)
      buffer:set_selection(3, 1)
      test.ok(math.abs(view:get_col_x_offset(3, 1) - view:get_col_x_offset(2, 7)) < 0.5,
        "the continuation must align with the task text")
      for col = 1, 12 do
        buffer:set_selection(3, col)
        local positions = {}
        local draw_text = renderer.draw_text
        renderer.draw_text = function(font, text, x, y, color, opts)
          local source_col = text:find("TODO:", 1, true) and 1
            or text:find("C:/Projects/", 1, true) and 8
          if source_col then
            local layout = font:text_layout(text, opts)
            for i = 0, math.min(#text, 5) do
              positions[source_col + i] = x + layout:width_at(i)
            end
          end
          return draw_text(font, text, x, y, color, opts)
        end
        local window = renwindow.create("Markdown task positions", 1000, 400)
        renderer.begin_frame(window)
        local ok, err = pcall(function() view:draw_line_text(3, 0, 0) end)
        renderer.end_frame()
        renderer.draw_text = draw_text
        if not ok then error(err, 0) end
        if col ~= 7 then
          test.not_nil(positions[col], "the source character must be drawn")
          local caret_x = view:get_col_x_offset(3, col)
          test.ok(math.abs(caret_x - positions[col]) < 0.5,
            string.format("column %d: caret %.3f, drawn text %.3f", col, caret_x, positions[col]))
          local line_x, line_y = view:get_line_screen_position(3)
          local hit_line, hit_col = view:resolve_screen_position(
            line_x + positions[col], line_y + view:get_line_height() / 2)
          test.equal(hit_line, 3)
          test.equal(hit_col, col, "mouse placement must follow the drawn text")
        end
        test.equal(visible_text(view, 3):find("`", 1, true) ~= nil, col >= 7,
          "delimiters must follow the source position")
      end
      model.close(buffer, "test")
    end)
  end
  for _, wrapped in ipairs({ false, true }) do
    test.it("keeps code reveal and positions current after a line join, wrapping=" .. tostring(wrapped), function()
      local name = "inline-position-" .. tostring(wrapped) .. ".md"
      local buffer = Buffer(name, name, true)
      local path = "C:/Projects/GLP4/src/main/appi/stock/OperacionesTraspasosAlmacen.kt:338"
      buffer:insert(1, 1, "TODO: \n`" .. path .. "`\nplain\n")
      local view = Editor(buffer)
      view.size.x, view.size.y = 960, 400
      view:set_wrapping_enabled(wrapped)
      buffer:set_selection(1, 7)
      markdown.live_render.refresh_view(view)
      wait_ready(view)
      view:get_line_render(2)
      buffer:remove(1, 7, 2, 1)
      local projected = test.not_nil(
        view.__markdown_live_owner.pending_lines[1],
        "the joined line has no edit projection"
      )
      local reveal_marker
      for _, fragment in ipairs(projected.render_line.fragments or {}) do
        if fragment.markdown_reveal_col1 then reveal_marker = fragment break end
      end
      test.not_nil(reveal_marker, "the joined inline code lost its reveal range: "
        .. common.serialize(projected.render_line.fragments))

      for phase = 1, 2 do
        if phase == 2 then wait_ready(view) end
        -- Do not drain workers in phase one. Exercise the presentation used
        -- between the edit and publication of the new Markdown parse.
        for _, col in ipairs({ 1, 7, 8, 9, 12, #path + 9, 1, 9 }) do
          buffer:set_selection(1, col)
          local expected = col == 1 and "TODO: " .. path
            or "TODO: `" .. path .. "`"
          local actual = visible_text(view, 1)
          test.equal(actual, expected, string.format(
            "delimiter visibility must follow the current selection, phase=%d col=%d expected=%s actual=%s",
            phase, col, expected, actual
          ))
          if col >= 8 and col < #path + 8 then
            local x = view:get_col_x_offset(1, col)
            test.equal(view:get_x_offset_col(1, x), col,
              "caret and hit testing must use the same source position")
            local drawn_x = drawn_path_x(view, col)
            test.ok(math.abs(x - drawn_x) < 0.5,
              "the caret must align with the drawn path")
            local line_x, line_y = view:get_line_screen_position(1)
            local hit_line, hit_col = view:resolve_screen_position(
              line_x + drawn_x, line_y + view:get_line_height() / 2)
            test.equal(hit_line, 1)
            test.equal(hit_col, col, "mouse placement must follow the drawn path")
          end
        end
        buffer:set_selection(1, 1)
        local target_x = drawn_path_x(view, 9)
        local line_x, line_y = view:get_line_screen_position(1)
        view:begin_line_render_interaction("mouse-selection")
        local hit_line, hit_col = view:resolve_screen_position(
          line_x + target_x, line_y + view:get_line_height() / 2)
        test.equal(hit_line, 1)
        test.equal(hit_col, 9)
        buffer:set_selection(hit_line, hit_col)
        view:on_mouse_released("left")
        test.equal(visible_text(view, 1), "TODO: `" .. path .. "`",
          "mouse release must reveal code at the selected source position")
      end
      model.close(buffer, "test")
    end)
  end
end)
