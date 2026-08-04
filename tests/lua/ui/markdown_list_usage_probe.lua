-- Exploratory Markdown list-usage probes.
--
-- This file is intentionally red while the list editing contract is being
-- discovered.  It drives public editor seams and puts all observations into
-- one final failure so one unexpected behavior does not hide the later probes.
-- Do not turn these observations into assertions until the desired UX is
-- settled; keep adding scenarios here during exploration.

local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

require "core.commands.doc"

local observations = {}

local function quoted(value)
  return string.format("%q", tostring(value))
end

local function source(doc)
  return quoted(table.concat(doc.lines or {}))
end

local function selection(view)
  local state = view:get_selection_state() or {}
  local values = state.selections or {}
  local result = {}
  for index = 1, #values, 4 do
    result[#result + 1] = string.format(
      "%d:%d-%d:%d",
      values[index] or -1,
      values[index + 1] or -1,
      values[index + 2] or values[index] or -1,
      values[index + 3] or values[index + 1] or -1
    )
  end
  return table.concat(result, ",")
end

local function make_view(text, filename)
  local name = filename or ("markdown-list-probe-" .. tostring(system.get_process_id()) .. ".md")
  local doc = Doc(name, name, true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 520, 260
  view:set_wrapping_enabled(false)
  return view, doc
end

local function drain_until(instance, wanted, timeout)
  if not instance then return false end
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == wanted then
      core.redraw = true
      return true
    end
    core.redraw = false
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == wanted
end

local function refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.doc)
  if instance then
    drain_until(instance, "ready")
    linewrapping.complete_async_reconstruction(view)
  end
  return instance
end

local function with_active_view(view, callback)
  local old_active = core.active_view
  core.active_view = view
  local ok, a, b = pcall(callback)
  core.active_view = old_active
  if not ok then error(a, 0) end
  return a, b
end

