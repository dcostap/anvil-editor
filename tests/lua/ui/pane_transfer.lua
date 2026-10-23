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

  test.it("refuses a Terminal View in Navigation History without starting a transfer", function()
    -- Do not start a shell. The module identity is the transfer boundary.
    local view = Capture { title = "Terminal" }
    function view:get_module() return "plugins.terminal" end
    function view:get_state() return { cwd = USERDIR } end
    local pane = panes.create { factory = function() return view end }
    panes.present(Capture { title = "Current" }, { pane = pane })
    test.equal(pane.current_view:get_name(), "Current")
    test.not_ok(export(pane))
    test.equal(#sent, 0)
    test.equal(panes.find(pane.id), pane)
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
