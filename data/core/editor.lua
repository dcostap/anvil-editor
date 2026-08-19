local core = require "core"
local TextView = require "core.textview"
local view_icons = require "core.view_icons"

---@class core.editor : core.textview
---@overload fun(buffer: core.buffer):core.editor
---@field super core.textview
local Editor = TextView:extend()

view_icons.register("editor", view_icons.ui("K"))

function Editor:__tostring()
  return "Editor"
end

function Editor:new(buffer)
  Editor.super.new(self, buffer)
  if core.buffer_registry then core.buffer_registry:retain(buffer, self) end
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

function Editor:get_navigation_state()
  return {
    selection_state = self:get_selection_state(),
    scroll = { x = self.scroll.x, y = self.scroll.y },
  }
end

function Editor:set_navigation_state(state)
  if state.selection_state then self:set_selection_state(state.selection_state) end
  if state.scroll then
    self.scroll.x, self.scroll.to.x = state.scroll.x or 0, state.scroll.x or 0
    self.scroll.y, self.scroll.to.y = state.scroll.y or 0, state.scroll.y or 0
  end
end

function Editor.from_state(state)
  local editor
  if not state.filename then
    editor = Editor(core.open_buffer())
  else
    local ok, buffer = pcall(core.open_buffer, state.filename)
    if ok then editor = Editor(buffer) end
  end

  if not editor then return nil end
  if editor.buffer.new_file and state.text then
    editor.buffer:insert(1, 1, state.text)
    editor.buffer.crlf = state.crlf
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
  editor.needs_initial_scroll_validation = true
  editor:restore_owned_feature_state(state.owned_features)
  return editor
end

return Editor