local function visible_text(view, line)
  local rendered = view:get_line_render(line)
  if not rendered then return "<no-render>" end
  local text = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(rendered)) do
    if not fragment.hidden then
      if fragment.text and fragment.text ~= "" then
        text[#text + 1] = fragment.text
      elseif fragment.widget then
        text[#text + 1] = "<widget>"
      end
    end
  end
  return table.concat(text)
end

local function marker_kind(fragment)
  if fragment.markdown_task_checkbox then
    return "task-checkbox" .. (fragment.checked and ":checked" or ":unchecked")
  end
  if fragment.markdown_task_source_marker then return "task-source" end
  if fragment.unordered_list_marker then
    return "unordered" .. (fragment.widget and ":widget" or ":text")
  end
  if fragment.ordered_list_marker then
    return "ordered:" .. tostring(fragment.text or "")
  end
  if fragment.markdown_quote_marker then return "quote" end
end

local function render_summary(view, line)
  local rendered = view:get_line_render(line)
  if not rendered then return "<no-render>" end
  local markers = {}
  for _, fragment in ipairs(rendered.fragments or {}) do
    local kind = marker_kind(fragment)
    if kind then
      local x = view:get_line_render_col_x_offset(rendered, fragment.source_col1 or 1)
      markers[#markers + 1] = string.format(
        "%s@%s-%s,x=%.2f,text=%s",
        kind,
        tostring(fragment.source_col1),
        tostring(fragment.source_col2),
        x or -1,
        quoted(fragment.text or "")
      )
    end
  end
  return string.format(
    "visible=%s markers=[%s]",
    quoted(visible_text(view, line)),
    table.concat(markers, "; ")
  )
end

local function document_summary(view, doc, lines)
  local result = { "source=" .. source(doc), "selection=" .. selection(view) }
  for _, line in ipairs(lines or {}) do
    result[#result + 1] = string.format("line%d{%s}", line, render_summary(view, line))
  end
  return table.concat(result, " ")
end

local function probe(label, callback)
  local ok, result = pcall(callback)
  if ok then
    observations[#observations + 1] = label .. ": " .. tostring(result)
  else
    observations[#observations + 1] = label .. " ERROR: " .. tostring(result)
  end
end

local function perform(view, name)
  return with_active_view(view, function()
    return command.perform(name)
  end)
end

local function enter_case(label, text)
  local view, doc = make_view(text, "markdown-list-enter-probe.md")
  local instance = refresh(view)
  local first_line = doc.lines[1] or ""
  doc:set_selection(1, #first_line)
  local performed = perform(view, "doc:newline")
  local immediate = document_summary(view, doc, { 1, 2 })
  local pending = instance and instance.status or "<no-model>"
  if instance then
    drain_until(instance, "ready")
    linewrapping.complete_async_reconstruction(view)
  end
  local settled = document_summary(view, doc, { 1, 2 })
  return string.format(
    "performed=%s pending=%s immediate{%s} settled{%s}",
    tostring(performed), pending, immediate, settled
  )
end

local function backspace_case(label, text, line, col)
  local view, doc = make_view(text, "markdown-list-backspace-probe.md")
  refresh(view)
  doc:set_selection(line, col)
  local performed = perform(view, "doc:backspace")
  return string.format(
    "performed=%s at=%d:%d %s",
    tostring(performed), line, col, document_summary(view, doc, { line })
  )
end

local function delete_case(text, line, col)
  local view, doc = make_view(text, "markdown-list-delete-probe.md")
  refresh(view)
  doc:set_selection(line, col)
  local performed = perform(view, "doc:delete")
  return string.format(
    "performed=%s at=%d:%d %s",
    tostring(performed), line, col, document_summary(view, doc, { line, line + 1 })
  )
end

local function join_case(text, line, col)
  local view, doc = make_view(text, "markdown-list-join-probe.md")
  refresh(view)
  doc:set_selection(line, col)
  local performed = perform(view, "doc:join-lines")
  return string.format(
    "performed=%s at=%d:%d %s",
    tostring(performed), line, col, document_summary(view, doc, { line, line + 1 })
  )
end

local function indent_case()
  local view, doc = make_view(
    "- parent\n- child\n  existing nested\nplain",
    "markdown-list-indent-command-probe.md"
  )
  doc:set_selection(2, 1)
  refresh(view)
  local indent = perform(view, "doc:indent")
  local after_indent = document_summary(view, doc, { 1, 2, 3, 4 })
  local unindent = perform(view, "doc:unindent")
  return string.format(
    "indent=%s after_indent{%s} unindent=%s after_unindent{%s}",
    tostring(indent), after_indent, tostring(unindent),
    document_summary(view, doc, { 1, 2, 3, 4 })
  )
end

local function marker_geometry_case()
  local view, doc = make_view(
    "- unordered body\n1. ordered body\n12. wide ordered body\n3) paren body\n- [ ] task body",
    "markdown-list-marker-geometry-probe.md"
  )
  doc:set_selection(5, 1)
  refresh(view)
  local rows = {}
  for line = 1, 5 do
    local rendered = view:get_line_render(line)
    local marker
    for _, fragment in ipairs(rendered and rendered.fragments or {}) do
      if marker_kind(fragment) then marker = fragment break end
    end
    if marker then
      local body_col = marker.source_col2 or 1
      local body_x = view:get_col_x_offset(line, body_col)
      rows[#rows + 1] = string.format(
        "line%d marker=%s source=%s-%s width=%.2f body_col=%d body_x=%.2f gap=%.2f",
        line, marker_kind(marker), tostring(marker.source_col1),
        tostring(marker.source_col2), marker.width or 0, body_col, body_x,
        body_x - (marker.width or 0)
      )
    else
      rows[#rows + 1] = "line" .. line .. " no-marker"
    end
  end
  return table.concat(rows, " ")
end

local function wrapped_continuation_case()
  local view, doc = make_view(
    "- [ ] " .. string.rep("wrapped task words ", 12)
      .. "\n    aligned continuation text\n- next",
    "markdown-list-wrapped-continuation-probe.md"
  )
  view.size.x = 190
  view:set_wrapping_enabled(true)
  doc:set_selection(3, 1)
  refresh(view)
  local _, _, task_rows = linewrapping.get_line_idx_col_count(view, 1, 1)
  local _, _, continuation_rows = linewrapping.get_line_idx_col_count(view, 2, 1)
  local task_x = view:get_col_x_offset(1, 7)
  local continuation_x = view:get_col_x_offset(2, 5)
  doc:set_selection(1, 7)
  local positions = { selection(view) }
  for _ = 1, math.min(task_rows + continuation_rows + 2, 10) do
    positions[#positions + 1] = tostring(perform(view, "doc:move-to-next-line"))
      .. " => " .. selection(view)
  end
  return string.format(
    "task_rows=%d continuation_rows=%d task_x=%.2f continuation_x=%.2f positions=%s line1=%s line2=%s",
    task_rows, continuation_rows, task_x, continuation_x,
    table.concat(positions, " | "), render_summary(view, 1), render_summary(view, 2)
  )
end

local function drag_selection_case()
  local view, doc = make_view("- [ ] task body\n  continuation\nplain", "markdown-list-drag-probe.md")
  doc:set_selection(3, 1)
  refresh(view)
  local start_x, start_y = view:get_line_screen_position(1, 8)
  local finish_x, finish_y = view:get_line_screen_position(1, 1)
  return with_active_view(view, function()
    local pressed = command.perform(
      "doc:set-cursor", start_x, start_y + 2
    )
    local moved = view:on_mouse_moved(
      finish_x, finish_y + 2, finish_x - start_x, finish_y - start_y
    )
    view:on_mouse_released("left", finish_x, finish_y + 2)
    return string.format(
      "pressed=%s moved=%s released=true %s",
      tostring(pressed), tostring(moved),
      document_summary(view, doc, { 1, 2 })
    )
  end)
end

local function selection_delete_case()
  local view, doc = make_view("- first\n- second\nplain", "markdown-list-selection-delete-probe.md")
  refresh(view)
  doc:set_selection(1, 1, 2, 3)
  local before = selection(view)
  local performed = perform(view, "doc:delete")
  return string.format(
    "before=%s performed=%s %s",
    before, tostring(performed), document_summary(view, doc, { 1, 2, 3 })
  )
end

local function list_text_input_case()
  local view, doc = make_view("- body\nplain", "markdown-list-text-input-probe.md")
  local instance = refresh(view)
  doc:set_selection(1, 3)
  view:on_text_input("typed ")
  local pending = instance and instance.status or "<no-model>"
  local immediate = document_summary(view, doc, { 1, 2 })
  if instance then
    drain_until(instance, "ready")
    linewrapping.complete_async_reconstruction(view)
  end
  return string.format(
    "pending=%s immediate{%s} settled{%s}",
    pending, immediate, document_summary(view, doc, { 1, 2 })
  )
end

local function move_case(text, line, col, command_name, count, lines)
  local view, doc = make_view(text, "markdown-list-navigation-probe.md")
  refresh(view)
  doc:set_selection(line, col)
  local positions = { selection(view) }
  for _ = 1, count do
    positions[#positions + 1] = tostring(perform(view, command_name)) .. " => " .. selection(view)
  end
  return document_summary(view, doc, lines) .. " moves=" .. table.concat(positions, " | ")
end

local function x_mapping_case()
  local view, doc = make_view(
    "- [ ] task text\n  continuation text\n- [x] checked text\n    indented text",
    "markdown-list-alignment-probe.md"
  )
  doc:set_selection(4, 1)
  refresh(view)
  local task_x = view:get_col_x_offset(1, 7)
  local continuation_x = view:get_col_x_offset(2, 3)
  local checked_x = view:get_col_x_offset(3, 7)
  local indented_x = view:get_col_x_offset(4, 5)
  return string.format(
    "task_content_x=%.2f continuation_x=%.2f checked_content_x=%.2f indented_x=%.2f %s",
    task_x, continuation_x, checked_x, indented_x,
    document_summary(view, doc, { 1, 2, 3, 4 })
  )
end

local function marker_matrix_case()
  local view, doc = make_view(
    "- bullet\n* star\n+ plus\n1. dot ordered\n3) paren ordered\n  - nested\n  1. nested ordered\nplain",
    "markdown-list-marker-probe.md"
  )
  doc:set_selection(8, 1)
  refresh(view)
  local rows = {}
  for line = 1, 8 do rows[#rows + 1] = "line" .. line .. "{" .. render_summary(view, line) .. "}" end
  return table.concat(rows, " ")
end

local function pointer_case()
  local view, doc = make_view("- bullet\nplain", "markdown-list-pointer-probe.md")
  doc:set_selection(2, 1)
  refresh(view)
  local rendered = view:get_line_render(1)
  local marker
  for _, fragment in ipairs(rendered.fragments or {}) do
    if fragment.unordered_list_marker then marker = fragment break end
  end
  if not marker then return "no unordered marker" end
  local line_x, line_y = view:get_line_screen_position(1)
  local marker_x = view:get_line_render_col_x_offset(rendered, marker.source_col1 or 1)
  local width = marker.width or 0
  local hits = {}
  for _, offset in ipairs({ -2, 0, width / 2, width + 2, width + 12 }) do
    local hit_line, hit_col = view:resolve_screen_position(
      line_x + marker_x + offset,
      line_y + 2
    )
    hits[#hits + 1] = string.format("offset=%.2f=>%s:%s", offset, tostring(hit_line), tostring(hit_col))
  end
  return string.format(
    "marker_source=%s-%s marker_x=%.2f marker_width=%.2f hits=[%s]",
    tostring(marker.source_col1), tostring(marker.source_col2), marker_x, width,
    table.concat(hits, "; ")
  )
end

local function reveal_case()
  local view, doc = make_view(" - [ ] todo\nplain", "markdown-list-reveal-probe.md")
  doc:set_selection(2, 1)
  refresh(view)
  local inactive = render_summary(view, 1)
  doc:set_selection(1, 4)
  local marker = render_summary(view, 1)
  doc:set_selection(2, 1)
  local restored = render_summary(view, 1)
  return "inactive{" .. inactive .. "} marker_caret{" .. marker .. "} restored{" .. restored .. "}"
end

local function typing_case()
  local view, doc = make_view("- [ ] Before **bold** after\nplain", "markdown-list-typing-probe.md")
  doc:set_selection(2, 1)
  local instance = refresh(view)
  doc:set_selection(1, 13)
  view:on_text_input("X")
  local pending = instance and instance.status or "<no-model>"
  return string.format(
    "pending=%s %s",
    pending, document_summary(view, doc, { 1, 2 })
  )
end

local function wrapped_navigation_case()
  local long_text = "- " .. string.rep("long list words ", 18)
  local view, doc = make_view(long_text .. "\n- next item\nplain", "markdown-list-wrapped-navigation-probe.md")
  view.size.x = 180
  view:set_wrapping_enabled(true)
  doc:set_selection(3, 1)
  refresh(view)
  local _, _, rows = linewrapping.get_line_idx_col_count(view, 1, 1)
  doc:set_selection(1, 4)
  local positions = { selection(view) }
  for _ = 1, math.min(rows + 2, 8) do
    positions[#positions + 1] = tostring(perform(view, "doc:move-to-next-line")) .. " => " .. selection(view)
  end
  return string.format(
    "wrapped_rows=%s positions=%s line1=%s line2=%s",
    tostring(rows), table.concat(positions, " | "),
    render_summary(view, 1), render_summary(view, 2)
  )
end

local function enter_middle_case()
  local view, doc = make_view("- first item\n- second item\nplain", "markdown-list-enter-middle-probe.md")
  refresh(view)
  doc:set_selection(1, 6)
  local performed = perform(view, "doc:newline")
  return string.format(
    "performed=%s %s",
    tostring(performed), document_summary(view, doc, { 1, 2, 3, 4 })
  )
end

local function enter_marker_boundary_case()
  local view, doc = make_view(
    "- [ ] task text\n  continuation text\nplain",
    "markdown-list-enter-boundary-probe.md"
  )
  refresh(view)
  doc:set_selection(1, 7)
  local first = perform(view, "doc:newline")
  local after_first = document_summary(view, doc, { 1, 2, 3, 4 })
  local second = perform(view, "doc:newline")
  return string.format(
    "at-task-content-start first=%s second=%s after_first{%s} after_second{%s}",
    tostring(first), tostring(second), after_first,
    document_summary(view, doc, { 1, 2, 3, 4, 5 })
  )
end

local function enter_continuation_case()
  local view, doc = make_view(
    "- parent\n  continuation text\n- next",
    "markdown-list-enter-continuation-probe.md"
  )
  refresh(view)
  doc:set_selection(2, #doc.lines[2])
  local performed = perform(view, "doc:newline")
  return string.format(
    "performed=%s %s",
    tostring(performed), document_summary(view, doc, { 1, 2, 3, 4 })
  )
end

local function second_enter_case()
  local view, doc = make_view("- item\nnext", "markdown-list-second-enter-probe.md")
  refresh(view)
  doc:set_selection(1, #doc.lines[1])
  local first = perform(view, "doc:newline")
  doc:set_selection(2, #doc.lines[2])
  local second = perform(view, "doc:newline")
  return string.format(
    "first=%s second=%s %s",
    tostring(first), tostring(second), document_summary(view, doc, { 1, 2, 3, 4 })
  )
end

local function multicursor_enter_case()
  local view, doc = make_view("- first\n- second\nplain", "markdown-list-multicursor-probe.md")
  local instance = refresh(view)
  doc:set_selection(1, #doc.lines[1])
  doc:add_selection(2, #doc.lines[2])
  local before = selection(view)
  local performed = perform(view, "doc:newline")
  local immediate = document_summary(view, doc, { 1, 2, 3, 4, 5 })
  if instance then
    drain_until(instance, "ready")
    linewrapping.complete_async_reconstruction(view)
  end
  return string.format(
    "before=%s performed=%s immediate{%s} settled{%s}",
    before, tostring(performed), immediate,
    document_summary(view, doc, { 1, 2, 3, 4, 5 })
  )
end

local function undo_redo_case()
  local view, doc = make_view("- item\nnext", "markdown-list-undo-probe.md")
  refresh(view)
  doc:set_selection(1, #doc.lines[1])
  perform(view, "doc:newline")
  local edited = document_summary(view, doc, { 1, 2, 3 })
  local undo = perform(view, "doc:undo")
  local undone = document_summary(view, doc, { 1, 2 })
  local redo = perform(view, "doc:redo")
  local redone = document_summary(view, doc, { 1, 2, 3 })
  return string.format(
    "edited{%s} undo=%s undone{%s} redo=%s redone{%s}",
    edited, tostring(undo), undone, tostring(redo), redone
  )
end

local function multicursor_task_case()
  local view, doc = make_view(
    "- [ ] first\n- [x] second\nplain",
    "markdown-list-multicursor-task-probe.md"
  )
  local instance = refresh(view)
  doc:set_selection(1, 7)
  doc:add_selection(2, 7)
  local before = selection(view)
  local performed = perform(view, "doc:newline")
  local immediate = document_summary(view, doc, { 1, 2, 3, 4, 5 })
  if instance then
    drain_until(instance, "ready")
    linewrapping.complete_async_reconstruction(view)
  end
  return string.format(
    "before=%s performed=%s immediate{%s} settled{%s}",
    before, tostring(performed), immediate,
    document_summary(view, doc, { 1, 2, 3, 4, 5 })
  )
end

local function indentation_matrix_case()
  local view, doc = make_view(
    "- parent\n\t- tab child\n\t  tab continuation\n    - four child\n      four continuation\nplain",
    "markdown-list-indent-probe.md"
  )
  doc.get_indent_info = function() return false, 1 end
  doc:set_selection(6, 1)
  refresh(view)
  local positions = {}
  for line, col in ipairs({ 2, 3, 4, 5 }) do
    local source_line = line + 1
    positions[#positions + 1] = string.format(
      "line%d:col3_x=%.2f col5_x=%.2f",
      source_line,
      view:get_col_x_offset(source_line, 3),
      view:get_col_x_offset(source_line, 5)
    )
  end
  return table.concat(positions, " ") .. " " .. document_summary(view, doc, { 1, 2, 3, 4, 5, 6 })
end

local function time_ms(callback)
  local started = system.get_time()
  callback()
  return (system.get_time() - started) * 1000
end

local function ordered_revision_case()
  local count = 1500
  local lines = {}
  for i = 1, count do lines[i] = "1. ordered item " .. i end
  local view, doc = make_view(table.concat(lines, "\n"), "markdown-list-revision-probe.md")
  doc:set_selection(count, 1)
  refresh(view)
  view:get_line_render(1)
  doc:set_selection(count, #(doc.lines[count] or ""))
  view:on_text_input("!")
  local cold_ms = time_ms(function() view:get_line_render(1) end)
  local hot_ms = time_ms(function() view:get_line_render(1) end)
  return string.format(
    "lines=%d render_after_revision_ms=%.3f cached_repeat_ms=%.3f source_tail=%s",
    count, cold_ms, hot_ms, quoted(doc.lines[count] or "")
  )
end

test.describe("Markdown list usage exploration (intentional report)", function()
  test.it("records real list editing and navigation observations", function()
    probe("Enter/plain bullet", function() return enter_case("plain", "- plain\nnext") end)
    probe("Enter/unchecked task", function() return enter_case("task", "- [ ] task\nnext") end)
    probe("Enter/checked task", function() return enter_case("checked-task", "- [x] task\nnext") end)
    probe("Enter/ordered dot", function() return enter_case("ordered-dot", "3. dot item\nnext") end)
    probe("Enter/ordered parenthesis", function() return enter_case("ordered-paren", "3) paren item\nnext") end)
    probe("Enter/plus bullet", function() return enter_case("plus", "+ plus item\nnext") end)
    probe("Enter/star bullet", function() return enter_case("star", "* star item\nnext") end)
    probe("Enter/nested bullet", function() return enter_case("nested", "  - nested item\nnext") end)
    probe("Enter/empty bullet", function() return enter_case("empty", "- \nnext") end)
    probe("Enter/in the middle of an item", enter_middle_case)
    probe("Enter/at task content boundary and repeat", enter_marker_boundary_case)
    probe("Enter/on a continuation line", enter_continuation_case)
    probe("Enter/twice to leave a list", second_enter_case)
    probe("Enter/multiple cursors in list items", multicursor_enter_case)
    probe("Enter/multiple task cursors", multicursor_task_case)

    probe("Backspace/nested content start", function()
      return backspace_case("nested-content", "- parent\n  - child\nafter", 2, 5)
    end)
    probe("Backspace/nested marker start", function()
      return backspace_case("nested-marker", "- parent\n  - child\nafter", 2, 3)
    end)
    probe("Backspace/empty nested item", function()
      return backspace_case("empty-nested", "- parent\n  - \nafter", 2, 5)
    end)
    probe("Backspace/empty task item", function()
      return backspace_case("empty-task", "- [ ] \nafter", 1, 7)
    end)
    probe("Delete/at nested marker start", function()
      return delete_case("- parent\n  - child\nafter", 2, 3)
    end)
    probe("Delete/at nested content start", function()
      return delete_case("- parent\n  - child\nafter", 2, 5)
    end)
    probe("Delete/at list line end", function()
      return delete_case("- first\n- second\nafter", 1, 8)
    end)
    probe("Delete/empty list line", function()
      return delete_case("- \nnext", 1, 3)
    end)
    probe("Join/list item with list item", function()
      return join_case("- first\n- second\nplain", 1, 5)
    end)
    probe("Join/list item with continuation", function()
      return join_case("- parent\n  continuation\nplain", 1, 5)
    end)
    probe("Indent-unindent/list item", indent_case)

    probe("Navigation/list marker widths", function()
      return move_case("- short\n- a much longer list item\n- third", 1, 5, "doc:move-to-next-line", 3, { 1, 2, 3 })
    end)
    probe("Navigation/continuation line", function()
      return move_case("- parent\n  continuation\n  more continuation\n- next", 1, 5, "doc:move-to-next-line", 3, { 1, 2, 3, 4 })
    end)
    probe("Navigation/back across list lines", function()
      return move_case("- first\n  continuation\n- third", 3, 5, "doc:move-to-previous-line", 3, { 1, 2, 3 })
    end)
    probe("Navigation/Home-End in task", function()
      local view, doc = make_view("  - [ ] task text\nplain", "markdown-list-home-end-probe.md")
      doc:set_selection(1, 10)
      refresh(view)
      local before = selection(view)
      local home = perform(view, "doc:move-to-start-of-indentation")
      local after_home = selection(view)
      local ending = perform(view, "doc:move-to-end-of-line")
      return string.format(
        "before=%s home=%s=>%s end=%s=>%s %s",
        before, tostring(home), after_home, tostring(ending), selection(view),
        document_summary(view, doc, { 1 })
      )
    end)

    probe("Rendering/marker matrix", marker_matrix_case)
    probe("Rendering/marker geometry and gaps", marker_geometry_case)
    probe("Rendering/task continuation alignment", x_mapping_case)
    probe("Pointer/bullet hit mapping", pointer_case)
    probe("Reveal/task marker transitions", reveal_case)
    probe("Typing/task plus inline formatting while pending", typing_case)
    probe("Wrapped navigation through list item", wrapped_navigation_case)
    probe("Wrapped task continuation and navigation", wrapped_continuation_case)
    probe("Mouse drag across task marker", drag_selection_case)
    probe("Selection delete across list markers", selection_delete_case)
    probe("Text input immediately after list marker", list_text_input_case)
    probe("Undo-redo/structural list newline", undo_redo_case)
    probe("Indentation/tabs versus spaces", indentation_matrix_case)
    probe("Revision/ordered-list render cost", ordered_revision_case)

    test.fail(
      "Exploratory observations (intentional failure; convert confirmed contracts into focused tests later):\n"
        .. table.concat(observations, "\n")
    )
  end)
end)
