local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local markdown_completion = require "core.markdown.completion"
local markdown_live = require "core.markdown.live_render"
local footnotes = require "core.markdown.footnotes"
local markdown_tables = require "core.markdown.tables"
local markdown_rename_links = require "core.markdown.rename_links"
local markdown_vault_index = require "core.markdown.vault_index"

local function live_preview_editor()
  local view = core.active_view
  if view and view:extends(Editor) and markdown_live.is_live_mode(view) then
    return true, view
  end
  return false
end

command.add(live_preview_editor, {
  ["markdown:add_footnote"] = command.palette(function(view)
    footnotes.add(view)
  end),
})

-- A Text Note goes on selected text.
command.add(function()
  local ok, view = live_preview_editor()
  if ok and view.buffer:has_selection() then return true, view end
  return false
end, {
  ["markdown:add_text_note"] = command.palette(function(view)
    footnotes.add(view, { on_text = true })
  end),
})

command.add(function()
  local ok, view = live_preview_editor()
  local note = ok and footnotes.note_at_caret(view)
  if note then return true, view, note end
  return false
end, {
  ["markdown:edit_footnote"] = command.palette(function(view, note)
    footnotes.begin_edit(view, note)
  end),
  ["markdown:remove_footnote"] = command.palette(function(view, note)
    footnotes.remove(view, note)
  end),
})

command.add(function()
  local owner = footnotes.input_owner(core.active_view)
  if owner then return true, owner end
  return false
end, {
  ["markdown:save_footnote"] = function(view)
    footnotes.commit_edit(view)
  end,
  ["markdown:cancel_footnote"] = function(view)
    footnotes.cancel_edit(view)
  end,
})

local function alternate_list_item_checkbox(view)
  local buffer = view.buffer
  local line = buffer:get_selection()
  local selection_state = view:get_selection_state()
  local text = buffer.lines[line]:sub(1, -2)
  local indent, body = text:match("^([ \t]*)(.*)$")
  local bullet, task, content = body:match("^([%-%*%+])%s+%[([ xX])%]%s*(.*)$")
  local replacement
  if bullet then
    replacement = indent .. bullet .. (task == " " and " [x] " or " [ ] ") .. content
  else
    bullet, content = body:match("^([%-%*%+])%s+(.*)$")
    if bullet then
      replacement = indent .. bullet .. " [ ] " .. content
    else
      content = body:match("^%d+[.)]%s+(.*)$") or body
      replacement = indent .. "- " .. content
    end
  end
  buffer:replace_cursor(nil, line, 1, line, #buffer.lines[line], function()
    return replacement
  end)
  local column_delta = #replacement - #text
  for index = 1, #selection_state.selections, 2 do
    if selection_state.selections[index] == line then
      selection_state.selections[index + 1] = math.max(
        1, selection_state.selections[index + 1] + column_delta
      )
    end
  end
  view:set_selection_state(selection_state)
end

command.add(function()
  local view = core.active_view
  if view and view:extends(Editor) and markdown_live.is_markdown_buffer(view.buffer) then
    return true, view
  end
  return false
end, {
  ["markdown:toggle_source_mode"] = command.palette(function(view)
    markdown_live.toggle_source_mode(view, "command-toggle")
  end),
  ["markdown:source_mode"] = command.palette(function(view)
    markdown_live.set_source_mode(view, true, "command-source")
  end),
  ["markdown:live_mode"] = command.palette(function(view)
    markdown_live.set_source_mode(view, false, "command-live")
  end),
  ["markdown:open_link"] = command.palette(function(view)
    markdown_live.open_link(view)
  end),
  ["markdown:create_link_target"] = command.palette(function(view)
    markdown_live.create_link_target(view)
  end),
  ["markdown:complete_link"] = command.palette(function(view)
    markdown_completion.open(view)
  end),
  ["markdown:load_remote_image"] = command.palette(function(view)
    markdown_live.allow_remote_image_once(view)
  end),
  ["markdown:trust_project_remote_images"] = command.palette(function(view)
    markdown_live.set_project_remote_image_trust(view, true)
  end),
  ["markdown:untrust_project_remote_images"] = command.palette(function(view)
    markdown_live.set_project_remote_image_trust(view, false)
  end),
  ["markdown:review_rename_link_updates"] = command.palette(function(view)
    markdown_rename_links.present(markdown_vault_index.pending_rename(view.buffer.abs_filename))
  end),
  ["markdown:alternate_list_item_checkbox"] = command.palette(function(view)
    alternate_list_item_checkbox(view)
  end),
})


command.add(function()
  local view = core.active_view
  if config.markdown_live_interactive_tables == true
  and view and view:extends(Editor)
  and markdown_live.is_markdown_buffer(view.buffer)
  and markdown_live.is_live_mode(view)
  and markdown_tables.has_interactive_context(view)
  then
    return true, view
  end
  return false
end, {
  ["markdown:table_next_cell"] = function(view)
    markdown_tables.navigate(view, "next")
  end,
  ["markdown:table_previous_cell"] = function(view)
    markdown_tables.navigate(view, "previous")
  end,
  ["markdown:table_cell_below"] = function(view)
    markdown_tables.navigate(view, "below")
  end,
  ["markdown:table_cell_up"] = function(view)
    markdown_tables.move_vertical(view, -1, false)
  end,
  ["markdown:table_cell_down"] = function(view)
    markdown_tables.move_vertical(view, 1, false)
  end,
  ["markdown:table_select_up"] = function(view)
    markdown_tables.move_vertical(view, -1, true)
  end,
  ["markdown:table_select_down"] = function(view)
    markdown_tables.move_vertical(view, 1, true)
  end,
  ["markdown:table_insert_cell_break"] = function(view)
    markdown_tables.insert_cell_break(view)
  end,
  ["markdown:table_previous_char"] = function(view)
    markdown_tables.move_char(view, -1, false)
  end,
  ["markdown:table_next_char"] = function(view)
    markdown_tables.move_char(view, 1, false)
  end,
  ["markdown:table_select_previous_char"] = function(view)
    markdown_tables.move_char(view, -1, true)
  end,
  ["markdown:table_select_next_char"] = function(view)
    markdown_tables.move_char(view, 1, true)
  end,
  ["markdown:table_backspace"] = function(view)
    markdown_tables.delete_char(view, -1)
  end,
  ["markdown:table_delete"] = function(view)
    markdown_tables.delete_char(view, 1)
  end,
})

