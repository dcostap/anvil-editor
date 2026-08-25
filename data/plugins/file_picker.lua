-- mod-version:3
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local file_picker = {}

---@class plugins.file_picker.options
---@field select "any"|"file"|"folder"? Accepted path type. Defaults to `any`.
---@field extensions string[]? Allowed file extensions, with or without a leading period.
---@field query string? Initial path query.
---@field label string? Status label.
---@field source_view core.view? View that started the interaction.
---@field source_pane core.panes.pane? Pane that started the interaction.
---@field submit fun(path: string, context: table) Called once after selection.
---@field cancel fun(reason: string)? Called once if selection does not finish.

---Open a File Picker.
---@param options plugins.file_picker.options
---@return table
function file_picker.open(options)
  return fuzzy_searcher.open_file_picker(options)
end

return file_picker
