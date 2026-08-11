local core = require "core"
local command = require "core.command"
local config = require "core.config"
local DocView = require "core.docview"
local markdown_completion = require "core.markdown.completion"
local markdown_live = require "core.markdown.live_render"
local markdown_tables = require "core.markdown.tables"
local markdown_rename_links = require "core.markdown.rename_links"
local markdown_vault_index = require "core.markdown.vault_index"

command.add(function()
  local view = core.active_view
  if view and view:extends(DocView) and markdown_live.is_markdown_doc(view.doc) then
    return true, view
  end
  return false
end, {
  ["markdown-live-preview:toggle-source-mode"] = function(view)
    markdown_live.toggle_source_mode(view, "command-toggle")
  end,
  ["markdown-live-preview:source-mode"] = function(view)
    markdown_live.set_source_mode(view, true, "command-source")
  end,
  ["markdown-live-preview:live-mode"] = function(view)
    markdown_live.set_source_mode(view, false, "command-live")
  end,
  ["markdown-live-preview:open-link"] = function(view)
    markdown_live.open_link(view)
  end,
  ["markdown-live-preview:create-link-target"] = function(view)
    markdown_live.create_link_target(view)
  end,
  ["markdown-live-preview:complete-link"] = function(view)
    markdown_completion.open(view)
  end,
  ["markdown-live-preview:load-remote-image"] = function(view)
    markdown_live.allow_remote_image_once(view)
  end,
  ["markdown-live-preview:trust-project-remote-images"] = function(view)
    markdown_live.set_project_remote_image_trust(view, true)
  end,
  ["markdown-live-preview:untrust-project-remote-images"] = function(view)
    markdown_live.set_project_remote_image_trust(view, false)
  end,
  ["markdown-live-preview:review-rename-link-updates"] = function(view)
    markdown_rename_links.present(markdown_vault_index.pending_rename(view.doc.abs_filename))
  end,
})

command.add(function()
  local view = core.active_view
  if config.markdown_live_interactive_tables == true
  and view and view:extends(DocView)
  and markdown_live.is_markdown_doc(view.doc)
  and markdown_live.is_live_mode(view)
  and markdown_tables.has_interactive_context(view)
  then
    return true, view
  end
  return false
end, {
  ["markdown-live-preview:table-next-cell"] = function(view)
    markdown_tables.navigate(view, "next")
  end,
  ["markdown-live-preview:table-previous-cell"] = function(view)
    markdown_tables.navigate(view, "previous")
  end,
  ["markdown-live-preview:table-cell-below"] = function(view)
    markdown_tables.navigate(view, "below")
  end,
  ["markdown-live-preview:table-cell-up"] = function(view)
    markdown_tables.move_vertical(view, -1, false)
  end,
  ["markdown-live-preview:table-cell-down"] = function(view)
    markdown_tables.move_vertical(view, 1, false)
  end,
  ["markdown-live-preview:table-select-up"] = function(view)
    markdown_tables.move_vertical(view, -1, true)
  end,
  ["markdown-live-preview:table-select-down"] = function(view)
    markdown_tables.move_vertical(view, 1, true)
  end,
  ["markdown-live-preview:table-insert-cell-break"] = function(view)
    markdown_tables.insert_cell_break(view)
  end,
  ["markdown-live-preview:table-previous-char"] = function(view)
    markdown_tables.move_char(view, -1, false)
  end,
  ["markdown-live-preview:table-next-char"] = function(view)
    markdown_tables.move_char(view, 1, false)
  end,
  ["markdown-live-preview:table-select-previous-char"] = function(view)
    markdown_tables.move_char(view, -1, true)
  end,
  ["markdown-live-preview:table-select-next-char"] = function(view)
    markdown_tables.move_char(view, 1, true)
  end,
  ["markdown-live-preview:table-backspace"] = function(view)
    markdown_tables.delete_char(view, -1)
  end,
  ["markdown-live-preview:table-delete"] = function(view)
    markdown_tables.delete_char(view, 1)
  end,
})

command.add(function()
  local view = core.active_view
  if config.markdown_live_interactive_tables == true
  and view and view:extends(DocView)
  and markdown_live.is_markdown_doc(view.doc)
  and markdown_live.is_live_mode(view)
  and markdown_tables.has_interactive_context(view)
  and markdown_tables.has_text_clipboard()
  then
    return true, view
  end
  return false
end, {
  ["markdown-live-preview:table-paste"] = function(view)
    markdown_tables.paste(view)
  end,
})

command.add(function(x, y)
  local view = core.active_view
  if config.markdown_live_interactive_tables == true
  and view and view:extends(DocView)
  and markdown_live.is_markdown_doc(view.doc)
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
  ["markdown-live-preview:table-paste-primary"] = function(view, x, y)
    markdown_tables.paste_primary(view, x, y)
  end,
})

command.add(function()
  local view = core.active_view
  if view and view:extends(DocView)
  and markdown_live.is_markdown_doc(view.doc)
  and markdown_tables.has_command_context(view)
  then
    return true, view
  end
  return false
end, {
  ["markdown-live-preview:table-insert-row-above"] = function(view)
    markdown_tables.insert_row(view, "above")
  end,
  ["markdown-live-preview:table-insert-row-below"] = function(view)
    markdown_tables.insert_row(view, "below")
  end,
  ["markdown-live-preview:table-delete-row"] = function(view)
    markdown_tables.delete_row(view)
  end,
  ["markdown-live-preview:table-move-row-up"] = function(view)
    markdown_tables.move_row(view, -1)
  end,
  ["markdown-live-preview:table-move-row-down"] = function(view)
    markdown_tables.move_row(view, 1)
  end,
  ["markdown-live-preview:table-insert-column-left"] = function(view)
    markdown_tables.insert_column(view, "left")
  end,
  ["markdown-live-preview:table-insert-column-right"] = function(view)
    markdown_tables.insert_column(view, "right")
  end,
  ["markdown-live-preview:table-delete-column"] = function(view)
    markdown_tables.delete_column(view)
  end,
  ["markdown-live-preview:table-move-column-left"] = function(view)
    markdown_tables.move_column(view, -1)
  end,
  ["markdown-live-preview:table-move-column-right"] = function(view)
    markdown_tables.move_column(view, 1)
  end,
})
