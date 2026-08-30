local core = require "core"
local BufferRegistry = require "core.buffer_registry"
local command = require "core.command"
local Editor = require "core.editor"
local panes = require "core.panes"
local Preview = require "plugins.tabular_data_preview"
local test = require "core.test"
local view_icons = require "core.view_icons"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.01) end
  return predicate()
end

local function wait_ready(view)
  return wait_until(function() return view.parse_status == "ready" end, 2)
end

test.describe("Tabular Data Preview", function()
  local saved
  local path
  local extra_path
  local editor
  local previews

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      buffers = core.buffers,
      buffer_registry = core.buffer_registry,
      active_view = core.active_view,
      set_active_view = core.set_active_view,
      global_prompt_enter = core.global_prompt_bar.enter,
      renderer_draw_rect = renderer.draw_rect,
      renderer_draw_rounded_rect = renderer.draw_rounded_rect,
      renderer_draw_text = renderer.draw_text,
      renderer_set_clip_rect = renderer.set_clip_rect,
      clipboard = system.get_clipboard(),
    }
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    core.set_active_view = function(view) core.active_view = view end
    previews = {}
    extra_path = nil
    local suffix = system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    path = USERDIR .. PATHSEP .. "tabular-preview-" .. suffix .. ".csv"
    write_file(path, "Name,Age,Note\nAda,37,first\nBob,40,second\n")
    editor = core.open_file(path)
  end)

  test.after_each(function()
    for _, view in ipairs(previews) do view:on_close() end
    panes.reset_for_tests()
    core.buffers = saved.buffers
    core.buffer_registry = saved.buffer_registry
    core.active_view = saved.active_view
    core.set_active_view = saved.set_active_view
    core.global_prompt_bar.enter = saved.global_prompt_enter
    renderer.draw_rect = saved.renderer_draw_rect
    renderer.draw_rounded_rect = saved.renderer_draw_rounded_rect
    renderer.draw_text = saved.renderer_draw_text
    renderer.set_clip_rect = saved.renderer_set_clip_rect
    system.set_clipboard(saved.clipboard or "")
    os.remove(path)
    if extra_path then os.remove(extra_path) end
  end)

  local function remember(view)
    previews[#previews + 1] = view
    return view
  end

  test.it("registers both commands as View openers", function()
    for _, name in ipairs {
      "tabular_data:open_preview",
      "tabular_data:open_preview_to_the_side",
    } do
      local metadata = test.not_nil(command.get_metadata(name))
      test.equal(metadata.opens_view, true)
    end
    test.not_nil(view_icons.get("tabular_data"))
  end)

  test.it("does not expose Preview commands for unsupported Editors", function()
    extra_path = path:gsub("%.csv$", ".txt")
    write_file(extra_path, "plain text\n")
    local unsupported = core.open_file(extra_path)
    test.ok(unsupported:is(Editor))
    test.not_ok(command.is_valid("tabular_data:open_preview"))
    test.not_ok(command.is_valid("tabular_data:open_preview_to_the_side"))
  end)

  test.it("opens in the current Pane and Back restores the source Editor", function()
    test.ok(command.is_valid("tabular_data:open_preview"))
    test.ok(command.perform("tabular_data:open_preview"))
    local view = remember(panes.active().current_view)
    test.ok(view:is(Preview))
    test.equal(view.buffer, editor.buffer)
    test.equal(panes.history_length(panes.active()), 2)
    test.equal(panes.back(), editor)
    test.equal(panes.forward(), view)
  end)

  test.it("opens to the side with the same Buffer", function()
    local source_pane = panes.active()
    test.ok(command.perform("tabular_data:open_preview_to_the_side"))
    local preview_pane = panes.active()
    local view = remember(preview_pane.current_view)
    test.not_equal(preview_pane, source_pane)
    test.equal(view.buffer, editor.buffer)
    test.equal(source_pane.current_view, editor)
  end)

  test.it("creates a side Preview when one exists in source history", function()
    command.perform("tabular_data:open_preview")
    local current_preview = remember(panes.active().current_view)
    panes.back()

    command.perform("tabular_data:open_preview_to_the_side")
    local side_preview = remember(panes.active().current_view)
    test.not_equal(side_preview, current_preview)
    test.equal(panes.count(), 2)
    test.equal(side_preview.buffer, editor.buffer)
  end)

  test.it("reuses a matching Preview in the source Pane", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    panes.back()
    command.perform("tabular_data:open_preview")
    test.equal(panes.active().current_view, view)
  end)

  test.it("updates after source Buffer edits", function()
    command.perform("tabular_data:open_preview_to_the_side")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    local revision = view.published_revision
    editor.buffer:insert(3, #editor.buffer.lines[3], "\nCara,25,third")
    test.ok(wait_until(function()
      return view.parse_status == "ready" and view.published_revision ~= revision
    end, 2))
    test.equal(view:row_count(), 3)
    test.equal(view:cell_value(3, 1), "Cara")
  end)

  test.it("updates while suspended behind its source Editor", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    panes.back()
    local revision = view.published_revision
    editor.buffer:insert(3, #editor.buffer.lines[3], "\nCara,25,third")
    test.ok(wait_until(function()
      return view.parse_status == "ready" and view.published_revision ~= revision
    end, 2))
    test.equal(view:cell_value(3, 1), "Cara")
  end)

  test.it("sorts and filters displayed rows without changing source data", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view:cycle_sort(2)
    test.equal(view:cell_value(1, 1), "Ada")
    view:cycle_sort(2)
    test.equal(view:cell_value(1, 1), "Bob")
    view:cycle_sort(2)
    test.equal(view:cell_value(1, 1), "Ada")

    view:toggle_filter_value(1, "Bob")
    test.equal(view:row_count(), 1)
    test.equal(view:cell_value(1, 2), "40")
    test.equal(
      table.concat(editor.buffer.lines),
      "Name,Age,Note\nAda,37,first\nBob,40,second\n"
    )
  end)

  test.it("uses OR within one column and AND across columns", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view:toggle_filter_value(1, "Ada")
    view:toggle_filter_value(1, "Bob")
    test.equal(view:row_count(), 2)
    view:toggle_filter_value(2, "37")
    test.equal(view:row_count(), 1)
    test.equal(view:cell_value(1, 1), "Ada")
  end)

  test.it("keeps missing values after real values in both sort directions", function()
    write_file(path, "A,B\nx\nz,1\ny,2\n")
    editor.buffer:reload()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view:cycle_sort(2)
    test.equal(view:cell_value(1, 1), "z")
    test.equal(view:cell_value(3, 1), "x")
    test.equal(view:cell_value(3, 2), false)
    view:cycle_sort(2)
    test.equal(view:cell_value(1, 1), "y")
    test.equal(view:cell_value(3, 1), "x")
  end)

  test.it("opens a Pane-scoped value filter prompt", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    local captured
    core.global_prompt_bar.enter = function(_, label, options)
      captured = { label = label, options = options }
    end

    test.ok(view:open_filter_prompt(1))
    test.equal(captured.label, "Filter Name")
    test.equal(captured.options.pane_scope, panes.active())
    local bob
    for _, item in ipairs(captured.options.suggest("Bob")) do
      if item.has_value and item.value == "Bob" then bob = item; break end
    end
    test.not_nil(bob)
    captured.options.submit(bob.text, bob)
    test.equal(view:row_count(), 1)
    test.equal(view:cell_value(1, 1), "Bob")
  end)

  test.it("copies complete cell values through mouse input", function()
    write_file(path, 'Name,Note\nAda,"first\nsecond"\n')
    editor.buffer:reload()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view.position = { x = 0, y = 0 }
    view.size = { x = 700, y = 400 }
    local hx, hy, _, hh = view:column_screen_rect(2)
    test.ok(view:on_mouse_pressed("right", hx + 10, hy + hh / 2, 1))
    test.equal(system.get_clipboard(), "Note")
    local x, y, w, h = view:cell_screen_rect(1, 2)
    test.ok(view:on_mouse_pressed("right", x + w / 2, y + h / 2, 1))
    test.equal(system.get_clipboard(), "first\nsecond")
  end)

  test.it("selects a dragged cell range and copies it as TSV", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view.position = { x = 0, y = 0 }
    view.size = { x = 700, y = 400 }

    local x1, y1, w1, h1 = view:cell_screen_rect(1, 1)
    local x2, y2, w2, h2 = view:cell_screen_rect(2, 2)
    test.ok(view:on_mouse_pressed("left", x1 + w1 / 2, y1 + h1 / 2, 1))
    test.ok(view:on_mouse_moved(x2 + w2 / 2, y2 + h2 / 2, 0, 0))
    test.ok(view:on_mouse_released("left", x2 + w2 / 2, y2 + h2 / 2))

    test.same({ view:selection_bounds() }, { 1, 1, 2, 2 })
    test.ok(view:copy_selection())
    test.equal(system.get_clipboard(), "Ada\t37\nBob\t40")
  end)

  test.it("moves and extends the active cell through Preview commands", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))

    test.ok(view:select_cell(1, 1))
    test.ok(command.perform("tabular_data:move_right"))
    test.same({ view:selection_bounds() }, { 1, 2, 1, 2 })
    test.ok(command.perform("tabular_data:extend_down"))
    test.same({ view:selection_bounds() }, { 1, 2, 2, 2 })
    test.ok(command.perform("tabular_data:select_all"))
    test.same({ view:selection_bounds() }, { 1, 1, 2, 3 })
  end)

  test.it("draws the table after horizontal and vertical scrolling", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view.position = { x = 10, y = 20 }
    view.size = { x = 420, y = 180 }
    view.scroll.x, view.scroll.to.x = 60, 60
    view.scroll.y, view.scroll.to.y = 10, 10
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end
    renderer.set_clip_rect = function() end
    view:update()
    view:draw()
    test.ok(true)
  end)

  test.it("resizes one column through mouse input", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view.position = { x = 0, y = 0 }
    view.size = { x = 700, y = 400 }
    local first, second = view.column_widths[1], view.column_widths[2]
    local x, y = view:column_divider_screen_position(1)
    test.ok(view:on_mouse_pressed("left", x, y, 1))
    view:on_mouse_moved(x + 40, y, 40, 0)
    view:on_mouse_released("left", x + 40, y)
    test.equal(view.column_widths[1], first + 40)
    test.equal(view.column_widths[2], second)
  end)

  test.it("restores its file and presentation state", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view:cycle_sort(2)
    view:toggle_filter_value(1, "Ada")
    view.column_widths[1] = view.column_widths[1] + 20
    view.scroll.x, view.scroll.to.x = 12, 12
    local state = view:get_state()

    local restored = remember(test.not_nil(Preview.from_state(state)))
    test.ok(wait_ready(restored))
    test.equal(restored.buffer, view.buffer)
    test.equal(restored.sort.column, 2)
    test.equal(restored.sort.direction, "ascending")
    test.equal(restored:row_count(), 1)
    test.equal(restored.column_widths[1], view.column_widths[1])
    test.equal(restored.scroll.x, 12)
  end)

  test.it("restores a filter for missing cells", function()
    write_file(path, "A,B\nx\nz,1\n")
    editor.buffer:reload()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    test.ok(wait_ready(view))
    view:toggle_filter_value(2, false)
    local restored = remember(test.not_nil(Preview.from_state(view:get_state())))
    test.ok(wait_ready(restored))
    test.equal(restored:row_count(), 1)
    test.equal(restored:cell_value(1, 1), "x")
    test.equal(restored:cell_value(1, 2), false)
  end)

  test.it("removes listeners and Buffer retention when closed", function()
    command.perform("tabular_data:open_preview")
    local view = remember(panes.active().current_view)
    local before = core.buffer_registry:reference_count(editor.buffer)
    test.ok(before >= 2)
    view:on_close()
    test.equal(core.buffer_registry:reference_count(editor.buffer), before - 1)
    test.is_nil(editor.buffer.text_change_listeners[view.listener_id])
    test.is_nil(editor.buffer.metadata_listeners[view.listener_id])
  end)
end)
