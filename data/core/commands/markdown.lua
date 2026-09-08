local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local markdown_completion = require "core.markdown.completion"
local markdown_live = require "core.markdown.live_render"
local markdown_tables = require "core.markdown.tables"
local markdown_rename_links = require "core.markdown.rename_links"
local markdown_vault_index = require "core.markdown.vault_index"

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
  ["markdown:table_insert_row_above"] = function(view)
    markdown_tables.insert_row(view, "above")
  end,
  ["markdown:table_insert_row_below"] = function(view)
    markdown_tables.insert_row(view, "below")
  end,
  ["markdown:table_delete_row"] = function(view)
    markdown_tables.delete_row(view)
  end,
  ["markdown:table_move_row_up"] = function(view)
    markdown_tables.move_row(view, -1)
  end,
  ["markdown:table_move_row_down"] = function(view)
    markdown_tables.move_row(view, 1)
  end,
  ["markdown:table_insert_column_left"] = function(view)
    markdown_tables.insert_column(view, "left")
  end,
  ["markdown:table_insert_column_right"] = function(view)
    markdown_tables.insert_column(view, "right")
  end,
  ["markdown:table_delete_column"] = function(view)
    markdown_tables.delete_column(view)
  end,
  ["markdown:table_move_column_left"] = function(view)
    markdown_tables.move_column(view, -1)
  end,
  ["markdown:table_move_column_right"] = function(view)
    markdown_tables.move_column(view, 1)
  end,
})
