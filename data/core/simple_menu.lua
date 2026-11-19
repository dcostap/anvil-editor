-- Simple Mode's Menu Bar: File, Edit, Format, View and Help, for users who edit text and Markdown files and do not
-- use the Command Palette. The Title Bar shows the bar and opens its menus.
local command = require "core.command"
local icons = require("core.context_menu").icons

local simple_menu = {}

local function item(label, name, icon) return {label = label, command = name, icon = icon} end
-- A toggle that is on shows a check in place of its icon.
local function toggle(label, name, icon) return {label = label, command = name, icon = icon, toggle = true} end

simple_menu.MENUS = {
  {label = "File", items = {
    item("New File", "editor:open", icons.new_file),
    item("Open File…", "core:pick_file_with_system_picker", icons.open_file),
    item("Open Folder…", "core:open_project_folder_system_file_picker", icons.folder),
    item("Find File…", "fuzzy:open_files", icons.file_search),
    "-",
    item("Save", "editor:save", icons.save),
    item("Save As…", "editor:save_as", icons.save_as),
    item("Rename…", "editor:rename", icons.rename),
    item("Show in File Explorer", "editor:reveal_active_file_in_explorer", icons.reveal),
    "-",
    item("Close Tab", "pane:close", icons.close),
    item("Reopen Closed Tab", "core:reopen_last_closed_pane", icons.reopen),
    "-",
    item("New Window", "core:new_anvil_window"),
    item("Close Window", "core:close_current_window"),
  }},
  {label = "Edit", items = {
    item("Undo", "core:undo", icons.undo),
    item("Redo", "core:redo", icons.redo),
    "-",
    item("Cut", "core:cut", icons.cut),
    item("Copy", "core:copy", icons.copy),
    item("Paste", "core:paste", icons.paste),
    item("Paste as Plain Text", "core:paste_as_plain_text"),
    item("Select All", "core:select_all", icons.select_all),
    "-",
    item("Find…", "editor:find", icons.search),
    item("Replace…", "editor:replace", icons.replace),
    item("Find in Files…", "fuzzy:open_grep", icons.text_search),
    item("Go to Heading…", "fuzzy:open_current_buffer_symbols", icons.heading),
    "-",
    item("Back", "core:navigate_back", icons.back),
    item("Forward", "core:navigate_forward", icons.forward),
  }},
  {label = "Format", items = {
    item("Bold", "markdown:surround_bold", icons.bold),
    item("Italic", "markdown:surround_italic", icons.italic),
    item("Strikethrough", "markdown:surround_strikethrough", icons.strikethrough),
    item("Inline Code", "markdown:surround_code", icons.code),
    "-",
    {label = "Heading", icon = icons.heading, items = {
      item("Normal Text", "markdown:normal_text", icons.text),
      item("Heading 1", "markdown:heading_1", icons.heading_1),
      item("Heading 2", "markdown:heading_2", icons.heading_2),
      item("Heading 3", "markdown:heading_3", icons.heading_3),
      item("Heading 4", "markdown:heading_4"),
      item("Heading 5", "markdown:heading_5"),
      item("Heading 6", "markdown:heading_6"),
    }},
    item("Bulleted List", "markdown:toggle_bullet_list", icons.bullet_list),
    item("Numbered List", "markdown:toggle_numbered_list", icons.numbered_list),
    item("Task List", "markdown:toggle_task_list", icons.task_list),
    item("Quote", "markdown:toggle_quote", icons.quote),
    "-",
    {label = "Insert", icon = icons.insert, items = {
      item("Link", "markdown:insert_link", icons.link),
      item("Table", "markdown:insert_table", icons.table),
      item("Code Block", "markdown:insert_code_block", icons.code_block),
      item("Callout", "markdown:insert_callout", icons.callout),
      item("Footnote", "markdown:add_footnote", icons.footnote),
    }},
  }},
  {label = "View", items = {
    toggle("Markdown Source", "markdown:toggle_source_mode"),
    "-",
    toggle("Sidebar", "core:toggle_project_sidebar"),
    item("File Tree", "filetree:open_at_project_root", icons.file_tree),
    "-",
    toggle("Word Wrap", "editor:toggle_line_wrapping"),
    toggle("Centered Text", "editor:toggle_centered"),
    toggle("Line Numbers", "core:toggle_line_numbers"),
    "-",
    item("Zoom In", "editor:zoom_in", icons.zoom_in),
    item("Zoom Out", "editor:zoom_out", icons.zoom_out),
    item("Reset Zoom", "editor:zoom_reset"),
    "-",
    item("Theme…", "core:select_theme", icons.theme),
    item("Wallpaper…", "core:select_wallpaper", icons.wallpaper),
    toggle("Full Screen", "core:toggle_fullscreen", icons.fullscreen),
  }},
  {label = "Help", items = {
    item("Settings", "settings:open", icons.settings),
    item("Check for Updates…", "updater:check", icons.update),
    "-",
    item("Exit Simple Mode", "core:toggle_simple_mode", icons.exit),
  }},
}

---The Context Menu items of menu `index`. An item whose command cannot run now shows dim.
---@param index integer
function simple_menu.items(index)
  local function convert(items)
    local result = {}
    for _, entry in ipairs(items) do
      if entry == "-" then
        result[#result + 1] = entry
      elseif entry.items then
        result[#result + 1] = {label = entry.label, icon = entry.icon, items = convert(entry.items)}
      else
        local on = entry.toggle and command.get_status(entry.command) == true
        result[#result + 1] = {label = entry.label, command = entry.command, show_disabled = true,
          icon = on and icons.check or entry.icon}
      end
    end
    return result
  end
  return convert(simple_menu.MENUS[index].items)
end

return simple_menu
