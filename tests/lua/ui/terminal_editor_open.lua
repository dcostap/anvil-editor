local ready = dofile("tests/fixtures/terminal_ready.lua")
local core = require "core"
local command = require "core.command"
local Editor = require "core.editor"
local panes = require "core.panes"
local terminal = require "plugins.terminal"
local test = require "core.test"

local function wait_for(view, predicate)
  local deadline = system.get_time() + 30
  repeat
    view:update()
    if predicate() then return end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  error("Terminal editor request did not complete")
end

local function idle_terminal()
  terminal._set_native_for_tests(nil)
  local view = ready(terminal.open {
    cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile",
  })
  wait_for(view, function() return view.busy == false end)
  return view
end

test.describe("Editor requests from a Terminal Session", function()
  test.before_each(function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    panes.reset_for_tests()
  end)

  test.after_each(function()
    for _, view in ipairs(terminal.open_views()) do view:on_close() end
    panes.reset_for_tests()
  end)

  test.it("waits for the command to finish before opening an Untitled Editor", function()
    local view = idle_terminal()
    local pane = panes.active()
    test.ok(view:write_input("Start-Sleep -Seconds 3\r"))
    wait_for(view, function() return view.busy == true end)
    test.ok(core.on_event("terminaleditor", view.session_id), "editor request was not accepted")
    view:update()
    test.equal(pane.current_view, view)
    test.equal(core.active_view, view)
    wait_for(view, function() return core.active_view ~= view end)
    test.ok(core.active_view:is(Editor))
    test.equal(core.active_view.buffer.abs_filename, nil)
    test.equal(view.busy, false)
    test.ok(view.session)
    test.equal(view.state, "running")
    test.ok(panes.focus(pane))
    test.equal(pane.current_view, view)
  end)

  test.it("does not steal focus after the user selects another Pane", function()
    local view = idle_terminal()
    local source = panes.active()
    test.ok(view:write_input("Start-Sleep -Seconds 3\r"))
    wait_for(view, function() return view.busy == true end)
    test.ok(core.on_event("terminaleditor", view.session_id, {USERDIR .. PATHSEP .. "not-opened.txt"}),
      "editor request was not accepted")
    test.ok(command.perform("pane:new_group"))
    local destination = panes.active()
    local editor = destination.current_view
    wait_for(view, function() return view.busy == false end)
    test.equal(panes.active(), destination)
    test.equal(destination.current_view, editor)
    test.equal(source.current_view, view)
    test.equal(#panes.ordered(), 2)
  end)

  test.it("opens requested files after the command ends and keeps the Terminal", function()
    local view = idle_terminal()
    local source = panes.active()
    local path = USERDIR .. PATHSEP .. "terminal-request.txt"
    test.ok(view:write_input("Start-Sleep -Seconds 3\r"))
    wait_for(view, function() return view.busy == true end)
    test.ok(core.on_event("terminaleditor", view.session_id, {path}))
    view:update()
    test.equal(core.active_view, view)
    wait_for(view, function() return core.active_view ~= view end)
    test.ok(core.active_view:is(Editor))
    test.equal(core.active_view.buffer.abs_filename:gsub("\\", "/"), path:gsub("\\", "/"))
    test.equal(view.busy, false)
    test.ok(panes.focus(source))
    test.equal(source.current_view, view)
  end)
end)
