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

function Model:selected_commit()
  local tab = self:log_tab()
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

local function log_limit()
  return config.plugins.git and config.plugins.git.log_page_size or nil
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

function Model:refresh_log(callback)
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
