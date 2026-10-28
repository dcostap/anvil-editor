-- Project File Search also lists the best files of the other loaded Projects, below this Project's results, in a
-- group for each Project. Each Project searches its own file index when a `file_search` Pane request arrives, and
-- sends its rows back in a `file_results` request. Opening a row selects its Project and opens the file there.
local core = require "core"
local common = require "core.common"
local look = require "core.project_look"
local projects = require "plugins.fuzzy_searcher.projects"

local other = {}

-- The most rows that each other Project shows.
local LIMIT = 5
-- The shell's Pane request header has four 32-bit fields. The Project path follows it without a terminator.
local MAX_TEXT = 65536 - 16

-- The Fuzzy Searcher sets this: `search_files(query, case_sensitive, limit, alive)` returns this Project's best
-- rows, or nil without a file index. It runs in a thread.
other.search_files = nil

local sequence = 0
-- The newest request from each Project, by path key. A search for an older request stops.
local latest = {}

local function send(route, path, request)
  local text = common.serialize(request, {escape = true})
  if #text > MAX_TEXT - #path then
    core.log_quiet("Other Project search: the %s request for %s exceeds the size limit", request.action, path)
    return false
  end
  return system.pane_request(route, path, text)
end

-- The ready Projects other than this one, in Path Search's order. The shell delivers requests only to them.
local function targets()
  local own, out = projects.current(), {}
  for _, project in ipairs(projects.list({}, {})) do
    if project.state == "ready" and not (own and common.path_equals(project.path, own.path)) then
      out[#out + 1] = project
    end
  end
  return out
end

local function span(value, size)
  return type(value) == "table" and type(value[1]) == "number" and type(value[2]) == "number"
    and value[1] >= 1 and value[1] <= value[2] and value[2] <= size
end

local function spans(value, size)
  local out = {}
  for _, item in ipairs(type(value) == "table" and value or {}) do
    if span(item, size) then out[#out + 1] = {item[1], item[2]} end
  end
  return out
end

local function text(value)
  return type(value) == "string" and value ~= "" and value or nil
end

-- A row of another Project, as Project File Search shows it. A row that has not the expected fields is nil.
local function result_row(row, project, state)
  if type(row) ~= "table" or not text(row.label) or not text(row.abs_path)
    or not common.is_absolute_path(row.abs_path) then
    return nil
  end
  return {
    kind = "file", label = row.label, file = row.label, abs_path = row.abs_path,
    root_label = text(row.root_label), root_role = text(row.root_role),
    prefix_span = span(row.prefix_span, #row.label) and {row.prefix_span[1], row.prefix_span[2]} or nil,
    match_spans = spans(row.spans, #row.label),
    line = state.line or 1, col = 1, query = state.query,
    other_project = project.path,
  }
end

-- Sends the query to the other loaded Projects. The same query keeps the replies that it already has, so a file
-- index update in this Project does not ask again.
function other.request(picker, query, line)
  local key = table.concat({query, tostring(line or ""), tostring(picker.case_sensitive == true)}, "\0")
  if picker.other_projects and picker.other_projects.key == key then return end
  picker.other_projects = nil
  query = query:match("^%s*(.-)%s*$")
  local root = core.root_project and core.root_project()
  if query == "" or not root or not core.project_sidebar or not system.is_hosted_surface() then return end
  sequence = sequence + 1
  local state = {id = sequence, key = key, query = query, line = line, targets = targets(), rows = {}, headers = {},
    sent = system.get_time()}
  picker.other_projects = state
  for _, project in ipairs(state.targets) do
    send("direct", project.path, {action = "file_search", from = root.path, id = state.id, query = query,
      case_sensitive = picker.case_sensitive == true, limit = LIMIT})
  end
end

-- This Project's rows, then each other Project that has rows: a header with its badge and name, then its rows.
function other.with_rows(picker, own)
  local state = picker.other_projects
  if not state then return own end
  local out = {}
  for index, row in ipairs(own) do out[index] = row end
  for _, project in ipairs(state.targets) do
    local rows = state.rows[project.path]
    if rows and #rows > 0 then
      state.headers[project.path] = state.headers[project.path]
        or {header = true, project = project, label = look.name(project)}
      out[#out + 1] = state.headers[project.path]
      for _, row in ipairs(rows) do out[#out + 1] = row end
    end
  end
  return out
end

-- Searches this Project for another Project's File Search and sends the rows back. A Project without a file index,
-- or without a match, sends nothing.
function other.answer(request)
  local from, id = common.path_compare_key(request.from), request.id
  latest[from] = id
  local function alive() return latest[from] == id end
  core.add_thread(function()
    local rows = other.search_files(request.query, request.case_sensitive, math.min(request.limit or LIMIT, LIMIT),
      alive)
    if not alive() then return end
    latest[from] = nil
    if not rows or #rows == 0 then return end
    local root = core.root_project()
    send("direct", request.from, {action = "file_results", source = root.path, id = id, rows = rows})
  end)
  return true
end

-- Shows the rows of another Project when they answer the open picker's current query.
function other.receive(request)
  local picker = core.fuzzy_searcher_active_view
  local state = picker and picker.other_projects
  if not state or state.id ~= request.id then return true end
  for _, project in ipairs(state.targets) do
    if common.path_equals(project.path, request.source) then
      local rows = {}
      for _, row in ipairs(request.rows) do
        rows[#rows + 1] = result_row(row, project, state)
        if #rows >= LIMIT then break end
      end
      state.rows[project.path] = rows
      core.log_quiet("Other Project search: %d rows from %s after %.1f ms", #rows, project.path,
        (system.get_time() - state.sent) * 1000)
      picker:show_other_projects()
      return true
    end
  end
  return true
end

-- Selects the row's Project and opens its file there.
function other.open(result)
  core.log_quiet("Other Project search: opening %s in %s", result.abs_path, result.other_project)
  return send("select", result.other_project,
    {action = "open_file", file = result.abs_path, line = result.line, col = result.col})
end

return other
