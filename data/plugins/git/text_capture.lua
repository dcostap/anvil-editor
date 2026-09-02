local M = {}

local STATUS_LABELS = {
  added = "added",
  copied = "copied",
  deleted = "deleted",
  modified = "modified",
  renamed = "renamed",
  typechange = "type changed",
  unmerged = "unmerged",
  untracked = "untracked",
}

local function add(lines, text)
  lines[#lines + 1] = tostring(text or "")
end

local function add_field(lines, label, value)
  if value == nil or value == "" then return end
  add(lines, label .. ": " .. tostring(value))
end

local function add_text(lines, text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text == "" then
    add(lines, "(empty)")
    return
  end
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  for line in text:gmatch("(.-)\n") do add(lines, line) end
end

local function section(lines, title)
  if #lines > 0 and lines[#lines] ~= "" then add(lines, "") end
  add(lines, title)
  add(lines, string.rep("-", #title))
end

local function ref_labels(commit)
  local labels = {}
  for _, ref in ipairs(commit and commit.ref_labels or {}) do
    if ref.label and ref.label ~= "" then labels[#labels + 1] = ref.label end
  end
  return table.concat(labels, ", ")
end

local function commit_summary(commit)
  if not commit then return "" end
  local parts = {}
  local hash = commit.short_hash or commit.hash
  if hash and hash ~= "" then parts[#parts + 1] = hash end
  local refs = ref_labels(commit)
  if refs ~= "" then parts[#parts + 1] = "[" .. refs .. "]" end
  if commit.subject and commit.subject ~= "" then parts[#parts + 1] = commit.subject end
  if commit.author_name and commit.author_name ~= "" then parts[#parts + 1] = commit.author_name end
  local timestamp = tonumber(commit.commit_time or commit.author_time)
  if timestamp and timestamp > 0 then parts[#parts + 1] = os.date("%Y-%m-%d %H:%M", timestamp) end
  return table.concat(parts, " — ")
end

local function file_path(file)
  if not file then return "" end
  local old_path = file.old_path or file.path
  local new_path = file.new_path or file.path
  if old_path and new_path and old_path ~= new_path then
    return tostring(old_path) .. " -> " .. tostring(new_path)
  end
  return tostring(new_path or old_path or "")
end

local function file_status(file)
  local status = file and (file.kind or file.status or file.raw_status or file.xy)
  if status == nil or status == "" then return nil end
  local normalized = tostring(status):lower()
  return STATUS_LABELS[normalized] or tostring(status)
end

local function file_summary(file)
  local parts = {}
  local status = file_status(file)
  if status then parts[#parts + 1] = status end
  parts[#parts + 1] = file_path(file)
  local stat = file and file.stat
  if stat and ((tonumber(stat.additions) or 0) > 0 or (tonumber(stat.deletions) or 0) > 0) then
    parts[#parts + 1] = string.format(
      "+%d −%d", tonumber(stat.additions) or 0, tonumber(stat.deletions) or 0
    )
  end
  return table.concat(parts, " — ")
end

local function append_commits(lines, commits, selected, noun)
  section(lines, noun)
  local selected_line
  for index, commit in ipairs(commits or {}) do
    local marker = index == selected and "> " or "  "
    add(lines, string.format("%s%d. %s", marker, index, commit_summary(commit)))
    if index == selected then selected_line = #lines end
  end
  if #(commits or {}) == 0 then add(lines, "  (none loaded)") end
  return selected_line
end

local function append_files(lines, files, selected)
  section(lines, "Changed files")
  for index, file in ipairs(files or {}) do
    local marker = index == selected and "> " or "  "
    add(lines, string.format("%s%d. %s", marker, index, file_summary(file)))
  end
  if #(files or {}) == 0 then add(lines, "  (none loaded)") end
end

local function append_commit_details(lines, commit)
  section(lines, "Selected commit")
  if not commit then
    add(lines, "(none)")
    return
  end
  add_field(lines, "Subject", commit.subject)
  if commit.kind ~= "working_tree" and commit.kind ~= "local_changes" then
    add_field(lines, "Hash", commit.hash)
  end
  add_field(lines, "Author", commit.author_name)
  add_field(lines, "Email", commit.author_email)
  add_field(lines, "Committer", commit.committer_name ~= commit.author_name and commit.committer_name or nil)
  local timestamp = tonumber(commit.commit_time or commit.author_time)
  if timestamp and timestamp > 0 then add_field(lines, "Date", os.date("%Y-%m-%d %H:%M:%S", timestamp)) end
  add_field(lines, "Refs", ref_labels(commit))
  if commit.body and commit.body ~= "" then
    section(lines, "Message")
    add_text(lines, commit.body)
  end
  if commit.changed_files_loading then add_field(lines, "Changed files", "loading") end
  if commit.changed_files_error then
    add_field(lines, "Changed files error", commit.changed_files_error.message or commit.changed_files_error.kind or commit.changed_files_error)
  end
  append_files(lines, commit.changed_files, commit.selected_changed_file)
end

local function side_buffer_text(view, tab, history, side)
  local comparison = history and tab.history_diff_view or tab.diff_view
  local buffer_view = comparison and (side == "left" and comparison.buffer_view_a or comparison.buffer_view_b)
  if buffer_view and buffer_view.buffer then return table.concat(buffer_view.buffer.lines or {}) end
  local prefix = history and "preview_" or ""
  return tab[prefix .. side .. "_text"]
end

local function append_comparison(lines, view, tab, history)
  section(lines, "Selected comparison")
  if history and tab.preview_loading or not history and tab.loading_file then
    add(lines, "Loading comparison...")
  end
  local err = history and tab.preview_error or tab.file_error
  if err then add_field(lines, "Error", err.message or err.kind or err) end
  local prefix = history and "preview_" or ""
  add_field(lines, "Left", tab[prefix .. "left_name"] or tab.left)
  if tab.non_text then
    add_field(lines, "Content", tab.non_text.kind or "non-text")
    add_field(lines, "Details", tab.non_text.message)
    add_field(lines, "Right", tab[prefix .. "right_name"] or tab.right)
    return
  end
  local left_text = side_buffer_text(view, tab, history, "left")
  local right_text = side_buffer_text(view, tab, history, "right")
  if left_text ~= nil then add_text(lines, left_text) else add(lines, "(not loaded)") end
  add(lines, "")
  add_field(lines, "Right", tab[prefix .. "right_name"] or tab.right)
  if right_text ~= nil then add_text(lines, right_text) else add(lines, "(not loaded)") end
end

local function build_log(view, tab, lines)
  add(lines, "Git Log")
  add_field(lines, "Repository", view.model.repo and view.model.repo.root)
  add_field(lines, "Loaded commits", #(tab.commits or {}))
  add_field(lines, "Selected commit", tab.selected_commit or 0)
  add_field(lines, "More commits", tab.has_more and "yes" or "no")
  add_field(lines, "Loading", (tab.loading or tab.loading_more) and "yes" or "no")
  if tab.error then add_field(lines, "Error", tab.error.message or tab.error.kind or tab.error) end
  local selected_line = append_commits(lines, tab.commits, tab.selected_commit, "Commits")
  append_commit_details(lines, tab.commits and tab.commits[tab.selected_commit])
  return selected_line
end

local function build_diff(view, tab, lines)
  add(lines, tab.title or "Commit Diff View")
  add_field(lines, "Repository", view.model.repo and view.model.repo.root)
  add_field(lines, "Left revision", tab.left)
  add_field(lines, "Right revision", tab.right)
  add_field(lines, "Loaded changed files", #(tab.changed_files or {}))
  add_field(lines, "Selected file", tab.selected_file or 0)
  add_field(lines, "Loading", tab.loading and "yes" or "no")
  if tab.error then add_field(lines, "Error", tab.error.message or tab.error.kind or tab.error) end
  append_files(lines, tab.changed_files, tab.selected_file)
  append_comparison(lines, view, tab, false)
end

local function build_history(view, tab, lines)
  add(lines, tab.title or "File History View")
  add_field(lines, "Repository", view.model.repo and view.model.repo.root)
  add_field(lines, "Path", tab.relpath)
  local context = tab.history_context
  if context and context.type == "selection" then
    add_field(lines, "Selected lines", string.format("%d-%d", context.start_line or 1, context.end_line or context.start_line or 1))
  end
  add_field(lines, "Loaded revisions", #(tab.commits or {}))
  add_field(lines, "Selected revision", tab.selected_commit or 0)
  add_field(lines, "More revisions", tab.has_more and "yes" or "no")
  add_field(lines, "Loading", tab.loading and "yes" or "no")
  if tab.error then add_field(lines, "Error", tab.error.message or tab.error.kind or tab.error) end
  local selected_line = append_commits(lines, tab.commits, tab.selected_commit, "Revisions")
  append_comparison(lines, view, tab, true)
  return selected_line
end

function M.build(view)
  local tab = view and view:model_tab()
  if not tab then return nil, "Git View content is unavailable" end
  local lines = {}
  local selected_line
  if tab.kind == "commit_diff" then
    build_diff(view, tab, lines)
  elseif tab.kind == "file_history" then
    selected_line = build_history(view, tab, lines)
  else
    selected_line = build_log(view, view.model:log_tab(), lines)
  end
  return {
    text = table.concat(lines, "\n") .. "\n",
    title = (tab.title or view:get_name()) .. " Text",
    display_name = "Git View Text",
    cursor_line = selected_line or 1,
    cursor_col = 1,
    wrapping = false,
    read_only_reason = "Git View text captures are read-only",
  }
end

return M
