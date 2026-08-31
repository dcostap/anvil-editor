-- mod-version:3
-- UI-independent model for the project Git View.

local config = require "core.config"
local core = require "core"
local common = require "core.common"
local range_marker = require "core.range_marker"
local backend_default = require "plugins.git.backend"
local diff_model = require "plugins.diff.model"

local Model = {}
Model.__index = Model

local diff_tab_id, history_tab_id, history_tab_title, diff_tab_title

local function new_log_tab()
  return {
    id = "log",
    kind = "log",
    title = "Log",
    closable = false,
    commits = {},
    selected_commit = 1,
    loading = false,
    loading_more = false,
    error = nil,
    has_more = false,
    next_offset = nil,
    graph_revision = 0,
  }
end

function Model.new(project, opts)
  opts = opts or {}
  local self = setmetatable({
    project = project,
    backend = opts.backend or backend_default,
    generation = 0,
    tabs = { new_log_tab() },
    repo = nil,
    error = nil,
    active_jobs = {},
    details_tree_collapsed = {},
  }, Model)
  if opts.state then self:apply_state(opts.state) end
  return self
end

local function clone_table(t)
  if type(t) ~= "table" then return nil end
  local copy = {}
  for key, value in pairs(t) do copy[key] = value end
  return copy
end

local function clone_boolean_map(t)
  if type(t) ~= "table" then return nil end
  local copy = {}
  for key, value in pairs(t) do
    if value == true then copy[key] = true end
  end
  return copy
end

local function clone_boolean_maps(t)
  if type(t) ~= "table" then return {} end
  local copy = {}
  for key, value in pairs(t) do copy[key] = clone_boolean_map(value) or {} end
  return copy
end

local function lightweight_commit(commit)
  if type(commit) ~= "table" then return nil end
  return {
    kind = commit.kind,
    hash = commit.hash,
    short_hash = commit.short_hash,
    subject = commit.subject,
    author_name = commit.author_name,
    author_email = commit.author_email,
    author_time = commit.author_time,
    committer_name = commit.committer_name,
    committer_email = commit.committer_email,
    commit_time = commit.commit_time,
    body = commit.body,
    refs = commit.refs,
    ref_labels = clone_table(commit.ref_labels),
    parents = clone_table(commit.parents),
  }
end

local function selected_commit_hash(tab)
  if tab and tab.selected_commit_hash then return tab.selected_commit_hash end
  local commit = tab and tab.commits and tab.commits[tab.selected_commit]
  if commit and commit.kind == "working_tree" then return nil end
  return commit and commit.hash or nil
end

local function commit_index_by_hash(commits, hash)
  if not hash then return nil end
  for index, commit in ipairs(commits or {}) do
    if commit.hash == hash then return index end
  end
end

local function apply_commit_anchor(tab)
  if not tab or not tab.selected_commit_hash then return end
  local index = commit_index_by_hash(tab.commits, tab.selected_commit_hash)
  if index then
    tab.selected_commit = index
  elseif not tab.has_more then
    tab.selected_commit_hash = nil
  end
end

local function changed_file_path(file)
  return file and (file.new_path or file.path or file.old_path) or nil
end

local function changed_file_index_by_path(files, path)
  if not path then return nil end
  for index, file in ipairs(files or {}) do
    if changed_file_path(file) == path then return index end
  end
end

function Model:get_state()
  local state = {
    repo = self.repo and { root = self.repo.root },
    details_tree_collapsed = clone_boolean_maps(self.details_tree_collapsed),
    tabs = {},
  }
  for _, tab in ipairs(self.tabs or {}) do
    if tab.kind == "log" then
      state.tabs[#state.tabs + 1] = {
        id = "log",
        kind = "log",
        selected_commit = tab.selected_commit,
        selected_commit_hash = selected_commit_hash(tab),
      }
    elseif tab.kind == "commit_diff" then
      local selected_file = tab.changed_files and tab.changed_files[tab.selected_file]
      state.tabs[#state.tabs + 1] = {
        id = tab.id,
        kind = "commit_diff",
        title = tab.title,
        left = tab.left,
        right = tab.right,
        commit = lightweight_commit(tab.commit),
        selected_file = tab.selected_file,
        selected_file_path = tab.selected_file_path or selected_file and changed_file_path(selected_file),
        file_scroll = tab.file_scroll,
        file_tree_collapsed = clone_boolean_map(tab.file_tree_collapsed),
      }
    elseif tab.kind == "file_history" then
      state.tabs[#state.tabs + 1] = {
        id = tab.id,
        kind = "file_history",
        title = tab.title,
        relpath = tab.relpath,
        history_context = clone_table(tab.history_context),
        selected_commit = tab.selected_commit,
        selected_commit_hash = selected_commit_hash(tab),
        scroll = tab.scroll,
        follow_renames = tab.follow_renames,
      }
    end
  end
  return state
end

function Model:apply_state(state)
  if type(state) ~= "table" then return end
  self.generation = (self.generation or 0) + 1
  self:invalidate_history_loads()
  self:invalidate_diff_loads()
  for _, tab in ipairs(self.tabs or {}) do
    tab.pending_history_callbacks = nil
    tab.pending_load_callbacks = nil
    self:dispose_tab(tab)
  end
  self:cancel_jobs()
  self.repo = type(state.repo) == "table" and state.repo.root and { root = state.repo.root } or nil
  self.details_tree_collapsed = clone_boolean_maps(state.details_tree_collapsed)
  self.tabs = { new_log_tab() }
  for _, saved in ipairs(state.tabs or {}) do
    if type(saved) == "table" and saved.kind == "log" then
      self.tabs[1].selected_commit = tonumber(saved.selected_commit) or 1
      self.tabs[1].selected_commit_hash = saved.selected_commit_hash
    elseif type(saved) == "table" and saved.kind == "commit_diff" and saved.left and saved.right then
      self.tabs[#self.tabs + 1] = {
        id = saved.id or diff_tab_id(self.repo, saved.left, saved.right),
        kind = "commit_diff",
        title = saved.title or diff_tab_title(saved.commit, saved.left, saved.right),
        closable = true,
        commit = lightweight_commit(saved.commit) or { kind = "commit", hash = saved.right },
        left = saved.left,
        right = saved.right,
        changed_files = {},
        selected_file = tonumber(saved.selected_file) or 1,
        selected_file_path = saved.selected_file_path,
        file_scroll = tonumber(saved.file_scroll) or 0,
        file_tree_collapsed = clone_boolean_map(saved.file_tree_collapsed) or {},
        loading = false,
        loading_file = false,
        error = nil,
        file_error = nil,
        diff_generation = 0,
      }
    elseif type(saved) == "table" and saved.kind == "file_history" and saved.relpath then
      local context = clone_table(saved.history_context)
      local id = saved.id or history_tab_id(self.repo, saved.relpath, context)
      self.tabs[#self.tabs + 1] = {
        id = id,
        kind = "file_history",
        title = saved.title or history_tab_title(saved.relpath, context),
        closable = true,
        relpath = tostring(saved.relpath):gsub("\\", "/"),
        history_context = context,
        commits = {},
        selected_commit = tonumber(saved.selected_commit) or 1,
        selected_commit_hash = saved.selected_commit_hash,
        scroll = tonumber(saved.scroll) or 0,
        restored_scroll = tonumber(saved.scroll) or nil,
        loading = false,
        error = nil,
        has_more = false,
        next_offset = nil,
        follow_renames = saved.follow_renames ~= false,
      }
    end
  end
