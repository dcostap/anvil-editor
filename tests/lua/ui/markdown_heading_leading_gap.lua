local core = require "core"
local config = require "core.config"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"
local autocomplete = require "plugins.autocomplete"

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

local created_views = {}
local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("heading-leading-gap.md", nil)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  created_views[#created_views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 200
  view:set_wrapping_enabled(false)
  return view, buffer
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.buffer)
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
    created_views = {}
    context.old_markdown_live_editor = config.markdown_live_editor
    context.old_active_view = core.active_view
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    autocomplete.close()
    config.markdown_live_editor = context.old_markdown_live_editor
    core.active_view = context.old_active_view
    for _, view in ipairs(created_views) do
      markdown.live_render.detach(view)
      if view.buffer:is_dirty() then view.buffer:clean() end
    end
    for _, view in ipairs(created_views) do
      core.buffer_registry:remove(view.buffer, true)
    end
  end)

  test.it("keeps a heading fixed when its preceding blank line becomes text", function()
    local view, buffer = make_view("\n## Resultados")
    buffer:set_selection(1, 1)
    refresh(view)

    local preceding_height = view:get_position_visual_row_height(1, 1)
    local heading_height = view:get_position_visual_row_height(2, 1)
    local text_y = heading_text_y(view, 2, "Resultados")
    local caret_y = heading_caret_y(view, 2, 5)
    local _, heading_row_y = view:get_line_screen_position(2)
    local highlight_y = view:get_position_highlight_geometry(2, 5)
    test.ok(text_y > heading_row_y)
    test.equal(caret_y, highlight_y)

    buffer:insert(1, 1, "x")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)

    test.equal(view:get_position_visual_row_height(1, 1), preceding_height)
    test.equal(view:get_position_visual_row_height(2, 1), heading_height)
    test.equal(heading_text_y(view, 2, "Resultados"), text_y)
    test.equal(heading_caret_y(view, 2, 5), caret_y)
    test.equal(view:get_position_highlight_geometry(2, 5), highlight_y)
  end)

  test.it("keeps heading spacing stable when the caret reveals its syntax", function()
    local view, buffer = make_view("# Heading\nstuff")
    buffer:set_selection(2, 1)
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
    buffer:set_selection(1, 1)

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
    local view, buffer = make_view("# Heading\n")
    buffer:set_selection(2, 1)
    refresh(view)
    view:on_text_input("stuff")

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local _, inactive_y = view:get_line_screen_position(2)
    buffer:set_selection(1, 1)

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
    local view, buffer = make_view("# Heading")
    buffer:set_selection(1, #buffer.lines[1] + 1)
    refresh(view)
    view:on_text_input("\nstuff")

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local _, inactive_y = view:get_line_screen_position(2)
    command.perform("text:move-to-previous-line", view)

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
    local view, buffer = make_view("# Heading\nstuff")
    view:set_wrapping_enabled(true)
    buffer:set_selection(2, 1)
    refresh(view)

    local inactive_count = view:get_visual_row_count_for_line(1)
    local inactive_height = view:get_position_visual_row_height(1, 1)
    buffer:set_selection(1, 1)

    test.equal(view:get_visual_row_count_for_line(1), inactive_count)
    test.equal(view:get_position_visual_row_height(1, 1), inactive_height)
  end)

  test.it("keeps following content fixed through publication when a heading unwraps", function()
    local source = "# This rendered heading wraps across several visual rows in a narrow editor"
    local view, buffer = make_view(source .. "\nstuff")
    view.size.x = 300
    view:set_wrapping_enabled(true)
    buffer:set_selection(1, 10)
    refresh(view)

    test.ok(
      view:get_visual_row_count_for_line(1) > 1,
      "the heading must initially occupy multiple Wrapped Visual Rows"
    )
    buffer:remove(1, 10, 1, #buffer.lines[1])
    test.equal(
      view:get_visual_row_count_for_line(1), 1,
      "deleting the suffix must unwrap the heading"
    )

    local _, pending_y = view:get_line_screen_position(2)
    local instance = test.not_nil(markdown_model.peek(buffer))
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
    local view, buffer = make_view(source .. "\nstuff")
    view.size.x = 620
    view:set_wrapping_enabled(true)
    buffer:set_selection(1, #buffer.lines[1])
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
    local instance = test.not_nil(markdown_model.peek(buffer))
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

  test.it("does not transiently unwrap an active heading before publication", function()
    local source = "# Procedimiento Apagado conexión host iDrac testing testingaa"
    local view, buffer = make_view(source .. "\nstuff")
    view.size.x = 1200
    buffer:set_selection(1, #buffer.lines[1])
    core.active_view = view
    refresh(view)

    local render = test.not_nil(view:get_line_render(1))
    local marker = test.not_nil(render.fragments[1])
    local content = test.not_nil(render.fragments[2])
    test.equal(marker.text, "# ")
    test.equal(content.text:sub(-1), "a")
    local marker_width = marker.font:get_width(marker.text)
    local final_content_width = content.font:get_width(content.text:sub(1, -2))
    local view_chrome = view.size.x - linewrapping.compute_wrap_width(view)
    view.size.x = math.floor(
      view_chrome + final_content_width + marker_width / 2
    )
    view:set_wrapping_enabled(true)

    test.ok(
      view:get_visual_row_count_for_line(1) > 1,
      "the heading must initially occupy multiple Wrapped Visual Rows"
    )
    test.ok(command.perform("text:backspace"))

    test.ok(
      view:get_visual_row_count_for_line(1) > 1,
      "the pending heading must not transiently unwrap"
    )
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)
    test.ok(
      view:get_visual_row_count_for_line(1) > 1,
      "the published heading must remain wrapped"
    )
  end)

  test.it("positions autocomplete below the rendered heading row", function()
    local view, buffer = make_view("# Proce")
    buffer:set_selection(1, #buffer.lines[1])
    core.active_view = view
    refresh(view)

    autocomplete.complete({
      name = "test-markdown-heading-popup-position",
      files = ".*",
      items = { Procedimiento = "" },
    })
    test.ok(autocomplete.is_open(), "autocomplete must be open for the heading")

    local line, col = buffer:get_selection()
    local row_y, row_height = view:get_position_highlight_geometry(line, col)
    local _, popup_y = autocomplete._test.get_suggestions_rect(view)
    test.ok(
      popup_y >= row_y + row_height,
      "the autocomplete popup must not overlap the rendered heading row"
    )
  end)

  test.it("keeps spacing stable when Enter and following characters are separate edits", function()
    local view, buffer = make_view("# Heading")
    buffer:set_selection(1, #buffer.lines[1] + 1)
    refresh(view)
    view:on_text_input("\n")
    for character in ("stuff"):gmatch(".") do view:on_text_input(character) end

    local inactive_height = view:get_position_visual_row_height(1, 1)
    local _, inactive_y = view:get_line_screen_position(2)
    command.perform("text:move-to-previous-line", view)

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

  test.it("keeps a following heading aligned while exiting a task and inserting blank rows", function()
    local view, buffer = make_view(table.concat({
      "- [ ] informar FechaSuAlbaran. Obligado",
      "- [ ] informar SuAlbaranNo Obligado",
      "- [ ] ",
      "## Albaranes.",
      "```sql",
      "select CodigoEmpresa from CabeceraAlbaranProveedor",
      "```",
    }, "\n"))
    view:set_wrapping_enabled(true)
    buffer:set_selection(3, #buffer.lines[3])
    core.active_view = view
    refresh(view)

    local function assert_heading_matches_fresh(label)
      local heading_line
      for line, text in ipairs(buffer.lines) do
        if text:find("## Albaranes.", 1, true) then heading_line = line break end
      end
      heading_line = test.not_nil(heading_line)
      local _, actual_heading_y = view:get_line_screen_position(heading_line)
      local actual_text_y = heading_text_y(view, heading_line, "Albaranes.")
      local actual_heading_height = view:get_position_visual_row_height(heading_line, 1)
      local actual_row_count = view:get_visual_row_count_for_line(heading_line)

      local fresh_view, fresh_buffer = make_view(table.concat(buffer.lines))
      fresh_view:set_wrapping_enabled(true)
      fresh_buffer:set_selection(math.max(1, heading_line - 1), 1)
      refresh(fresh_view)
      linewrapping.complete_async_reconstruction(fresh_view)
      local _, expected_heading_y = fresh_view:get_line_screen_position(heading_line)
      local expected_text_y = heading_text_y(fresh_view, heading_line, "Albaranes.")
      local expected_heading_height = fresh_view:get_position_visual_row_height(heading_line, 1)
      local expected_row_count = fresh_view:get_visual_row_count_for_line(heading_line)

      test.ok(
        math.abs(actual_heading_y - expected_heading_y) <= 2,
        string.format(
          "%s left heading row at y=%s instead of fresh-layout y=%s",
          label, tostring(actual_heading_y), tostring(expected_heading_y)
        )
      )
      test.equal(
        actual_heading_height, expected_heading_height,
        string.format(
          "%s left heading height at %s instead of %s",
          label, tostring(actual_heading_height), tostring(expected_heading_height)
        )
      )
      test.equal(actual_row_count, expected_row_count)
      test.equal(actual_text_y, expected_text_y)
      return heading_line
    end

    local function assert_pending_metrics_have_one_owner(label)
      local owner = test.not_nil(view.__markdown_live_owner)
      local fallback_heights = owner.pending_metric_state
        and owner.pending_metric_state.heights or {}
      for line in pairs(owner.pending_lines or {}) do
        test.equal(
          fallback_heights[line], nil,
          string.format(
            "%s gave line %d both a pending render metric and a fallback metric",
            label, line
          )
        )
      end
    end

    test.equal(command.perform("text:newline"), true)
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    assert_pending_metrics_have_one_owner("exiting the empty task")
    assert_heading_matches_fresh("exiting the empty task")
    test.equal(command.perform("text:newline"), true)
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    assert_pending_metrics_have_one_owner("inserting the following blank row")
    assert_heading_matches_fresh("inserting the following blank row")
    buffer:set_selection(4, 1)
    test.equal(command.perform("text:backspace"), true)
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    assert_pending_metrics_have_one_owner("deleting the inserted blank row")
    assert_heading_matches_fresh("deleting the inserted blank row")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_ready(instance), instance.reason)
    linewrapping.complete_async_reconstruction(view)

    local heading_line = assert_heading_matches_fresh("semantic publication")
    test.ok(heading_line >= 4)
  end)

  test.it("keeps retained fallback metrics disjoint through consecutive edits", function()
    local lines = {}
    for line = 1, 60 do
      lines[line] = line % 5 == 0
        and ("## Heading " .. line)
        or ("ordinary Markdown line " .. line)
    end
    local view, buffer = make_view(table.concat(lines, "\n"))
    view:set_wrapping_enabled(true)
    buffer:set_selection(10, #buffer.lines[10])
    refresh(view)
    linewrapping.complete_async_reconstruction(view)

    buffer:insert(10, #buffer.lines[10], "a")
    buffer:insert(10, #buffer.lines[10], "b")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")

    local owner = test.not_nil(view.__markdown_live_owner)
    test.equal(
      owner.pending_metric_invariant_violations or 0, 0,
      "ordinary typing required metric ownership repair"
    )
    local fallback_heights = owner.pending_metric_state
      and owner.pending_metric_state.heights or {}
    for line in pairs(owner.pending_lines or {}) do
      test.equal(
        fallback_heights[line], nil,
        string.format("line %d has duplicate pending metric ownership", line)
      )
    end
  end)
end)
