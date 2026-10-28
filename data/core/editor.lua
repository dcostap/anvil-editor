local core = require "core"
local common = require "core.common"
local bookmarks = require "core.bookmarks"
local style = require "core.style"
local editor_file_pois = require "core.editor_file_pois"
local language_mode = require "core.language_mode"
local navigation_history = require "core.navigation_history"
local TextView = require "core.textview"
local view_icons = require "core.view_icons"

---@class core.editor : core.textview
---@overload fun(buffer: core.buffer):core.editor
---@field super core.textview
local Editor = TextView:extend()

Editor.records_edit_navigation = true

view_icons.register("editor", view_icons.ui("K"))

function Editor:__tostring()
  return "Editor"
end

function Editor:new(buffer)
  Editor.super.new(self, buffer)
  self.remote_poi_source_capable = true
  self:add_poi_provider("core.editor-file-location", editor_file_pois, { priority = 0 })
  if core.buffer_registry then core.buffer_registry:retain(buffer, self) end
  self.pending_bookmark_attach = buffer:is_loading()
  if not self.pending_bookmark_attach then bookmarks.attach(buffer) end
end

function Editor:bookmark_gutter_width()
  if not self.buffer.abs_filename or self.buffer.git_historical_key then return 0 end
  return self:get_font():get_height() * 0.6 + style.padding.x
end

function Editor:get_gutter_width()
  local width, padding = Editor.super.get_gutter_width(self)
  return width + self:bookmark_gutter_width(), padding
end

function Editor:draw_line_gutter(line, x, y, width)
  local lane = self:bookmark_gutter_width()
  local height = Editor.super.draw_line_gutter(self, line, x + lane, y, width - lane)
  if lane > 0 and bookmarks.at(self.buffer, line) then
    local row_height = self:get_position_visual_row_height(line, 1)
    local icon_height = common.round(math.min(row_height, self:get_font():get_height()) * 0.7)
    local icon_width = common.round(icon_height * 0.65)
    local left = x + (lane - icon_width) / 2
    local top = y + (row_height - icon_height) / 2
    local notch = math.max(1, common.round(icon_height * 0.3))
    renderer.draw_rect(left, top, icon_width, icon_height - notch, style.bookmark)
    for row = 0, notch - 1 do
      local leg = math.max(1, common.round(icon_width * (1 - row / notch) / 2))
      renderer.draw_rect(left, top + icon_height - notch + row, leg, 1, style.bookmark)
      renderer.draw_rect(left + icon_width - leg, top + icon_height - notch + row, leg, 1, style.bookmark)
    end
  end
  return height
end

function Editor:draw_line_body(line, x, y)
  local height = Editor.super.draw_line_body(self, line, x, y)
  editor_file_pois.draw_line(self, line, x, y)
  return height
end

function Editor:update()
  if self.buffer:is_loading() or self.buffer.load_error then return end
  if self.pending_bookmark_attach then
    self.pending_bookmark_attach = nil
    bookmarks.attach(self.buffer)
  end
  Editor.super.update(self)
  editor_file_pois.update(self)
  navigation_history.update(self)
end

function Editor:draw()
  if self.buffer:is_loading() or self.buffer.load_error then
    self:draw_background(style.background)
    local message = self.buffer.load_error and ("Could not load file: " .. self.buffer.load_error)
      or "Loading file..."
    common.draw_text(style.font, style.dim, message, "left",
      self.position.x + style.padding.x, self.position.y + style.padding.y,
      math.max(0, self.size.x - style.padding.x * 2), style.font:get_height())
    return
  end
  return Editor.super.draw(self)
end

function Editor:release_buffer()
  if self.buffer_retention_released then return end
  self.buffer_retention_released = true
  if core.buffer_registry then core.buffer_registry:release(self.buffer, self) end
end

function Editor:on_history_discarded()
  self:on_close()
end

function Editor:on_close()
  require("core.poi").clear_remote_source(self)
  editor_file_pois.close(self)
  Editor.super.on_close(self)
  self:release_buffer()
  if self.discard_buffer_on_close and core.buffer_registry
      and core.buffer_registry:reference_count(self.buffer) == 0 then
    core.buffer_registry:remove(self.buffer, true)
  end
end

function Editor:can_suspend()
  return self.buffer.abs_filename ~= nil
end

function Editor:get_pane_constraint()
  if not self.buffer.abs_filename then return self end
end

function Editor:get_navigation_state()
  return {
    selection_state = self:get_selection_state(),
    scroll = { x = self.scroll.x, y = self.scroll.y },
  }
end

