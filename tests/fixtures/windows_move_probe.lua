-- mod-version:3
-- Seam: public hosted APIs, Sidebar input, and isolated owned native Windows.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if not action or not action:match("^windows%-move") then return end
local core, common = require "core", require "core.common"
local command = require "core.command"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 int __stdcall IsWindowVisible(void *);
 int __stdcall IsIconic(void *);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 void * __stdcall GetWindow(void *, unsigned int);
 int __stdcall GetWindowTextW(void *, wchar_t *, int);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
 int __stdcall CloseHandle(void *);
]]
local user32, kernel = ffi.load("user32"), ffi.load("kernel32")
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
 error(message or "Move probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
local menus = dofile(DATADIR .. "/shell_sidebar_menu.lua"){trace = trace, logs = root .. "/user/logs",
 post = function(window, action, value) user32.PostMessageW(window, 0x804a, action, value) end}
local function windows(pid)
 local found = {}
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then
   for id, hex in trace():gmatch("Shell Window record: id=(%d+) SDL=%d+ hwnd=(%x+)") do
    if ffi.cast("void *", tonumber(hex, 16)) == window then found[tonumber(id)] = window end
   end
  end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
local function dialog(pid, title)
 local found
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.IsWindowVisible(window) ~= 0 then
   local text = ffi.new("wchar_t[128]"); local length = user32.GetWindowTextW(window, text, 128)
   local label = {}; for i=0,length-1 do label[#label+1] = string.char(text[i] < 128 and text[i] or 63) end
   if table.concat(label) == title then found = window; return 0 end
  end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
local function quit() core.exit(function() core.quit_request = true end, true) end
if path:match("/driver$") then
 core.add_background_thread(function()
  local subject
  local ok, err = pcall(function()
   subject = assert(require("core.process").start({EXEFILE,"--shell",root .. "/Project"}, {
    stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local a = wait(function() return load("a-ready") end, 20)
   local b = wait(function() return load("b-ready") end, 20)
   local c = wait(function() return load("c-ready") end, 20)
   assert(a.shell_pid == b.shell_pid and c.window_id == a.window_id)
   local all = windows(a.shell_pid); local aw, bw = assert(all[a.window_id]), assert(all[b.window_id])
   local function model()
    os.remove(root .. "/sidebar-0.lua"); user32.PostMessageW(bw, 0x804d, 0, 0)
    return wait(function() return load("sidebar-0") end, 3)
   end
   local function row(page, pid)
    for _, item in ipairs(page.items) do if item.kind == "project" and item.pid == pid then return item end end
    error("Project is missing from Sidebar")
   end
   local function selected(page, id)
    for _, item in ipairs(page.windows) do if item.id == id then return item.selected_project end end
   end
   local page = model(); local ar, br, cr = row(page,a.pid), row(page,b.pid), row(page,c.pid)
   assert(selected(page,a.window_id) == cr.id, "A's original Project was not unpresented")
   wait(function() return trace():find("Shell Sidebar surface Ready: Window=" .. b.window_id, 1, true) end)
   -- Finds A's row in B's Sidebar. Terminal rows appear while the Projects start, so rows have no fixed position. A
   -- right-click on a Project row opens its menu, which names the row, and Escape closes it. A Terminal Tab's menu
   -- names its Project's row too, but it offers no Move.
   local function a_row_y()
    for y = 46, 600, 12 do
     local menu = menus.open(bw, 20 + y * 65536, .3)
     if menu then
      menus.choose(bw)
      if menu.window == b.window_id and menu.row == ar.row_id and menu.labels:find("Move to", 1, true) then return y end
     end
    end
    error("A's row is missing from B's Sidebar")
   end
   -- Select the original Project through B's actual Sidebar surface input.
   user32.PostMessageW(aw, 0x112, 0xf020, 0); wait(function() return user32.IsIconic(aw) ~= 0 end, 3)
   local y = a_row_y()
   user32.PostMessageW(bw,0x804a,1,20+y*65536); user32.PostMessageW(bw,0x804a,2,20+y*65536)
   wait(function() return user32.IsIconic(aw) == 0 end, 5, "B Sidebar did not restore A's owning Window")
   page = model()
   assert(selected(page,a.window_id) == ar.id and selected(page,b.window_id) == br.id,
    "B Sidebar selection changed B or failed to select the Project in A")
   assert(row(page,a.pid).window_id == a.window_id, "Sidebar selection silently moved the Project")
   save("inspect-0",{target=a.window_id}); local before = wait(function() return load("a-state-0") end)
   local function sidebar_move()
    -- Right-click A's row in B's Sidebar and choose B in the Project menu. Its first item moves A to B.
    y = a_row_y()
    local menu = menus.open(bw, 20 + y * 65536)
    assert(menu, "A right-click on A's row showed no menu")
    assert(menu.labels:find("^Move to Window " .. b.window_id .. "|"), "Project menu items: " .. menu.labels)
    menus.choose(bw, "Move to Window " .. b.window_id)
   end
   local function move(target, stage)
    save("move-"..stage,{project_id=ar.id,target=target})
    wait(function() return load("requested-"..stage) end,5)
   end
   if action ~= "windows-move" then
    local blocked = action == "windows-move-dialog" and "dialog" or "close"
    save("block", {kind=blocked})
    wait(function() return load("blocked") end)
    local native
    if blocked == "dialog" then
     native = wait(function() return dialog(a.shell_pid,"Move dialog probe") end,8)
     assert(user32.GetWindow(native,4) == aw,"native dialog lost its source parent")
    else wait(function() return trace():find("Shell close decision: waiting for user",1,true) end,8) end
    -- A closing Window shows no Project menu, and other menus do not offer it as a target. The hosted API still
    -- reaches the shell, which must reject the Move.
    move(b.window_id,"reject")
    local message = blocked == "close" and "Cannot move Project while it closes" or
      "Cannot move Project while a dialog is open"
    wait(function() return trace():find("Shell Window status: id="..b.window_id.." "..message,1,true) end,5,
      "Move rejection did not show its status message")
    assert(row(model(),a.pid).window_id == a.window_id, "rejected Move changed assignment")
    if native then user32.PostMessageW(native,0x10,0,0) else save("cancel-close",true) end
    wait(function() return load("unblocked") end)
    if blocked == "close" then
     wait(function() return trace():find("Shell close decision: cancelled; Ready; request reset",1,true) end,5)
    end
    coroutine.yield(.3)
    assert(row(model(),a.pid).window_id == a.window_id, "rejected Move ran after the blocker ended")
   end
   sidebar_move()
   wait(function() return row(model(),a.pid).window_id == b.window_id end,5,"Move to occupied Window did not change assignment")
   page = model()
   assert(selected(page,b.window_id)==ar.id and selected(page,a.window_id)==cr.id)
   assert(row(page,b.pid).window_id==b.window_id and row(page,b.pid).pid==b.pid,"Move lost target's prior Project")
   save("inspect-1",{target=b.window_id}); local after = wait(function() return load("a-state-1") end)
   assert(after.pid==before.pid and after.text==before.text and after.same_editor and after.dirty,
    "Move replaced the live Buffer or Project")
   assert(after.selection==before.selection and after.session_id==before.session_id and after.host_pid==before.host_pid
    and after.attach_count==before.attach_count and after.workspace==before.workspace,"Move lost selection, Workspace, or Terminal attachment")
   local function new_window(stage)
    local known = windows(a.shell_pid)
    save("new-"..stage,true); wait(function() return load("new-requested-"..stage) end)
    return wait(function() for id in pairs(windows(a.shell_pid)) do if not known[id] then return id end end end,5)
   end
   local function closed(id, message)
    wait(function()
     local hwnd = windows(a.shell_pid)[id]
     return (not hwnd or user32.IsWindowVisible(hwnd)==0) and selected(model(),id)==nil
    end,5,message)
   end
   -- New Window loads Scratch with its Sidebar shown. The Window then holds Scratch, so Moves do not close it.
   local scratch_id = new_window("1")
   local scratch = wait(function() return load("scratch-ready") end,20,"New Window did not load Scratch")
   assert(scratch.window_id==scratch_id and scratch.content_x>0,"New Window did not show Scratch beside its Sidebar")
   local sr = row(model(),scratch.pid)
   assert(selected(model(),scratch_id)==sr.id,"New Window did not select Scratch")
   move(scratch_id,"empty")
   wait(function() return row(model(),a.pid).window_id==scratch_id end,5,"Move to the Scratch Window failed")
   page=model(); assert(selected(page,b.window_id)==br.id and selected(page,scratch_id)==ar.id)
   move(b.window_id,"occupied-again")
   wait(function() return row(model(),a.pid).window_id==b.window_id end,5)
   assert(selected(model(),scratch_id)==sr.id,"A Move out of the Scratch Window lost Scratch")
   -- A second New Window takes Scratch. The first keeps its Window open without a Project.
   local minimized_id = new_window("2")
   wait(function() return row(model(),scratch.pid).window_id==minimized_id end,5,"New Window did not take Scratch")
   page=model()
   assert(selected(page,minimized_id)==sr.id and row(page,scratch.pid).pid==scratch.pid,"Scratch did not move live")
   local kept=windows(a.shell_pid)[scratch_id]
   assert(kept and user32.IsWindowVisible(kept)~=0 and selected(page,scratch_id)~=sr.id,
    "The Window that lost Scratch closed or still shows it")
   local minimized=windows(a.shell_pid)[minimized_id]
   user32.PostMessageW(minimized,0x112,0xf020,0); wait(function() return user32.IsIconic(minimized)~=0 end,3)
   move(minimized_id,"minimized")
   wait(function() return row(model(),a.pid).window_id==minimized_id end,5)
   assert(user32.IsIconic(minimized)~=0,"Move raised a deliberately minimized target")
   page=model(); assert(selected(page,b.window_id)==br.id,"Move did not select B's previous Project")
   assert(selected(page,minimized_id)==ar.id)
   user32.PostMessageW(minimized,0x112,0xf120,0); wait(function() return user32.IsIconic(minimized)==0 end,3)
   save("inspect-2",{target=minimized_id}); local final=wait(function() return load("a-state-2") end)
   assert(final.window_id==minimized_id and final.session_id==before.session_id and final.attach_count==before.attach_count)
   -- Selecting Scratch in B moves it there, as a click on its Sidebar row does.
   save("select-scratch",true)
   wait(function() return row(model(),scratch.pid).window_id==b.window_id end,5,"Selecting Scratch did not move it")
   assert(selected(model(),b.window_id)==sr.id,"Selecting Scratch did not select it in B")
   move(a.window_id,"return")
   wait(function() return row(model(),a.pid).window_id==a.window_id end,5)
   assert(selected(model(),a.window_id)==ar.id)
   closed(minimized_id,"Move left its source Window open without a Project")
   user32.PostMessageW(kept,0x10,0,0)
   closed(scratch_id,"The Window without a Project did not close")
   save("finish",true)
   wait(function() return not subject:running() end,15)
  end)
  local file=assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"),"wb"))
  file:write("return ",common.serialize{ok=ok,error=ok and nil or tostring(err),action=action}); file:close()
  if subject and subject:running() then subject:terminate(); subject:wait(1) end
  quit()
 end)
elseif path == root .. "/Project" then
 core.add_background_thread(function()
  -- Let first-run Workspace setup finish before creating and saving the specimen.
  coroutine.yield(.2)
  local editor=core.open_file(path.."/edited.txt"); core.set_active_view(editor)
  editor.buffer:insert(1,1,"MOVE_LIVE_"); editor.buffer:set_selection(1,2,1,6)
  local terminal=require("plugins.terminal").open{cwd=path,shell="cmd.exe /D /Q"}
  wait(function() return terminal.session and terminal.state=="running" and terminal.session:stats().host_pid>0 end,15)
  core.set_active_view(editor)
  local function state()
   local stats=terminal.session:stats()
   core.save_workspace()
   local storage=require "core.storage"
   local workspace
   for _, key in ipairs(storage.keys("ws") or {}) do
    local value=storage.load("ws",key)
    if value and value.path:gsub("\\","/")==path then workspace=value; break end
   end
   assert(workspace,"Workspace save is missing")
   -- Native placement is App State, not Workspace. Compare the persisted editing layout.
   return {pid=tonumber(kernel.GetCurrentProcessId()),shell_pid=system.get_window_process_id(),window_id=system.get_anvil_window_id(),
    text=editor.buffer:get_text(1,1,1,math.huge),selection=table.concat({editor.buffer:get_selection()},","),
    same_editor=core.active_view==editor,dirty=editor.buffer:is_dirty(),session_id=stats.session_id,host_pid=stats.host_pid,
    attach_count=stats.attach_count,workspace=common.serialize(workspace.pane_state,{sort=true})}
  end
  save("a-ready",state()); assert(core.open_project_in_new_window(root.."/Replacement"))
  assert(system.select_project(root.."/Other"))
  local inspected={}
  local blocking=false
  while not load("finish") do
   for i=0,2 do
    local request=load("inspect-"..i)
    if request and not inspected[i] and request.target==system.get_anvil_window_id() then
     save("a-state-"..i,state()); inspected[i]=true
    end
   end
   if load("block") and not blocking and action ~= "windows-move-target-close" then
    blocking=true
    if load("block").kind=="dialog" then
     core.open_file_dialog(core.window,function(status) assert(status=="cancel"); save("unblocked",true) end,
      {title="Move dialog probe",default_location=(path.."/"):gsub("/","\\")})
    else
     assert(core.begin_quit()); system.project_close_decision("waiting")
    end
    save("blocked",true)
   end
   if action ~= "windows-move-target-close" and load("cancel-close") and not load("unblocked") then
    core.cancel_quit(); save("unblocked",true)
   end
   coroutine.yield(.01)
  end
  terminal.session:close(); editor.buffer:clean(); quit()
 end)
elseif path == root .. "/Replacement" then
 core.add_background_thread(function()
  -- The Move check uses this Window's Sidebar, which starts hidden in an additional Window.
  assert(command.perform("core:toggle_project_sidebar"))
  wait(function() return system.get_window_content_x() > 0 end)
  save("b-ready",{pid=tonumber(kernel.GetCurrentProcessId()),shell_pid=system.get_window_process_id(),window_id=system.get_anvil_window_id()})
  local sent={}
  local blocking, editor
  while not load("finish") do
   if action == "windows-move-target-close" and load("block") and not blocking then
    editor=core.open_file(path.."/edited.txt"); editor.buffer:insert(1,1,"TARGET_DIRTY_")
    blocking=true
    assert(core.begin_quit()); system.project_close_decision("waiting"); save("blocked",true)
   end
   if action == "windows-move-target-close" and load("cancel-close") and not load("unblocked") then
    core.cancel_quit(); editor.buffer:clean(); save("unblocked",true)
   end
   for _,stage in ipairs{"reject","occupied","empty","occupied-again","minimized","return"} do
    local request=load("move-"..stage)
    if request and not sent[stage] then
     assert(system.move_project,"hosted Project Move API is missing")
     assert(system.move_project(request.project_id,request.target)); sent[stage]=true; save("requested-"..stage,true)
    end
   end
   if load("select-scratch") and not sent.scratch then
    assert(system.select_project(USERDIR.."/scratch")); sent.scratch=true
   end
   for _,stage in ipairs{"1","2"} do
    if load("new-"..stage) and not load("new-requested-"..stage) then
     assert(command.perform("core:new_anvil_window")); save("new-requested-"..stage,true)
    end
   end
   coroutine.yield(.01)
  end
  quit()
 end)
elseif path:match("/user/scratch$") then
 core.add_background_thread(function()
  wait(function() return system.get_window_content_x() > 0 end,10)
  save("scratch-ready",{pid=tonumber(kernel.GetCurrentProcessId()),window_id=system.get_anvil_window_id(),
   content_x=system.get_window_content_x()})
  wait(function() return load("finish") end,90); quit()
 end)
else
 core.add_background_thread(function()
  save("c-ready",{pid=tonumber(kernel.GetCurrentProcessId()),window_id=system.get_anvil_window_id()})
  wait(function() return load("finish") end,90); quit()
 end)
end
