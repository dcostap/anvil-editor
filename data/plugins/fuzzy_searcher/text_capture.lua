local keymap = require "core.keymap"

local M = {}

local MODE_LABELS = {
  [""] = "Project File Search",
  ["@"] = "Path Search",
  ["#"] = "Text Search",
  ["$"] = "Project Symbol Search",
  ["$$"] = "Current Buffer Symbol Search",
  [">"] = "Command Palette",
  ["!"] = "Shell Command Mode",
}

local function add_part(parts, value)
  if value == nil then return end
  value = tostring(value)
  if value ~= "" then parts[#parts + 1] = value end
end

local function result_location(result)
  local path = result.file or result.path or result.abs_path
  if not path or path == "" then return nil end
  local location = tostring(path)
  if result.line then
    location = location .. ":" .. tostring(result.line)
    if result.col then location = location .. ":" .. tostring(result.col) end
  end
  return location
end

local function result_text(result, support)
  if result.header then
    if result.separator then return string.rep("-", 40) end
    return "[" .. tostring(result.label or "Results") .. "]"
  end

  local parts = {}
  local main = support.result_main_text(result)
  if result.kind == "grep" then
    add_part(parts, result_location(result))
    add_part(parts, main)
  elseif result.kind == "symbol" then
    add_part(parts, result_location(result))
    add_part(parts, main)
    add_part(parts, result.symbol_kind_label or result.symbol_kind)
    add_part(parts, result.declaration or result.signature or result.detail)
  elseif result.kind == "command" then
    add_part(parts, result.command or main)
    if result.status then
      add_part(parts,
        tostring(result.status.prefix or "")
          .. tostring(result.status.value or "")
          .. tostring(result.status.suffix or ""))
    end
    add_part(parts, result.info)
    add_part(parts, result.command and keymap.get_binding(result.command))
  elseif result.kind == "shell_command" then
    add_part(parts, result.command or main)
    add_part(parts, result.cwd and ("Working directory: " .. result.cwd))
  elseif result.kind == "file" then
    add_part(parts, result.file or main)
    local edited = support.format_recent_file_age(result.last_edited)
    local viewed = support.format_recent_file_age(result.last_viewed)
    add_part(parts, edited and ("edited " .. edited))
    add_part(parts, viewed and ("viewed " .. viewed))
  elseif result.kind == "path" or result.kind == "create_path"
      or result.kind == "folder" or result.kind == "project"
      or result.kind == "new_project"
  then
    add_part(parts, result.path or result.project or main)
    add_part(parts, result.is_folder and "folder" or nil)
    add_part(parts, result.size_label)
    add_part(parts, result.modified_label)
  else
    add_part(parts, main)
    add_part(parts, result.detail or result.info)
  end
  return table.concat(parts, " — ")
end

local function append_preview(lines, view)
  local preview = view.preview_view
  if preview and preview.buffer then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Preview"
    lines[#lines + 1] = "-------"
    local preview_text = table.concat(preview.buffer.lines)
    if preview_text ~= "" then
      for line in (preview_text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
      end
    end
  elseif preview and preview.path then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Preview: " .. tostring(preview.path)
  elseif view.preview_blocked then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Preview unavailable: "
      .. tostring(view.preview_blocked.reason or view.preview_blocked.path or "unknown reason")
  end
end

function M.build(view, support)
  local query = view.input and view.input:get_text() or ""
  local mode = view.static_mode and "Static Results"
    or MODE_LABELS[support.prompt_mode(query)]
    or "Fuzzy Searcher"
  local modifiers = view.active_search_modifiers and view:active_search_modifiers() or {}
  local loading = view.loading_feedback_pending or view.everything_loading_pending
    or view.everything_loading or view.loading_more
  local lines = {
    "Fuzzy Searcher",
    "",
    "Query: " .. query,
    "Mode: " .. mode,
    "Status: " .. tostring(view.status or ""),
    "Loaded results: " .. tostring(#(view.results or {})),
    "Selected result: " .. tostring(view.selected or 0),
    "More results: " .. (view.has_more and "yes" or "no"),
    "Loading: " .. (loading and "yes" or "no"),
    "Search modifiers: " .. (#modifiers > 0 and table.concat(modifiers, ", ") or "none"),
    "",
    "Results",
    "-------",
  }

  local selected_capture_line
  for index, result in ipairs(view.results or {}) do
    local marker = not result.header and index == view.selected and "> " or "  "
    lines[#lines + 1] = string.format(
      "%s%d. %s", marker, index, result_text(result, support)
    )
    if index == view.selected then selected_capture_line = #lines end
  end
  if #(view.results or {}) == 0 then lines[#lines + 1] = "  (no loaded results)" end
  append_preview(lines, view)

  return {
    text = table.concat(lines, "\n") .. "\n",
    title = "Fuzzy Searcher Text — " .. (query ~= "" and query or mode),
    display_name = "Fuzzy Searcher Text",
    cursor_line = selected_capture_line or 1,
    cursor_col = 1,
    wrapping = false,
    read_only_reason = "Fuzzy Searcher text captures are read-only",
  }
end

return M