function Editor:set_navigation_state(state, opts)
  if state.selection_state then self:set_selection_state(state.selection_state) end
  if state.scroll then
    self.scroll.to.x = state.scroll.x or 0
    self.scroll.to.y = state.scroll.y or 0
    if not (opts and opts.animate_scroll) then
      self.scroll.x, self.scroll.y = self.scroll.to.x, self.scroll.to.y
      self.scroll.move_data_x, self.scroll.move_data_y = nil, nil
    end
  end
  -- Same-View history already has valid layout and must keep its transition.
  self.needs_initial_scroll_validation = not (opts and opts.animate_scroll) or nil
end

function Editor:duplicate()
  local copy = Editor(self.buffer)
  copy:set_navigation_state(self:get_navigation_state())
  copy:set_wrapping_enabled(self:is_wrapping_enabled())
  copy:restore_owned_feature_state(self:get_owned_feature_state())
  for _, fold in ipairs(self.fold_regions or {}) do
    if fold.kind ~= "markdown-callout" then
      copy:add_fold_region {
        line1 = fold.line1,
        col1 = fold.col1,
        line2 = fold.line2,
        col2 = fold.col2,
        collapsed = fold.collapsed,
        placeholder = fold.placeholder,
        show_widget = fold.show_widget,
        allow_nested = fold.allow_nested,
        kind = fold.kind,
        metadata = fold.metadata,
      }
    end
  end
  return copy
end

function Editor.from_state(state)
  local editor
  if not state.filename then
    editor = Editor(core.open_buffer())
  else
    local ok, buffer = pcall(core.open_buffer, state.filename)
    -- Only new files save their text. A saved file that opens as new was deleted.
    if ok and buffer.new_file and not state.text
        and core.buffer_registry:reference_count(buffer) == 0 then
      buffer:mark_file_missing()
    end
    if ok then editor = Editor(buffer) end
  end

  if not editor then return nil end
  if editor.buffer.new_file and state.text then
    editor.buffer:insert(1, 1, state.text)
    editor.buffer.crlf = state.crlf
  end
  if state.inferred_language_mode then
    language_mode.set_buffer_inference(editor.buffer, state.inferred_language_mode, {
      reason = "workspace-restore",
    })
  end
  if state.language_mode then
    editor.buffer:set_language_mode(state.language_mode, { reason = "workspace-restore" })
  end
  if state.selection_state then
    editor:set_selection_state(state.selection_state)
  elseif state.selection then
    editor:set_selection_state({ selections = state.selection, last_selection = 1 })
  end
  editor.last_line1, editor.last_col1, editor.last_line2, editor.last_col2 =
    table.unpack(editor.selection_state.selections, 1, 4)
  local scroll = state.scroll or { x = 0, y = 0 }
  editor.scroll.x, editor.scroll.to.x = scroll.x or 0, scroll.x or 0
  editor.scroll.y, editor.scroll.to.y = scroll.y or 0, scroll.y or 0
  -- The saved top line keeps its place when the restored rows have other
  -- heights, such as the provisional rows of a long document's first wrap.
  local anchor = state.scroll_anchor
  if anchor and anchor.line and anchor.line <= #editor.buffer.lines then
    editor:restore_viewport_anchor({ line = anchor.line, col = anchor.col or 1, content_y = anchor.content_y })
  end
  editor.needs_initial_scroll_validation = true
  -- Restore presentation before feature state, even when another Pane keeps focus.
  require("core.markdown.live_render").refresh_view(editor)
  editor:restore_owned_feature_state(state.owned_features)
  return editor
end

local icons = require("core.context_menu").icons

local MARKDOWN_TABLE_MENU = {
  { label = "Insert Row Above", icon = icons.row_above, command = "markdown:table_insert_row_above" },
  { label = "Insert Row Below", icon = icons.row_below, command = "markdown:table_insert_row_below" },
  { label = "Delete Row", icon = icons.row_delete, command = "markdown:table_delete_row" },
  "-",
  { label = "Insert Column Left", icon = icons.column_left, command = "markdown:table_insert_column_left" },
  { label = "Insert Column Right", icon = icons.column_right, command = "markdown:table_insert_column_right" },
  { label = "Delete Column", icon = icons.column_delete, command = "markdown:table_delete_column" },
  "-",
  { label = "Align Left", icon = icons.align_left, command = "markdown:table_align_column_left" },
  { label = "Align Center", icon = icons.align_center, command = "markdown:table_align_column_center" },
  { label = "Align Right", icon = icons.align_right, command = "markdown:table_align_column_right" },
  "-",
  { label = "Sort Ascending", icon = icons.sort_ascending, command = "markdown:table_sort_ascending" },
  { label = "Sort Descending", icon = icons.sort_descending, command = "markdown:table_sort_descending" },
  { label = "Format Table", icon = icons.tidy, command = "markdown:table_format" },
}

