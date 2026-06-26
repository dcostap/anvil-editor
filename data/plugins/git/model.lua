-- mod-version:3
-- UI-independent model for the project Git View.

local config = require "core.config"
local backend_default = require "plugins.git.backend"

local Model = {}
Model.__index = Model

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
  }
end

function Model.new(project, opts)
  opts = opts or {}
  local self = setmetatable({
    project = project,
    backend = opts.backend or backend_default,
    generation = 0,
    tabs = { new_log_tab() },
    active_tab = "log",
    repo = nil,
    error = nil,
    active_jobs = {},
  }, Model)
  return self
end

function Model:log_tab()
  return self.tabs[1]
end

function Model:selected_tab()
  for _, tab in ipairs(self.tabs) do
    if tab.id == self.active_tab then return tab end
  end
  return self.tabs[1]
end

function Model:select_tab(id, callback)
  local tab = self:find_tab(id)
  if tab then
    self.active_tab = id
    if tab.kind == "commit_diff" and #(tab.changed_files or {}) > 0
        and tab.left_text == nil and tab.right_text == nil and not tab.loading_file then
      self:load_selected_diff_file(tab, callback)
    end
    return tab
  end
end

function Model:selected_commit()
  local tab = self:selected_tab()
  if tab and tab.kind == "file_history" then return tab.commits[tab.selected_commit] end
  tab = self:log_tab()
  return tab.commits[tab.selected_commit]
end

