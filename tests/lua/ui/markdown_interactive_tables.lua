local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local markdown_tables = require "core.markdown.tables"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_view(text, filename)
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename(filename or "interactive-table.md", nil)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 300
  view:set_wrapping_enabled(false)
  return view, buffer
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.buffer)
  local deadline = system.get_time() + 5
  while instance and instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then system.sleep(0.001) end
  end
  test.equal(test.not_nil(instance).status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
end

local function table_cells(view, line)
  local cells = {}
  for _, fragment in ipairs(test.not_nil(view:get_line_render(line)).fragments or {}) do
    if fragment.table_cell then cells[#cells + 1] = fragment end
  end
  return cells
end

local function cell_center(view, line, column)
  local render = test.not_nil(view:get_line_render(line))
  local x = 0
  for _, fragment in ipairs(render.fragments or {}) do
    local width = fragment.width or 0
    if fragment.table_cell and fragment.table_column == column then
      local line_x, line_y = view:get_line_screen_position(line)
      return line_x + x + width / 2, line_y + (render.table_row_height or view:get_line_height()) / 2
    end
    x = x + width
  end
  error("table cell not found")
end

local function table_control(view, line, kind, index)
  for _, fragment in ipairs(test.not_nil(view:get_line_render(line)).fragments or {}) do
    if fragment.table_insert_control == kind
    and (index == nil or fragment.table_insert_after == index)
    then
      return fragment
    end
  end
end

test.describe("Markdown Interactive Table Editing", function()
  test.before_each(function(context)
    context.live = config.markdown_live_editor
    context.interactive = config.markdown_live_interactive_tables
    config.markdown_live_editor = true
    config.markdown_live_interactive_tables = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.live
    config.markdown_live_interactive_tables = context.interactive
  end)

  test.it("keeps the grid rendered while a body cell is active", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:set_selection(3, 4)
    refresh(view)

    local cells = table_cells(view, 3)
    test.equal(#cells, 2)
    test.ok(test.not_nil(view:get_line_render(3)).table_row)
  end)

  test.it("falls back to raw table Markdown when interactive editing is disabled", function()
    config.markdown_live_interactive_tables = false
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    test.equal(view:get_line_render(1), nil)
    test.equal(view:get_line_render(3), nil)
  end)

  test.it("keeps tables separate across empty rows and prose", function()
    local view = make_view(table.concat({
      "| Measure | Current value |",
      "|---|---:|",
      "| Original PDB C/C++ modules | 224 |",
      "| Modules with registered exact coverage | 224 |",
      "|  |  |",
      "| Registered groups | 239 |",
      "",
      "The Phase 0 integration audit is current.",
      "",
      "## Current integration backlog",
      "",
      "| Category | Functions |",
      "|---|---:|",
      "| Grouped exact, not registered | 193 |",
      "",
      "plain",
    }, "\n"))
    refresh(view)

    test.ok(test.not_nil(view:get_line_render(1)).table_row)
    test.ok(test.not_nil(view:get_line_render(4)).table_row)
    test.ok(test.not_nil(view:get_line_render(6)).table_row)
    test.equal(test.not_nil(view:get_line_render(7)).table_row, nil)
    test.ok(test.not_nil(view:get_line_render(12)).table_row)
    test.ok(test.not_nil(view:get_line_render(14)).table_row)
  end)

  test.it("does not intercept table commands in Markdown Source Mode", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, 4)
      refresh(view)
      markdown.live_render.set_source_mode(view, true, "interactive-table-test")
      test.equal(command.perform("markdown:table_next_cell"), false)
      test.same({ buffer:get_selection() }, { 3, 4, 3, 4 })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("does not fabricate interactive tables inside fenced code", function()
    local view, buffer = make_view(
      "```markdown\n| A | B |\n| --- | --- |\n| one | two |\n```\n"
    )
    buffer:set_selection(4, 4)
    refresh(view)
    test.equal(markdown_tables.has_interactive_context(view), false)
  end)

  test.it("does not intercept tables beyond the rendered column limit", function()
    local cells, markers = {}, {}
    for column = 1, markdown_tables.MAX_PRESENTATION_COLUMNS + 1 do
      cells[column], markers[column] = " C" .. column .. " ", " --- "
    end
    local source = "|" .. table.concat(cells, "|") .. "|\n|"
      .. table.concat(markers, "|") .. "|\n|"
      .. table.concat(cells, "|") .. "|\n"
    local view, buffer = make_view(source)
    buffer:set_selection(3, 3)
    refresh(view)
    test.equal(markdown_tables.has_interactive_context(view), false)
    test.equal(test.not_nil(view:get_line_render(3)).table_row, nil)
  end)

  test.it("does not show insertion controls for optional-pipe tables", function()
    local view, buffer = make_view("A | B\n--- | ---\none | two\n")
    buffer:set_selection(3, 4)
    refresh(view)
    test.equal(table_control(view, 1, "column", 1), nil)
    test.equal(table_control(view, 3, "row", 3), nil)
  end)

  test.it("navigates every selected cell and selects destination contents", function()
    local view, buffer = make_view(
      "| A | B | C |\n| --- | --- | --- |\n| one | two | three |\n| four | five | six |\n\nplain"
    )
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection_list({
        3, 4, 3, 4,
        4, 4, 4, 4,
      }, 2)
      refresh(view)

      test.equal(command.perform("markdown:table_next_cell"), true)
      local selections = view:get_selection_state().selections
      test.same(selections, {
        3, 12, 3, 9,
        4, 14, 4, 10,
      })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("moves down in the same column and appends a row at the bottom", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, 9)
      refresh(view)

      test.equal(command.perform("markdown:table_cell_below"), true)
      test.equal(buffer.lines[4], "|  |  |\n")
      local appended = test.not_nil(
        view.__markdown_live_owner.pending_lines[4],
        "appended table row did not receive an pending presentation"
      )
      test.ok(test.not_nil(appended.render_line).table_row, "appended row fell back to source")
      test.equal(#table_cells(view, 4), 2)
      local line1, col1, line2, col2 = buffer:get_selection()
      test.same({ line1, col1, line2, col2 }, { 4, 6, 4, 6 })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("appends a distinct row when the table ends the Buffer", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, 10)
      refresh(view)
      test.equal(command.perform("markdown:table_next_cell"), true)
      test.equal(buffer.lines[3], "| one | two |\n")
      test.equal(buffer.lines[4], "|  |  |\n")
      test.equal(#table_cells(view, 4), 2)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("inserts an explicit row below a table at end of Buffer", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, 4)
      refresh(view)
      test.equal(command.perform("markdown:table_insert_row_below"), true)
      test.equal(buffer.lines[3], "| one | two |\n")
      test.equal(buffer.lines[4], "|  |  |\n")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("renders a Tab-appended row before a following thematic break", function()
    local source = table.concat({
      "| CodigoEmpresa | Proyecto                  | proyecto2                      | PROT PROD |",
      "| ------------- | ------------------------- | ------------------------------ | --------- |",
      "| 1             | 2023/031                  | MISTY MOUNTAINS/ MG. LE 15M D  | 1         |",
      "| 2             | 202<3/121<br><br><br>test | ARRIVA/ NELEC 12M 2P           | 1         |",
      "|               | Total 2                   |                                |           |",
      "---",
    }, "\n")
    local view, buffer = make_view(source)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(5, 82)
      refresh(view)
      test.equal(command.perform("markdown:table_next_cell"), true)
      test.equal(buffer.lines[6], "|  |  |  |  |\n")
      local cells = table_cells(view, 6)
      test.equal(#cells, 4)
      local header = table_cells(view, 1)
      for column = 1, 4 do
        test.equal(cells[column].width, header[column].width)
        test.equal(cells[column].text_lines[1].text, "")
      end
      test.ok(test.not_nil(view:get_line_render(6)).table_row)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("inserts canonical br breaks in every selected cell", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection_list({
        3, 4, 3, 4,
        3, 10, 3, 10,
      }, 2)
      refresh(view)

      test.equal(command.perform("markdown:table_insert_cell_break"), true)
      test.equal(buffer.lines[3], "| o<br>ne | t<br>wo |\n")
      local cells = table_cells(view, 3)
      test.equal(#cells[1].text_lines, 2)
      test.equal(#cells[2].text_lines, 2)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("renders br variants as cell-local visual lines for Home and End", function()
    local source = "| A | B |\n| --- | --- |\n| one<br>two<br/>three<br />four | x |\n\nplain"
    local view, buffer = make_view(source)
    local two = test.not_nil(buffer.lines[3]:find("two", 1, true))
    buffer:set_selection(3, two + 2)
    refresh(view)

    local first = test.not_nil(table_cells(view, 3)[1])
    test.equal(#test.not_nil(first.text_lines), 4)
    test.ok(#test.not_nil(view:get_line_render(3)).position_rows >= 5)

    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("core:move_to_start_of_line"), true)
      local line, col = buffer:get_selection()
      test.same({ line, col }, { 3, two })

      buffer:set_selection(3, two + 1)
      test.equal(command.perform("core:move_to_end_of_line"), true)
      line, col = buffer:get_selection()
      test.same({ line, col }, { 3, two + 3 })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("moves vertically within a cell and then to the same column below", function()
    local source = "| A | B |\n| --- | --- |\n| one<br>two<br>three | x |\n| four | y |\n\nplain"
    local view, buffer = make_view(source)
    local three = test.not_nil(buffer.lines[3]:find("three", 1, true))
    local two = test.not_nil(buffer.lines[3]:find("two", 1, true))
    buffer:set_selection(3, three + 2)
    refresh(view)

    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("markdown:table_cell_up"), true)
      local line, col = buffer:get_selection()
      test.same({ line, col }, { 3, two + 2 })

      local one = test.not_nil(buffer.lines[3]:find("one", 1, true))
      buffer:set_selection(3, one + 1)
      test.equal(command.perform("markdown:table_cell_down"), true)
      line, col = buffer:get_selection()
      test.same({ line, col }, { 3, two + 1 })

      buffer:set_selection(3, three + 1)
      test.equal(command.perform("markdown:table_cell_down"), true)
      line, col = buffer:get_selection()
      test.equal(line, 4)
      test.ok(col >= 3 and col <= 7)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("drag-selects a rectangle as full-content cell selections", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| four | five |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local start_x, start_y = cell_center(view, 3, 1)
    local finish_x, finish_y = cell_center(view, 4, 2)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      local hit_line, hit_col = view:resolve_screen_position(finish_x, finish_y)
      test.equal(hit_line, 4)
      test.ok(hit_col >= 10, "second-column hit resolved to source column " .. tostring(hit_col))
      test.equal(command.perform("core:set_cursor", start_x, start_y), true)
      view:on_mouse_moved(finish_x, finish_y, finish_x - start_x, finish_y - start_y)
      view:on_mouse_released("left", finish_x, finish_y)
      test.same(view:get_selection_state().selections, {
        3, 6, 3, 3,
        3, 12, 3, 9,
        4, 7, 4, 3,
        4, 14, 4, 10,
      })
      test.equal(view:get_selection_state().last_selection, 4)

      test.equal(view:on_text_input("x"), true)
      test.equal(buffer.lines[3], "| x | x |\n")
      test.equal(buffer.lines[4], "| x | x |\n")
      test.equal(#table_cells(view, 3), 2)
      test.equal(#table_cells(view, 4), 2)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps a drag within one cell as an ordinary text selection", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    local line_x, line_y = view:get_line_screen_position(3)
    local start_x = line_x + view:get_col_x_offset(3, 3)
    local finish_x = line_x + view:get_col_x_offset(3, 5)
    local y = line_y + view:get_position_visual_row_height(3, 3) / 2
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("core:set_cursor", start_x, y), true)
      view:on_mouse_moved(finish_x, y, finish_x - start_x, 0)
      view:on_mouse_released("left", finish_x, y)
      local line1, col1, line2, col2 = buffer:get_selection(true)
      test.same({ line1, line2 }, { 3, 3 })
      test.equal(buffer:get_text(line1, col1, line2, col2), "on")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("draws partial text selection above table cell backgrounds", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    view:set_wrapping_enabled(true)
    buffer:set_selection(3, 5, 3, 3)
    refresh(view)
    view:prepare_line_body_draw_cache(3, 3)
    local x, y = view:get_line_screen_position(3)
    local calls = {}
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    renderer.draw_rect = function(rx, ry, width, height, color)
      calls[#calls + 1] = { rx, ry, width, height, color }
    end
    renderer.draw_text = function(font, text, tx)
      return tx + font:get_width(text)
    end
    local ok, err = pcall(function() view:draw_line_body(3, x, y) end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    local selected
    for _, call in ipairs(calls) do
      if call[5] == style.selection and call[3] > 1 then selected = call break end
    end
    selected = test.not_nil(selected, "partial table text selection was not drawn")
    local px, py = selected[1] + selected[3] / 2, selected[2] + selected[4] / 2
    local top_color
    for _, call in ipairs(calls) do
      if px >= call[1] and px <= call[1] + call[3]
      and py >= call[2] and py <= call[2] + call[4]
      then
        top_color = call[5]
      end
    end
    test.equal(top_color, style.selection)
  end)

  test.it("outlines a completely selected cell", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:set_selection(3, 6, 3, 3)
    refresh(view)
    view:prepare_line_body_draw_cache(3, 3)
    local x, y = view:get_line_screen_position(3)
    local outlines = 0
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.caret then outlines = outlines + 1 end
    end
    renderer.draw_text = function(font, text, tx)
      return tx + font:get_width(text)
    end
    local ok, err = pcall(function() view:draw_line_body(3, x, y) end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end
    test.ok(outlines >= 4, "fully selected table cell did not receive an outline")
  end)

  test.it("paints selection state for an empty selected cell", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n|  | two |\n\nplain")
    buffer:set_selection(3, 3)
    refresh(view)
    view:prepare_line_body_draw_cache(3, 3)
    local x, y = view:get_line_screen_position(3)
    local selection_fills, outlines = 0, 0
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    renderer.draw_rect = function(_, _, width, height, color)
      if color == style.selection and width > 1 and height > 1 then
        selection_fills = selection_fills + 1
      elseif color == style.caret then
        outlines = outlines + 1
      end
    end
    renderer.draw_text = function(font, text, tx)
      return tx + font:get_width(text)
    end
    local ok, err = pcall(function() view:draw_line_body(3, x, y) end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end
    test.ok(selection_fills >= 1, "empty selected table cell was not painted")
    test.ok(outlines >= 4, "empty selected table cell was not outlined")
  end)

  test.it("keeps every table row rendered through direct editing paths", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nplain"
    )
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, 5)
      refresh(view)
      view:on_ime_text_editing("x", 0, 1)
      for line = 1, 4 do
        test.ok(
          test.not_nil(view:get_line_render(line)).table_row,
          "table row " .. line .. " flashed to raw source during IME editing"
        )
      end
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps table row height stable when a cell becomes active", function()
    local view, buffer = make_view(
      "| A |\n| --- |\n| ``````abcdefghijklmnop`````` |\n\nplain"
    )
    view.size.x = 180
    buffer:set_selection(5, 1)
    refresh(view)
    local inactive_height = test.not_nil(view:get_line_render(3)).layout_height
    buffer:set_selection(3, 10)
    local active_height = test.not_nil(view:get_line_render(3)).layout_height
    test.equal(active_height, inactive_height)
  end)

  test.it("remeasures pending table rows when the viewport narrows", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n"
        .. "| one two three four five six seven eight | value |\n\nplain"
    )
    view.size.x = 900
    buffer:set_selection(3, 4)
    refresh(view)
    test.equal(view:on_text_input("x"), true)
    local wide = test.not_nil(view:get_line_render(3)).layout_height
    view.size.x = 190
    local narrow = test.not_nil(view:get_line_render(3)).layout_height
    test.ok(narrow > wide, "pending table row retained stale wide geometry")
  end)

  test.it("exposes horizontal overflow for a wide rendered table", function()
    local view = make_view(table.concat({
      "|   |   |   |   |   |   |   |   |   |",
      "|---|---|---|---|---|---|---|---|---|",
      "|CodigoEmpresa|Proyecto|proyecto2|PROT PROD|Reales|Previstos|Diferencia|Incremento|Previsto + Incre|",
      "|1|2023/031|MISTY MOUNTAINS/ MG. LE 15M D|1|1.428,15|1.263,41|164,73|324,25|1.587,66|",
      "",
    }, "\n"))
    view.size.x = 760
    view:set_wrapping_enabled(true)
    refresh(view)
    local function column_boundaries(line)
      local boundaries, x = {}, 0
      for _, fragment in ipairs(test.not_nil(view:get_line_render(line)).fragments or {}) do
        if fragment.table_border then boundaries[#boundaries + 1] = x end
        x = x + (fragment.width or 0)
      end
      return boundaries
    end
    test.same(column_boundaries(1), column_boundaries(3))
    test.same(column_boundaries(1), column_boundaries(4))
    local function drawn_vertical_borders(line)
      local result = {}
      local row_height = view:get_position_visual_row_height(line, 1)
      local old_draw_rect = renderer.draw_rect
      local old_draw_text = renderer.draw_text
      renderer.draw_rect = function(x, _, width, height)
        if width <= math.max(1, math.ceil(SCALE)) and height >= row_height - 1 then
          result[#result + 1] = math.floor(x * 100 + 0.5) / 100
        end
      end
      renderer.draw_text = function(font, text, x)
        return x + font:get_width(text)
      end
      local ok, err = pcall(function() view:draw_line_text(line, 0, 0) end)
      renderer.draw_rect = old_draw_rect
      renderer.draw_text = old_draw_text
      if not ok then error(err, 0) end
      table.sort(result)
      return result
    end
    test.same(drawn_vertical_borders(1), drawn_vertical_borders(3))
    test.same(drawn_vertical_borders(1), drawn_vertical_borders(4))
    local scrollable_width = view:get_h_scrollable_size()
    test.ok(
      scrollable_width > view.size.x,
      "wide rendered table should extend the horizontal scroll range"
    )
    view:update_scrollbar()
    test.equal(view.h_scrollbar.force_status, "expanded")
    local _, _, scrollbar_width, scrollbar_height = view.h_scrollbar:get_track_rect()
    test.ok(scrollbar_width > 0 and scrollbar_height > 0)

    local last_cell = table_cells(view, 4)[9]
    view:scroll_to_make_visible(4, last_cell.text_source_col1, true)
    test.ok(view.scroll.x > 0, "caret visibility should scroll a wide wrapped table")

    view.scroll.x = scrollable_width - view.size.x
    view.scroll.to.x = view.scroll.x
    local x, y = cell_center(view, 4, 9)
    test.ok(x >= view.position.x and x <= view.position.x + view.size.x)
    local line, col = view:resolve_screen_position(x, y)
    local context = test.not_nil(markdown_tables.interactive_context(view, line, col))
    test.equal(context.column, 9)

    view.size.x = 2000
    test.equal(view:get_h_scrollable_size(), view.size.x)
    view:clamp_scroll_position()
    test.equal(view.scroll.to.x, 0)

    view.size.x = 760
    view:set_wrapping_enabled(false)
    view:update_scrollbar()
    test.equal(view.h_scrollbar.force_status, "expanded")
  end)

  test.it("shows hover controls that insert columns and rows at their edges", function()
    local function click_control(view, line, control)
      local line_x, line_y = view:get_line_screen_position(line)
      local width = control.hit_width or control.widget.width
      local height = control.widget.height
      local x = line_x + control.layout_x + width / 2
      local y = line_y + control.draw_y_offset + height / 2
      local hit_line, hit_col = view:resolve_screen_position(x, y)
      if not view:get_render_widget_at_position(x, y) then
        error(string.format(
          "table insertion control was not hit (wanted line %d, resolved %d:%d at %.1f,%.1f)",
          line, hit_line, hit_col, x, y
        ), 0)
      end
      view:on_mouse_moved(x, y, 0, 0)
      local hovered = view.hovered_render_fragment
      if not hovered then
        error(string.format(
          "table insertion control did not hover (cursor=%s gutter=%s scrollbar=%s selecting=%s posthit=%s)",
          tostring(view.cursor), tostring(view.hovering_gutter),
          tostring(view:scrollbar_hovering()), tostring(view.mouse_selecting),
          tostring(view:get_render_widget_at_position(x, y) ~= nil)
        ), 0)
      end
      test.equal(hovered.table_insert_control, control.table_insert_control)
      test.equal(hovered.hovered, true)
      test.equal(view.cursor, "hand")
      test.equal(view:on_mouse_pressed("left", x, y, 1), true)
    end

    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    click_control(view, 1, test.not_nil(table_control(view, 1, "column", 1)))
    test.equal(buffer.lines[1], "| A |  | B |\n")
    test.equal(buffer.lines[3], "| one |  | two |\n")

    markdown_model.get(buffer):submit("interactive-table-hover-column")
    refresh(view)
    click_control(view, 3, test.not_nil(table_control(view, 3, "row", 3)))
    test.equal(buffer.lines[4], "|  |  |  |\n")
  end)

  test.it("keeps a wide table rendered after inserting an empty body row", function()
    local view, buffer = make_view(table.concat({
      "| CodigoEmpresa | Proyecto | proyecto2                              | PROT PROD |",
      "| ------------- | -------- | -------------------------------------- | --------- |",
      "| 1             | 2023/017 | TIB-RUIZ / MAGNUS. ES GNC ARTd         |           |",
      "| 2             | 2023/023 | E. SAGALES / MG. E PA GNC ART.         |           |",
      "| 2             | 2024/004 | MOBILIS-CRAddfCOV/ NEW CITY 12M GNC    |           |",
      "|               | Total 1  |                                        |           |",
      "| 2             | 2023/122 | EL-GITARR 75CS 15M LE ELÉCTRICO        |           |",
      "| 2             | 2024/106 | POZUELO LLORENTE - NEW CITY VOLVO B5LH |           |",
      "|               | Total 2  |                                        |           |",
      "",
    }, "\n"))
    view.size.x = 760
    view:set_wrapping_enabled(true)
    buffer:set_selection(3, 4)
    refresh(view)

    local control = test.not_nil(table_control(view, 3, "row", 3))
    local line_x, line_y = view:get_line_screen_position(3)
    local x = line_x + control.layout_x + (control.hit_width or control.widget.width) / 2
    local y = line_y + control.draw_y_offset + control.widget.height / 2
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view:on_mouse_pressed("left", x, y, 1), true)
    test.equal(buffer.lines[4], "|  |  |  |  |\n")

    markdown_model.get(buffer):submit("interactive-table-empty-row")
    refresh(view)
    local semantic = {}
    for _, node in ipairs(markdown_model.peek(buffer):nodes_for_lines(1, 10, { limit = 200 }) or {}) do
      if node.type == "table" then
        semantic[#semantic + 1] = string.format(
          "%s:%d-%d", node.type, node.source.line1, node.source.line2
        )
      end
    end
    local semantic_summary = table.concat(semantic, ",")
    local expected_boundaries
    for line = 1, 10 do
      if line ~= 2 then
        local render = test.not_nil(view:get_line_render(line))
        test.ok(render.table_row, string.format(
          "row %d fell back to source (tables=%s)", line, semantic_summary
        ))
        local boundaries, offset = {}, 0
        for _, fragment in ipairs(render.fragments or {}) do
          if fragment.table_border then boundaries[#boundaries + 1] = offset end
          offset = offset + (fragment.width or 0)
        end
        expected_boundaries = expected_boundaries or boundaries
        test.same(expected_boundaries, boundaries)
      end
    end
    buffer:set_selection(5, 4)
    test.equal(test.not_nil(markdown_tables.interactive_context(view)).line, 5)
  end)

  test.it("reveals insertion controls progressively as the pointer approaches", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection(3, 4)
    refresh(view)
    local control = test.not_nil(table_control(view, 1, "column", 2))
    local line_x, line_y = view:get_line_screen_position(1)
    local size = control.widget.width
    local x = line_x + control.layout_x - size
    local y = line_y + control.draw_y_offset + size / 2
    local near = test.not_nil(view:get_render_widget_near_position(x, y), string.format(
      "control proximity missing at %d:%d (radius=%s)",
      view:resolve_screen_position(x, y), select(2, view:resolve_screen_position(x, y)),
      tostring(control.widget.proximity_radius)
    ))
    test.equal(near.fragment.semantic_id, control.semantic_id)
    view:on_mouse_moved(x, y, 0, 0)
    local approaching = test.not_nil(view.proximity_render_fragment)
    test.equal(approaching.semantic_id, control.semantic_id)
    test.ok(not approaching.hovered)
    test.ok((approaching.proximity or 0) > 0 and approaching.proximity < 1)
  end)

  test.it("scales insertion controls with editor zoom", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection(3, 4)
    refresh(view)
    local normal = test.not_nil(table_control(view, 1, "column", 1)).control_size
    local font = view:get_font()
    local old_size = font:get_size()
    local ok, err = pcall(function()
      font:set_size(old_size * 0.5)
      view:invalidate_line_render("test-zoom")
      local smaller = test.not_nil(table_control(view, 1, "column", 1)).control_size
      test.ok(smaller < normal * 0.75)
    end)
    font:set_size(old_size)
    view:invalidate_line_render("test-zoom-restore")
    if not ok then error(err, 0) end
  end)

  test.it("reveals only the active cell's inline Markdown source", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| `one` | `two` |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    local cells = table_cells(view, 3)
    test.equal(cells[1].text_lines[1].text, "one")
    test.equal(cells[2].text_lines[1].text, "two")

    buffer:set_selection(3, 4)
    cells = table_cells(view, 3)
    test.equal(cells[1].text_lines[1].text, "`one`")
    test.equal(cells[2].text_lines[1].text, "two")
  end)

  test.it("refreshes elided active-cell identity within one row", function()
    local view, buffer = make_view(table.concat({
      "| A | B |",
      "| --- | --- |",
      "| ![one](data:image/png;base64,AAAA) | ![two](data:image/png;base64,BBBB) |",
      "",
    }, "\n"))
    buffer:set_selection(3, 4)
    refresh(view)
    local cells = table_cells(view, 3)
    test.ok(cells[1].text:find("![one]", 1, true) ~= nil)
    test.ok(cells[2].text:find("Embedded image: two", 1, true) ~= nil)

    local second = test.not_nil(buffer.lines[3]:find("![two]", 1, true))
    buffer:set_selection(3, second + 3)
    test.equal(test.not_nil(markdown_tables.interactive_context(view)).column, 2)
    cells = table_cells(view, 3)
    test.ok(cells[1].text:find("Embedded image: one", 1, true) ~= nil)
    test.ok(cells[2].text:find("![two]", 1, true) ~= nil)
  end)

  test.it("converts typed newlines to br and escapes pipes inside cells", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    buffer:set_selection(3, 6, 3, 3)
    refresh(view)

    test.equal(view:on_text_input("left|\nright"), true)
    test.equal(buffer.lines[3], "| left\\|<br>right | two |\n")
    local pending = view.__markdown_live_owner.pending_lines[3]
    test.not_nil(pending, "interactive table edit did not retain an pending row")
    test.ok(test.not_nil(pending.render_line).table_row, "pending row fell back to source")
    local cells = table_cells(view, 3)
    test.equal(#cells[1].text_lines, 2)

    local context, reason = markdown_tables.interactive_context(view)
    test.not_nil(context, reason)
    local old_active = core.active_view
    core.active_view = view
    local navigated = command.perform("markdown:table_next_cell")
    core.active_view = old_active
    test.equal(navigated, true)
    local line, col1, _, col2 = buffer:get_selection()
    test.same({ line, col1, col2 }, { 3, 24, 21 })
  end)

  test.it("preserves escaped pipes and code-span pipes during cell input", function()
    test.equal(markdown_tables.normalize_cell_input("\\|"), "\\|")
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one\\ | `code` |\n"
    )
    buffer:set_selection(3, 7)
    refresh(view)
    test.equal(view:on_text_input("|"), true)
    test.equal(buffer.lines[3], "| one\\| | `code` |\n")

    local code = test.not_nil(buffer.lines[3]:find("code", 1, true))
    buffer:set_selection(3, code + 2)
    test.equal(view:on_text_input("|"), true)
    test.equal(buffer.lines[3], "| one\\| | `co|de` |\n")
  end)

  test.it("normalizes IME newlines and pipes without flashing raw rows", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n"
    )
    buffer:set_selection(3, 4)
    refresh(view)
    view:on_ime_text_editing("x|\ny", 0, 4)
    test.equal(buffer.lines[3], "| ox\\|<br>yne | two |\n")
    for line = 1, 4 do test.ok(test.not_nil(view:get_line_render(line)).table_row) end
  end)

  test.it("normalizes IME text independently for every selected cell", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | `code` |\n"
    )
    local code = test.not_nil(buffer.lines[3]:find("code", 1, true))
    buffer:set_selection_list({ 3, 4, 3, 4, 3, code + 2, 3, code + 2 }, 2)
    refresh(view)
    view:on_ime_text_editing("|", 0, 1)
    test.equal(buffer.lines[3], "| o\\|ne | `co|de` |\n")
  end)

  test.it("keeps br literal inside a whole-cell code span", function()
    local view, buffer = make_view(
      "| A |\n| --- |\n| `one<br>two` |\n"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local cell = test.not_nil(table_cells(view, 3)[1])
    test.equal(#cell.text_lines, 1)
    test.equal(cell.text_lines[1].text, "one<br>two")
  end)

  test.it("rejects mixed table and prose selections before routing commands", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n\nplain\n"
    )
    buffer:set_selection_list({
      5, 2, 5, 2,
      3, 4, 3, 4,
    }, 2)
    refresh(view)
    test.equal(markdown_tables.has_interactive_context(view), false)
  end)

  test.it("rejects a selection spanning table structure", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n"
    )
    buffer:set_selection(3, 4, 1, 3)
    refresh(view)
    test.equal(markdown_tables.has_interactive_context(view), false)
  end)

  test.it("preserves matching per-cursor clipboard payloads", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n")
    buffer:set_selection_list({ 3, 6, 3, 3, 3, 12, 3, 9 }, 2)
    refresh(view)
    local old_get = system.get_clipboard
    local old_clipboard = core.cursor_clipboard
    local old_whole = core.cursor_clipboard_whole_line
    system.get_clipboard = function() return "first\nsecond" end
    core.cursor_clipboard = {
      [1] = "left|value", [2] = "right\nvalue", full = "first\nsecond",
    }
    core.cursor_clipboard_whole_line = { false, false }
    local ok, err = pcall(function()
      test.equal(markdown_tables.paste(view), true)
      test.equal(buffer.lines[3], "| left\\|value | right<br>value |\n")
    end)
    system.get_clipboard = old_get
    core.cursor_clipboard = old_clipboard
    core.cursor_clipboard_whole_line = old_whole
    if not ok then error(err, 0) end
  end)

  test.it("normalizes primary-selection paste inside a cell", function()
    local view, buffer = make_view("| A |\n| --- |\n| one |\n")
    buffer:set_selection(3, 4)
    refresh(view)
    local old_primary = system.get_primary_selection
    system.get_primary_selection = function() return "x|y\nz" end
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("markdown:table_paste_primary"), true)
      test.equal(buffer.lines[3], "| ox\\|y<br>zne |\n")
    end)
    core.active_view = old_active
    system.get_primary_selection = old_primary
    if not ok then error(err, 0) end
  end)

  test.it("routes middle-click paste by the clicked cell", function()
    local view, buffer = make_view("| A |\n| --- |\n| one |\n\nplain\n")
    buffer:set_selection(5, 2)
    refresh(view)
    local x, y = cell_center(view, 3, 1)
    local old_primary = system.get_primary_selection
    system.get_primary_selection = function() return "x|y" end
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(
        command.perform("markdown:table_paste_primary", x, y), true
      )
      test.ok(buffer.lines[3]:find("x\\|y", 1, true) ~= nil)
      local plain_x, plain_y = view:get_line_screen_position(5)
      test.equal(command.perform(
        "markdown:table_paste_primary", plain_x + 5, plain_y + 5
      ), false)
    end)
    core.active_view = old_active
    system.get_primary_selection = old_primary
    if not ok then error(err, 0) end
  end)

  test.it("navigates across and deletes br variants atomically", function()
    local view, buffer = make_view("| A |\n| --- |\n| one<br/>two |\n\nplain")
    local break_start, break_end = buffer.lines[3]:find("<br/>", 1, true)
    buffer:set_selection(3, break_end + 1)
    refresh(view)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("markdown:table_previous_char"), true)
      local line, col = buffer:get_selection()
      test.same({ line, col }, { 3, break_start })

      test.equal(command.perform("markdown:table_next_char"), true)
      line, col = buffer:get_selection()
      test.same({ line, col }, { 3, break_end + 1 })

      test.equal(command.perform("markdown:table_backspace"), true)
      test.equal(buffer.lines[3], "| onetwo |\n")
      test.equal(table_cells(view, 3)[1].text_lines[1].text, "onetwo")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("collapses a selected cell before moving left or right", function()
    local view, buffer = make_view("| A |\n| --- |\n| one |\n")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, 6, 3, 3)
      refresh(view)
      test.equal(command.perform("markdown:table_previous_char"), true)
      test.same({ buffer:get_selection() }, { 3, 3, 3, 3 })
      buffer:set_selection(3, 6, 3, 3)
      test.equal(command.perform("markdown:table_next_char"), true)
      test.same({ buffer:get_selection() }, { 3, 6, 3, 6 })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("inserts rows and columns on explicit palette sides", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nplain")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(4, 11)
      refresh(view)
      test.equal(command.perform("markdown:table_insert_row_above"), true)
      test.equal(buffer.lines[4], "|  |  |\n")
      buffer:undo()
      markdown_model.get(buffer):submit("interactive-table-command-undo")
      refresh(view)

      buffer:set_selection(3, 10)
      test.equal(command.perform("markdown:table_insert_column_left"), true)
      test.equal(buffer.lines[1], "| A |  | B |\n")
      test.equal(buffer.lines[3], "| one |  | two |\n")
      test.equal(#table_cells(view, 3), 3)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)
end)
