local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local ime = require "core.ime"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"
local autocomplete = require "plugins.autocomplete"
local scale = require "plugins.scale"

local function make_view(context, live, text)
  local name = live and "wrap-caret.md" or "wrap-caret.txt"
  local buffer = Buffer(name, name, true)
  buffer:insert(1, 1, text or ("alpha beta gamma delta "):rep(80))
  local view = Editor(buffer)
  view.discard_buffer_on_close = true
  context.view = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, view:get_line_height() * 8
  config.plugins.linewrapping.width_override = view:get_font():get_width("xxxxxxxxxxxxxxxx")
  view:set_wrapping_enabled(true)
  core.set_active_view(view)
  if live then
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    local deadline = system.get_time() + 5
    while instance.status ~= "ready" and system.get_time() < deadline do
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      coroutine.yield(0.01)
    end
    test.equal(instance.status, "ready", instance.reason)
  end
  linewrapping.complete_async_reconstruction(view)
  view:update()
  return view, buffer
end

test.describe("wrapped caret geometry", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.config = {}
    for _, key in ipairs {
      "markdown_live_editor", "scroll_context_lines", "scroll_past_end", "transitions",
    } do
      context.config[key] = config[key]
    end
    context.wrap_config = {}
    for key, value in pairs(config.plugins.linewrapping) do context.wrap_config[key] = value end
    config.markdown_live_editor = true
    config.scroll_context_lines = 1
    config.scroll_past_end = true
    config.transitions = false
    config.plugins.linewrapping.mode = "letter"
    config.plugins.linewrapping.indent = false
    config.plugins.linewrapping.require_tokenization = false
  end)

  test.after_each(function(context)
    autocomplete.close()
    if context.code_scale then scale.set_code(context.code_scale) end
    if context.set_location then ime.set_location = context.set_location end
    if context.other_view then context.other_view:on_close() end
    if context.view then context.view:on_close() end
    for key, value in pairs(context.config) do config[key] = value end
    local cfg = config.plugins.linewrapping
    for key in pairs(cfg) do cfg[key] = context.wrap_config[key] end
    for key, value in pairs(context.wrap_config) do cfg[key] = value end
    core.active_view = context.active_view
  end)

  test.it("keeps caret geometry local to each Text View of a shared Buffer", function(context)
    local view, buffer = make_view(context, false)
    local start_col, end_col = view:get_visual_row_bounds_for_line(1, 3)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    local expected = { view:get_line_screen_position(1, end_col, true) }
    local other = Editor(buffer)
    context.other_view = other
    core.set_active_view(other)
    other:set_selection_state { selections = { 1, 1, 1, 1 }, last_selection = 1 }

    test.same({ view:get_caret_screen_position(1, end_col) }, expected)
    view:scroll_to_make_visible(1, end_col)
    core.set_active_view(view)
    test.same({ view:get_caret_screen_position(1, end_col) },
      { view:get_line_screen_position(1, end_col, true) })
  end)

  test.it("keeps a visual-end caret at the same screen height during code zoom", function(context)
    local view, buffer = make_view(context, false)
    config.plugins.linewrapping.width_override = function(owner)
      return owner:get_font():get_width("xxxxxxxxxxxxxxxx")
    end
    local start_col, end_col = view:get_visual_row_bounds_for_line(1, 10)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    view:update()
    local _, before_y = view:get_line_screen_position(1, end_col, true)
    context.code_scale = scale.get_code()

    scale.set_code(context.code_scale * 1.2)

    local _, after_y = view:get_line_screen_position(1, end_col, true)
    test.ok(math.abs(after_y - before_y) < 0.01, "zoom must preserve the visible caret row")
  end)

  test.it("places completion suggestions beside the caret when a symbol spans wrapped rows", function(context)
    local view, buffer = make_view(context, false, string.rep("x", 80))
    local start_col, end_col = view:get_visual_row_bounds_for_line(1, 2)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    autocomplete.complete {
      name = "wrap-caret-completion", files = ".*",
      items = { [string.rep("x", end_col + 1)] = "" },
    }
    test.ok(autocomplete.is_open())
    local _, caret_y = view:get_line_screen_position(1, end_col, true)
    local popup_y
    local draw_rect, draw_text = renderer.draw_rect, renderer.draw_text
    local set_clip_rect = renderer.set_clip_rect
    renderer.set_clip_rect = function() end
    renderer.draw_rect = function(_, y, _, _, color)
      if color == style.background3 then popup_y = popup_y or y end
    end
    renderer.draw_text = function(font, text, x) return x + font:get_width(text) end
    local ok, err = pcall(autocomplete.draw, view)
    renderer.draw_rect, renderer.draw_text = draw_rect, draw_text
    renderer.set_clip_rect = set_clip_rect
    if not ok then error(err, 0) end

    test.ok(test.not_nil(popup_y) >= caret_y + view:get_line_height(),
      "the completion popup must start below the caret, not below the symbol's first row")
  end)

  test.it("anchors the system IME rectangle to the visual end of a wrapped row", function(context)
    local view, buffer = make_view(context, false)
    local start_col, end_col = view:get_visual_row_bounds_for_line(1, 3)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    local x, y = view:get_line_screen_position(1, end_col, true)
    local location
    context.set_location = ime.set_location
    ime.set_location = function(lx, ly) location = { lx, ly } end

    view:update_ime_location()

    test.same(location, { x, y })
  end)

  test.it("scrolls when a mouse move changes the caret row without changing its Buffer position", function(context)
    local view, buffer = make_view(context, false)
    local start_col, end_col = view:get_visual_row_bounds_for_line(1, 10)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    view:update()
    local scroll_y = view.scroll.to.y
    local selection = { buffer:get_selection() }
    local x, y = view:get_line_screen_position(1, end_col, false)

    test.ok(command.perform("core:set_cursor", x, y + view:get_line_height() / 2))
    view:on_mouse_released("left", x, y)
    test.same({ buffer:get_selection() }, selection)
    view:update()

    test.ok(view.scroll.to.y > scroll_y, "the next visual row must receive scroll context")
  end)

  test.it("updates the system IME when only the caret row changes", function(context)
    local view, buffer = make_view(context, false)
    local _, end_col = view:get_visual_row_bounds_for_line(1, 3)
    local x, y = view:get_line_screen_position(1, end_col, false)
    local location
    context.set_location = ime.set_location
    ime.set_location = function(lx, ly) location = { lx, ly } end
    buffer:set_selection(1, end_col)
    view:update_ime_location()

    local end_x, end_y = view:get_line_screen_position(1, end_col, true)
    test.ok(command.perform("core:set_cursor", end_x, end_y + view:get_line_height() / 2))
    view:on_mouse_released("left", end_x, end_y)
    view:update_ime_location()

    test.same(location, { end_x, end_y })
    test.ok(end_y < y and end_x > x)
  end)

  test.it("keeps both visual positions available at the same wrap boundary", function(context)
    local view, buffer = make_view(context, false)
    local _, end_col = view:get_visual_row_bounds_for_line(1, 3)
    buffer:set_selection(1, end_col - 1)
    test.ok(command.perform("core:move_to_next_char"))
    local selection = { buffer:get_selection() }
    local end_x, end_y = view:get_caret_screen_position(1, end_col)
    test.same({ end_x, end_y }, { view:get_line_screen_position(1, end_col, true) })

    test.ok(command.perform("core:move_to_next_char"))
    test.ok(command.perform("core:move_to_previous_char"))

    test.same({ buffer:get_selection() }, selection)
    local start_x, start_y = view:get_caret_screen_position(1, end_col)
    test.same({ start_x, start_y }, { view:get_line_screen_position(1, end_col, false) })
    test.ok(start_y > end_y and start_x < end_x)
  end)

  test.it("moves the system IME rectangle with the visible caret during scrolling", function(context)
    local view, buffer = make_view(context, false)
    local start_col, end_col = view:get_visual_row_bounds_for_line(1, 10)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    local location
    context.set_location = ime.set_location
    ime.set_location = function(x, y) location = { x, y } end
    view:update()
    local before = { view:get_line_screen_position(1, end_col, true) }

    view.scroll.y = view.scroll.y + view:get_line_height()
    view:update_ime_location()

    test.equal(location[1], before[1])
    test.equal(location[2], before[2] - view:get_line_height())
  end)

  test.it("selects the complete Buffer without scrolling away from a visual-end caret", function(context)
    local view, buffer = make_view(context, false)
    local start_col = view:get_visual_row_bounds_for_line(1, 10)
    buffer:set_selection(1, start_col + 1)
    test.ok(command.perform("core:move_to_end_of_line"))
    view:update()
    local scroll_y = view.scroll.to.y

    test.ok(command.perform("core:select_all"))
    view:update()

    test.equal(view.scroll.to.y, scroll_y)
    test.equal(buffer:get_selection_text(), buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines]))
  end)

  for _, action in ipairs {
    "core:select_to_end_of_line", "core:move_to_next_char", "core:select_to_next_char",
    "typing", "mouse",
  } do
    test.it("keeps scrolling on the visible row after " .. action, function(context)
      local view, buffer = make_view(context, false, string.rep("x", 800))
      local _, end_col = view:get_visual_row_bounds_for_line(1, 10)
      buffer:set_selection(1, end_col - 1)
      view:update()
      local scroll_y = view.scroll.to.y
      if action == "typing" then
        view:on_text_input("x")
      elseif action == "mouse" then
        local x, y = view:get_line_screen_position(1, end_col, true)
        test.ok(command.perform("core:set_cursor", x, y + view:get_line_height() / 2))
        view:on_mouse_released("left", x, y)
      else
        test.ok(command.perform(action))
      end
      view:update()

      test.equal(select(2, buffer:get_selection()), end_col)
      test.equal(view.scroll.to.y, scroll_y)
    end)
  end

  for _, live in ipairs { false, true } do
    local mode = live and "Markdown Live Preview" or "Standard Editor"
    test.it("keeps the scroll position when End stays on the same row in " .. mode, function(context)
      local view, buffer = make_view(context, live)
      local start_col, end_col = view:get_visual_row_bounds_for_line(1, 10)
      buffer:set_selection(1, start_col + 1)
      view:update()
      local scroll_y = view.scroll.to.y
      test.ok(scroll_y > 0, "the caret must reach the lower scroll context boundary")

      test.ok(command.perform("core:move_to_end_of_line"))
      test.same({ buffer:get_selection() }, { 1, end_col, 1, end_col })
      view:update()

      test.equal(view.scroll.to.y, scroll_y, "End must not scroll to the next wrapped row")
      test.equal(view.scroll.y, scroll_y)
    end)
  end
end)
