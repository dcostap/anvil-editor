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
    transfer = id or transfer_id, target = { mode = "group", side = "after" }, focus = true }
end

test.describe("Pane transfer", function()
  local sent, original_send
  test.before_each(function()
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

  for _, destination in ipairs { "missing", "stale", "open", "matching" } do
    test.it("moves Untitled text safely when the target recovery copy is " .. destination, function()
      local recovery = require "plugins.untitled_recovery"
      local untitled = require "plugins.untitled_tabs"
      local BufferRegistry = require "core.buffer_registry"
      local Project = require "core.project"
      local path = USERDIR .. PATHSEP .. "transfer-untitled-" .. sequence
      test.ok(common.mkdirp(path))
      local projects, buffers, registry = core.projects, core.buffers, core.buffer_registry
      local pane = panes.create()
      local buffer = untitled.tag_buffer(pane.current_view.buffer)
      buffer.crlf = false
      local text = "# Pasted Markdown\n\nText with **bold**, ñ and 日本語.\n"
      buffer:insert(1, 1, text)
      buffer:set_language_mode("Markdown")
      local sibling = panes.create { factory = function() return Editor(buffer) end }
      test.ok(recovery.flush_buffer(buffer, "transfer test", true))
      test.ok(export(pane))
      -- Another process has another Buffer registry and another Project recovery folder.
      core.projects, core.buffers = { Project(path) }, {}
      core.buffer_registry = BufferRegistry(core.buffers)
      local moved, old, old_pane
      local ok, err = pcall(function()
        if destination ~= "missing" then
          old = untitled.tag_buffer(core.open_buffer(), "Untitled-1", buffer.intellij_untitled_id)
          old.crlf = false
          if destination == "matching" then
            old:insert(1, 1, text)
            old:set_language_mode("Markdown")
          else
            old:insert(1, 1, "different")
            old:insert(1, 1, "older ")
            old:insert(1, 1, "still ")
          end
          test.ok(recovery.flush_buffer(old, "transfer test", true))
          if destination == "stale" then core.buffer_registry:remove(old, true)
          else old_pane = panes.create { factory = function() return Editor(old) end } end
        end
        if destination == "open" then
          test.not_ok(perform(sent[1].request))
          test.equal(old:get_text(1, 1, math.huge, math.huge), "still older different")
          return
        end
        test.ok(perform(sent[1].request))
        moved = panes.active()
        test.equal(moved.current_view.buffer:get_text(1, 1, math.huge, math.huge), text)
        test.equal(moved.current_view.buffer.language_mode_override, "Markdown")
        test.ok(moved.current_view.buffer:is_dirty())
        if destination == "matching" then test.ok(moved.current_view.buffer == old) end
        recovery.flush_buffer(moved.current_view.buffer, "transfer test", true)
        local file = assert(io.open(moved.current_view.buffer.intellij_untitled_backing_path, "rb"))
        local bytes = file:read("*a"); file:close()
        test.equal(bytes, text .. "\n")
      end)
      if moved then panes.close(moved, { force = true }) end
      if old_pane then panes.close(old_pane, { force = true }) end
      core.projects, core.buffers, core.buffer_registry = projects, buffers, registry
      test.ok(test.remove_tree(recovery.project_paths(path).root))
      test.ok(test.remove_tree(path))
      test.ok(ok, err)
      if destination == "open" then
        test.not_ok(perform(sent[2].request))
        test.ok(panes.find(pane.id) == pane)
        test.equal(buffer:get_text(1, 1, math.huge, math.huge), text)
      else
        test.ok(perform(sent[2].request))
        test.not_ok(panes.find(pane.id))
      end
      test.equal(sibling.current_view.buffer:get_text(1, 1, math.huge, math.huge), text)
    end)
  end

  test.it("keeps new text after undo and a replacement edit while the move waits", function()
    local pane = panes.create()
    local buffer = pane.current_view.buffer
    buffer:insert(1, 1, "exported")
    test.ok(export(pane))
    test.ok(perform(sent[1].request))
    buffer:undo()
    buffer:insert(1, 1, "replacement")
    test.ok(perform(sent[2].request))
    test.ok(panes.find(pane.id) == pane)
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "replacement")
  end)

  test.it("keeps the source when a target confirms without checking its text", function()
    local pane = panes.create()
    pane.current_view.buffer:insert(1, 1, "keep this")
    test.ok(export(pane))
    test.not_ok(perform { action = "transferred", transfer = transfer_id, ok = true })
    test.ok(panes.find(pane.id) == pane)
  end)

  test.it("refuses an older transfer that has no Untitled text", function()
    local untitled = require "plugins.untitled_tabs"
    local pane = panes.create()
    untitled.tag_buffer(pane.current_view.buffer):insert(1, 1, "keep this")
    test.ok(export(pane))
    sent[1].request.snapshot.views[1].state.text = nil
    test.not_ok(perform(sent[1].request))
    test.not_ok(perform(sent[2].request))
    test.equal(panes.count(), 1)
    test.equal(pane.current_view.buffer:get_text(1, 1, math.huge, math.huge), "keep this")
  end)

  test.it("accepts edited text returning after its only source View moved away", function()
    local untitled = require "plugins.untitled_tabs"
    local pane = panes.create()
    local buffer = untitled.tag_buffer(pane.current_view.buffer)
    buffer:insert(1, 1, "original")
    test.ok(export(pane))
    test.ok(perform { action = "transferred", transfer = transfer_id, ok = true, contents_verified = true })
    test.equal(panes.count(), 0)
    -- The other process sends the same Untitled identity back with its current text.
    local returned = sent[1].request
    returned.transfer = transfer_id .. "-return"
    returned.snapshot.views[1].state.text = "edited in the other Project"
    test.ok(perform(returned))
    test.equal(panes.active().current_view.buffer:get_text(1, 1, math.huge, math.huge),
      "edited in the other Project")
    test.ok(panes.active().current_view.buffer:is_dirty())
  end)

  test.it("names a Project on a Machine by its key, and moves a Pane only where its files are", function()
    local machine_project = require "core.machine_project"
    local machine = "anvil-machine://0123456789abcdef0123456789abcdef/"
    local current = machine_project.current
    machine_project.current = machine .. "C:/a"
    -- Opening an Editor for a path can change the working folder. Later tests read fixtures from it.
    local cwd = system.getcwd()
    local ok, err = pcall(function()
      local pane = panes.create { factory = function() return Capture { title = "Notes", text = "one" } end }
      test.ok(perform { action = "export", pane = pane.id, to = machine .. "C:/b", transfer = transfer_id,
        target = { mode = "group", side = "after" } })
      test.equal(sent[1].request.source, machine_project.current)
      -- The source keeps its Pane when the target fails.
      test.not_ok(perform { action = "transferred", transfer = transfer_id, ok = false, error = "test" })

      -- This PC and another Machine have other files at the same paths.
      pane = panes.create { factory = function() return Capture { title = "Notes", text = "one" } end }
      test.not_ok(export(pane, transfer_id .. "-local"))
      test.not_ok(perform { action = "export", pane = pane.id, transfer = transfer_id .. "-other",
        to = "anvil-machine://fedcba9876543210fedcba9876543210/C:/a", target = { mode = "group", side = "after" } })

      -- The target Project reaches only the files inside it.
      local Buffer = require "core.buffer"
      local buffer = Buffer()
      buffer:set_filename("x.md", "C:\\a\\x.md")
      pane = panes.create { factory = function() return Editor(buffer) end }
      test.not_ok(perform { action = "export", pane = pane.id, to = machine .. "C:/b", transfer = transfer_id .. "-file",
        target = { mode = "group", side = "after" } })

      -- An Image View and a File Tree also name files.
      local image = USERDIR .. PATHSEP .. "pane-transfer.png"
      assert(canvas.new(2, 2, { 0, 0, 0, 255 }, true):save_image(image))
      pane = panes.create { factory = function() return require("core.imageview")(image) end }
      test.not_ok(perform { action = "export", pane = pane.id, to = machine .. "C:/b", transfer = transfer_id .. "-image",
        target = { mode = "group", side = "after" } })
      pane = panes.create { factory = function() return require("plugins.filetree").View { root = USERDIR } end }
      test.not_ok(perform { action = "export", pane = pane.id, to = machine .. "C:/b", transfer = transfer_id .. "-tree",
        target = { mode = "group", side = "after" } })
      os.remove(image)
      test.equal(#sent, 1)
    end)
    machine_project.current = current
    system.chdir(cwd)
    test.ok(ok, err)
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

  test.it("keeps a running Terminal when a later View fails to restore", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local terminal = require "plugins.terminal"
    local ready = dofile("tests/fixtures/terminal_ready.lua")
    local source = ready(open_terminal())
    source:mark_input_used()
    wait_until(function() source:service_session(true); return not source.busy end, "shell did not become idle")
    local pane, id = panes.pane_for_view(source), source.session_id
    wait_until(function() local record = session_record(id); return record and record.movable end,
      "the host did not write its record")
    local host_pid = session_record(id).host_pid
    local buffer = require("plugins.untitled_tabs").tag_buffer(core.open_buffer())
    buffer:insert(1, 1, "exported")
    test.ok(panes.present(Editor(buffer), { pane = pane }))
    test.equal(#panes.views(pane), 2)
    -- Control connection timing, not the failure: the real host must finish attaching before rollback.
    local original_restore = terminal.from_state
    terminal.from_state = function(state, opts) return ready(original_restore(state, opts)) end
    local ok, err = pcall(function()
      test.ok(export(pane))
      buffer:insert(1, 1, "conflicting ")
      test.not_ok(perform(sent[1].request))
      -- Delay the failure reply, as separate processes can. Reattaching at once can hide a destructive Close.
      coroutine.yield(2)
      test.ok(session_record(id), "failed import deleted the source Terminal record")
      test.not_ok(perform(sent[2].request))
      ready(source)
      test.equal(source.session_id, id)
      test.equal(session_record(id).host_pid, host_pid, "the shell must not restart after a failed move")
      test.equal(panes.count(), 1)
      test.equal(buffer:get_text(1, 1, math.huge, math.huge), "conflicting exported")
    end)
    terminal.from_state = original_restore
    test.ok(ok, err)
  end)

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
    test.equal(pane.current_view.buffer, buffer)
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
    local buffer = require("plugins.untitled_tabs").tag_buffer(pane.current_view.buffer)
    buffer:insert(1, 1, string.rep("x", 65536))
    test.ok(require("plugins.untitled_recovery").flush_buffer(buffer, "transfer test", true))
    test.not_ok(export(pane))
    test.equal(#sent, 0)
    test.ok(panes.find(pane.id) == pane)
  end)
end)