function Model:select_log_index(index)
  local tab = self:log_tab()
  if #tab.commits == 0 then
    tab.selected_commit = 1
    return nil
  end
  index = math.max(1, math.min(#tab.commits, tonumber(index) or 1))
  tab.selected_commit = index
  return tab.commits[index]
end

function Model:close_selected_tab()
  local tab = self:selected_tab()
  if not tab or not tab.closable then return false end
  for i, candidate in ipairs(self.tabs) do
    if candidate == tab then
      table.remove(self.tabs, i)
      self.active_tab = "log"
      return true
    end
  end
  return false
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

local function diff_tab_id(repo, left, right, scope)
  return table.concat({
    "diff", repo and repo.root or "", tostring(left or ""), tostring(right or ""), scope or "",
  }, "\0")
end

local function history_tab_id(repo, relpath, context)
  if context and context.type == "selection" then
    return table.concat({
      "history", "selection", repo and repo.root or "", tostring(relpath or ""),
      tostring(context.start_line or ""), tostring(context.end_line or ""),
    }, "\0")
  end
  return table.concat({ "history", "file", repo and repo.root or "", tostring(relpath or "") }, "\0")
end

local function history_tab_title(relpath, context)
  if context and context.type == "selection" then
    return string.format("History: %s:%d-%d", tostring(relpath or ""), context.start_line or 0, context.end_line or 0)
  end
  return "History: " .. tostring(relpath or "")
end

local function diff_tab_title(commit, left, right)
  if commit and commit.kind == "working_tree" then return "Diff Working Tree" end
  return "Diff " .. short_rev(right) .. " ← " .. short_rev(left)
end

local function normalize_for_diff(text)
  return tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
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

local function working_tree_diff_records(records)
  local filtered = {}
  for _, record in ipairs(records or {}) do
    -- A path staged as added and then deleted from the worktree has no
    -- HEAD-to-worktree file content to compare in this diff tab.
    -- Default porcelain status reports untracked directories as summary
    -- entries (`?? dir/`); do not auto-load those summaries as files.
    if record.xy ~= "AD" and not untracked_directory_summary(record) then
      filtered[#filtered + 1] = record
    end
  end
  return filtered
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

function Model:open_commit_diff(commit, callback)
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
  self.active_tab = tab.id
  if commit.kind == "working_tree" then
    self:load_changed_files(tab, callback)
  elseif tab.changed_files and #tab.changed_files > 0 then
    self:load_selected_diff_file(tab, callback)
  else
    self:load_changed_files(tab, callback)
  end
  return tab
end

function Model:open_selected_commit_diff(callback)
  return self:open_commit_diff(self:selected_commit(), callback)
end

function Model:open_working_tree_diff(callback)
  local log_tab = self:log_tab()
  for _, commit in ipairs(log_tab.commits) do
    if commit.kind == "working_tree" then return self:open_commit_diff(commit, callback) end
  end
  return self:open_commit_diff({ kind = "working_tree", changed_files = {} }, callback)
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
  self.active_tab = tab.id
  if #tab.commits == 0 then self:load_file_history(tab, callback) end
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

function Model:load_file_history(tab, callback)
  if not tab or tab.loading then return false end
  tab.history_generation = (tab.history_generation or 0) + 1
  local generation = tab.history_generation
  tab.loading = true
  tab.error = nil
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
    if generation ~= tab.history_generation then return end
    tab.loading = false
    tab.error = err
    if page and page.commits then
      for _, commit in ipairs(page.commits) do
        commit.kind = commit.kind or "commit"
        commit.short_hash = commit.hash and commit.hash:sub(1, 8) or ""
        tab.commits[#tab.commits + 1] = commit
      end
      tab.has_more = page.has_more
      tab.next_offset = page.next_offset
    end
    if callback then callback(self, err) end
    if self.on_update then self.on_update(self) end
  end
  if tab.history_context and tab.history_context.type == "selection" then
    job = self.backend.selection_history(
      self.repo, tab.relpath, tab.history_context.start_line, tab.history_context.end_line, opts, on_page
    )
  else
    job = self.backend.file_history(self.repo, tab.relpath, opts, on_page)
  end
  if not done then self:_track_job(job) end
  return true
end

function Model:clear_diff_content(tab)
  tab.file_generation = (tab.file_generation or 0) + 1
  tab.loading_file = false
  tab.file_error = nil
  tab.left_text, tab.right_text = nil, nil
  tab.left_name, tab.right_name = nil, nil
  tab.diff_view = nil
  tab.diff_generation = (tab.diff_generation or 0) + 1
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
    tab.file_scroll = 0
    tab.selected_file = math.min(tab.selected_file or 1, math.max(1, #tab.changed_files))
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
  tab = tab or self:selected_tab()
  if not tab or tab.kind ~= "commit_diff" then return nil end
  if #tab.changed_files == 0 then return nil end
  tab.selected_file = math.max(1, math.min(#tab.changed_files, tonumber(index) or 1))
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

function Model:selected_historical_document()
  local tab = self:selected_tab()
  if not tab or tab.kind ~= "commit_diff" then
    return nil, { kind = "no_diff_tab", message = "No commit diff tab is active" }
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
  tab = tab or self:selected_tab()
  if not tab or tab.kind ~= "commit_diff" then return false end
  local file = tab.changed_files and tab.changed_files[tab.selected_file]
  if not file then return false end
  tab.file_generation = (tab.file_generation or 0) + 1
  local generation = tab.file_generation
  tab.loading_file = true
  tab.file_error = nil
  local pending = 2
  local left_text, right_text, file_err
  local function finish()
    pending = pending - 1
    if pending ~= 0 then return end
    if generation ~= tab.file_generation then return end
    tab.loading_file = false
    tab.file_error = file_err
    tab.left_text = normalize_for_diff(left_text)
    tab.right_text = normalize_for_diff(right_text)
    tab.left_name = path_for_file(file, "left") or "<empty>"
    tab.right_name = path_for_file(file, "right") or "<empty>"
    tab.diff_generation = (tab.diff_generation or 0) + 1
    if callback then callback(self, file_err) end
    if self.on_update then self.on_update(self) end
  end
  local function load(side, rev, relpath)
    if missing_side_for_status(file, side) or not relpath then
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
  for _, job in ipairs(self.active_jobs) do
    if job and job.cancel then pcall(job.cancel, job) end
  end
  self.active_jobs = {}
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
end

function Model:sync_working_tree_diff_tabs()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "commit_diff" and tab.right == self.backend.WORKING_TREE then
      local old_id = tab.id
      local new_left = self:working_tree_left_revision()
      tab.left = new_left
      tab.id = diff_tab_id(self.repo, tab.left, tab.right)
      tab.title = diff_tab_title(tab.commit, tab.left, tab.right)
      if self.active_tab == old_id then self.active_tab = tab.id end
      self:load_changed_files(tab)
    end
  end
end

function Model:_finish_refresh(generation, status_records, log_page, err, callback)
  if generation ~= self.generation then return end
  local tab = self:log_tab()
  tab.loading = false
  tab.loading_more = false
  tab.error = err
  tab.commits = {}
  if status_records and #status_records > 0 then
    tab.commits[#tab.commits + 1] = {
      kind = "working_tree",
      hash = "WORKING_TREE",
      short_hash = "working",
      subject = "Working Tree",
      author_name = "",
      refs = "",
      changed_files = status_records,
    }
  end
  append_log_commits(tab, log_page)
  if self.repo then
    self:sync_working_tree_diff_tabs()
    self:reload_file_history_tabs()
  else
    self:mark_diff_tabs_error(err)
    self:mark_file_history_tabs_error(err)
  end
  if tab.selected_commit > #tab.commits then tab.selected_commit = math.max(1, #tab.commits) end
  if callback then callback(self, err) end
end

function Model:_start_refresh_jobs(repo, generation, callback)
  local pending = 2
  local status_records, log_page, final_err
  local function done()
    pending = pending - 1
    if pending == 0 then
      self:_finish_refresh(generation, status_records, log_page, final_err, callback)
    end
  end

  local status_job, status_done
  status_job = self.backend.run_git(repo, { "status", "--porcelain=v1", "-z" }, {}, function(result, err)
    status_done = true
    self:_untrack_job(status_job)
    if generation ~= self.generation then return end
    if err and not final_err then final_err = err end
    status_records = result and self.backend.parse_status_z(result.stdout) or {}
    done()
  end)
  if not status_done then self:_track_job(status_job) end

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
end

function Model:reload_file_history_tabs()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "file_history" then
      tab.commits = {}
      tab.selected_commit = 1
      tab.scroll = 0
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
      tab.error = err
    end
  end
end

function Model:invalidate_history_loads()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "file_history" then
      tab.history_generation = (tab.history_generation or 0) + 1
      tab.loading = false
    end
  end
end

function Model:invalidate_diff_loads()
  for _, tab in ipairs(self.tabs) do
    if tab.kind == "commit_diff" then
      local was_loading = tab.loading or tab.loading_file
      tab.file_generation = (tab.file_generation or 0) + 1
      tab.list_generation = (tab.list_generation or 0) + 1
      tab.loading = false
      tab.loading_file = false
      if was_loading then self:clear_diff_content(tab) end
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
  tab.has_more = false
  tab.next_offset = nil

  local function on_repo(repo, repo_err)
    if generation ~= self.generation then return end
    if not repo then
      self.repo = nil
      self:_finish_refresh(generation, nil, nil, repo_err, callback)
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
    end
    if callback then callback(self, err) end
  end)
  if not log_done then self:_track_job(log_job) end
  return true
end

return Model