local MARKDOWN_PARAGRAPH_MENU = {
  { label = "Normal Text", icon = icons.text, command = "markdown:normal_text" },
  { label = "Heading 1", icon = icons.heading_1, command = "markdown:heading_1" },
  { label = "Heading 2", icon = icons.heading_2, command = "markdown:heading_2" },
  { label = "Heading 3", icon = icons.heading_3, command = "markdown:heading_3" },
  "-",
  { label = "Bulleted List", icon = icons.bullet_list, command = "markdown:toggle_bullet_list" },
  { label = "Numbered List", icon = icons.numbered_list, command = "markdown:toggle_numbered_list" },
  { label = "Task List", icon = icons.task_list, command = "markdown:toggle_task_list" },
  { label = "Quote", icon = icons.quote, command = "markdown:toggle_quote" },
}

local MARKDOWN_FORMAT_MENU = {
  { label = "Strikethrough", icon = icons.strikethrough, command = "markdown:surround_strikethrough" },
  { label = "Inline Code", icon = icons.code, command = "markdown:surround_code" },
  "-",
  { label = "Code Block", icon = icons.code_block, command = "markdown:insert_code_block" },
  { label = "Callout", icon = icons.callout, command = "markdown:insert_callout" },
}

local MARKDOWN_INSERT_MENU = {
  { label = "Table", icon = icons.table, command = "markdown:insert_table" },
  { label = "Link", icon = icons.link, command = "markdown:insert_link" },
  { label = "Code Block", icon = icons.code_block, command = "markdown:insert_code_block" },
  { label = "Callout", icon = icons.callout, command = "markdown:insert_callout" },
  { label = "Footnote", icon = icons.footnote, command = "markdown:add_footnote" },
}

---A Markdown Editor offers writing commands instead of the code commands of a Text View.
---Selected text gets formatting. A caret gets paragraph styles and things to insert.
function Editor:context_menu(x, y)
  local live = require "core.markdown.live_render"
  if not live.is_markdown_buffer(self.buffer) then return Editor.super.context_menu(self, x, y) end
  self:place_context_menu_caret(x, y)
  local editable = self:can_edit("context menu")
  local selected = self.buffer:has_selection()
  local items = {}
  local function add(item) items[#items + 1] = item end
  if not selected and require("core.poi").point_at_caret(self, { activatable = true, silent = true }) then
    add { label = "Open", icon = icons.open, command = "core:activate_point_of_interest" }
    add "-"
  end
  if selected then
    if editable then add { label = "Cut", icon = icons.cut, command = "core:cut" } end
    add { label = "Copy", icon = icons.copy, command = "core:copy" }
  end
  if editable then
    add { label = "Paste", icon = icons.paste, command = { "markdown:table_paste", "markdown:paste_table", "core:paste" } }
  end
  if not selected then add { label = "Select All", icon = icons.select_all, command = "core:select_all" } end
  add "-"
  if selected then
    add { label = "Bold", icon = icons.bold, command = "markdown:surround_bold" }
    add { label = "Italic", icon = icons.italic, command = "markdown:surround_italic" }
    add { label = "Link", icon = icons.link, command = "markdown:insert_link" }
    add { label = "Format", icon = icons.format, items = MARKDOWN_FORMAT_MENU }
    add { label = "Paragraph", icon = icons.text, items = MARKDOWN_PARAGRAPH_MENU }
    add { label = "Add Text Note", icon = icons.note, command = "markdown:add_text_note" }
  else
    add { label = "Paragraph", icon = icons.text, items = MARKDOWN_PARAGRAPH_MENU }
    add { label = "Insert", icon = icons.insert, items = MARKDOWN_INSERT_MENU }
    add { label = "Table", icon = icons.table, items = MARKDOWN_TABLE_MENU }
    add { label = "Edit Footnote", icon = icons.edit, command = "markdown:edit_footnote" }
    add { label = "Remove Footnote", icon = icons.delete, command = "markdown:remove_footnote" }
  end
  add "-"
  local live_mode = live.is_live_mode(self)
  add {
    label = live_mode and "Show Markdown Source" or "Show Live Preview",
    icon = live_mode and icons.source or icons.preview,
    command = "markdown:toggle_source_mode",
  }
  return items
end

return Editor
