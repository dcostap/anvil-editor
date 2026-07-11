local core = require "core"
local common = require "core.common"
local Doc = require "core.doc"

local rename_links = {}

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local text = file:read("*a")
  file:close()
  return text
end

local function apply_edits_to_text(text, edits)
  local crlf = text:find("\r\n", 1, true) ~= nil
  local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (normalized .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local ordered = {}
  for _, edit in ipairs(edits or {}) do ordered[#ordered + 1] = edit end
  table.sort(ordered, function(a, b)
    if a.line1 ~= b.line1 then return a.line1 > b.line1 end
    return a.col1 > b.col1
  end)
  for _, edit in ipairs(ordered) do
    if edit.line1 ~= edit.line2 or not lines[edit.line1] then
      return nil, "unsupported multiline rename edit"
    end
    local line = lines[edit.line1]
    if edit.col1 < 1 or edit.col2 < edit.col1 or edit.col2 > #line + 1 then
      return nil, "rename edit no longer matches source"
    end
    lines[edit.line1] = line:sub(1, edit.col1 - 1) .. edit.text .. line:sub(edit.col2)
  end
  local result = table.concat(lines, "\n")
  if crlf then result = result:gsub("\n", "\r\n") end
  return result
end

function rename_links.apply(plan)
  if not (plan and plan.files) or plan.applied then return false, { reason = "rename plan unavailable", applied = {} } end
  local result = { applied = {}, failed = {}, total = #plan.files }
  for _, file_plan in ipairs(plan.files) do
    local ok, err
    if file_plan.doc then
      ok, err = pcall(function()
        file_plan.doc:apply_edits(file_plan.edits, {
          type = "markdown-link-rename",
          old_path = plan.old_path,
          new_path = plan.new_path,
        })
      end)
    else
      local text
      text, err = read_file(file_plan.path)
      if text then
        local updated
        updated, err = apply_edits_to_text(text, file_plan.edits)
        if updated then ok, err = pcall(Doc.write_text_safely, file_plan.path, updated) end
      end
    end
    if ok then
      result.applied[#result.applied + 1] = file_plan.path
      if plan.index then
        if file_plan.doc then plan.index:update_doc(file_plan.doc)
        else plan.index:update_path(file_plan.path, { cooperative = true }) end
      end
    else
      result.failed[#result.failed + 1] = { path = file_plan.path, error = tostring(err) }
      core.error("Markdown rename updated %d/%d files before %s failed: %s",
        #result.applied, #plan.files, file_plan.path, tostring(err))
      return false, result
    end
  end
  plan.applied = true
  core.log_quiet("Markdown rename updated %d affected files for %s -> %s",
    #result.applied, tostring(plan.old_path), tostring(plan.new_path))
  return true, result
end

local function preview_suggestions(plan)
  local suggestions = {
    { text = string.format("Apply updates to %d file%s", #plan.files, #plan.files == 1 and "" or "s"), apply = true },
  }
  for _, file_plan in ipairs(plan.files) do
    suggestions[#suggestions + 1] = {
      text = common.relative_path(plan.index.root, file_plan.path):gsub("\\", "/"),
      detail = string.format("%d link%s", #file_plan.edits, #file_plan.edits == 1 and "" or "s"),
      file_plan = file_plan,
    }
  end
  return suggestions
end

function rename_links.present(plan)
  if not (plan and not plan.applied and #plan.files > 0 and core.command_view) then return false end
  local suggestions = preview_suggestions(plan)
  core.command_view:enter("Markdown links affected by rename", {
    text = "",
    suggest = function(text)
      local needle = tostring(text or ""):lower()
      if needle == "" then return suggestions end
      local filtered = {}
      for _, item in ipairs(suggestions) do
        if item.text:lower():find(needle, 1, true) then filtered[#filtered + 1] = item end
      end
      return filtered
    end,
    validate = function(_, suggestion) return suggestion and suggestion.apply == true end,
    submit = function(_, suggestion)
      if not (suggestion and suggestion.apply) then return end
      local text = string.format(
        "Rename %s to %s and update %d affected Markdown file%s?",
        common.basename(plan.old_path), common.basename(plan.new_path),
        #plan.files, #plan.files == 1 and "" or "s"
      )
      core.nag_view:show("Update Markdown Links", text, {
        { text = "Update Links", default_yes = true },
        { text = "Cancel", default_no = true },
      }, function(item)
        if item.text == "Update Links" then rename_links.apply(plan) end
      end)
    end,
  })
  return true
end

rename_links.apply_edits_to_text = apply_edits_to_text

return rename_links