command.add(function()
  local view = core.active_view
  if config.markdown_live_interactive_tables == true
  and view and view:extends(Editor)
  and markdown_live.is_markdown_buffer(view.buffer)
  and markdown_live.is_live_mode(view)
  and markdown_tables.has_interactive_context(view)
  and markdown_tables.has_text_clipboard()
  then
    return true, view
  end
  return false
end, {
  ["markdown:table_paste"] = function(view)
    markdown_tables.paste(view)
  end,
})

command.add(function(x, y)
  local view = core.active_view
  if config.markdown_live_interactive_tables == true
  and view and view:extends(Editor)
  and markdown_live.is_markdown_buffer(view.buffer)
  and markdown_live.is_live_mode(view)
  and ((type(x) == "number" and type(y) == "number")
    and markdown_tables.has_interactive_position(view, x, y)
    or (x == nil or y == nil) and markdown_tables.has_interactive_context(view))
  and markdown_tables.has_primary_selection()
  then
    return true, view, x, y
  end
  return false
end, {
  ["markdown:table_paste_primary"] = function(view, x, y)
    markdown_tables.paste_primary(view, x, y)
  end,
})

command.add(function()
  local view = core.active_view
  if view and view:extends(Editor)
  and markdown_live.is_markdown_buffer(view.buffer)
  and markdown_tables.has_command_context(view)
  then
    return true, view
  end
  return false
end, {
  ["markdown:table_insert_row_above"] = command.palette(function(view)
    markdown_tables.insert_row(view, "above")
  end),
  ["markdown:table_insert_row_below"] = command.palette(function(view)
    markdown_tables.insert_row(view, "below")
  end),
  ["markdown:table_delete_row"] = command.palette(function(view)
    markdown_tables.delete_row(view)
  end),
  ["markdown:table_move_row_up"] = command.palette(function(view)
    markdown_tables.move_row(view, -1)
  end),
  ["markdown:table_move_row_down"] = command.palette(function(view)
    markdown_tables.move_row(view, 1)
  end),
  ["markdown:table_insert_column_left"] = command.palette(function(view)
    markdown_tables.insert_column(view, "left")
  end),
  ["markdown:table_insert_column_right"] = command.palette(function(view)
    markdown_tables.insert_column(view, "right")
  end),
  ["markdown:table_delete_column"] = command.palette(function(view)
    markdown_tables.delete_column(view)
  end),
  ["markdown:table_move_column_left"] = command.palette(function(view)
    markdown_tables.move_column(view, -1)
  end),
  ["markdown:table_move_column_right"] = command.palette(function(view)
    markdown_tables.move_column(view, 1)
  end),
  ["markdown:table_align_column_left"] = command.palette(function(view)
    markdown_tables.set_alignment(view, "left")
  end),
  ["markdown:table_align_column_center"] = command.palette(function(view)
    markdown_tables.set_alignment(view, "center")
  end),
  ["markdown:table_align_column_right"] = command.palette(function(view)
    markdown_tables.set_alignment(view, "right")
  end),
  ["markdown:table_clear_column_alignment"] = command.palette(function(view)
    markdown_tables.set_alignment(view, nil)
  end),
  ["markdown:table_sort_ascending"] = command.palette(function(view)
    markdown_tables.sort_rows(view, false)
  end),
  ["markdown:table_sort_descending"] = command.palette(function(view)
    markdown_tables.sort_rows(view, true)
  end),
  ["markdown:table_format"] = command.palette(function(view)
    markdown_tables.format(view)
  end),
})

command.add(function()
  local view = core.active_view
  if view and view:extends(Editor)
  and not view.buffer.read_only
  and markdown_live.is_markdown_buffer(view.buffer)
  and markdown_tables.can_insert_table(view)
  then
    return true, view
  end
  return false
end, {
  ["markdown:insert_table"] = command.palette(function(view)
    markdown_tables.insert_table(view, 2, 1)
  end),
})

local function live_table_editing(view)
  return config.markdown_live_interactive_tables == true
    and view and view:extends(Editor)
    and not view.buffer.read_only
    and markdown_live.is_markdown_buffer(view.buffer)
    and markdown_live.is_live_mode(view)
end

command.add(function()
  local view = core.active_view
  if live_table_editing(view) and markdown_tables.header_row_at_caret(view) then
    return true, view
  end
  return false
end, {
  ["markdown:table_from_header_row"] = function(view)
    markdown_tables.create_from_header_row(view)
  end,
})

command.add(function()
  local view = core.active_view
  if live_table_editing(view) and markdown_tables.can_paste_table(view) then
    return true, view
  end
  return false
end, {
  ["markdown:paste_table"] = command.palette(function(view)
    markdown_tables.paste_table(view)
  end),
})
