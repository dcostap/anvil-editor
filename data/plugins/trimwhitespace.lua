-- mod-version:3
local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"

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
      description = "Remove any empty new lines at the end of documents.",
      path = "trim_empty_end_lines",
      type = "toggle",
      default = false
    }
  }

---@class plugins.trimwhitespace
local trimwhitespace = {}

---Disable whitespace trimming for a specific document.
---@param doc core.doc
function trimwhitespace.disable(doc)
  doc.disable_trim_whitespace = true
end

---Re-enable whitespace trimming if previously disabled.
---@param doc core.doc
function trimwhitespace.enable(doc)
  doc.disable_trim_whitespace = nil
end

---Perform whitespace trimming in all lines of a document except the
---line where the caret is currently positioned.
---@param doc core.doc
function trimwhitespace.trim(doc)
  local cline, ccol = doc:get_selection()
  local edits = {}
  for i = 1, #doc.lines do
    local old_text = doc:get_text(i, 1, i, math.huge)
    local new_text = old_text:gsub("%s*$", "")

    -- don't remove whitespace which would cause the caret to reposition
    if cline == i and ccol > #new_text then
      new_text = old_text:sub(1, ccol - 1)
    end

    if old_text ~= new_text then
      edits[#edits + 1] = {
        line1 = i,
        col1 = 1,
        line2 = i,
        col2 = #doc.lines[i],
        text = new_text,
      }
    end
  end
  if #edits > 0 then
    local selections = {}
    for i = 1, #(doc.selections or {}) do selections[i] = doc.selections[i] end
    doc:apply_edits(edits, {
      type = "replace",
      selections = selections,
      last_selection = doc.last_selection,
      merge_cursors = false,
    })
  end
end

---Removes all empty new lines at the end of the document.
---@param doc core.doc
---@param raw_remove? boolean Perform the removal not registering to undo stack
function trimwhitespace.trim_empty_end_lines(doc, raw_remove)
  if raw_remove then
    for _=#doc.lines, 1, -1 do
      local l = #doc.lines
      if l > 1 and doc.lines[l] == "\n" then
        table.remove(doc.lines, l)
      else
        break
      end
    end
    return
  end

  local first_empty
  for l = #doc.lines, 2, -1 do
    if doc.lines[l] == "\n" then
      first_empty = l
    else
      break
    end
  end
  if not first_empty then return end

  local current_line = doc:get_selection()
  if current_line and current_line >= first_empty then
    doc:set_selection(first_empty - 1, math.huge, first_empty - 1, math.huge)
  end
  doc:remove(first_empty - 1, math.huge, #doc.lines, math.huge)
end


command.add("core.docview", {
  ["trim-whitespace:trim-trailing-whitespace"] = function(dv)
    trimwhitespace.trim(dv.doc)
  end,

  ["trim-whitespace:trim-empty-end-lines"] = function(dv)
    trimwhitespace.trim_empty_end_lines(dv.doc)
  end,
})


local doc_save = Doc.save
Doc.save = function(self, ...)
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
  doc_save(self, ...)
end


return trimwhitespace
