local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function wait_ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == "ready"
end

local function make_view(text)
  local doc = Doc("heading-leading-gap.md", "heading-leading-gap.md", true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 200
  view:set_wrapping_enabled(false)
  return view, doc
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.doc)
  if not instance then return end
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then system.sleep(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

local function heading_text_y(view, line, text)
  local old_draw_text = renderer.draw_text
  local text_y
  renderer.draw_text = function(font, drawn_text, x, y, color, opts)
    if drawn_text == text then text_y = y end
    return x + font:get_width(drawn_text, opts)
  end
  local ok, err = pcall(function()
    local _, line_y = view:get_line_screen_position(line)
    view:draw_line_text(line, 0, line_y)
  end)
  renderer.draw_text = old_draw_text
  if not ok then error(err, 0) end
  return test.not_nil(text_y)
end

local function heading_caret_y(view, line, col)
  local old_draw_rect = renderer.draw_rect
  local caret_y
  renderer.draw_rect = function(_, y, _, _, color)
    if color == style.caret then caret_y = y end
  end
  local ok, err = pcall(function()
    local _, line_y = view:get_line_screen_position(line, col)
    view:draw_caret(0, line_y, line, col, 1, style.caret)
  end)
  renderer.draw_rect = old_draw_rect
  if not ok then error(err, 0) end
  return test.not_nil(caret_y)
end

test.describe("Markdown heading leading spacing", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.old_markdown_live_editor
  end)

  test.it("keeps a heading fixed when its preceding blank line becomes text", function()
    local view, doc = make_view("\n## Resultados")
    doc:set_selection(1, 1)
    refresh(view)

    local preceding_height = view:get_position_visual_row_height(1, 1)
    local heading_height = view:get_position_visual_row_height(2, 1)
    local text_y = heading_text_y(view, 2, "Resultados")
    local caret_y = heading_caret_y(view, 2, 5)
    local _, heading_row_y = view:get_line_screen_position(2)
    local highlight_y = view:get_position_highlight_geometry(2, 5)
    test.ok(text_y > heading_row_y)
    test.equal(caret_y, highlight_y)

    doc:insert(1, 1, "x")
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_ready(instance), instance.reason)

    test.equal(view:get_position_visual_row_height(1, 1), preceding_height)
    test.equal(view:get_position_visual_row_height(2, 1), heading_height)
    test.equal(heading_text_y(view, 2, "Resultados"), text_y)
    test.equal(heading_caret_y(view, 2, 5), caret_y)
    test.equal(view:get_position_highlight_geometry(2, 5), highlight_y)
  end)

  test.it("keeps heading spacing stable when the caret reveals its syntax", function()
    local view, doc = make_view("# Heading\nstuff")
    doc:set_selection(2, 1)
    refresh(view)

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local inactive_render = test.not_nil(view:get_line_render(1))
    test.equal(
      inactive_height,
      test.not_nil(inactive_render.first_row_content_y_offset)
        + test.not_nil(inactive_render.text_row_height),
      "heading must not reserve trailing spacing"
    )
    local _, inactive_y = view:get_line_screen_position(2)
    doc:set_selection(1, 1)

    local active_height = view:get_position_visual_row_height(1, 1)
    local active_render = test.not_nil(view:get_line_render(1))
    test.equal(
      active_height,
      test.not_nil(active_render.first_row_content_y_offset)
        + test.not_nil(active_render.text_row_height),
      "revealed heading must not reserve trailing spacing"
    )
    local _, active_y = view:get_line_screen_position(2)
    test.equal(
      active_height, inactive_height,
      string.format("heading height changed from %d to %d", inactive_height, active_height)
    )
    test.equal(
      active_y, inactive_y,
      string.format("following line moved from %d to %d", inactive_y, active_y)
    )
  end)

  test.it("keeps typed following text from changing heading spacing on reveal", function()
    local view, doc = make_view("# Heading\n")
    doc:set_selection(2, 1)
    refresh(view)
    view:on_text_input("stuff")

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local _, inactive_y = view:get_line_screen_position(2)
    doc:set_selection(1, 1)

    local active_height = view:get_position_visual_row_height(1, 1)
    local _, active_y = view:get_line_screen_position(2)
    test.equal(
      active_height, inactive_height,
      string.format("typed heading height changed from %d to %d", inactive_height, active_height)
    )
    test.equal(
      active_y, inactive_y,
      string.format("typed following line moved from %d to %d", inactive_y, active_y)
    )
  end)

  test.it("keeps spacing stable through enter, typing, and vertical movement", function()
    local view, doc = make_view("# Heading")
    doc:set_selection(1, #doc.lines[1] + 1)
    refresh(view)
    view:on_text_input("\nstuff")

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local _, inactive_y = view:get_line_screen_position(2)
    command.perform("doc:move-to-previous-line", view)

    local active_height = view:get_position_visual_row_height(1, 1)
    local _, active_y = view:get_line_screen_position(2)
    test.equal(
      active_height, inactive_height,
      string.format("vertical move changed heading height from %d to %d", inactive_height, active_height)
    )
    test.equal(
      active_y, inactive_y,
      string.format("vertical move changed following line from %d to %d", inactive_y, active_y)
    )
  end)

  test.it("keeps spacing stable through reveal with wrapping enabled", function()
    local view, doc = make_view("# Heading\nstuff")
    view:set_wrapping_enabled(true)
    doc:set_selection(2, 1)
    refresh(view)

    local inactive_count = view:get_visual_row_count_for_line(1)
    local inactive_height = view:get_position_visual_row_height(1, 1)
    doc:set_selection(1, 1)

    test.equal(view:get_visual_row_count_for_line(1), inactive_count)
    test.equal(view:get_position_visual_row_height(1, 1), inactive_height)
  end)

  test.it("keeps following content fixed through publication when a heading unwraps", function()
    local source = "# This rendered heading wraps across several visual rows in a narrow editor"
    local view, doc = make_view(source .. "\nstuff")
    view.size.x = 300
    view:set_wrapping_enabled(true)
    doc:set_selection(1, 10)
    refresh(view)

    test.ok(
      view:get_visual_row_count_for_line(1) > 1,
      "the heading must initially occupy multiple Wrapped Visual Rows"
    )
    doc:remove(1, 10, 1, #doc.lines[1])
    test.equal(
      view:get_visual_row_count_for_line(1), 1,
      "deleting the suffix must unwrap the heading"
    )

    local _, pending_y = view:get_line_screen_position(2)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_ready(instance), instance.reason)
    local _, published_y = view:get_line_screen_position(2)

    test.equal(
      published_y, pending_y,
      string.format(
        "following content moved from %d to %d when the heading presentation published",
        pending_y, published_y
      )
    )
  end)

  test.it("keeps following content fixed through publication when a heading wraps", function()
    local source = "# Procedimiento Apagado conexión host iDrac testing testinga"
    local view, doc = make_view(source .. "\nstuff")
    view.size.x = 620
    view:set_wrapping_enabled(true)
    doc:set_selection(1, #doc.lines[1])
    refresh(view)

    test.equal(
      view:get_visual_row_count_for_line(1), 1,
      "the heading must initially occupy one Wrapped Visual Row"
    )
    view:on_text_input("a")
    test.ok(
      view:get_visual_row_count_for_line(1) > 1,
      "typing the suffix must wrap the heading"
    )

    local _, pending_y = view:get_line_screen_position(2)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_ready(instance), instance.reason)
    local _, published_y = view:get_line_screen_position(2)

    test.equal(
      published_y, pending_y,
      string.format(
        "following content moved from %d to %d when the heading presentation published",
        pending_y, published_y
      )
    )
  end)

  test.it("keeps spacing stable when Enter and following characters are separate edits", function()
    local view, doc = make_view("# Heading")
    doc:set_selection(1, #doc.lines[1] + 1)
    refresh(view)
    view:on_text_input("\n")
    for character in ("stuff"):gmatch(".") do view:on_text_input(character) end

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local _, inactive_y = view:get_line_screen_position(2)
    command.perform("doc:move-to-previous-line", view)

    local active_height = view:get_position_visual_row_height(1, 1)
    local _, active_y = view:get_line_screen_position(2)
    test.equal(
      active_height, inactive_height,
      string.format("separate edits changed heading height from %d to %d", inactive_height, active_height)
    )
    test.equal(
      active_y, inactive_y,
      string.format("separate edits moved following line from %d to %d", inactive_y, active_y)
    )
  end)
end)
