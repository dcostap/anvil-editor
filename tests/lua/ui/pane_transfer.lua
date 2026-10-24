local core = require "core"
local panes = require "core.panes"
local common = require "core.common"
local system = require "system"
local Capture = require("core.text_capture").View
local Editor = require "core.editor"
local test = require "core.test"
local sequence = 0
local transfer_id

local function perform(request)
  return require("core.pane_transfer").perform(request)
end

local function export(pane, id)
  return perform { action = "export", pane = pane.id, to = USERDIR,
    transfer = id or transfer_id, target = { mode = "group", side = "after" } }
end

test.describe("Pane transfer", function()
  local sent, original_send
  test.before_each(function()
    coroutine.yield(0.05)
    panes.reset_for_tests()
    sequence = sequence + 1
    transfer_id = "test-transfer-" .. sequence
    sent = {}
    original_send = system.pane_request
    system.pane_request = function(route, path, text)
      sent[#sent + 1] = { route = route, path = path,
        request = assert(load("return " .. text, "request", "t", {}))() }
      return true
    end
  end)
  test.after_each(function()
    system.pane_request = original_send
    panes.reset_for_tests()
  end)

  test.it("moves Views and Navigation History only after the target confirms", function()
    local pane = panes.create { factory = function() return Capture { title = "First", text = "one" } end }
    panes.present(Capture { title = "Second", text = "two" }, { pane = pane })
    panes.back(pane)
    test.ok(export(pane))
    test.equal(panes.count(), 1)
    test.equal(sent[1].route, "select")
    test.ok(perform(sent[1].request))
    local restored = panes.active()
    test.equal(restored.current_view:get_name(), "First")
    test.equal(panes.forward(restored):get_name(), "Second")
    test.equal(panes.back(restored):get_name(), "First")
    test.equal(panes.count(), 2)
    test.ok(perform(sent[2].request))
    test.not_ok(panes.find(pane.id))
    test.equal(panes.count(), 1)
    test.ok(panes.validate())
  end)

  test.it("carries Untitled text and keeps edits made before confirmation", function()
    local pane = panes.create()
    pane.current_view.buffer:insert(1, 1, "unsaved text")
    test.ok(export(pane))
    test.ok(perform(sent[1].request))
    test.equal(panes.active().current_view.buffer:get_text(1, 1, math.huge, math.huge), "unsaved text")
    pane.current_view.buffer:insert(1, 1, "later ")
    test.ok(perform(sent[2].request))
    test.equal(panes.find(pane.id), pane)
  end)

  test.it("keeps the source when the target reports failure", function()
    local pane = panes.create()
    test.ok(export(pane))
    test.not_ok(perform { action = "transferred", transfer = transfer_id, ok = false, error = "Cannot restore" })
    test.equal(panes.find(pane.id), pane)
  end)

  -- A real shell, because the move hands its host from one client to the next.
  local function open_terminal(shell)
    local terminal = require "plugins.terminal"
    terminal._set_native_for_tests(nil)
    return terminal.open { shell = shell or "powershell.exe -NoLogo -NoProfile" }
  end

  local function session_record(id)
    local text = require("terminal_native").read_session_record(id)
    return text and assert(load(text, "record", "t", {}))()
  end

  local function wait_until(fn, message)
    local deadline = system.get_time() + 30
    repeat
      if fn() then return end
      coroutine.yield(0.02)
    until system.get_time() >= deadline
    test.fail(message)
  end

  test.it("moves a running Terminal Session to the target Project", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local ready = dofile("tests/fixtures/terminal_ready.lua")
    local Project = require "core.project"
    local source = ready(open_terminal())
    local pane, id = panes.pane_for_view(source), source.session_id
    wait_until(function() local record = session_record(id); return record and record.movable end,
      "the host did not write its record")
    test.ok(export(pane))
    local target = USERDIR .. PATHSEP .. "pane-transfer-target"
    test.ok(common.mkdirp(target))
    local projects, moved = core.projects, nil
    core.projects = { Project(target) }
    local ok, err = pcall(function()
      test.ok(perform(sent[1].request))
      moved = ready(panes.active().current_view)
      test.equal(moved.session_id, id)
      wait_until(function() return common.path_equals(session_record(id).project_path, target) end,
        "the host did not save the target Project")
    end)
    core.projects = projects
    if ok then
      ok, err = pcall(function()
        test.ok(perform(sent[2].request))
        test.not_ok(panes.find(pane.id))
        moved:service_session(true)
        test.equal(moved.state, "running")
        test.ok(session_record(id), "closing the source ended the moved session")
      end)
    end
    if moved then panes.close(panes.pane_for_view(moved), { force = true }) end
    test.ok(test.remove_tree(target))
    test.ok(ok, err)
  end)

  test.it("attaches the Terminal Session again when the target cannot take it", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local ready = dofile("tests/fixtures/terminal_ready.lua")
    local source = ready(open_terminal())
    local pane, id = panes.pane_for_view(source), source.session_id
    wait_until(function() local record = session_record(id); return record and record.movable end,
      "the host did not write its record")
    test.ok(export(pane))
    test.not_ok(perform { action = "transferred", transfer = transfer_id, ok = false, error = "Cannot restore" })
    test.equal(panes.find(pane.id), pane)
    ready(source)
    test.equal(source.session_id, id)
    panes.close(pane, { force = true })
  end)

  test.it("refuses a Terminal View that has not started without starting a transfer", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local view = open_terminal()
    local pane = panes.pane_for_view(view)
    test.equal(view.state, "reconnecting")
    test.not_ok(export(pane))
    test.equal(#sent, 0)
    test.equal(panes.find(pane.id), pane)
    dofile("tests/fixtures/terminal_ready.lua")(view)
    panes.close(pane, { force = true })
  end)

  test.it("saves modified file-backed Buffers before sending", function()
    local cwd = system.getcwd()
    local path = USERDIR .. PATHSEP .. "pane-transfer-save"
    test.ok(common.mkdirp(path))
    local filename = path .. PATHSEP .. "file.txt"
    local file = assert(io.open(filename, "wb")); file:write("old\n"); file:close()
    local buffer = core.open_buffer(filename)
    local pane = panes.create { factory = function() return Editor(buffer) end }
    coroutine.yield(0.05)
    buffer:insert(1, 1, "new ")
    test.ok(export(pane))
    test.not_ok(buffer:is_dirty())
    test.ok(common.path_equals(sent[1].request.snapshot.views[1].state.filename, filename))
    file = assert(io.open(filename, "rb"))
    test.equal(file:read("*a"), "new old\n"); file:close()
    panes.close(pane, { force = true })
    core.buffer_registry:remove(buffer, true)
    system.chdir(cwd)
    test.ok(test.remove_tree(path))
  end)

  test.it("refuses text that exceeds the transport limit", function()
    local pane = panes.create()
    pane.current_view.buffer:insert(1, 1, string.rep("x", 65536))
    test.not_ok(export(pane))
    test.equal(#sent, 0)
  end)
end)
