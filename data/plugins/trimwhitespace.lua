-- mod-version:3
local config = require "core.config"
local command = require "core.command"
local Buffer = require "core.buffer"

---Configuration options for `trimwhitespace` plugin.
---@class config.plugins.trimwhitespace
---Disable or enable the trimming of white spaces by default.
---@field enabled boolean
---Remove any empty new lines at the end of documents.
---@field trim_empty_end_lines boolean
config.plugins.trimwhitespace.config_spec = {
    name = "Trim Whitespace",
    {
      label = "Enabled",
      description = "Disable or enable the trimming of white spaces by default.",
      path = "enabled",
      type = "toggle",
      default = false
    },
    {
      label = "Trim Empty End Lines",
      description = "Remove any empty new lines at the end of Buffers.",
      path = "trim_empty_end_lines",
      type = "toggle",
      default = false
    }
  }

---@class plugins.trimwhitespace
local trimwhitespace = {}

---Disable whitespace trimming for a specific buffer.
---@param buffer core.buffer
function trimwhitespace.disable(buffer)
  buffer.disable_trim_whitespace = true
end

---Re-enable whitespace trimming if previously disabled.
---@param buffer core.buffer
function trimwhitespace.enable(buffer)
  buffer.disable_trim_whitespace = nil
end

---Perform whitespace trimming in all lines of a buffer except the
---line where the caret is currently positioned.
---@param buffer core.buffer
function trimwhitespace.trim(buffer)
  local protected_cols_by_line = {}
  local function protect_endpoint(line, col)
    protected_cols_by_line[line] = math.max(protected_cols_by_line[line] or 0, col)
  end
  local function protect_selections(selections)
    for i = 1, #(selections or {}), 4 do
      local line1, col1, line2, col2 = selections[i], selections[i + 1], selections[i + 2], selections[i + 3]
      if line1 and col1 then protect_endpoint(line1, col1) end
      if line2 and col2 then protect_endpoint(line2, col2) end
    end
  end

  protect_selections(buffer.selections)

  local ok, TextView = pcall(require, "core.textview")
  local views = ok and TextView.registry and TextView.registry[buffer]
  if views then
    for view in pairs(views) do
      if view.buffer == buffer and view.selection_state then
        protect_selections(view.selection_state.selections)
      end
    end
  end

  local edits = {}
  for i = 1, #buffer.lines do
    local line = buffer.lines[i]
    local content_end = #line - 1
    local keep_end = content_end
    while keep_end > 0 do
      local byte = line:byte(keep_end)
      if byte ~= 32 and (byte < 9 or byte > 13) then break end
      keep_end = keep_end - 1
    end

    -- don't remove whitespace which would cause any caret/selection endpoint to reposition
    local protected_col = protected_cols_by_line[i]
    if protected_col then
      keep_end = math.max(keep_end, protected_col - 1)
    end

    if keep_end < content_end then
      edits[#edits + 1] = {
        line1 = i,
        col1 = keep_end + 1,
        line2 = i,
        col2 = content_end + 1,
        text = "",
      }
    end
  end
  if #edits > 0 then
    local snapshots = ok and TextView.snapshot_registered_selection_states
      and TextView.snapshot_registered_selection_states(buffer)
      or nil
    local selections = {}
    for i = 1, #(buffer.selections or {}) do selections[i] = buffer.selections[i] end
    buffer:apply_edits(edits, {
      type = "replace",
      selections = selections,
      last_selection = buffer.last_selection,
      merge_cursors = false,
    })
    if snapshots and TextView.restore_registered_selection_states then
      TextView.restore_registered_selection_states(buffer, snapshots)
    end
  end
end

---Removes all empty new lines at the end of the buffer.
---@param buffer core.buffer
---@param raw_remove? boolean Perform the removal not registering to undo stack
function trimwhitespace.trim_empty_end_lines(buffer, raw_remove)
  if raw_remove then
    for _=#buffer.lines, 1, -1 do
      local l = #buffer.lines
      if l > 1 and buffer.lines[l] == "\n" then
        table.remove(buffer.lines, l)
      else
        break
      end
    end
    return
  end

  local first_empty
  for l = #buffer.lines, 2, -1 do
    if buffer.lines[l] == "\n" then
      first_empty = l
    else
      break
    end
  end
  if not first_empty then return end

  local current_line = buffer:get_selection()
  if current_line and current_line >= first_empty then
    buffer:set_selection(first_empty - 1, math.huge, first_empty - 1, math.huge)
  end
  buffer:remove(first_empty - 1, math.huge, #buffer.lines, math.huge)
end


command.add("core.textview", {
  ["trim-whitespace:trim-trailing-whitespace"] = function(dv)
    if dv.can_edit and not dv:can_edit("trim whitespace", { warn = true }) then return end
    trimwhitespace.trim(dv.buffer)
  end,

  ["trim-whitespace:trim-empty-end-lines"] = function(dv)
    if dv.can_edit and not dv:can_edit("trim whitespace", { warn = true }) then return end
    trimwhitespace.trim_empty_end_lines(dv.buffer)
  end,
})


local buffer_save = Buffer.save
Buffer.save = function(self, ...)
  if
    config.plugins.trimwhitespace.enabled
    and
    not self.disable_trim_whitespace
  then
    trimwhitespace.trim(self)
    if config.plugins.trimwhitespace.trim_empty_end_lines then
      trimwhitespace.trim_empty_end_lines(self)
    end
  end
  buffer_save(self, ...)
end


return trimwhitespace
