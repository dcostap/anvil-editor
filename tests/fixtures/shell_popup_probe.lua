-- mod-version:3
-- Seam: an owned hosted Window on a private desktop. An autocomplete popup in the right part of a Project puts its
-- wide description left of its list. The description stays in the Project's area, so the shell's Sidebar shows the same
-- pixels with and without the popup. Pointer input that the shell routes to the Project selects a suggestion on
-- hover, keeps the popup for a press on its description, and inserts a clicked suggestion at the caret.
local action = os.getenv("ANVIL_PROJECT_PROBE")
if action ~= "popup-sidebar" then return end
local core, common = require "core", require "core.common"
local ffi = require "ffi"
ffi.cdef [[
 unsigned long __stdcall GetCurrentProcessId(void);
 int __stdcall EnumWindows(int (__stdcall *)(void *, intptr_t), intptr_t);
 unsigned long __stdcall GetWindowThreadProcessId(void *, unsigned long *);
 void * __stdcall GetPropW(void *, const wchar_t *);
 intptr_t __stdcall SendMessageW(void *, unsigned int, uintptr_t, intptr_t);
 int __stdcall PostMessageW(void *, unsigned int, uintptr_t, intptr_t);
 void * __stdcall OpenProcess(unsigned long, int, unsigned long);
 int __stdcall TerminateProcess(void *, unsigned int);
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
 local text = file:read("*a"); file:close()
 local chunk = loadstring(text)
 return chunk and chunk()
end
local function wait(fn, seconds, message)
 local deadline = system.get_time() + (seconds or 10)
 repeat local value = fn(); if value then return value end; coroutine.yield(.01) until system.get_time() >= deadline
 error(message or "shell popup probe timed out")
end
local function trace()
 local file = assert(io.open(os.getenv("ANVIL_SURFACE_LOG"), "rb"))
 local text = file:read("*a"); file:close(); return text
end
local function shell_window(pid)
 local property = ffi.new("wchar_t[17]", {65,110,118,105,108,83,104,101,108,108,87,105,110,100,111,119,0})
 local found
 local cb = ffi.cast("int (__stdcall *)(void *, intptr_t)", function(window)
  local owner = ffi.new("unsigned long[1]"); user32.GetWindowThreadProcessId(window, owner)
  if tonumber(owner[0]) == pid and user32.GetPropW(window, property) ~= nil then found = window end
  return 1
 end)
 user32.EnumWindows(cb, 0); cb:free(); return found
end
-- Saves the shell's next composed frame beside the result, for visual review.
local function capture(window, index)
 user32.SendMessageW(window, 0x8052, index, 0)
 wait(function() return trace():find("capture%-" .. index .. "%.bmp") end, 5,
  "shell capture " .. index .. " was not written")
end
local function capture_bytes(index)
 local file_path = assert(trace():match("Shell probe capture written: ([^\r\n]-capture%-" .. index .. "%.bmp)"))
 local file = assert(io.open(file_path, "rb")); local bytes = file:read("*a"); file:close()
 return bytes, bytes:byte(19) + bytes:byte(20) * 256 + bytes:byte(21) * 65536
end
local function quit() core.exit(function() core.quit_request = true end, true) end

if path:match("/driver$") then
 core.add_background_thread(function()
  local shell
  local ok, err = pcall(function()
   shell = assert(require("core.process").start({EXEFILE, "--shell", root .. "/Project"},
    {stdin=process.REDIRECT_DISCARD, stdout=process.REDIRECT_DISCARD, stderr=process.REDIRECT_DISCARD}))
   local editor = wait(function() return load("editor") end, 30, "the Project did not open its Editor")
   wait(function() return trace():find("Shell Sidebar surface Ready", 1, true) end, 15, "Sidebar did not become Ready")
   if os.getenv("ANVIL_RENDERER") ~= "software" then
    wait(function() return trace():find("Shell Sidebar layer: Window=%d+ transparent=1") end, 10,
     "the D3D11 Sidebar was not blended")
   end
   local window = wait(function() return shell_window(shell:pid()) end, 10, "shell Window not found")
   coroutine.yield(1.5)
   capture(window, 1)
   save("popup-go", {go=true})
   local popup = wait(function() return load("popup") end, 15, "the Project did not show the popup")
   assert(popup.list and popup.description, "the popup did not draw its list and description")
   for name, card in pairs{list=popup.list, description=popup.description} do
    assert(card.x >= editor.content_x, string.format("the %s starts at %d, left of the Project area at %d",
     name, card.x, editor.content_x))
   end
   assert(popup.description.x + popup.description.w <= popup.list.x,
    "the description does not go left of the list")
   coroutine.yield(1)
   capture(window, 2)
   -- The Sidebar beside the description's rows looks the same with and without the popup.
   local before, width = capture_bytes(1)
   local after = capture_bytes(2)
   local changed = 0
   local d = popup.description
   for y = math.floor(d.y), math.floor(d.y + d.h) - 1, 2 do
    for x = 2, editor.content_x - 2, 2 do
     local offset = 54 + (y * width + x) * 4
     if before:sub(offset + 1, offset + 3) ~= after:sub(offset + 1, offset + 3) then changed = changed + 1 end
    end
   end
   assert(changed == 0, changed .. " Sidebar pixels changed under the popup")
   -- Pointer input through the shell's routing probe: 0 moves, 1 presses and 2 releases the left button.
   local function post(step, x, y)
    user32.PostMessageW(window, 0x804a, step, math.floor(x) + math.floor(y) * 65536); coroutine.yield(.1)
   end
   local function report(name)
    save(name .. "-check", {go=true})
    return wait(function() return load(name) end, 10, "the Project did not report " .. name)
   end
   local row_x, row_y = popup.list.x + popup.list.w / 2, popup.row_y + popup.row_h * 1.5
   post(0, row_x, row_y)
   local hovered = report("hover")
   assert(hovered.selected == "test02", "hover selected " .. tostring(hovered.selected))
   post(0, d.x + 4, d.y + d.h / 2); post(1, d.x + 4, d.y + d.h / 2); post(2, d.x + 4, d.y + d.h / 2)
   local pressed = report("description")
   assert(pressed.open, "a press on the description closed the popup")
   assert(pressed.line == hovered.line and pressed.col == hovered.col, "a press on the description reached the Editor")
   post(0, row_x, row_y); post(1, row_x, row_y); post(2, row_x, row_y)
   local clicked = report("click")
   assert(not clicked.open, "the clicked suggestion did not close the popup")
   assert(clicked.line:match("test02\n$"), "the click did not insert its suggestion: " .. clicked.line)
  end)
  local file = assert(io.open(os.getenv("ANVIL_PROJECT_PROBE_RESULT"), "wb"))
  file:write("return ", common.serialize{ok=ok, error=ok and nil or tostring(err), action=action})
  file:close()
  if shell and shell:running() then shell:terminate(); shell:wait(1) end
  local editor = load("editor")
  if editor then
   local handle = kernel.OpenProcess(0x1F0FFF, 0, editor.pid)
   if handle ~= nil then kernel.TerminateProcess(handle, 9); kernel.CloseHandle(handle) end
  end
  quit()
 end)
elseif path == root .. "/Project" then
 local card = require "core.card"
 local style = require "core.style"
 local Editor = require "core.editor"
 local autocomplete = require "plugins.autocomplete"
 -- The cards that the popup drew in the last frame: its list, then its description.
 local cards = {}
 local draw_card = card.draw
 card.draw = function(x, y, w, h, ...)
  cards[#cards + 1] = {x=x, y=y, w=w, h=h}
  return draw_card(x, y, w, h, ...)
 end
 local draw_popup = autocomplete.draw
 autocomplete.draw = function(...)
  cards = {}
  return draw_popup(...)
 end
 core.add_background_thread(function()
  coroutine.yield(.5)
  local buffer = core.open_buffer()
  local view = require("core.panes").place(function() return Editor(buffer) end, {placement="new", focus=true})
  wait(function() return view.size.x > 0 end, 10, "the Editor has no size")
  -- The word ends at 60% of the Editor. The list then has more room on its left, and the description is wider
  -- than that room, so it meets the edge of the Project's area.
  local font = view:get_font()
  local text_x = view:get_line_screen_position(1, 1)
  local columns = math.floor((view.position.x + view.size.x * 0.6 - text_x) / font:get_width("x"))
  buffer:insert(1, 1, string.rep("x", math.max(0, columns - 5)) .. " ")
  view:with_selection_state(function() buffer:set_selection(1, math.huge) end)
  coroutine.yield(.5)
  local line = buffer.lines[1]
  save("editor", {pid=tonumber(kernel.GetCurrentProcessId()), content_x=system.get_window_content_x(), line=line})
  wait(function() return load("popup-go") end, 30)
  -- Each Editor keeps its own selection, so text goes in through the Editor's caret.
  view:with_selection_state(function() buffer:text_input("test") end)
  local items = {}
  for i = 1, 3 do
   items[i] = {text=string.format("test%02d", i),
    desc=string.format("test%02d: ", i) .. string.rep("a long description that does not wrap ", 12)}
  end
  autocomplete.add_provider("shell-popup-probe", function(active_view)
   if active_view ~= view then return nil end
   local col
   view:with_selection_state(function() col = select(2, buffer:get_selection()) end)
   return {query="test", line=1, query_col=col - 4, items=items}
  end)
  autocomplete.trigger()
  core.redraw = true
  local shown = wait(function() return #cards >= 2 and cards end, 10, "the popup did not draw")
  local list_h = font:get_height() + style.padding.y
  save("popup", {list=shown[1], description=shown[2], row_y=shown[1].y + style.padding.y / 2, row_h=list_h})
  local function state()
   local selected = autocomplete.get_selected_suggestion()
   local col
   view:with_selection_state(function() col = select(2, buffer:get_selection()) end)
   return {selected=selected and selected.text, open=autocomplete.is_open(), line=buffer.lines[1], col=col}
  end
  for _, name in ipairs{"hover", "description", "click"} do
   wait(function() return load(name .. "-check") end, 30)
   save(name, state())
  end
 end)
end
