-- Project File Search and Text Search also list the best rows of the other loaded Projects, below this Project's
-- results, in a group for each Project. Each Project searches itself when a `project_search` Pane request arrives,
-- and sends its rows back in a `project_results` request. Opening a row selects its Project and opens the row there.
local core = require "core"
local common = require "core.common"
local look = require "core.project_look"
local projects = require "plugins.fuzzy_searcher.projects"

local other = {}

-- The most rows that each other Project sends.
local LIMIT = 20
-- The fewest rows that a group shows before its More row.
local MIN_ROWS = 5
-- The shell's Pane request header has four 32-bit fields. The Project path follows it without a terminator.
local MAX_TEXT = 65536 - 16

-- The Fuzzy Searcher sets one function for each search mode, "files" and "text". Each
-- `search[mode](query, case_sensitive, limit, alive)` returns this Project's best rows, or nil when it cannot
-- search, for example without a file index. They run in a thread.
other.search = {}

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

local function positive(value)
  return type(value) == "number" and value >= 1 and value % 1 == 0 and value or nil
end

local function path(value)
  return text(value) and common.is_absolute_path(value) and value or nil
end

-- A Terminal of another Project. Its entry holds only the lines near the match, at their own line numbers, so the
-- preview shows them.
local function terminal(value, project)
  if type(value) ~= "table" or not text(value.id) or not text(value.query) or type(value.item) ~= "table"
    or type(value.item.name) ~= "string" or type(value.item.terminal) ~= "table" or type(value.context) ~= "table"
    or not positive(value.context.first) or type(value.context.text) ~= "string" then
    return nil
  end
  return {id = value.id, project = project.path, item = value.item, query = value.query,
    entry = {text = string.rep("\n", value.context.first - 1) .. value.context.text}}
end

-- A row of another Project, as this Project's search shows it. A row that has not the expected fields is nil.
local function result_row(row, project, state)
  if type(row) ~= "table" or not text(row.label) then return nil end
  local out = {
    label = row.label, file = row.label, root_label = text(row.root_label), root_role = text(row.root_role),
    prefix_span = span(row.prefix_span, #row.label) and {row.prefix_span[1], row.prefix_span[2]} or nil,
    other_project = project.path,
  }
  if state.mode == "files" then
    out.kind, out.abs_path, out.match_spans = "file", path(row.abs_path), spans(row.spans, #row.label)
    out.line, out.col, out.query = state.line or 1, 1, state.query
    return out.abs_path and out
  end
  if not positive(row.line) or type(row.text) ~= "string" then return nil end
  out.kind, out.line, out.col, out.text, out.exact = "grep", row.line, positive(row.col) or 1, row.text,
    row.exact == true
  out.content_spans, out.grep_query, out.case_sensitive = spans(row.spans, #row.text), state.query,
    state.case_sensitive
  if row.terminal then
    out.terminal = terminal(row.terminal, project)
    out.abs_path = out.terminal and "terminal:" .. out.terminal.id
  else
    out.abs_path = path(row.abs_path)
  end
  return out.abs_path and out
end

-- Sends the query of a search mode, "files" or "text", to the other loaded Projects. The same query keeps the
-- replies that it already has, so a file index update in this Project does not ask again.
function other.request(picker, mode, query, line)
  local key = table.concat({mode, query, tostring(line or ""), tostring(picker.case_sensitive == true)}, "\0")
  if picker.other_projects and picker.other_projects.key == key then return end
  picker.other_projects = nil
  query = query:match("^%s*(.-)%s*$")
  local root = core.root_project and core.root_project()
  -- Only the shell gives a Project the Sidebar model.
  if query == "" or not root or not core.project_sidebar then return end
  sequence = sequence + 1
  local state = {id = sequence, key = key, mode = mode, query = query, line = line,
    case_sensitive = picker.case_sensitive == true, targets = targets(), rows = {}, more = {}, headers = {},
    sent = system.get_time()}
  picker.other_projects = state
  for _, project in ipairs(state.targets) do
    send("direct", project.path, {action = "project_search", from = root.path, id = state.id, mode = mode,
      query = query, case_sensitive = state.case_sensitive, limit = LIMIT})
  end
end

-- This Project's rows, then each other Project that has rows: a divider, a header with its badge and name, then
-- its rows. While other Projects show rows, each group gets a share of the screen. A group with more rows ends with
-- a More row. Without other Projects, this Project's rows are not cut.
function other.with_rows(picker, own)
  local state = picker.other_projects
  if not state then return own end
  local groups = {}
  for _, project in ipairs(state.targets) do
    if state.rows[project.path] and #state.rows[project.path] > 0 then groups[#groups + 1] = project end
  end
  if #groups == 0 then return own end
  local screen = picker:list_metrics().result_rows
  local shown = #own
  if not state.expanded then
    -- Each other group needs a divider, a header, its rows and a More row.
    shown = math.min(#own, math.max(MIN_ROWS, screen - #groups * (MIN_ROWS + 3) - 1))
    -- A row that the user selected stays in the list.
    local selected = picker.results and picker.results[picker.selected]
    for index = shown + 1, #own do
      if own[index] == selected then state.expanded, shown = true, #own end
    end
  end
  local out = {}
  for index = 1, shown do out[index] = own[index] end
  if shown < #own then
    local current = projects.current()
    state.own_more = state.own_more
      or {kind = "more", own = true, label = "More in " .. (current and look.name(current) or "this Project")}
    out[#out + 1] = state.own_more
  end
  local share = math.max(MIN_ROWS, math.floor((screen - #out) / #groups) - 3)
  for _, project in ipairs(groups) do
    local rows = state.rows[project.path]
    -- The rows keep their identity across replies, so the selection can follow its row.
    local group = state.headers[project.path] or {
      divider = {header = true, separator = true, label = ""},
      header = {header = true, project = project, label = look.name(project)},
      more = {kind = "more", project_path = project.path, label = "More in " .. look.name(project)},
    }
    state.headers[project.path] = group
    if #out > 0 then out[#out + 1] = group.divider end
    out[#out + 1] = group.header
    for index = 1, math.min(#rows, share) do out[#out + 1] = rows[index] end
    if #rows > share or state.more[project.path] then out[#out + 1] = group.more end
  end
  return out
end

-- Confirms a More row: this Project's shows the rest of its rows. Another Project's opens the same search in that
-- Project.
function other.more(picker, result)
  if result.own then
    picker.other_projects.expanded = true
    picker:show_other_projects()
    return true
  end
  local text = picker.input:get_text()
  picker:close()
  core.log_quiet("Other Project search: opening %q in %s", text, result.project_path)
  return send("select", result.project_path, {action = "search", text = text})
end

-- Searches this Project for another Project's search and sends the rows back. A Project that cannot search, or that
-- has no match, sends nothing.
function other.answer(request)
  local from, id = common.path_compare_key(request.from), request.id
  latest[from] = id
  local function alive() return latest[from] == id end
  core.add_thread(function()
    local rows, more = other.search[request.mode](request.query, request.case_sensitive,
      math.min(request.limit or LIMIT, LIMIT), alive)
    if not alive() then return end
    latest[from] = nil
    core.log_quiet("Other Project search: %s search for %s found %d rows, more=%s", request.mode, request.from,
      rows and #rows or 0, tostring(more == true))
    if not rows or #rows == 0 then return end
    local root = core.root_project()
    send("direct", request.from, {action = "project_results", source = root.path, id = id, rows = rows,
      more = more or nil})
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
      state.more[project.path] = request.more == true
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
