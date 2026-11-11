-- SQL History: the SQL that this Project's Queries ran, newest first, as DbVisualizer's SQL History keeps
-- it. A run of the same SQL on the same connection as the newest entry counts in that entry. The history
-- belongs to the Project, as its connections do. The settings worker reads and writes it.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local worker_pool = require "core.worker_pool"
local M = {}

-- Longer SQL is not kept, so the history file stays small.
M.TEXT_LIMIT = 64 * 1024
local MODULE = "sql_server_history"

local entries, key, state, saving, pending_save, waiting = {}, nil, "unloaded", false, false, {}

local function job(operation, value, callback)
  return worker_pool.named("sql-settings", { worker_count = 1 }):submit {
    kind = "plugins.sql_server.worker",
    payload = { operation = operation, module = MODULE, userdir = USERDIR, key = key, value = value },
    on_result = function(message)
      local result = message.payload or {}
      callback(result.value, result.error)
    end,
    on_error = function() callback(nil, "SQL History worker failed.") end,
  }
end

local function valid(entry)
  return type(entry) == "table" and type(entry.text) == "string" and type(entry.connection) == "string"
    and type(entry.name) == "string" and type(entry.time) == "number" and type(entry.count) == "number"
    and type(entry.status) == "string"
end

local function limit()
  local max = math.max(0, config.plugins.sql_server.history_entries)
  for i = #entries, max + 1, -1 do entries[i] = nil end
end

local function save()
  pending_save = true
  if saving or state ~= "loaded" then return end
  pending_save, saving = false, true
  local value = { entries = entries }
  local handle = job("save", value, function(_, err)
    saving = false
    if err then core.warn("SQL History did not save: %s", err) end
    core.log_quiet("SQL History: saved entries=%d failed=%s", #value.entries, tostring(err ~= nil))
    if pending_save then save() end
  end)
  if not handle then saving = false; core.warn("SQL History did not save.") end
end

-- Reads the Project's history once. `done` runs when the history is ready.
function M.load(project_key, done)
  if key ~= project_key then M.reset(); key = project_key end
  if state == "loaded" then if done then done() end; return end
  if done then waiting[#waiting + 1] = done end
  if state == "loading" then return end
  state = "loading"
  local handle = job("load", nil, function(value, err)
    if key ~= project_key or state ~= "loading" then return end
    local loaded = {}
    for _, entry in ipairs(type(value) == "table" and type(value.entries) == "table" and value.entries or {}) do
      if valid(entry) then loaded[#loaded + 1] = entry end
    end
    if err then core.warn("SQL History did not load: %s", err) end
    -- Runs that ended during the read go first.
    for _, entry in ipairs(loaded) do entries[#entries + 1] = entry end
    limit()
    state = "loaded"
    core.log_quiet("SQL History: loaded entries=%d", #entries)
    if pending_save then save() end
    local callbacks = waiting
    waiting = {}
    for _, callback in ipairs(callbacks) do callback() end
  end)
  if not handle then state = "unloaded"; waiting = {}; core.warn("SQL History did not load.") end
end

-- Adds a run. `run` has text, connection, name, seconds and status ("OK", "Error" or "Cancelled").
function M.record(project_key, run)
  if config.plugins.sql_server.history_entries <= 0 or #run.text > M.TEXT_LIMIT then return false end
  M.load(project_key)
  local newest = entries[1]
  local time = os.time()
  if newest and newest.text == run.text and newest.connection == run.connection then
    newest.count, newest.time, newest.seconds, newest.status, newest.name =
      newest.count + 1, time, run.seconds, run.status, run.name
  else
    table.insert(entries, 1, { text = run.text, connection = run.connection, name = run.name, time = time,
      seconds = run.seconds, status = run.status, count = 1 })
    limit()
  end
  save()
  return true
end

function M.entries() return entries end
function M.is_saving() return saving or (pending_save and state == "loaded") end

function M.clear(project_key)
  M.load(project_key, function()
    entries = {}
    save()
  end)
end

-- Forgets the loaded history, for a Project switch.
function M.reset()
  entries, key, state, pending_save, waiting = {}, nil, "unloaded", false, {}
end

local function age(seconds)
  if seconds < 60 then return "now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
  return math.floor(seconds / 86400) .. "d ago"
end

-- The prompt rows: the SQL on one line, and the connection, age, status and count on the right.
function M.items()
  local now, items = os.time(), {}
  for i, entry in ipairs(entries) do
    local line = entry.text:gsub("%s+", " "):gsub("^ ", "")
    local info = { entry.name, age(now - entry.time) }
    if type(entry.seconds) == "number" and entry.seconds >= 1 then info[#info + 1] = string.format("%.1f s", entry.seconds) end
    if entry.status ~= "OK" then info[#info + 1] = entry.status end
    if entry.count > 1 then info[#info + 1] = "×" .. entry.count end
    items[i] = { text = line:sub(1, 400), info = table.concat(info, " · "), entry = entry }
  end
  return items
end

-- Opens the prompt. The chosen SQL opens in a new Query on its connection; nothing runs.
function M.open(sql, project_key)
  M.load(project_key, function()
    if #entries == 0 then core.log("SQL History is empty."); return end
    local items = M.items()
    core.global_prompt_bar:enter("SQL History", {
      text = "",
      -- Without a query, the newest run goes first.
      suggest = function(query) return query == "" and items or common.fuzzy_match(items, query) end,
      validate = function(_, item) return item ~= nil end,
      submit = function(_, item)
        local entry = item.entry
        local editor = sql.new_query(sql.find(entry.connection) and entry.connection or nil)
        if not editor then return end
        editor.buffer:text_input(entry.text)
        editor.buffer:set_selection(1, 1)
        core.log_quiet("SQL History: opened an entry")
      end,
    })
  end)
end

return M
