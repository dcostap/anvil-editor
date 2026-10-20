local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local markdown_tables = require "core.markdown.tables"
local keymap = require "core.keymap"
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
      local height = render.table_content_height or render.table_row_height
        or view:get_line_height()
      local top = line_y + (render.first_row_content_y_offset or 0)
      return line_x + x + width / 2, top + height / 2
    end
    x = x + width
  end
  error("table cell not found")
end

local function row_cells(buffer, line)
  local text = (buffer.lines[line] or ""):gsub("\n$", "")
  local row = test.not_nil(
    markdown_tables.source_row(text), "line " .. line .. " is not a table row"
  )
  local cells = {}
  for index, cell in ipairs(row.cells) do
    cells[index] = text:sub(cell.content_col1, cell.content_col2 - 1)
  end
  return cells
end

local function caret_cell(buffer)
  local line, col = buffer:get_selection()
  local text = (buffer.lines[line] or ""):gsub("\n$", "")
  local row = test.not_nil(markdown_tables.source_row(text), "caret is outside a table row")
  for index, cell in ipairs(row.cells) do
    if col >= cell.col1 and col <= cell.col2 then return line, index end
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

  test.it("draws inline code in a cell at the size it has in prose", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| `tipo` | see `ip` here |\n\nplain `code`"
    )
    view.size.x = 800
    buffer:set_selection(5, 1)
    refresh(view)
    local prose
    for _, fragment in ipairs(test.not_nil(view:get_line_render(5)).fragments) do
      if fragment.text == "code" then prose = fragment.font:get_size() end
    end
    local sizes = {}
    for _, cell in ipairs(table_cells(view, 3)) do
      for _, text_line in ipairs(cell.text_lines or {}) do
        for _, run in ipairs(text_line.runs or {}) do sizes[run.text] = (run.font or cell.font):get_size() end
      end
    end
    test.equal(sizes.tipo, test.not_nil(prose))
    test.equal(sizes.ip, prose)
  end)

  test.it("keeps the table layout while typing in a cell beside inline code", function()
    local view, buffer = make_view(table.concat({
      "| Propiedad | Qué es |",
      "| --- | --- |",
      "| `descripcion` | Documentación, nota |",
      "| `ip` | Sin `ip` no se vigila |",
      "",
      "plain",
    }, "\n"))
    view.size.x = 800
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, #"| `descripcion` | Documentación, nota" + 1)
      refresh(view)
      -- The typed text widens only its own column.
      local function layout()
        local heights = {}
        for line = 3, 4 do heights[line] = test.not_nil(view:get_line_render(line)).layout_height end
        return { first_column = table_cells(view, 3)[1].width, heights = heights }
      end
      local before = layout()
      view:on_text_input("s")
      test.same(layout(), before)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("draws the caret after a space typed at the end of a cell", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two words |\n\nplain")
    view.size.x = 800
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, #"| one | two words" + 1)
      refresh(view)
      local before = view:get_col_x_offset(3, #"| one | two words" + 1)
      test.equal(view:on_text_input(" "), true)
      refresh(view)
      test.equal(buffer.lines[3], "| one | two words  |\n")
      local space = table_cells(view, 3)[2].font:get_width(" ")
      test.same({ buffer:get_selection() }, { 3, #"| one | two words " + 1, 3, #"| one | two words " + 1 })
      test.ok(math.abs(view:get_col_x_offset(3, #"| one | two words " + 1) - (before + space)) < 0.5,
        "the caret must sit one space after the text")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("deletes a space typed at the end of a cell", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two words |\n\nplain")
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(3, #"| one | two words" + 1)
      refresh(view)
      test.equal(view:on_text_input(" "), true)
      test.equal(command.perform("markdown:table_backspace"), true)
      test.equal(buffer.lines[3], "| one | two words |\n")
      test.same({ buffer:get_selection() }, { 3, #"| one | two words" + 1, 3, #"| one | two words" + 1 })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("wraps inline code within the available table width", function()
    local code = "alpha_beta_gamma_delta_epsilon_zeta_eta_theta_iota_kappa_lambda"
    local view, buffer = make_view(table.concat({
      "| Value |",
      "| --- |",
      "| `" .. code .. "` |",
      "",
      "plain",
    }, "\n"))
    view.size.x = 220
    buffer:set_selection(5, 1)
    refresh(view)

    local cell = test.not_nil(table_cells(view, 3)[1])
    test.equal(cell.text, code)
    test.ok(#cell.text_lines > 1, "inline code did not wrap inside its table cell")
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
      test.same(row_cells(buffer, 4), { "", "" })
      local appended = test.not_nil(
        view.__markdown_live_owner.pending_lines[4],
        "appended table row did not receive an pending presentation"
      )
      test.ok(test.not_nil(appended.render_line).table_row, "appended row fell back to source")
      test.equal(#table_cells(view, 4), 2)
      test.ok(not buffer:has_selection(), "appended empty cell was not a caret")
      test.same({ caret_cell(buffer) }, { 4, 2 })
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps the header and delimiter rows in place after appending an empty row", function()
    local view, buffer = make_view(
      "intro\n\n| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nplain"
    )
    view:set_wrapping_enabled(true)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      buffer:set_selection(6, 4)
      refresh(view)
      local function row_top(line)
        local _, y = view:get_line_screen_position(line)
        return y
      end
      local header_to_body = row_top(5) - row_top(3)
      local delimiter_to_body = row_top(5) - row_top(4)

      test.equal(command.perform("markdown:table_cell_below"), true)
      test.same(row_cells(buffer, 7), { "", "" })
      refresh(view)

      test.equal(row_top(5) - row_top(3), header_to_body)
      test.equal(row_top(5) - row_top(4), delimiter_to_body)
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
      test.same(row_cells(buffer, 3), { "one", "two" })
      test.same(row_cells(buffer, 4), { "", "" })
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
      test.same(row_cells(buffer, 3), { "one", "two" })
      test.same(row_cells(buffer, 4), { "", "" })
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
      test.same(row_cells(buffer, 6), { "", "", "", "" })
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

  local SELECTION_FILL, SELECTION_OUTLINE = { 1, 2, 3, 40 }, { 4, 5, 6, 255 }

  ---Run `fn` with recognizable Table Cell Selection colors.
  local function with_cell_selection_colors(fn)
    local fill = style.markdown_live_table_cell_selection
    local outline = style.markdown_live_table_cell_selection_outline
    style.markdown_live_table_cell_selection = SELECTION_FILL
    style.markdown_live_table_cell_selection_outline = SELECTION_OUTLINE
    local ok, err = pcall(fn)
    style.markdown_live_table_cell_selection = fill
    style.markdown_live_table_cell_selection_outline = outline
    if not ok then error(err, 0) end
  end

  ---Draw the bodies of `lines` and return the rectangles painted per color.
  local function paint_rects(view, lines)
    view:prepare_line_body_draw_cache(lines[1], lines[#lines])
    local rects = {}
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_draw_poly = renderer.draw_poly
    renderer.draw_rect = function(_, _, width, height, color)
      rects[color] = rects[color] or {}
      table.insert(rects[color], { width = width, height = height })
    end
    renderer.draw_text = function(font, text, tx)
      return tx + font:get_width(text)
    end
    renderer.draw_poly = function() end
    local ok, err = pcall(function()
      for _, line in ipairs(lines) do
        local x, y = view:get_line_screen_position(line)
        view:draw_line_body(line, x, y)
      end
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    renderer.draw_poly = old_draw_poly
    if not ok then error(err, 0) end
    return rects
  end

  local function count_cell_paint(view, line)
    local rects = paint_rects(view, { line })
    return #(rects[SELECTION_FILL] or {}), #(rects[SELECTION_OUTLINE] or {})
  end

  test.it("shows a lone selection of a cell's whole text as text selection", function()
    with_cell_selection_colors(function()
      local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
      buffer:set_selection(3, 6, 3, 3)
      refresh(view)
      local rects = paint_rects(view, { 3 })
      test.equal(#(rects[SELECTION_FILL] or {}), 0, "a lone selection looked like a selected cell")
      test.equal(#(rects[SELECTION_OUTLINE] or {}), 0, "a lone selection was outlined")
      local text = test.not_nil((rects[style.selection] or {})[1], "the text selection was not drawn")
      test.ok(text.width < table_cells(view, 3)[1].width, "the text selection covered the whole cell")

      local active_view, disable_blink = core.active_view, config.disable_blink
      local carets = {}
      view.active_window_has_focus = function() return true end
      view.draw_caret = function(_, _, _, line) carets[#carets + 1] = line end
      core.active_view, config.disable_blink = view, true
      local ok, err = pcall(function() view:draw_overlay() end)
      core.active_view, config.disable_blink = active_view, disable_blink
      if not ok then error(err, 0) end
      test.same(carets, { 3 }, "a lone selection in a cell hid its caret")
    end)
  end)

  test.it("paints no text selection on the wrapped lines of selected cells", function()
    with_cell_selection_colors(function()
      local view, buffer = make_view(
        "| A | B |\n| --- | --- |\n| first<br>second | two |\n\nplain"
      )
      buffer:set_selection(5, 1)
      refresh(view)
      test.equal(#table_cells(view, 3)[1].text_lines, 2)
      test.equal(markdown_tables.select_row(view, 3), true)
      local rects = paint_rects(view, { 3 })
      test.equal(#(rects[SELECTION_FILL] or {}), 2)
      test.equal(#(rects[style.selection] or {}), 0, "selected cells also drew text selection")
    end)
  end)

  test.it("paints selection state for an empty cell in a Table Cell Selection", function()
    with_cell_selection_colors(function()
      local view, buffer = make_view("| A | B |\n| --- | --- |\n|  | two |\n\nplain")
      buffer:set_selection(3, 3)
      refresh(view)
      test.equal(markdown_tables.select_rectangle(view, 3, 3, 3, 8), true)
      local fills, outlines = count_cell_paint(view, 3)
      test.equal(fills, 2, "empty selected table cell was not painted")
      test.ok(outlines > 0, "empty selected table cell was not outlined")
    end)
  end)

  test.it("tints empty and filled cells of a Table Cell Selection alike", function()
    local active_cell = style.markdown_live_table_active_cell
    local marker = { 7, 8, 9, 30 }
    style.markdown_live_table_active_cell = marker
    local ok, err = pcall(with_cell_selection_colors, function()
      local view, buffer = make_view("| A | B |\n| --- | --- |\n|  | two |\n|  | four |\n\nplain")
      buffer:set_selection(6, 1)
      refresh(view)
      test.equal(markdown_tables.select_rectangle(view, 3, 3, 4, 9), true)
      local rects = paint_rects(view, { 3, 4 })
      test.equal(#(rects[marker] or {}), 0, "selected empty cells drew the active cell tint")
      test.equal(#(rects[SELECTION_FILL] or {}), 4)
    end)
    style.markdown_live_table_active_cell = active_cell
    if not ok then error(err, 0) end
  end)

  test.it("tints the pressed cell like the rest of a dragged Table Cell Selection", function()
    local active_cell = style.markdown_live_table_active_cell
    local marker = { 7, 8, 9, 30 }
    style.markdown_live_table_active_cell = marker
    local ok, err = pcall(with_cell_selection_colors, function()
      local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
      buffer:set_selection(5, 1)
      refresh(view)
      -- The press puts a caret in the first cell, and the drag holds the
      -- rendered rows from that moment until the button is released.
      buffer:set_selection(3, 4)
      view:begin_line_render_interaction("mouse-selection")
      local paint_ok, paint_err = pcall(function()
        test.equal(markdown_tables.select_rectangle(view, 3, 4, 3, 9), true)
        local rects = paint_rects(view, { 3 })
        test.equal(#(rects[marker] or {}), 0, "the pressed cell kept the active cell tint")
        test.equal(#(rects[SELECTION_FILL] or {}), 2)
      end)
      view:end_line_render_interaction("mouse-release")
      if not paint_ok then error(paint_err, 0) end
    end)
    style.markdown_live_table_active_cell = active_cell
    if not ok then error(err, 0) end
  end)

  test.it("shows a lone caret in an empty cell without selection paint", function()
    with_cell_selection_colors(function()
      local view, buffer = make_view("| A | B |\n| --- | --- |\n|  | two |\n\nplain")
      buffer:set_selection(3, 3)
      refresh(view)
      local fills, outlines = count_cell_paint(view, 3)
      test.equal(fills, 0)
      test.equal(outlines, 0)
    end)
  end)

  test.it("opens a link in a table cell from its rendered text", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | see [notes](https://example.com) |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local old_open = common.open_in_system
    local opened
    common.open_in_system = function(path) opened = path return true end
    local ok, err = pcall(function()
      local function point(word)
        local x, y = view:get_line_screen_position(3, buffer.lines[3]:find(word, 1, true))
        return x + 3, y + 3
      end
      local x, y = point("see")
      view:on_mouse_moved(x, y, 0, 0)
      test.equal(view.cursor, "ibeam")
      x, y = point("notes")
      view:on_mouse_moved(x, y, 0, 0)
      test.equal(view.cursor, "hand")
      view:on_mouse_pressed("left", x, y, 1)
      test.equal(opened, "https://example.com")
    end)
    common.open_in_system = old_open
    if not ok then error(err, 0) end
  end)

  test.it("does not frame a link's hidden bracket in a selected cell", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | see [notes](https://example.com) |\n| two | four |\n\nplain"
    )
    buffer:set_selection(6, 1)
    refresh(view)
    local old_active = core.active_view
    core.active_view = view
    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local ok, err = pcall(function()
      test.equal(markdown_tables.select_rectangle(
        view, 4, buffer.lines[4]:find("four"), 3, buffer.lines[3]:find("see") + 1
      ), true)
      -- The primary caret ends the link cell, right after its hidden ")".
      local line, col = buffer:get_selection()
      test.same({ line, buffer.lines[3]:sub(col - 1, col - 1) }, { 3, ")" })
      test.equal(table_cells(view, 3)[2].text_lines[1].text, "see notes")
      view:update()
      local bracket_frames = 0
      renderer.draw_rect = function(_, _, _, _, color)
        if color == style.bracketmatch_frame_color then
          bracket_frames = bracket_frames + 1
        end
      end
      renderer.draw_text = function(font, text, x)
        return x + font:get_width(text)
      end
      local x, y = view:get_line_screen_position(3)
      view:draw_line_text(3, x, y)
      test.equal(bracket_frames, 0)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("outlines a group of selected cells once around its edge", function()
    with_cell_selection_colors(function()
      local view, buffer = make_view(table.concat({
        "| A | B | C |", "| --- | --- | --- |",
        "| one | two | three |", "| four | five | six |", "| seven | eight | nine |",
        "", "plain",
      }, "\n"))
      buffer:set_selection(7, 1)
      refresh(view)
      local function outline_edges(lines)
        local horizontal, vertical = 0, 0
        for _, rect in ipairs(paint_rects(view, lines)[SELECTION_OUTLINE] or {}) do
          if rect.width > rect.height then
            horizontal = horizontal + 1
          else
            vertical = vertical + 1
          end
        end
        return horizontal, vertical
      end

      test.equal(markdown_tables.select_row(view, 4), true)
      local horizontal, vertical = outline_edges({ 4 })
      test.equal(vertical, 2, "a selected row needs one left and one right edge")
      test.equal(horizontal, 3 * 2, "each selected cell needs its top and bottom edge")

      test.equal(markdown_tables.select_column(view, 3, 2), true)
      horizontal, vertical = outline_edges({ 1, 3, 4, 5 })
      test.equal(horizontal, 2, "a selected column needs one top and one bottom edge")
      test.equal(vertical, 4 * 2, "each selected cell needs its left and right edge")
    end)
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

  test.it("draws cell text of a table without cell padding where a padded table draws it", function()
    ---Return the y offset of each cell text drawn on `line`, keyed by text.
    local function text_offsets(text, line)
      local view, buffer = make_view(text)
      buffer:set_selection(5, 1)
      refresh(view)
      view:prepare_line_body_draw_cache(line, line)
      local x, y = view:get_line_screen_position(line)
      local offsets = {}
      local old_draw_rect = renderer.draw_rect
      local old_draw_text = renderer.draw_text
      renderer.draw_rect = function() end
      renderer.draw_text = function(font, drawn, tx, ty)
        offsets[drawn] = ty - y
        return tx + font:get_width(drawn)
      end
      local ok, err = pcall(function() view:draw_line_body(line, x, y) end)
      renderer.draw_rect = old_draw_rect
      renderer.draw_text = old_draw_text
      if not ok then error(err, 0) end
      return offsets
    end

    for _, line in ipairs({ 1, 3 }) do
      local padded = text_offsets("| A | B |\n| --- | --- |\n| one | two |\n\nplain", line)
      local compact = text_offsets("|A|B|\n|---|---|\n|one|two|\n\nplain", line)
      local cell = line == 1 and "A" or "one"
      test.equal(compact[cell], test.not_nil(padded[cell]), "row " .. line)
    end
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

  local WIDE_TABLE = table.concat({
    "|   |   |   |   |   |   |   |   |   |",
    "|---|---|---|---|---|---|---|---|---|",
    "|CodigoEmpresa|Proyecto|proyecto2|PROT PROD|Reales|Previstos|Diferencia|Incremento|Previsto + Incre|",
    "|1|2023/031|MISTY MOUNTAINS/ MG. LE 15M D|1|1.428,15|1.263,41|164,73|324,25|1.587,66|",
    "",
    "plain",
  }, "\n")

  local function wide_table_view()
    local view, buffer = make_view(WIDE_TABLE)
    view.size.x = 760
    view:set_wrapping_enabled(true)
    buffer:set_selection(6, 1)
    refresh(view)
    return view, buffer
  end

  local function content_left(view)
    return view.position.x + view:get_gutter_width()
  end

  local function visible(view, x)
    return x >= content_left(view) and x <= view.position.x + view.size.x
  end

  test.it("scrolls a wide table inside its own frame instead of the document", function()
    local view = wide_table_view()
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
    test.ok(view:get_h_scrollable_size() <= view.size.x,
      "a wide table must not widen the document")
    test.not_ok(visible(view, (cell_center(view, 4, 9))), "the last column starts out of view")

    local last_cell = table_cells(view, 4)[9]
    view.buffer:set_selection(4, last_cell.text_source_col1)
    view:scroll_to_make_visible(4, last_cell.text_source_col1, true)
    test.equal(view.scroll.x, 0)
    local x, y = cell_center(view, 4, 9)
    test.ok(visible(view, x), "caret visibility should scroll the table to the last column")
    test.not_ok(visible(view, (cell_center(view, 4, 1))), "the first column scrolled out of view")
    local line, col = view:resolve_screen_position(x, y)
    test.equal(test.not_nil(markdown_tables.interactive_context(view, line, col)).column, 9)

    local first_cell = table_cells(view, 3)[1]
    view.buffer:set_selection(3, first_cell.text_source_col1)
    view:scroll_to_make_visible(3, first_cell.text_source_col1, true)
    test.ok(visible(view, (cell_center(view, 3, 1))), "the first column scrolled back into view")
  end)

  test.it("keeps clicks on a scrolled table inside its visible columns", function()
    local view = wide_table_view()
    local last_cell = table_cells(view, 4)[9]
    view:scroll_to_make_visible(4, last_cell.text_source_col1, true)
    local _, y = cell_center(view, 4, 1)
    local line, col = view:resolve_screen_position(content_left(view) + 2, y)
    local column = test.not_nil(markdown_tables.interactive_context(view, line, col)).column
    test.ok(column > 1, "a click at the frame's left edge reached a hidden column")
    local cell = table_cells(view, 4)[column]
    local center = cell_center(view, 4, column)
    test.ok(center + cell.width / 2 > content_left(view), "the clicked column is not visible")
  end)

  test.it("hides the caret of a cell scrolled out of the table frame", function()
    local view = wide_table_view()
    local last_cell = table_cells(view, 4)[9]
    local animated = config.animated_caret
    local old_draw_rect = renderer.draw_rect
    local drawn = 0
    config.animated_caret = false
    renderer.draw_rect = function() drawn = drawn + 1 end
    local ok, err = pcall(function()
      local x, y = view:get_caret_screen_position(4, last_cell.text_source_col1)
      view:draw_caret(x, y, 4, last_cell.text_source_col1)
      test.equal(drawn, 0, "a caret outside the table frame was drawn")
      x, y = view:get_caret_screen_position(4, table_cells(view, 4)[1].text_source_col1)
      view:draw_caret(x, y, 4, table_cells(view, 4)[1].text_source_col1)
      test.equal(drawn, 1, "a caret inside the table frame was not drawn")
    end)
    renderer.draw_rect = old_draw_rect
    config.animated_caret = animated
    if not ok then error(err, 0) end
  end)

  test.it("scrolls a wide table with a horizontal wheel over it", function()
    local view = wide_table_view()
    local transitions = config.transitions
    local mouse_x, mouse_y = core.root_panel.mouse.x, core.root_panel.mouse.y
    config.transitions = false
    local ok, err = pcall(function()
      local before, y = cell_center(view, 4, 1)
      core.root_panel.mouse.x, core.root_panel.mouse.y = before, y
      test.equal(view:on_mouse_wheel(0, -1), true)
      view:update()
      local after = cell_center(view, 4, 1)
      test.ok(after < before, "the wheel did not scroll the table")
      test.equal(view.scroll.x, 0)
      -- Shift+wheel scrolls the table back.
      keymap.modkeys.shift = true
      test.equal(view:on_mouse_wheel(1, 0), true)
      keymap.modkeys.shift = false
      view:update()
      test.equal(cell_center(view, 4, 1), before)
    end)
    keymap.modkeys.shift = false
    config.transitions = transitions
    core.root_panel.mouse.x, core.root_panel.mouse.y = mouse_x, mouse_y
    if not ok then error(err, 0) end
  end)

  test.it("scrolls a wide table from the scrollbar below it", function()
    local view = wide_table_view()
    local render = test.not_nil(view:get_line_render(4))
    local scrollbar
    for _, fragment in ipairs(render.fragments or {}) do
      if fragment.table_scrollbar then scrollbar = fragment end
    end
    test.not_nil(scrollbar, "an overflowing table needs a scrollbar")
    local _, line_y = view:get_line_screen_position(4)
    local y = line_y + scrollbar.draw_y_offset + scrollbar.widget.height / 2
    local right = view.position.x + view:get_gutter_width()
      + require("core.markdown.table_presentation").available_width(view) - 2
    view:on_mouse_moved(right, y, 0, 0)
    test.equal(view:on_mouse_pressed("left", right, y, 1), true)
    view:on_mouse_released("left", right, y)
    test.ok(visible(view, (cell_center(view, 4, 9))), "the scrollbar did not reach the last column")
    test.equal(view.buffer:get_selection(), 6, "the scrollbar moved the caret")
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

    test.equal(markdown_tables.insert_row(view, "below"), true)
    test.same(row_cells(buffer, 4), { "", "", "", "" })

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

  test.it("renders inline formatting and link labels inside cells", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| ship **done** now | see [the docs](https://example.com/a/b) |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local cells = table_cells(view, 3)
    test.equal(cells[1].text_lines[1].text, "ship done now")
    test.equal(cells[2].text_lines[1].text, "see the docs")
    local strong
    for _, run in ipairs(cells[1].text_lines[1].runs or {}) do
      if run.text == "done" then strong = run end
    end
    test.not_nil(strong, "bold text did not render as its own run")
    test.ok(strong.font ~= cells[1].font, "bold text used the cell's plain font")
  end)

  test.it("renders a link whose label is a code span as code", function()
    local view, buffer = make_view(
      "| Path | What |\n| --- | --- |\n| [`notes/`](notes) | Saved notes |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local line = table_cells(view, 3)[1].text_lines[1]
    test.equal(line.text, "notes/")
    test.equal(line.runs[#line.runs].background, style.markdown_live_inline_code_bg)
  end)

  test.it("keeps unbreakable link labels inside their column", function()
    local name = "a_very_long_attachment_name_for_this_table.pdf"
    local view, buffer = make_view(
      "| Path | What |\n| --- | --- |\n| [" .. name .. "](" .. name .. ") | "
        .. string.rep("words that wrap ", 12) .. "|\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local cell = table_cells(view, 3)[1]
    for _, text_line in ipairs(cell.text_lines) do
      for _, run in ipairs(text_line.runs or {}) do
        test.ok(run.x + run.width <= cell.width,
          ("run %q ends at %.1f past cell width %.1f"):format(
            run.text, run.x + run.width, cell.width))
      end
    end
  end)

  test.it("reveals only the syntax of the span holding the caret in an active cell", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| **a** b | two |\n\nplain")
    buffer:set_selection(3, buffer.lines[3]:find("b |", 1, true) + 1)
    refresh(view)
    test.equal(table_cells(view, 3)[1].text_lines[1].text, "a b")

    buffer:set_selection(3, buffer.lines[3]:find("a", 1, true) + 1)
    test.equal(table_cells(view, 3)[1].text_lines[1].text, "**a** b")
  end)

  test.it("keeps whole-cell selections rendered without revealing syntax", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| **a** b | ~~two~~ |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    test.equal(markdown_tables.select_row(view, 3), true)
    test.equal(table_cells(view, 3)[1].text_lines[1].text, "a b")
    test.equal(table_cells(view, 3)[2].text_lines[1].text, "two")

    buffer:set_selection(3, buffer.lines[3]:find("a", 1, true) + 1)
    test.equal(table_cells(view, 3)[1].text_lines[1].text, "**a** b")
  end)

  test.it("shows no carets in a group of selected cells", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | see [notes](https://example.com) |\n| three | four |\n\nplain"
    )
    buffer:set_selection(6, 1)
    refresh(view)
    local active_view, disable_blink = core.active_view, config.disable_blink
    local carets = {}
    view.active_window_has_focus = function() return true end
    view.draw_caret = function(_, _, _, line) carets[#carets + 1] = line end
    core.active_view, config.disable_blink = view, true
    local ok, err = pcall(function()
      test.equal(markdown_tables.select_column(view, 3, 1), true)
      view:draw_overlay()
      test.same(carets, {}, "selected cells drew carets")
      test.equal(markdown_tables.select_column(view, 3, 2), true)
      view:draw_overlay()
      test.same(carets, {}, "selected cells holding a link drew carets")
      buffer:set_selection(3, 3)
      view:draw_overlay()
      test.same(carets, { 3 }, "a caret in a cell was not drawn")
    end)
    core.active_view, config.disable_blink = active_view, disable_blink
    if not ok then error(err, 0) end
  end)

  test.it("places the caret after hidden syntax when clicking rendered text", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| **bold** x | two |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    local cell = table_cells(view, 3)[1]
    local line_x, line_y = view:get_line_screen_position(3)
    local runs = test.not_nil(cell.text_lines[1].runs)
    local x_run
    for _, run in ipairs(runs) do
      if run.text and run.text:match("x$") then x_run = run end
    end
    x_run = test.not_nil(x_run)
    local x = line_x + cell.layout_x + cell.text_lines[1].x_offset + x_run.x + x_run.width
    local y = line_y + cell.text_y_padding + 2
    local line, col = view:resolve_screen_position(x, y)
    test.same({ line, col }, { 3, buffer.lines[3]:find("x", 1, true) + 1 })
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
      test.same(row_cells(buffer, 4), { "", "" })
      test.same(row_cells(buffer, 5), { "three", "four" })
      buffer:undo()
      markdown_model.get(buffer):submit("interactive-table-command-undo")
      refresh(view)

      buffer:set_selection(3, 10)
      test.equal(command.perform("markdown:table_insert_column_left"), true)
      test.same(row_cells(buffer, 1), { "A", "", "B" })
      test.same(row_cells(buffer, 3), { "one", "", "two" })
      test.equal(#table_cells(view, 3), 3)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  local function with_active(view, fn)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(fn)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end

  local function source(buffer)
    return table.concat(buffer.lines):gsub("\n$", "")
  end

  test.it("formats a table into padded columns with alignment markers", function()
    local original = "| A | Long header |\n|:-|--:|\n| one | 2 |\n\nplain"
    local view, buffer = make_view(original)
    with_active(view, function()
      buffer:set_selection(3, 5)
      refresh(view)
      test.equal(command.perform("markdown:table_format"), true)
      test.equal(source(buffer), table.concat({
        "| A   | Long header |",
        "| :-- | ----------: |",
        "| one |           2 |",
        "",
        "plain",
      }, "\n"))
      local line, col = buffer:get_selection()
      test.same({ line, col }, { 3, 5 })
      buffer:undo()
      test.equal(source(buffer), original)
    end)
  end)

  test.it("aligns every column of a Table Cell Selection", function()
    local view, buffer = make_view("| A | B | C |\n| --- | --- | --- |\n| one | two | three |\n\nplain")
    with_active(view, function()
      buffer:set_selection(3, 4)
      refresh(view)
      test.equal(markdown_tables.select_rectangle(view, 3, 4, 3, 10), true)
      test.equal(command.perform("markdown:table_align_column_right"), true)
      local markers = row_cells(buffer, 2)
      test.ok(markers[1]:match("^%-+:$"), "first selected column is not right-aligned")
      test.ok(markers[2]:match("^%-+:$"), "second selected column is not right-aligned")
      test.ok(markers[3]:match("^%-+$"), "unselected column changed alignment")
      test.equal(#view.buffer.selections / 4, 2)

      markdown_model.get(buffer):submit("interactive-table-align")
      refresh(view)
      test.equal(table_cells(view, 3)[1].table_alignment, "right")
      test.equal(command.perform("markdown:table_clear_column_alignment"), true)
      test.ok(row_cells(buffer, 2)[1]:match("^%-+$"), "alignment was not cleared")
    end)
  end)

  test.it("sorts body rows by the caret's column with the header fixed", function()
    local view, buffer = make_view(
      "| Name | Size |\n| --- | --- |\n| b | 10 |\n| a | 9 |\n|  |  |\n| c |  |\n\nplain"
    )
    with_active(view, function()
      buffer:set_selection(3, 10)
      refresh(view)
      test.equal(command.perform("markdown:table_sort_ascending"), true)
      test.same(row_cells(buffer, 1), { "Name", "Size" })
      test.same(row_cells(buffer, 3), { "a", "9" })
      test.same(row_cells(buffer, 4), { "b", "10" })
      test.same({ caret_cell(buffer) }, { 4, 2 })

      test.equal(command.perform("markdown:table_sort_descending"), true)
      test.same(row_cells(buffer, 3), { "b", "10" })
      test.same(row_cells(buffer, 4), { "a", "9" })
      test.equal(row_cells(buffer, 5)[2], "")
      test.equal(row_cells(buffer, 6)[2], "")
    end)
  end)

  test.it("moves a column with its alignment as one undo step", function()
    local original = "| A | B |\n| :-- | --: |\n| 1 | 2 |\n\nplain"
    local view, buffer = make_view(original)
    with_active(view, function()
      buffer:set_selection(3, 3)
      refresh(view)
      test.equal(command.perform("markdown:table_move_column_right"), true)
      test.same(row_cells(buffer, 1), { "B", "A" })
      test.same(row_cells(buffer, 3), { "2", "1" })
      local markers = row_cells(buffer, 2)
      test.ok(markers[1]:match("^%-+:$") and markers[2]:match("^:%-+$"),
        "alignment did not move with its column")
      test.same({ caret_cell(buffer) }, { 3, 2 })
      buffer:undo()
      test.equal(source(buffer), original)
    end)
  end)

  test.it("inserts a new table below the caret line and starts in its header", function()
    local view, buffer = make_view("intro\nafter")
    with_active(view, function()
      buffer:set_selection(1, 6)
      refresh(view)
      test.equal(command.perform("markdown:insert_table"), true)
      test.equal(buffer.lines[1], "intro\n")
      test.equal(buffer.lines[2], "\n")
      test.same(row_cells(buffer, 3), { "", "" })
      test.ok(row_cells(buffer, 4)[1]:match("^%-+$"), "delimiter row is missing")
      test.same(row_cells(buffer, 5), { "", "" })
      test.equal(buffer.lines[6], "\n")
      test.equal(buffer.lines[7], "after\n")
      test.same({ caret_cell(buffer) }, { 3, 1 })

      refresh(view)
      test.equal(#table_cells(view, 3), 2)
      test.equal(command.perform("markdown:insert_table"), false)
      view:on_text_input("Name")
      test.equal(row_cells(buffer, 3)[1], "Name")
    end)
  end)

  local function with_clipboard(text, fn)
    local old_get = system.get_clipboard
    local old_clipboard = core.cursor_clipboard
    system.get_clipboard = function() return text end
    core.cursor_clipboard = nil
    local ok, err = pcall(fn)
    system.get_clipboard = old_get
    core.cursor_clipboard = old_clipboard
    if not ok then error(err, 0) end
  end

  test.it("turns a typed header row into a table on Enter", function()
    local view, buffer = make_view("Intro paragraph\n| Name | Owner |\nafter")
    with_active(view, function()
      buffer:set_selection(2, 17)
      refresh(view)
      test.equal(command.perform("markdown:table_from_header_row"), true)
      test.equal(buffer.lines[2], "\n")
      test.same(row_cells(buffer, 3), { "Name", "Owner" })
      test.ok(row_cells(buffer, 4)[1]:match("^%-+$"), "delimiter row is missing")
      test.same(row_cells(buffer, 5), { "", "" })
      test.equal(buffer.lines[6], "\n")
      test.equal(buffer.lines[7], "after\n")
      test.same({ caret_cell(buffer) }, { 5, 1 })
      refresh(view)
      test.equal(#table_cells(view, 3), 2)
      test.equal(#table_cells(view, 5), 2)
    end)
  end)

  test.it("keeps Enter literal for pipe rows that cannot start a table", function()
    local view, buffer = make_view(
      "```\n| a | b |\n```\n\n| only |\n\n| a | b |\n| --- | --- |"
    )
    with_active(view, function()
      refresh(view)
      buffer:set_selection(2, 10)
      test.equal(command.perform("markdown:table_from_header_row"), false)
      buffer:set_selection(5, 9)
      test.equal(command.perform("markdown:table_from_header_row"), false)
      buffer:set_selection(7, 10)
      test.equal(command.perform("markdown:table_from_header_row"), false)
    end)
  end)

  test.it("pastes spreadsheet cells into the grid and grows the table", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| one | two |\n\nplain")
    with_active(view, function()
      buffer:set_selection(3, 10)
      refresh(view)
      with_clipboard("x\ty|z\tw\n1\t2\t3\n", function()
        test.equal(command.perform("markdown:table_paste"), true)
      end)
      test.same(row_cells(buffer, 1), { "A", "B", "", "" })
      test.same(row_cells(buffer, 3), { "one", "x", "y\\|z", "w" })
      test.same(row_cells(buffer, 4), { "", "1", "2", "3" })
      test.same({ caret_cell(buffer) }, { 4, 4 })
    end)
  end)

  test.it("pastes spreadsheet rows outside a table as a new table", function()
    local view, buffer = make_view("intro")
    with_active(view, function()
      buffer:set_selection(1, 6)
      refresh(view)
      with_clipboard("plain text", function()
        test.equal(command.perform("markdown:paste_table"), false)
      end)
      with_clipboard('Name\tQty\r\napple\t3\r\n"two\r\nlines"\t10\r\n', function()
        test.equal(command.perform("markdown:paste_table"), true)
      end)
      test.same(row_cells(buffer, 3), { "Name", "Qty" })
      test.same(row_cells(buffer, 5), { "apple", "3" })
      test.same(row_cells(buffer, 6), { "two<br>lines", "10" })
      test.same({ caret_cell(buffer) }, { 6, 2 })
    end)
  end)

  test.it("pastes tab-indented notes outside a table as text", function()
    local view, buffer = make_view("intro")
    with_active(view, function()
      buffer:set_selection(1, 6)
      refresh(view)
      local notes = "la vista es:\n```sql\nselect *\t\nfrom Stock\nwhere a = 1\n\tand b = 2\n```\n"
      with_clipboard(notes, function()
        test.equal(command.perform("markdown:paste_table"), false)
      end)
      test.equal(buffer:get_text(1, 1, math.huge, math.huge), "intro")
    end)
  end)

  local function fragment_rect(view, line, fragment)
    local render = test.not_nil(view:get_line_render(line))
    local line_x, line_y = view:get_line_screen_position(line)
    return line_x + fragment.layout_x,
      line_y + (render.first_row_content_y_offset or 0) + fragment.draw_y_offset,
      fragment.hit_width, fragment.widget.height
  end

  -- The screen rectangle of a table handle: x, y, width, height. `side` picks
  -- the handle on the "right" of a row or "bottom" of a column.
  local function table_handle_rect(view, line, kind, index, side)
    local render = test.not_nil(view:get_line_render(line))
    for _, fragment in ipairs(render.fragments or {}) do
      if fragment.table_handle == kind and fragment.table_handle_index == index
      and (not side or fragment.table_handle_side == side)
      then
        return fragment_rect(view, line, fragment)
      end
    end
    error(kind .. " handle " .. tostring(index) .. " not found on line " .. line)
  end

  local function table_handle(view, line, kind, index, side)
    local x, y, width, height = table_handle_rect(view, line, kind, index, side)
    return x + width / 2, y + height / 2
  end

  -- The center of a visible insert button beside a selected row or column.
  local function insert_button(view, line, kind, side)
    local render = test.not_nil(view:get_line_render(line))
    for _, fragment in ipairs(render.fragments or {}) do
      if fragment.table_insert == side and fragment.table_insert_kind == kind
      and fragment.widget.visible(view)
      then
        local x, y, width, height = fragment_rect(view, line, fragment)
        return x + width / 2, y + height / 2
      end
    end
    error(kind .. " insert button " .. side .. " not visible on line " .. line)
  end

  local function has_insert_button(view, line)
    local render = test.not_nil(view:get_line_render(line))
    for _, fragment in ipairs(render.fragments or {}) do
      if fragment.table_insert and fragment.widget.visible(view) then return true end
    end
    return false
  end

  local function with_modkey(key, fn)
    local old = keymap.modkeys[key]
    keymap.modkeys[key] = true
    local ok, err = pcall(fn)
    keymap.modkeys[key] = old
    if not ok then error(err, 0) end
  end

  -- The screen rectangle of a table cell: x, y, width, height.
  local function cell_rect(view, line, column)
    local render = test.not_nil(view:get_line_render(line))
    for _, fragment in ipairs(render.fragments or {}) do
      if fragment.table_cell and fragment.table_column == column then
        local line_x, line_y = view:get_line_screen_position(line)
        return line_x + fragment.layout_x,
          line_y + (render.first_row_content_y_offset or 0),
          fragment.width, render.table_content_height or render.table_row_height
      end
    end
    error("table cell not found")
  end

  local function overlaps(x1, y1, w1, h1, x2, y2, w2, h2)
    return x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1
  end

  local function selected_cells(view)
    local cells = {}
    local selections = view.buffer.selections
    for index = 1, #selections, 4 do
      local line, col = selections[index], selections[index + 1]
      local text = (view.buffer.lines[line] or ""):gsub("\n$", "")
      local row = test.not_nil(markdown_tables.source_row(text))
      for column, cell in ipairs(row.cells) do
        if col >= cell.col1 and col <= cell.col2 then
          local other = selections[index + 3]
          test.equal(math.min(col, other), cell.content_col1,
            "selection did not cover the whole cell")
          test.equal(math.max(col, other), cell.content_col2,
            "selection did not cover the whole cell")
          cells[#cells + 1] = line .. ":" .. column
        end
      end
    end
    table.sort(cells)
    return cells
  end

  local function click_at(view, x, y)
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view:on_mouse_pressed("left", x, y, 1), true)
    view:on_mouse_released("left", x, y)
  end

  local function drag_from_to(view, x1, y1, x2, y2)
    view:on_mouse_moved(x1, y1, 0, 0)
    test.equal(view:on_mouse_pressed("left", x1, y1, 1), true)
    view:on_mouse_moved((x1 + x2) / 2, (y1 + y2) / 2, 0, 0)
    view:on_mouse_moved(x2, y2, 0, 0)
    view:on_mouse_released("left", x2, y2)
  end

  test.it("selects a whole row or column from its handle", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nplain"
    )
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 4, "row", 4))
    test.same(selected_cells(view), { "4:1", "4:2" })

    refresh(view)
    click_at(view, table_handle(view, 1, "column", 2))
    test.same(selected_cells(view), { "1:2", "3:2", "4:2" })
  end)

  test.it("drags a row handle to move the row as one undo step", function()
    local original = "| A | B |\n| --- | --- |\n| one | 1 |\n| two | 2 |\n| three | 3 |\n\nplain"
    local view, buffer = make_view(original)
    buffer:set_selection(7, 1)
    refresh(view)
    local x, y = table_handle(view, 3, "row", 3)
    local _, target_y = cell_center(view, 5, 1)
    drag_from_to(view, x, y, x, target_y)
    test.same(row_cells(buffer, 3), { "two", "2" })
    test.same(row_cells(buffer, 4), { "three", "3" })
    test.same(row_cells(buffer, 5), { "one", "1" })
    test.same(selected_cells(view), { "5:1", "5:2" })
    buffer:undo()
    test.equal(table.concat(buffer.lines):gsub("\n$", ""), original)
  end)

  test.it("drops a wide column onto a narrower column under the pointer", function()
    local view, buffer = make_view(
      "| A much, much wider header text | B |\n| --- | --- |\n| one | two |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local x, y = table_handle(view, 1, "column", 1)
    local target_x = cell_center(view, 3, 2)
    drag_from_to(view, x, y, target_x, y)
    test.same(row_cells(buffer, 1), { "B", "A much, much wider header text" })
    test.same(row_cells(buffer, 3), { "two", "one" })
  end)

  test.it("keeps the view still when a dragged row is dropped", function()
    local lines = { "# Title", "", "intro", "", "| A | B |", "| --- | --- |",
      "| one | 1 |", "| two | 2 |", "| three | 3 |", "" }
    for index = 1, 40 do lines[#lines + 1] = "line " .. index end
    local view, buffer = make_view(table.concat(lines, "\n"))
    buffer:set_selection(3, 1)
    refresh(view)
    with_active(view, function()
      view:update()
      local scroll_y = view.scroll.to.y
      local x, y = table_handle(view, 7, "row", 7)
      local _, target_y = cell_center(view, 9, 1)
      drag_from_to(view, x, y, x, target_y)
      test.same(row_cells(buffer, 9), { "one", "1" })
      for _ = 1, 3 do
        refresh(view)
        view:update()
      end
      test.equal(view.scroll.to.y, scroll_y, "dropping the row moved the view")
    end)
  end)

  test.it("drags a column handle to move the column and its alignment", function()
    local view, buffer = make_view(
      "| A | B | C |\n| --- | :---: | --- |\n| one | two | three |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local x, y = table_handle(view, 1, "column", 2)
    local target_x = cell_center(view, 3, 3)
    drag_from_to(view, x, y, target_x, y)
    test.same(row_cells(buffer, 1), { "A", "C", "B" })
    test.same(row_cells(buffer, 3), { "one", "three", "two" })
    test.ok(row_cells(buffer, 2)[3]:match("^:%-+:$"), "alignment did not move with its column")
    test.same(selected_cells(view), { "1:3", "3:3" })
  end)

  test.it("gives handles their own room beside and above the cells", function()
    local view = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nplain"
    )
    view.buffer:set_selection(6, 1)
    refresh(view)
    local line_x = view:get_line_screen_position(3)
    for _, line in ipairs({ 1, 3, 4 }) do
      for column = 1, 2 do
        local cx, cy, cw, ch = cell_rect(view, line, column)
        for _, handle in ipairs({ { 3, "row", 3 }, { 4, "row", 4 }, { 1, "column", 1 },
          { 1, "column", 2 } }) do
          local hx, hy, hw, hh = table_handle_rect(view, handle[1], handle[2], handle[3])
          test.ok(hx >= line_x, "a handle starts left of the table's own space")
          test.ok(not overlaps(hx, hy, hw, hh, cx, cy, cw, ch), string.format(
            "%s handle %d covers cell %d:%d", handle[2], handle[3], line, column
          ))
        end
      end
    end
  end)

  test.it("selects the row or column as soon as its handle is pressed", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| three | four |\n\nplain"
    )
    buffer:set_selection(6, 1)
    refresh(view)
    local x, y = table_handle(view, 1, "column", 1)
    view:on_mouse_moved(x, y, 0, 0)
    test.equal(view:on_mouse_pressed("left", x, y, 1), true)
    test.same(selected_cells(view), { "1:1", "3:1", "4:1" })
    view:on_mouse_released("left", x, y)
  end)

  test.it("keeps the view still when a column handle selects a tall column", function()
    local rows = { "| A | B |", "| --- | --- |" }
    for index = 1, 60 do rows[#rows + 1] = "| row " .. index .. " | value |" end
    rows[#rows + 1] = ""
    rows[#rows + 1] = "plain"
    local view, buffer = make_view(table.concat(rows, "\n"))
    buffer:set_selection(1, 1)
    refresh(view)
    with_active(view, function()
      view:update()
      local scroll_y = view.scroll.to.y
      click_at(view, table_handle(view, 1, "column", 2))
      test.equal(#selected_cells(view), 61)
      view:update()
      view:update()
      test.equal(view.scroll.to.y, scroll_y, "selecting the column moved the view")
    end)
  end)

  local GRID = "| A | B | C |\n| --- | --- | --- |\n| one | two | three |\n"
    .. "| four | five | six |\n\nplain"

  test.it("selects rows and columns from handles on their far sides", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 3, "row", 3, "right"))
    test.same(selected_cells(view), { "3:1", "3:2", "3:3" })

    refresh(view)
    click_at(view, table_handle(view, 4, "column", 2, "bottom"))
    test.same(selected_cells(view), { "1:2", "3:2", "4:2" })
  end)

  test.it("selects the header row from its handle", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "row", 1))
    test.same(selected_cells(view), { "1:1", "1:2", "1:3" })
  end)

  test.it("drags the header row down so a body row becomes the header", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    local x, y = table_handle(view, 1, "row", 1)
    local _, target_y = cell_center(view, 3, 1)
    drag_from_to(view, x, y, x, target_y)
    test.same(row_cells(buffer, 1), { "one", "two", "three" })
    test.same(row_cells(buffer, 3), { "A", "B", "C" })
    test.same(row_cells(buffer, 4), { "four", "five", "six" })
  end)

  test.it("adds and removes rows with Ctrl on their handles", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "row", 1))
    refresh(view)
    with_modkey("ctrl", function()
      click_at(view, table_handle(view, 4, "row", 4))
      test.same(selected_cells(view), { "1:1", "1:2", "1:3", "4:1", "4:2", "4:3" })
      refresh(view)
      click_at(view, table_handle(view, 1, "row", 1))
      test.same(selected_cells(view), { "4:1", "4:2", "4:3" })
    end)
  end)

  test.it("extends a column selection to the Shift-clicked column handle", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "column", 3))
    refresh(view)
    with_modkey("shift", function()
      click_at(view, table_handle(view, 1, "column", 1))
    end)
    test.same(selected_cells(view),
      { "1:1", "1:2", "1:3", "3:1", "3:2", "3:3", "4:1", "4:2", "4:3" })
  end)

  test.it("starts a fresh selection when Ctrl-clicking a handle of another kind", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 3, "row", 3))
    refresh(view)
    with_modkey("ctrl", function()
      click_at(view, table_handle(view, 1, "column", 1))
    end)
    test.same(selected_cells(view), { "1:1", "3:1", "4:1" })
  end)

  test.it("inserts a row beside a selected row from its insert buttons", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    test.equal(has_insert_button(view, 3), false)
    click_at(view, table_handle(view, 3, "row", 3))
    refresh(view)
    click_at(view, insert_button(view, 3, "row", "below"))
    test.same(row_cells(buffer, 3), { "one", "two", "three" })
    test.same(row_cells(buffer, 4), { "", "", "" })
    test.same(row_cells(buffer, 5), { "four", "five", "six" })
    test.same({ caret_cell(buffer) }, { 4, 1 })
  end)

  test.it("keeps a one-line row's grip usable while its insert buttons show", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 3, "row", 3))
    refresh(view)
    test.ok(has_insert_button(view, 3), "the selected row shows its insert buttons")
    -- The buttons leave the grip at least as long as it is wide.
    local _, grip_y, grip_width, grip_height = table_handle_rect(view, 3, "row", 3)
    local top, bottom = grip_y, grip_y + grip_height
    local _, above_y = insert_button(view, 3, "row", "above")
    local _, below_y = insert_button(view, 3, "row", "below")
    local render = view:get_line_render(3)
    for _, fragment in ipairs(render.fragments) do
      if fragment.table_insert == "above" and fragment.layout_x < grip_width * 2 then
        local _, y, _, height = fragment_rect(view, 3, fragment)
        if y + height > top and y < bottom then top = y + height end
      elseif fragment.table_insert == "below" and fragment.layout_x < grip_width * 2 then
        local _, y = fragment_rect(view, 3, fragment)
        if y < bottom and y >= grip_y then bottom = y end
      end
    end
    test.ok(above_y < below_y)
    test.ok(bottom - top >= grip_width, string.format(
      "the buttons leave %d of the grip uncovered", bottom - top
    ))
    local x, y = table_handle(view, 3, "row", 3)
    local _, target_y = cell_center(view, 4, 1)
    drag_from_to(view, x, y, x, target_y)
    test.same(row_cells(buffer, 3), { "four", "five", "six" })
    test.same(row_cells(buffer, 4), { "one", "two", "three" })
  end)

  test.it("deletes selected whole rows instead of blanking their cells", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 3, "row", 3))
    with_active(view, function()
      test.equal(command.perform("markdown:table_backspace"), true)
    end)
    test.same(row_cells(buffer, 1), { "A", "B", "C" })
    test.same(row_cells(buffer, 3), { "four", "five", "six" })
    test.equal(buffer.lines[4], "\n")
    buffer:undo()
    test.same(row_cells(buffer, 3), { "one", "two", "three" })
  end)

  test.it("makes the next row the header when the header row is deleted", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "row", 1))
    with_active(view, function()
      test.equal(command.perform("markdown:table_delete"), true)
    end)
    test.same(row_cells(buffer, 1), { "one", "two", "three" })
    test.same(row_cells(buffer, 3), { "four", "five", "six" })
  end)

  test.it("deletes selected whole columns with their alignment", function()
    local view, buffer = make_view(
      "| A | B | C |\n| --- | :---: | ---: |\n| one | two | three |\n\nplain"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "column", 2))
    with_active(view, function()
      test.equal(command.perform("markdown:table_delete"), true)
    end)
    test.same(row_cells(buffer, 1), { "A", "C" })
    test.same(row_cells(buffer, 3), { "one", "three" })
    test.ok(row_cells(buffer, 2)[2]:match("^%-+:$"), "the remaining alignment moved")
  end)

  test.it("gives a floating insert button the click over a taller row's grip", function()
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n| one | two |\n| three<br>more<br>lines | four |\n\nplain"
    )
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 3, "row", 3))
    refresh(view)
    click_at(view, insert_button(view, 3, "row", "below"))
    test.same(row_cells(buffer, 3), { "one", "two" })
    test.same(row_cells(buffer, 4), { "", "" })
    test.same(row_cells(buffer, 5), { "three<br>more<br>lines", "four" })
  end)

  test.it("deletes a selected column whose cells are all empty", function()
    local view, buffer = make_view("| A |  | C |\n| --- | --- | --- |\n| one |  | three |\n\nplain")
    buffer:set_selection(5, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "column", 2))
    with_active(view, function()
      test.equal(command.perform("markdown:table_delete"), true)
    end)
    test.same(row_cells(buffer, 1), { "A", "C" })
    test.same(row_cells(buffer, 3), { "one", "three" })
  end)

  test.it("removes the table when every row is selected and deleted", function()
    local view, buffer = make_view("before\n\n| A | B |\n| --- | --- |\n| one | two |\n\nafter")
    buffer:set_selection(1, 1)
    refresh(view)
    click_at(view, table_handle(view, 3, "row", 3))
    refresh(view)
    with_modkey("shift", function() click_at(view, table_handle(view, 5, "row", 5)) end)
    with_active(view, function()
      test.equal(command.perform("markdown:table_backspace"), true)
    end)
    test.equal(table.concat(buffer.lines):gsub("\n$", ""), "before\n\n\nafter")
  end)

  test.it("inserts a new header above the selected header row", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "row", 1))
    refresh(view)
    click_at(view, insert_button(view, 1, "row", "above"))
    test.same(row_cells(buffer, 1), { "", "", "" })
    test.same(row_cells(buffer, 3), { "A", "B", "C" })
    test.same({ caret_cell(buffer) }, { 1, 1 })
  end)

  test.it("inserts a column left of the leftmost selected column", function()
    local view, buffer = make_view(GRID)
    buffer:set_selection(6, 1)
    refresh(view)
    click_at(view, table_handle(view, 1, "column", 2))
    refresh(view)
    with_modkey("shift", function()
      click_at(view, table_handle(view, 1, "column", 3))
    end)
    refresh(view)
    click_at(view, insert_button(view, 1, "column", "left"))
    test.same(row_cells(buffer, 1), { "A", "", "B", "C" })
    test.same(row_cells(buffer, 4), { "four", "", "five", "six" })
  end)

  test.it("grows a cell selection across cells with Shift and the arrow keys", function()
    local view, buffer = make_view(GRID)
    with_active(view, function()
      buffer:set_selection(3, 5)
      refresh(view)
      -- The first press selects to the cell's end; the next leaves the cell.
      test.equal(command.perform("markdown:table_select_next_char"), true)
      test.equal(command.perform("markdown:table_select_next_char"), true)
      test.same(selected_cells(view), { "3:1", "3:2" })
      test.equal(command.perform("markdown:table_select_down"), true)
      test.same(selected_cells(view), { "3:1", "3:2", "4:1", "4:2" })
      test.equal(command.perform("markdown:table_select_previous_char"), true)
      test.same(selected_cells(view), { "3:1", "4:1" })
    end)
  end)

  test.it("turns Shift+Up and Shift+Down at a cell's edge into cell selection", function()
    local view, buffer = make_view(GRID)
    with_active(view, function()
      buffer:set_selection(3, 5)
      refresh(view)
      test.equal(command.perform("markdown:table_select_down"), true)
      test.same(selected_cells(view), { "3:1", "4:1" })
      -- Shrinking back to one cell keeps its whole contents selected.
      test.equal(command.perform("markdown:table_select_up"), true)
      test.same(selected_cells(view), { "3:1" })
      test.equal(command.perform("markdown:table_select_up"), true)
      test.same(selected_cells(view), { "1:1", "3:1" })
    end)
  end)

  test.it("keeps a keyboard cell selection inside the table at its edge", function()
    local view, buffer = make_view(GRID)
    with_active(view, function()
      buffer:set_selection(4, 3)
      refresh(view)
      test.equal(command.perform("markdown:table_select_down"), true)
      test.same(selected_cells(view), { "4:1" })
      test.equal(command.perform("markdown:table_select_up"), true)
      test.same(selected_cells(view), { "3:1", "4:1" })
    end)
  end)
end)