end

function Model:log_tab()
  return self.tabs[1]
end

function Model:load_view(tab, callback)
  if not tab then return nil end
  if tab.kind == "commit_diff" then
    if #(tab.changed_files or {}) == 0 and not tab.loading then
      self:load_changed_files(tab, callback)
    elseif tab.left_text == nil and tab.right_text == nil and not tab.loading_file then
      self:load_selected_diff_file(tab, callback)
    end
  elseif tab.kind == "file_history" then
    if #(tab.commits or {}) == 0 and not tab.loading then
      self:load_file_history(tab, callback)
    else
      self:load_history_preview(tab, callback)
    end
  end
  return tab
end

function Model:selected_commit(tab)
  tab = tab or self:log_tab()
  if tab and tab.kind == "file_history" then
    local commit = tab.commits[tab.selected_commit]
    if tab.selected_commit_hash and (not commit or commit.hash ~= tab.selected_commit_hash) then return nil end
    return commit
  end
  tab = self:log_tab()
  local commit = tab.commits[tab.selected_commit]
  if tab.selected_commit_hash and (not commit or commit.hash ~= tab.selected_commit_hash) then return nil end
  return commit
end

function Model:select_log_index(index, callback)
  local tab = self:log_tab()
  if #tab.commits == 0 then
    tab.selected_commit = 1
    return nil
  end
  index = math.max(1, math.min(#tab.commits, tonumber(index) or 1))
  tab.selected_commit = index
  local commit = tab.commits[index]
  tab.selected_commit_hash = commit and commit.kind ~= "working_tree" and commit.hash or nil
  self:load_commit_changed_files(commit, callback)
  return tab.commits[index]
end

function Model:dispose_tab(tab)
  if not tab then return end
  self:clear_binary_files(tab)
  tab.disposed = true
  tab.history_generation = (tab.history_generation or 0) + 1
  tab.preview_generation = (tab.preview_generation or 0) + 1
  tab.local_changes_generation = (tab.local_changes_generation or 0) + 1
  tab.pending_history_callbacks = nil
  tab.pending_load_callbacks = nil
  for _, job in ipairs { tab.history_job, tab.local_changes_job } do
    if job and job.cancel then pcall(job.cancel, job) end
    self:_untrack_job(job)
  end
  tab.history_job, tab.local_changes_job = nil, nil
  if tab.history_buffer and tab.history_listener_id then
    tab.history_buffer:remove_text_change_listener(tab.history_listener_id)
    tab.history_buffer, tab.history_listener_id = nil, nil
  end
  for _, job in ipairs(tab.preview_jobs or {}) do
    if job and job.cancel then pcall(job.cancel, job) end
    self:_untrack_job(job)
  end
  tab.preview_jobs = nil
  tab.loading = false
  tab.refreshing = false
  tab.preview_loading = false
  if tab.history_range_marker then
    range_marker.remove(tab.history_range_marker)
    tab.history_range_marker = nil
  end
  for _, child in ipairs { tab.diff_view, tab.history_diff_view } do
    if child then
      child:dispose_integrations()
      child:dispose_owned_buffers()
    end
  end
  tab.diff_view, tab.history_diff_view = nil, nil
end

function Model:find_tab(id)
  for _, tab in ipairs(self.tabs) do
    if tab.id == id then return tab end
  end
end

local function log_limit()
  return config.plugins.git and config.plugins.git.log_page_size or nil
end

local function short_rev(rev)
  if rev == backend_default.WORKING_TREE then return "working" end
  if rev == backend_default.EMPTY_TREE then return "empty" end
  return tostring(rev or ""):sub(1, 8)
end

function diff_tab_id(repo, left, right, scope)
  if right == backend_default.WORKING_TREE then
    return table.concat({ "diff", repo and repo.root or "", "working_tree", scope or "" }, "\0")
  end
  return table.concat({
    "diff", repo and repo.root or "", tostring(left or ""), tostring(right or ""), scope or "",
  }, "\0")
end

function history_tab_id(repo, relpath, context)
  if context and context.type == "selection" then
    return table.concat({
      "history", "selection", repo and repo.root or "", tostring(relpath or ""),
      tostring(context.start_line or ""), tostring(context.end_line or ""),
    }, "\0")
  end
  return table.concat({ "history", "file", repo and repo.root or "", tostring(relpath or "") }, "\0")
end

function history_tab_title(relpath, context)
  if context and context.type == "selection" then
    return string.format("History: %s:%d-%d", tostring(relpath or ""), context.start_line or 0, context.end_line or 0)
  end
  return "History: " .. tostring(relpath or "")
end

function diff_tab_title(commit, left, right)
  if commit and commit.kind == "working_tree" then return "Diff Working Tree" end
  return "Diff " .. short_rev(right) .. " ← " .. short_rev(left)
end

local function normalize_for_diff(text)
  return tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function dispose_diff_view(tab)
  if not (tab and tab.diff_view) then return end
  tab.diff_view:dispose_integrations()
  tab.diff_view:dispose_owned_buffers()
  tab.diff_view = nil
end

local function line_fragment(text, start_line, end_line)
  local lines = {}
  for line in (normalize_for_diff(text) .. "\n"):gmatch("(.-\n)") do lines[#lines + 1] = line end
  local out = {}
  start_line = math.max(1, tonumber(start_line) or 1)
  end_line = math.max(start_line, tonumber(end_line) or start_line)
  for line = start_line, math.min(end_line, #lines) do out[#out + 1] = lines[line] end
  return table.concat(out):gsub("\n$", "")
end

local function text_lines(text)
  local lines = {}
  text = normalize_for_diff(text)
  if text == "" then return { "\n" } end
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  for line in text:gmatch("(.-\n)") do lines[#lines + 1] = line end
  return lines
end

local function update_local_selection_diff(tab, current_text, head_text)
  local context = tab.history_context
  if not (context and context.type == "selection") then return nil end
  local previous = tab.local_selection_diff
  local left_start, left_end
  if previous and previous.head_text == head_text then
    left_start = previous.left_start_line
    left_end = previous.left_end_line
  else
    local mapping = diff_model.compute(text_lines(head_text), text_lines(current_text))
    local start_mapping = { mapping:map_range("b", context.start_line) }
    local end_mapping = { mapping:map_range("b", context.end_line) }
    left_start, left_end = start_mapping[3], end_mapping[4]
  end
  local tracked = {
    left_text = line_fragment(head_text, left_start, left_end),
    right_text = line_fragment(current_text, context.start_line, context.end_line),
    left_start_line = left_start,
    left_end_line = left_end,
    right_start_line = context.start_line,
    head_text = head_text,
  }
  tab.local_selection_diff = tracked
  return tracked.left_text ~= tracked.right_text
end

local function path_for_file(file, side)
  if not file then return nil end
  if side == "left" then return file.old_path or file.path end
  return file.new_path or file.path
end

local function missing_side_for_status(file, side)
  local status = file and (file.status or file.kind)
  return (side == "left" and (status == "added" or status == "untracked"))
      or (side == "right" and status == "deleted")
end

local function untracked_directory_summary(record)
  if not record or record.kind ~= "untracked" then return false end
  local path = record.path or record.new_path or record.old_path or ""
  return path:sub(-1) == "/"
end

local function add_dirty_buffer_records(repo, records, seen)
  if not (repo and repo.root and core.buffer_registry) then return end
  for _, buffer in ipairs(core.buffer_registry:list()) do
    local path = buffer.abs_filename and common.normalize_path(buffer.abs_filename)
    if path and buffer.is_dirty and buffer:is_dirty()
        and core.buffer_registry:reference_count(buffer) > 0
        and (common.path_equals(path, repo.root) or common.path_belongs_to(path, repo.root)) then
      local root = common.normalize_path(repo.root):gsub("[\\/]+$", "")
      local relpath = path:sub(#root + 2):gsub("\\", "/")
      if relpath ~= "" and not seen[relpath] then
        local untracked = system.get_file_info(path) == nil
        records[#records + 1] = {
          status = untracked and "untracked" or "modified",
          kind = untracked and "untracked" or "modified",
          old_path = relpath,
          new_path = relpath,
          path = relpath,
        }
        seen[relpath] = true
      end
    end
  end
end

function Model:_new_diff_tab(commit, endpoint)
  local id = diff_tab_id(self.repo, endpoint.left, endpoint.right)
  return {
    id = id,
    kind = "commit_diff",
    title = diff_tab_title(commit, endpoint.left, endpoint.right),
    closable = true,
    commit = commit,
    left = endpoint.left,
    right = endpoint.right,
    changed_files = {},
    selected_file = 1,
    loading = false,
    loading_file = false,
    error = nil,
    file_error = nil,
    diff_generation = 0,
  }
end

function Model:working_tree_left_revision()
  for _, row in ipairs(self:log_tab().commits) do
    if row.kind ~= "working_tree" and row.hash and row.hash ~= "" then return "HEAD" end
  end
  return self.backend.EMPTY_TREE
end

function Model:open_commit_diff(commit, callback, opts)
  opts = opts or {}
  commit = commit or self:selected_commit()
  if not commit then return nil, { kind = "no_commit", message = "No commit selected" } end
  if not self.repo then return nil, { kind = "no_repo", message = "Git repository is not loaded" } end

  local endpoint
  if commit.kind == "working_tree" then
    endpoint = { left = self:working_tree_left_revision(), right = self.backend.WORKING_TREE }
  else
    endpoint = self.backend.diff_endpoint_for_commit(commit)
  end
  local id = diff_tab_id(self.repo, endpoint.left, endpoint.right)
  local tab = self:find_tab(id)
  if not tab then
    tab = self:_new_diff_tab(commit, endpoint)
    self.tabs[#self.tabs + 1] = tab
  elseif commit.kind == "working_tree" then
    tab.commit = commit
  end
  if opts.selected_file_path then
    tab.selected_file_path = changed_file_path({ path = opts.selected_file_path })
    local selected = changed_file_index_by_path(tab.changed_files, tab.selected_file_path)
    if selected then tab.selected_file = selected end
  end
  if commit.kind == "working_tree" then
    self:load_changed_files(tab, callback)
  elseif tab.changed_files and #tab.changed_files > 0 then
    self:load_selected_diff_file(tab, callback)
  else
    self:load_changed_files(tab, callback)
  end
  return tab
end

function Model:open_selected_commit_diff(source_tab, callback, opts)
  return self:open_commit_diff(self:selected_commit(source_tab), callback, opts)
end

function Model:open_working_tree_diff(callback, opts)
  return self:open_commit_diff({ kind = "working_tree", changed_files = {} }, callback, opts)
end

function Model:open_history_tab(relpath, context, callback)
  if not self.repo then return nil, { kind = "no_repo", message = "Git repository is not loaded" } end
  if not relpath or relpath == "" then return nil, { kind = "no_path", message = "No file path selected" } end
  relpath = tostring(relpath):gsub("\\", "/")
  local id = history_tab_id(self.repo, relpath, context)
  local tab = self:find_tab(id)
  if not tab then
    tab = {
      id = id,
      kind = "file_history",
      title = history_tab_title(relpath, context),
      closable = true,
      relpath = relpath,
      history_context = context,
      commits = {},
      selected_commit = 1,
      loading = false,
      error = nil,
      has_more = false,
      next_offset = nil,
      follow_renames = true,
    }
    self.tabs[#self.tabs + 1] = tab
  end
  self:attach_history_buffer(tab)
  if #tab.commits == 0 then
    self:load_file_history(tab, function(model, err)
      if callback then callback(model, err, tab) end
    end)
  elseif callback then
    callback(self, nil, tab)
  end
  return tab
end

function Model:open_file_history(relpath, callback)
  return self:open_history_tab(relpath, nil, callback)
end

function Model:open_selection_history(relpath, start_line, end_line, callback)
  return self:open_history_tab(relpath, {
    type = "selection",
    start_line = start_line,
    end_line = end_line,
  }, callback)
end

function Model:load_commit_changed_files(commit, callback)
  if not commit then return false end
  if commit.kind == "working_tree" or commit.changed_files or commit.changed_files_loaded then
    if callback then callback(self, commit.changed_files_error) end
    return false
  end
  if commit.changed_files_loading then
    if callback then
      commit.pending_changed_file_callbacks = commit.pending_changed_file_callbacks or {}
      commit.pending_changed_file_callbacks[#commit.pending_changed_file_callbacks + 1] = callback
    end
    return false
  end
  if not (self.repo and self.backend and self.backend.changed_files and self.backend.diff_endpoint_for_commit) then
    return false
  end
  local endpoint = self.backend.diff_endpoint_for_commit(commit)
  if not (endpoint and endpoint.right) then return false end
  commit.changed_files_generation = (commit.changed_files_generation or 0) + 1
  local generation = commit.changed_files_generation
  commit.changed_files_loading = true
  commit.changed_files_error = nil
  local job, done
  job = self.backend.changed_files(self.repo, endpoint.left, endpoint.right, {}, function(files, err)
    done = true
    self:_untrack_job(job)
    if generation ~= commit.changed_files_generation then return end
    commit.changed_files_loading = false
    commit.changed_files_error = err
    if not err then
      commit.changed_files = files or {}
      commit.changed_files_loaded = true
    end
    local callbacks = commit.pending_changed_file_callbacks or {}
    commit.pending_changed_file_callbacks = nil
    if callback then callback(self, err) end
    for _, cb in ipairs(callbacks) do cb(self, err) end
    if self.on_update then self.on_update(self) end
  end)
  if not done then self:_track_job(job) end
  return true
end

function Model:load_selected_commit_changed_files(callback)
  return self:load_commit_changed_files(self:selected_commit(), callback)
end

function Model:load_file_history(tab, callback)
  if not tab or tab.disposed then return false end
  if tab.loading then
    if callback then
      tab.pending_history_callbacks = tab.pending_history_callbacks or {}
      tab.pending_history_callbacks[#tab.pending_history_callbacks + 1] = callback
    end
    return false
  end
  tab.history_generation = (tab.history_generation or 0) + 1
  local generation = tab.history_generation
  tab.loading = true
  tab.error = nil
  local replace_existing = tab.replace_history_on_load == true
  tab.replace_history_on_load = nil
  local limit = log_limit()
  local job, done
  local opts = {
    limit = limit,
    offset = tab.next_offset,
    follow = tab.follow_renames,
  }
  local function on_page(page, err)
    done = true
    self:_untrack_job(job)
    tab.history_job = nil
    if tab.disposed or generation ~= tab.history_generation then return end
    tab.loading = false
    tab.refreshing = false
    tab.error = err
    local function notify(_, preview_err)
      local final_err = err or preview_err
      local callbacks = tab.pending_history_callbacks or {}
      tab.pending_history_callbacks = nil
      if callback then callback(self, final_err) end
      for _, cb in ipairs(callbacks) do cb(self, final_err) end
      if self.on_update then self.on_update(self) end
    end
    local function publish()
      if self:load_history_preview(tab, notify) then return end
      notify()
    end
    if page and page.commits then
      if replace_existing then tab.commits = {} end
      for _, commit in ipairs(page.commits) do
        commit.kind = commit.kind or "commit"
        commit.short_hash = commit.hash and commit.hash:sub(1, 8) or ""
        tab.commits[#tab.commits + 1] = commit
      end
      tab.has_more = page.has_more
      tab.next_offset = page.next_offset
      apply_commit_anchor(tab)
      if tab.selected_commit > #tab.commits then tab.selected_commit = math.max(1, #tab.commits) end
      if not err and self:refresh_local_changes_revision(tab, publish) then return end
    end
    publish()
  end
  if tab.history_context and tab.history_context.type == "selection" then
    job = self.backend.selection_history(
      self.repo, tab.relpath, tab.history_context.start_line, tab.history_context.end_line, opts, on_page
    )
  else
    job = self.backend.file_history(self.repo, tab.relpath, opts, on_page)
  end
  if not done then
    tab.history_job = job
    self:_track_job(job)
  end
  return true
end

function Model:refresh_local_changes_revision(tab, callback)
  if not (tab and not tab.disposed and self.repo and self.repo.root) then return false end
  tab.local_changes_generation = (tab.local_changes_generation or 0) + 1
  local generation = tab.local_changes_generation
  local path = common.normalize_path(self.repo.root .. PATHSEP .. tab.relpath)
  local buffer = core.buffer_registry and core.buffer_registry:find(path)
  if not buffer then return false end
  self:attach_history_buffer(tab)
  local current_text = normalize_for_diff(table.concat(buffer.lines or {}))
  local job, done
  job = self.backend.file_at(self.repo, "HEAD", tab.relpath, {}, function(text, err)
    done = true
    self:_untrack_job(job)
    tab.local_changes_job = nil
    if tab.disposed or generation ~= tab.local_changes_generation then return end
    if err and self.backend.is_missing_path_error and self.backend.is_missing_path_error(err) then
      text, err = "", nil
    end
    local head_text = normalize_for_diff(text)
    tab.history_head_text = not err and head_text or tab.history_head_text
    for index = #tab.commits, 1, -1 do
      if tab.commits[index].kind == "local_changes" then table.remove(tab.commits, index) end
    end
    local context = tab.history_context
    local changed
    if context and context.type == "selection" then
      changed = update_local_selection_diff(tab, current_text, head_text)
    else
      changed = current_text ~= head_text
    end
    if not err and changed then
      table.insert(tab.commits, 1, {
        kind = "local_changes",
        subject = "Local Changes",
        short_hash = "local",
        hash = nil,
        author_name = "",
        refs = "",
      })
      if tab.selected_commit_hash then
        apply_commit_anchor(tab)
      else
        tab.selected_commit = 1
      end
      core.log_quiet("Git File History added Local Changes Revision for %s", tab.relpath)
    end
    callback()
  end)
  if not done then
    tab.local_changes_job = job
    self:_track_job(job)
  end
  return true
end

function Model:update_local_changes_from_buffer(tab)
  local buffer = tab and tab.history_buffer
  if not (buffer and tab.history_head_text ~= nil) then return false end
  local current_text = normalize_for_diff(table.concat(buffer.lines or {}))
  local context = tab.history_context
  local changed
  if context and context.type == "selection" then
    changed = update_local_selection_diff(tab, current_text, tab.history_head_text)
  else
    changed = current_text ~= tab.history_head_text
  end
  local had_local = false
  for index = #tab.commits, 1, -1 do
    if tab.commits[index].kind == "local_changes" then
      had_local = true
      if not changed then table.remove(tab.commits, index) end
    end
  end
  if changed and not had_local then
    table.insert(tab.commits, 1, {
      kind = "local_changes", subject = "Local Changes", short_hash = "local",
      hash = nil, author_name = "", refs = "",
    })
  end
  apply_commit_anchor(tab)
  if tab.selected_commit > #tab.commits then tab.selected_commit = math.max(1, #tab.commits) end
  self:load_history_preview(tab)
  if self.on_update then self.on_update(self) end
  return changed ~= had_local
end

function Model:attach_history_buffer(tab)
  if not (tab and self.repo and self.repo.root and core.buffer_registry) then return false end
  local path = common.normalize_path(self.repo.root .. PATHSEP .. tab.relpath)
  local buffer = core.buffer_registry:find(path)
  if not buffer then return false end
  if tab.history_buffer == buffer and tab.history_listener_id then return true end
  if tab.history_buffer and tab.history_listener_id then
    tab.history_buffer:remove_text_change_listener(tab.history_listener_id)
  end
  local id = "git-history-" .. tab.id
  tab.history_buffer, tab.history_listener_id = buffer, id
  local context = tab.history_context
  if context and context.type == "selection" and not tab.history_range_marker then
    local end_line = math.min(#buffer.lines, context.end_line)
    tab.history_range_marker = range_marker.new(buffer, {
      line1 = context.start_line, col1 = 1,
      line2 = end_line, col2 = #(buffer.lines[end_line] or ""),
      sticky_right = true,
      preserve_on_replace = true,
      kind = "git-selection-history",
    })
  end
  buffer:add_text_change_listener(id, {
    after_change = function()
      local tracked = tab.history_range_marker and tab.history_range_marker:range()
      if tracked then
        context.start_line, context.end_line = tracked.line1, tracked.line2
      end
      self:update_local_changes_from_buffer(tab)
    end,
  })
  return true
end

function Model:select_history_index(tab, index, callback)
  if not tab or tab.kind ~= "file_history" or #(tab.commits or {}) == 0 then return nil end
  index = math.max(1, math.min(#tab.commits, tonumber(index) or 1))
  tab.selected_commit = index
  local commit = tab.commits[index]
  tab.selected_commit_hash = commit and commit.hash or nil
  self:load_history_preview(tab, callback)
  return commit
end

function Model:load_history_preview(tab, callback)
  if not tab or tab.disposed or tab.kind ~= "file_history" then return false end
  local commit = tab.commits and tab.commits[tab.selected_commit]
  if not commit then return false end
  tab.preview_generation = (tab.preview_generation or 0) + 1
  local generation = tab.preview_generation
  for _, job in ipairs(tab.preview_jobs or {}) do
    if job and job.cancel then pcall(job.cancel, job) end
  end
  tab.preview_jobs = {}
  tab.preview_loading = true
  tab.preview_error = nil
  local left_rev, right_rev
  if commit.kind == "local_changes" then
    left_rev, right_rev = "HEAD", self.backend.WORKING_TREE
  else
    right_rev = commit.hash
    local older = tab.commits[tab.selected_commit + 1]
    left_rev = older and older.hash or commit.parents and commit.parents[1] or self.backend.EMPTY_TREE
  end
  local right_path = commit.kind == "local_changes" and tab.relpath
    or commit.history_path or tab.relpath
  local left_path = commit.kind == "local_changes" and tab.relpath
    or commit.history_parent_path or right_path
  local context = tab.history_context
  local tracked = context and context.type == "selection" and commit.selection_diff
  if tracked and commit.kind ~= "local_changes" then
    tab.preview_loading = false
    tab.preview_left_text = tracked.left_text or ""
    tab.preview_right_text = tracked.right_text or ""
    tab.preview_source_line = math.max(1, tracked.right_start_line or context.start_line)
    tab.preview_right_fragment = nil
    tab.preview_right_current_path = nil
    tab.preview_left_name = (tracked.left_start_line == 0 and tracked.left_text == "")
      and "File did not exist" or short_rev(left_rev) .. ":" .. left_path
    tab.preview_right_name = short_rev(right_rev) .. ":" .. right_path
    tab.preview_generation_value = (tab.preview_generation_value or 0) + 1
    if callback then callback(self, nil) end
    if self.on_update then self.on_update(self) end
    return true
  end
  local pending = 2
  local left_text, right_text, right_current_path, preview_err
  local left_missing, right_missing = false, false
  local function finish()
    pending = pending - 1
    if pending ~= 0 or generation ~= tab.preview_generation then return end
    tab.preview_loading = false
    tab.preview_jobs = {}
    tab.preview_error = preview_err
    if not preview_err then
      local context = tab.history_context
      if context and context.type == "selection" then
        local local_tracked = commit.kind == "local_changes" and tab.local_selection_diff
        tab.preview_left_text = local_tracked and local_tracked.left_text
          or line_fragment(left_text, context.start_line, context.end_line)
        tab.preview_right_text = local_tracked and local_tracked.right_text
          or line_fragment(right_text, context.start_line, context.end_line)
        tab.preview_source_line = local_tracked and local_tracked.right_start_line or context.start_line
        tab.preview_right_fragment = right_current_path and {
          start_line = local_tracked and local_tracked.right_start_line or context.start_line,
          end_line = local_tracked
            and (local_tracked.right_start_line + math.max(0, context.end_line - context.start_line))
            or context.end_line,
        } or nil
        right_current_path = nil
      else
        tab.preview_left_text = normalize_for_diff(left_text)
        tab.preview_right_text = normalize_for_diff(right_text)
        tab.preview_source_line = nil
        tab.preview_right_fragment = nil
      end
      tab.preview_right_current_path = right_current_path
      tab.preview_left_name = short_rev(left_rev) .. ":" .. left_path
      tab.preview_right_name = right_rev == self.backend.WORKING_TREE
        and right_path or short_rev(right_rev) .. ":" .. right_path
      if left_missing then tab.preview_left_name = "File did not exist" end
      if right_missing then tab.preview_right_name = "File did not exist" end
      tab.preview_generation_value = (tab.preview_generation_value or 0) + 1
    end
    if callback then callback(self, preview_err) end
    if self.on_update then self.on_update(self) end
  end
  local function load(rev, side, relpath)
    if rev == self.backend.EMPTY_TREE then
      if side == "left" then left_text = "" else right_text = "" end
      finish()
      return
    end
    if rev == self.backend.WORKING_TREE then
      right_text = ""
      right_current_path = relpath
      finish()
      return
    end
    if rev == "HEAD" and tab.history_head_text ~= nil then
      if side == "left" then left_text = tab.history_head_text else right_text = tab.history_head_text end
      finish()
      return
    end
    local job, done
    job = self.backend.file_at(self.repo, rev, relpath, {}, function(text, err)
      done = true
      self:_untrack_job(job)
      if generation ~= tab.preview_generation then return end
      if err and self.backend.is_missing_path_error and self.backend.is_missing_path_error(err) then
        if side == "left" then left_missing = true else right_missing = true end
        text, err = "", nil
      end
      if err and not preview_err then preview_err = err end
      if side == "left" then left_text = text or "" else right_text = text or "" end
      finish()
    end)
    if not done then
      self:_track_job(job)
      tab.preview_jobs[#tab.preview_jobs + 1] = job
    end
  end
  load(left_rev, "left", left_path)
  load(right_rev, "right", right_path)
  return true
end

function Model:clear_diff_content(tab)
  self:clear_binary_files(tab)
  tab.file_generation = (tab.file_generation or 0) + 1
  dispose_diff_view(tab)
  tab.loading_file = false
  tab.file_loading_started_at = nil
  tab.file_error = nil
  tab.left_text, tab.right_text = nil, nil
  tab.left_current_path, tab.right_current_path = nil, nil
  tab.non_text = nil
  tab.left_name, tab.right_name = nil, nil
  tab.diff_view = nil
  tab.diff_generation = (tab.diff_generation or 0) + 1
end

function Model:clear_binary_files(tab)
  if not tab then return end
  tab.binary_generation = (tab.binary_generation or 0) + 1
  tab.binary_loading = false
  tab.binary_error = nil
  for _, path in ipairs(tab.binary_temp_paths or {}) do os.remove(path) end
  tab.binary_temp_paths = nil
  tab.binary_paths = nil
  tab.image_comparison_view = nil
end

local function binary_temp_suffix(relpath)
  return tostring(relpath or ""):match("(%.[%a%d]+)$") or ".bin"
end

local function write_binary_temp_file(relpath, content)
  local path = core.temp_filename(binary_temp_suffix(relpath))
  local fp, open_err = io.open(path, "wb")
  if not fp then
    return nil, { kind = "write_failed", message = open_err or "Could not create temporary file" }
  end
  local ok, write_err = fp:write(content or "")
  fp:close()
  if not ok then
    os.remove(path)
    return nil, { kind = "write_failed", message = write_err or "Could not write temporary file" }
  end
  return path
end

function Model:load_selected_binary_files(tab, callback)
  if not (tab and tab.kind == "commit_diff" and tab.non_text and tab.non_text.kind == "binary") then
    return false
  end
  if tab.binary_loading then return false end
  local file = tab.changed_files and tab.changed_files[tab.selected_file]
  if not file then return false end

  self:clear_binary_files(tab)
  local generation = tab.binary_generation
  tab.binary_loading = true
  local pending = 2
  local paths = {}
  local temp_paths = {}
  local load_err
  local function finish()
    pending = pending - 1
    if pending ~= 0 or generation ~= tab.binary_generation then return end
    tab.binary_loading = false
    tab.binary_error = load_err
    if load_err then
      for _, path in ipairs(temp_paths) do os.remove(path) end
    else
      tab.binary_paths = paths
      tab.binary_temp_paths = temp_paths
      tab.binary_generation_value = (tab.binary_generation_value or 0) + 1
    end
    if callback then callback(self, load_err) end
    if self.on_update then self.on_update(self) end
  end
  local function load(side, rev, relpath)
    if missing_side_for_status(file, side) or rev == self.backend.EMPTY_TREE or not relpath then
      paths[side] = nil
      finish()
      return
    end
    if rev == self.backend.WORKING_TREE then
      paths[side] = common.normalize_path(self.repo.root .. PATHSEP .. relpath)
      finish()
      return
    end
    local job, done
    job = self.backend.file_at(self.repo, rev, relpath, {}, function(content, err)
      done = true
      self:_untrack_job(job)
      if generation ~= tab.binary_generation then return end
      local path
      if not err then path, err = write_binary_temp_file(relpath, content) end
      if err and not load_err then load_err = err end
      if path then
        paths[side] = path
        temp_paths[#temp_paths + 1] = path
      end
      finish()
    end)
    if not done then self:_track_job(job) end
  end
  load("left", tab.left, path_for_file(file, "left"))
  load("right", tab.right, path_for_file(file, "right"))
  return true
end

function Model:load_changed_files(tab, callback)
  if not tab then return false end
  if tab.loading then
    if callback then
      tab.pending_load_callbacks = tab.pending_load_callbacks or {}
      tab.pending_load_callbacks[#tab.pending_load_callbacks + 1] = callback
    end
    return false
  end
  tab.list_generation = (tab.list_generation or 0) + 1
  local generation = tab.list_generation
  tab.loading = true
  tab.error = nil
  local function finish(files, err)
    if generation ~= tab.list_generation then return end
    tab.loading = false
    tab.error = err
    tab.changed_files = files or {}
    if #tab.changed_files == 0 then tab.file_scroll = 0 end
    if tab.selected_file_path then
      local selected_file = changed_file_index_by_path(tab.changed_files, tab.selected_file_path)
      tab.selected_file = selected_file or math.min(tab.selected_file or 1, math.max(1, #tab.changed_files))
      if not selected_file then tab.selected_file_path = nil end
    else
      tab.selected_file = math.min(tab.selected_file or 1, math.max(1, #tab.changed_files))
    end
    local callbacks = tab.pending_load_callbacks or {}
    tab.pending_load_callbacks = nil
    if err or #tab.changed_files == 0 then
      self:clear_diff_content(tab)
      if callback then callback(self, err) end
      for _, cb in ipairs(callbacks) do cb(self, err) end
      if self.on_update then self.on_update(self) end
    else
      local function chained_callback(model, file_err)
        if callback then callback(model, file_err) end
        for _, cb in ipairs(callbacks) do cb(model, file_err) end
        if self.on_update then self.on_update(self) end
      end
      self:load_selected_diff_file(tab, chained_callback)
    end
  end
  local job, done
  if tab.right == self.backend.WORKING_TREE then
    local pending, tracked_records, untracked_records, final_err = 2, nil, nil, nil
    local function done_one()
      pending = pending - 1
      if pending ~= 0 then return end
      local records, seen = {}, {}
      for _, record in ipairs(tracked_records or {}) do
        local path = record.new_path or record.path or record.old_path
        if path then seen[path] = true end
        records[#records + 1] = record
      end
      for _, record in ipairs(untracked_records or {}) do
        local path = record.path or record.new_path or record.old_path
        if path and not seen[path] then records[#records + 1] = record end
      end
      add_dirty_buffer_records(self.repo, records, seen)
      finish(records, (#records == 0) and final_err or nil)
    end
    local diff_job, diff_done
    diff_job = self.backend.changed_files(self.repo, tab.left, tab.right, {}, function(files, err)
      diff_done = true
      self:_untrack_job(diff_job)
      if err and not final_err then final_err = err end
      tracked_records = files or {}
      done_one()
    end)
    if not diff_done then self:_track_job(diff_job) end
    local status_job, status_done
    status_job = self.backend.run_git(self.repo, { "status", "--porcelain=v1", "-z", "--untracked-files=all" }, {}, function(result, err)
      status_done = true
      self:_untrack_job(status_job)
      if err and not final_err then final_err = err end
      untracked_records = {}
      if result then
        for _, record in ipairs(self.backend.parse_status_z(result.stdout)) do
          if record.kind == "untracked" and not untracked_directory_summary(record) then
            untracked_records[#untracked_records + 1] = record
          end
        end
      end
      done_one()
    end)
    if not status_done then self:_track_job(status_job) end
    return true
  else
    job = self.backend.changed_files(self.repo, tab.left, tab.right, {}, function(files, err)
      done = true
      self:_untrack_job(job)
      finish(files, err)
    end)
  end
  if not done then self:_track_job(job) end
  return true
end

function Model:select_diff_file(tab, index, callback)
  if not tab or tab.kind ~= "commit_diff" then return nil end
  if #tab.changed_files == 0 then return nil end
  tab.change_boundary_arm = nil
  tab.selected_file = math.max(1, math.min(#tab.changed_files, tonumber(index) or 1))
  tab.selected_file_path = changed_file_path(tab.changed_files[tab.selected_file])
  self:load_selected_diff_file(tab, callback)
  return tab.changed_files[tab.selected_file]
end

function Model:resolve_historical_rev(rev)
  if rev == "HEAD" then
    for _, row in ipairs(self:log_tab().commits) do
      if row.kind ~= "working_tree" and row.hash and row.hash ~= "" then return row.hash end
    end
  end
  return rev
end

function Model:selected_historical_buffer(tab)
  if not tab or tab.kind ~= "commit_diff" then
    return nil, { kind = "no_diff_view", message = "This is not a Commit Diff View" }
  end
  local file = tab.changed_files and tab.changed_files[tab.selected_file]
  if not file then return nil, { kind = "no_file", message = "No changed file is selected" } end

  local rev, relpath
  if tab.right ~= self.backend.WORKING_TREE and not missing_side_for_status(file, "right") then
    rev, relpath = tab.right, path_for_file(file, "right")
  elseif tab.left ~= self.backend.WORKING_TREE and tab.left ~= self.backend.EMPTY_TREE and not missing_side_for_status(file, "left") then
    rev, relpath = tab.left, path_for_file(file, "left")
  end
  if not rev or not relpath then
    return nil, { kind = "no_historical_revision", message = "Selected file has no Git revision to open" }
  end
  rev = self:resolve_historical_rev(rev)
  return { repo = self.repo, rev = rev, relpath = relpath, tab = tab, file = file }
end

function Model:load_selected_diff_file(tab, callback)
  if not tab or tab.kind ~= "commit_diff" then return false end
  local file = tab.changed_files and tab.changed_files[tab.selected_file]
  if not file then return false end
  self:clear_binary_files(tab)
  if file.binary or (file.stat and file.stat.binary) then
    tab.file_generation = (tab.file_generation or 0) + 1
    dispose_diff_view(tab)
    tab.loading_file = false
    tab.file_loading_started_at = nil
    tab.file_error = nil
    tab.left_text, tab.right_text = nil, nil
    tab.left_current_path, tab.right_current_path = nil, nil
    tab.left_name = path_for_file(file, "left") or "File did not exist"
    tab.right_name = path_for_file(file, "right") or "File did not exist"
    tab.non_text = {
      kind = "binary",
      message = "Binary file changed. Text comparison is not available.",
    }
    tab.diff_view = nil
    tab.diff_generation = (tab.diff_generation or 0) + 1
    if callback then callback(self, nil) end
    if self.on_update then self.on_update(self) end
    return true
  end
  tab.file_generation = (tab.file_generation or 0) + 1
  local generation = tab.file_generation
  tab.loading_file = true
  tab.file_loading_started_at = system.get_time()
  tab.file_error = nil
  local pending = 2
  local left_text, right_text, left_current_path, right_current_path, file_err
  local function finish()
    pending = pending - 1
    if pending ~= 0 then return end
    if generation ~= tab.file_generation then return end
    tab.loading_file = false
    tab.file_loading_started_at = nil
    tab.file_error = file_err
    if not file_err then
      tab.left_text = normalize_for_diff(left_text)
      tab.right_text = normalize_for_diff(right_text)
      tab.left_current_path = left_current_path
      tab.right_current_path = right_current_path
      tab.non_text = nil
      tab.left_name = path_for_file(file, "left") or "<empty>"
      tab.right_name = path_for_file(file, "right") or "<empty>"
      tab.diff_generation = (tab.diff_generation or 0) + 1
    end
    if callback then callback(self, file_err) end
    if self.on_update then self.on_update(self) end
  end
  local function load(side, rev, relpath)
    if missing_side_for_status(file, side) or not relpath then
      if side == "left" then left_text = "" else right_text = "" end
      finish()
      return
    end
    if rev == self.backend.WORKING_TREE then
      if side == "left" then left_current_path = relpath else right_current_path = relpath end
      if side == "left" then left_text = "" else right_text = "" end
      finish()
      return
    end
    local job, done
    job = self.backend.file_at(self.repo, rev, relpath, {}, function(text, err)
      done = true
      self:_untrack_job(job)
      if generation ~= tab.file_generation then return end
      if err and not file_err then file_err = err end
      if side == "left" then left_text = text or "" else right_text = text or "" end
      finish()
    end)
    if not done then self:_track_job(job) end
  end
  load("left", tab.left, path_for_file(file, "left"))
  load("right", tab.right, path_for_file(file, "right"))
  return true
end

function Model:cancel_jobs()
  local jobs = self.active_jobs
  self.active_jobs = {}
  for _, job in ipairs(jobs) do
    if job and job.cancel then pcall(job.cancel, job) end
  end
end

function Model:_track_job(job)
  if job and not job.__finished then self.active_jobs[#self.active_jobs + 1] = job end
  return job
end

function Model:_untrack_job(job)
  if not job then return end
  for i = #self.active_jobs, 1, -1 do
    if self.active_jobs[i] == job then
      table.remove(self.active_jobs, i)
      job.__finished = true
      return
    end
  end
  job.__finished = true
end

local function project_path(project)
  return type(project) == "table" and project.path or project
end

local function empty_log_error(err)
  if not err or err.kind ~= "exit" then return false end
  local text = tostring(err.stderr or err.message or ""):lower()
  return text:find("does not have any commits", 1, true)
      or text:find("bad revision", 1, true)
      or text:find("unknown revision", 1, true)
end

local function append_log_commits(tab, log_page)
  if not log_page or not log_page.commits then return end
  for _, commit in ipairs(log_page.commits) do
    commit.kind = commit.kind or "commit"
    commit.short_hash = commit.hash and commit.hash:sub(1, 8) or ""
    tab.commits[#tab.commits + 1] = commit
  end
  tab.has_more = log_page.has_more
  tab.next_offset = log_page.next_offset
  tab.graph_revision = (tab.graph_revision or 0) + 1
end

function Model:sync_working_tree_diff_tabs()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "commit_diff" and tab.right == self.backend.WORKING_TREE then
      tab.reload_after_refresh = nil
      local new_left = self:working_tree_left_revision()
      tab.left = new_left
      tab.id = diff_tab_id(self.repo, tab.left, tab.right)
      tab.title = diff_tab_title(tab.commit, tab.left, tab.right)
      self:load_changed_files(tab)
    end
  end
end

function Model:_finish_refresh(generation, total_commits, log_page, local_changes, err, callback)
  if generation ~= self.generation then return end
  local tab = self:log_tab()
  local retained_commits = {}
  for _, commit in ipairs(tab.commits or {}) do
    if commit.hash then retained_commits[commit.hash] = commit end
  end
  tab.loading = false
  tab.loading_more = false
  tab.error = err
  tab.commits = {}
  append_log_commits(tab, log_page)
  tab.total_commits = total_commits
  if tab.total_commits == nil and log_page and not log_page.has_more then
    tab.total_commits = #tab.commits
  end
  if local_changes and #local_changes > 0 then
    local head = tab.commits[1]
    table.insert(tab.commits, 1, {
      kind = "working_tree",
      short_hash = "",
      subject = "Local Changes",
      parents = head and head.hash and { head.hash } or {},
      changed_files = local_changes,
      changed_files_loaded = true,
    })
    tab.graph_revision = (tab.graph_revision or 0) + 1
  end
  for _, commit in ipairs(tab.commits) do
    local retained = retained_commits[commit.hash]
    if retained and retained.changed_files_loaded then
      commit.changed_files = retained.changed_files
      commit.changed_files_loaded = true
      commit.details_tree_collapsed = retained.details_tree_collapsed
    end
  end
  if self.repo then
    self:sync_working_tree_diff_tabs()
    for _, candidate in ipairs(self.tabs) do
      if candidate.kind == "commit_diff" and candidate.reload_after_refresh then
        candidate.reload_after_refresh = nil
        self:load_view(candidate)
      end
    end
    self:reload_file_history_tabs()
  else
    self:mark_diff_tabs_error(err)
    self:mark_file_history_tabs_error(err)
  end
  apply_commit_anchor(tab)
  if tab.selected_commit > #tab.commits then tab.selected_commit = math.max(1, #tab.commits) end
  self:load_commit_changed_files(tab.commits[tab.selected_commit])
  if callback then callback(self, err) end
end

function Model:_start_refresh_jobs(repo, generation, callback)
  local pending = self.backend.commit_count and 3 or 2
  local total_commits, log_page, local_changes, final_err
  local function done()
    pending = pending - 1
    if pending == 0 then
      self:_finish_refresh(generation, total_commits, log_page, local_changes, final_err, callback)
    end
  end

  if self.backend.commit_count then
    local count_job, count_done
    count_job = self.backend.commit_count(repo, {}, function(count, err)
      count_done = true
      self:_untrack_job(count_job)
      if generation ~= self.generation then return end
      total_commits = count
      if err then core.log_quiet("Git Log commit count unavailable: %s", err.message or err.kind) end
      done()
    end)
    if not count_done then self:_track_job(count_job) end
  end

  local limit = log_limit()
  local args = self.backend.build_log_args({ limit = limit })
  local log_job, log_done
  log_job = self.backend.run_git(repo, args, {}, function(result, err)
    log_done = true
    self:_untrack_job(log_job)
    if generation ~= self.generation then return end
    if err and not empty_log_error(err) and not final_err then final_err = err end
    log_page = result and self.backend.parse_log_page(result.stdout, { limit = limit }) or { commits = {} }
    done()
  end)
  if not log_done then self:_track_job(log_job) end

  local status_job, status_done
  status_job = self.backend.run_git(
    repo,
    { "status", "--porcelain=v1", "-z", "--untracked-files=all" },
    {},
    function(result, err)
      status_done = true
      self:_untrack_job(status_job)
      if generation ~= self.generation then return end
      local_changes = {}
      local seen = {}
      if result then
        for _, record in ipairs(self.backend.parse_status_z(result.stdout)) do
          if not untracked_directory_summary(record) then
            local path = changed_file_path(record)
            if path and path ~= "" then seen[path] = true end
            local_changes[#local_changes + 1] = record
          end
        end
      elseif err then
        core.log_quiet("Git Log local changes unavailable: %s", err.message or err.kind)
      end
      add_dirty_buffer_records(repo, local_changes, seen)
      done()
    end
  )
  if not status_done then self:_track_job(status_job) end
end

function Model:reload_file_history_tabs()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "file_history" then
      tab.replace_history_on_load = true
      tab.refreshing = true
      tab.has_more = false
      tab.next_offset = nil
      tab.error = nil
      self:load_file_history(tab)
    end
  end
end

function Model:mark_file_history_tabs_error(err)
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "file_history" then
      tab.loading = false
      tab.error = err
    end
  end
end

function Model:mark_diff_tabs_error(err)
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "commit_diff" then
      tab.loading = false
      tab.loading_file = false
      tab.file_loading_started_at = nil
      tab.error = err
    end
  end
end

function Model:invalidate_history_loads()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "file_history" then
      tab.history_generation = (tab.history_generation or 0) + 1
      tab.preview_generation = (tab.preview_generation or 0) + 1
      tab.local_changes_generation = (tab.local_changes_generation or 0) + 1
      tab.loading = false
      tab.refreshing = false
      tab.preview_loading = false
    end
  end
end

function Model:invalidate_diff_loads()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "commit_diff" then
      local was_loading = tab.loading or tab.loading_file or tab.binary_loading
      if tab.binary_loading then self:clear_binary_files(tab) end
      tab.file_generation = (tab.file_generation or 0) + 1
      tab.list_generation = (tab.list_generation or 0) + 1
      tab.loading = false
      tab.loading_file = false
      tab.file_loading_started_at = nil
      if was_loading then
        tab.reload_after_refresh = true
        self:clear_diff_content(tab)
      end
    end
  end
end

function Model:refresh_log(callback)
  self:invalidate_history_loads()
  self:invalidate_diff_loads()
  self:cancel_jobs()
  self.generation = self.generation + 1
  local generation = self.generation
  local tab = self:log_tab()
  tab.loading = true
  tab.loading_more = false
  tab.error = nil

  local function on_repo(repo, repo_err)
    if generation ~= self.generation then return end
    if not repo then
      self.repo = nil
      self:_finish_refresh(generation, nil, nil, nil, repo_err, callback)
      return
    end
    self.repo = repo
    self:_start_refresh_jobs(repo, generation, callback)
  end

  if self.backend.repo_for_path_async then
    local repo_job, repo_done
    repo_job = self.backend.repo_for_path_async(project_path(self.project), function(repo, err)
      repo_done = true
      self:_untrack_job(repo_job)
      on_repo(repo, err)
    end)
    if not repo_done then self:_track_job(repo_job) end
  else
    local repo, repo_err = self.backend.repo_for_path(project_path(self.project))
    on_repo(repo, repo_err)
  end

  return generation
end

function Model:load_more_log(callback)
  local tab = self:log_tab()
  if tab.loading or tab.loading_more or not tab.has_more or not tab.next_offset then return false end
  if not self.repo then return false end
  self.generation = self.generation + 1
  local generation = self.generation
  tab.loading_more = true
  tab.error = nil
  local limit = log_limit()
  local args = self.backend.build_log_args({ limit = limit, offset = tab.next_offset })
  local log_job, log_done
  log_job = self.backend.run_git(self.repo, args, {}, function(result, err)
    log_done = true
    self:_untrack_job(log_job)
    if generation ~= self.generation then return end
    tab.loading_more = false
    tab.error = err
    if result then
      append_log_commits(tab, self.backend.parse_log_page(result.stdout, { limit = limit, offset = tab.next_offset }))
      apply_commit_anchor(tab)
      self:load_commit_changed_files(tab.commits[tab.selected_commit])
    end
    if callback then callback(self, err) end
  end)
  if not log_done then self:_track_job(log_job) end
  return true
end

return Model
