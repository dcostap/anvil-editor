-- mod-version:3
-- Seam: the real MCP endpoint of a hosted Project on a private desktop. An agent opens a second Project without
-- selecting it, moves a running Terminal Session there, and unloads that Project. The Window keeps its Selected
-- Project and its focused editor throughout.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "agent-projects" then return end
local core, common = require "core", require "core.common"
local json = require "core.json"
local root = assert(os.getenv("ANVIL_PROJECT_PROBE_ROOT"))
local path = core.root_project().path:gsub("\\", "/")
local function save(name, value)
 local file = assert(io.open(root .. "/" .. name .. ".lua", "wb"))
 file:write("return ", common.serialize(value)); file:close()
end
local function load(name)
 local file = io.open(root .. "/" .. name .. ".lua", "rb")
 if not file then return end
 local text = file:read("*a"); file:close(); return assert(loadstring(text))()
end
local function wait(fn, seconds, message)
 local deadline = system.get_time() + (seconds or 10)
 repeat local value = fn(); if value then return value end; coroutine.yield(.01) until system.get_time() >= deadline
 error(message or "Agent Project probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
-- The Project that a control discovery file names, or nil.
local function endpoint(project)
 for _, name in ipairs(system.list_dir(USERDIR .. "/control") or {}) do
  local file = name:match("^%d+%.json$") and io.open(USERDIR .. "/control/" .. name, "rb")
  if file then
   local ok, value = pcall(json.decode, file:read("*a")); file:close()
   if ok and type(value) == "table" and type(value.project) == "string" and common.path_equals(value.project, project) then
    return value
   end
  end
 end
end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local done = wait(function() return load("done") or load("project-error") end, 90, "The Project did not finish")
   assert(not done.error, done.error)
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  save("finish", {go=true})
  if shell then
   local deadline = system.get_time() + 15
   while shell:running() and system.get_time() < deadline do coroutine.yield(.1) end
   if shell:running() then shell:terminate(); shell:wait(1) end
  end
  core.exit(function() core.quit_request = true end, true)
 end)
elseif path == root .. "/Project" then
 core.add_background_thread(function()
  local terminal_plugin, panes = require "plugins.terminal", require "core.panes"
  local ok, err = pcall(function()
   local own = wait(function() return endpoint(path) end, 30, "The Project published no control endpoint")
   -- One MCP tool call through the real transport, as an agent makes it.
   local calls = 0
   local function call(name, args)
    calls = calls + 1
    local reply
    require("core.http").post(own.url .. "/mcp", "application/json", nil, {
     body = json.encode{jsonrpc="2.0", id=calls, method="tools/call", params={name=name, arguments=args}},
     decode_json = false, timeout = 30,
     headers = {Authorization = "Bearer " .. own.token, ["Content-Type"] = "application/json"},
     on_done = function(success, failure, body) reply = {success, failure, body} end})
    wait(function() return reply end, 40, "No reply to " .. name)
    assert(reply[1], "MCP request failed: " .. tostring(reply[2]))
    local result = json.decode(reply[3]).result
    return result.structuredContent, result.isError
   end
   local editor = core.open_file(path .. "/edited.txt")
   local terminal = terminal_plugin.open {cwd = path, shell = "cmd.exe /D /Q", placement = "new", focus = true}
   wait(function() return terminal.session and terminal.state == "running" and terminal.session_id end, 20,
    "The Terminal Session did not start")
   local record = function()
    local text = require("terminal_native").read_session_record(terminal.session_id)
    return text and assert(loadstring(text))()
   end
   wait(function() local r = record(); return r and r.movable end, 10, "The Terminal host is not movable")
   core.set_active_view(editor)
   local other = root .. "/Replacement"
   local function focused(step)
    assert(core.active_view == editor, step .. " took the editor's focus: " .. tostring(core.active_view and core.active_view:get_name()))
   end

   local result, failed = call("project", {action = "open", path = other, request_id = "open"})
   assert(not failed and result.status == "accepted", "Open failed: " .. json.encode(result))
   wait(function() return endpoint(other) end, 30, "The opened Project published no control endpoint")
   assert(trace():find("Shell background load: Project=", 1, true), "The shell did not load the Project in the background")
   focused("Open")

   -- Move at once, while the target can still start. The shell keeps the request until the target is ready.
   save("terminal", {id = terminal.session_id})
   local pane = assert(panes.pane_for_view(terminal))
   assert(panes.pane_for_view(editor) ~= pane, "The Terminal shares the editor's Pane")
   result, failed = call("pane", {action = "move", pane = pane.id, target_project = other, request_id = "move"})
   assert(not failed and result.status == "accepted", "Move failed: " .. json.encode(result))
   wait(function() return not panes.find(pane.id) end, 30, "The source kept the moved Pane")
   wait(function() return load("moved") end, 30, "The target did not show the moved Terminal")
   focused("Move")

   result, failed = call("project", {action = "unload", path = path, request_id = "unload-self"})
   assert(failed, "The agent unloaded the Project that serves its call")
   result, failed = call("project", {action = "unload", path = other, request_id = "unload"})
   assert(not failed and result.status == "accepted", "Unload failed: " .. json.encode(result))
   wait(function() return not endpoint(other) end, 30, "The unloaded Project kept running")

   focused("Unload")
   for line in trace():gmatch("[^\n]+") do
    assert(not (line:find("Shell selected loaded Project", 1, true) and line:find("Replacement", 1, true)),
     "The shell selected the opened Project: " .. line)
   end
   save("done", {go = true})
  end)
  if not ok then save("project-error", {error = tostring(err)}) end
  wait(function() return load("finish") end, 120)
  require("core.command").perform("core:close_current_window")
 end)
elseif path == root .. "/Replacement" then
 core.add_background_thread(function()
  local ok, err = pcall(function()
   local id = wait(function() local moved = load("terminal"); return moved and moved.id end, 60)
   local view = wait(function()
    for _, candidate in ipairs(require("plugins.terminal").open_views()) do
     if candidate.session_id == id then return candidate end
    end
   end, 30, "Replacement did not receive the Terminal")
   wait(function() return view.state == "running" end, 20, "The moved Terminal did not attach")
   -- End the shell, so the unload asks no question about a live Terminal Session.
   assert(view:write_input("exit\r"))
   wait(function() return view.state ~= "running" end, 20, "The moved Terminal did not end")
   save("moved", {go = true})
  end)
  if not ok then save("project-error", {error = "Replacement: " .. tostring(err)}) end
 end)
end
