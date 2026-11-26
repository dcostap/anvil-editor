local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local panes = require "core.panes"
local keymap = require "core.keymap"
local Project = require "core.project"
local View = require "core.view"
local test = require "core.test"
local external_agents = require "plugins.external_agents"

-- Seam: an External Agent View in a Project process that uses a Machine. The Machine has its own user folder, as
-- the other PC has, and holds the thread.
test.describe("External Agent View on a Machine", function()
  local function wait_until(predicate, message)
    local deadline = system.get_time() + 30
    while system.get_time() < deadline do
      if predicate() then return end
      coroutine.yield(0.02)
    end
    test.fail(message)
  end

  local function request(context, method, params)
    params.project = context.project
    local done, err, result
    fs.machine:request(method, params, nil, function(e, r) done, err, result = true, e, r end)
    wait_until(function() return done end, method .. " timed out")
    test.is_nil(err, err and err.message)
    return result
  end

  test.before_each(function(context)
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "xagent" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    test.ok(common.mkdirp(context.project))
    context.projects = core.projects
    core.projects = { Project(context.project) }
    context.server = machine_server.start(context.user, { context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    wait_until(function() return fs.machine.state == "ready" end, "The Machine did not connect")
    -- The agent's first wait creates it, as Antigravity's first call does.
    request(context, "external.read", { agent = "agy", listen = true })
    request(context, "external.post", { agent = "agy", text = "Hello from agy", from = { kind = "self" } })
  end)

  test.after_each(function(context)
    if context.view then context.view:on_close() end
    panes.reset_for_tests()
    fs.use_local()
    core.projects = context.projects
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("shows the thread, sends a message and follows the agent's answer", function(context)
    local view = external_agents.open("agy")
    context.view = view
    test.ok(view and view:is(external_agents.View), "The command did not open an External Agent View")
    test.equal(view:get_name(), "agy")
    wait_until(function() return #view.messages == 1 end, "The View did not load the thread")
    test.equal(view.messages[1].text, "Hello from agy")
    test.equal(view:author(view.messages[1]), "agy")
    test.equal(view.status, "listening")
    -- The root panel sends View.cursor to the system as the mouse cursor name.
    test.equal(type(view.cursor), "string", "The View must keep a mouse cursor name")

    view.field:on_text("Check the build")
    test.ok(view:send())
    test.equal(view.field:get_text(), "")
    local thread
    wait_until(function()
      thread = request(context, "external.read", { agent = "agy" })
      return #thread.messages == 2
    end, "The message did not reach the Machine")
    test.equal(thread.messages[2].text, "Check the build")
    test.equal(thread.messages[2].from.kind, "user")
    wait_until(function() return #view.messages == 2 end, "The View did not show the sent message")
    test.equal(view:author(view.messages[2]), "You")

    -- The View waits on the Machine, so the answer shows without a new open.
    request(context, "external.post", { agent = "agy", text = "Build is green", reply_to = thread.messages[2].request,
      from = { kind = "self" } })
    wait_until(function() return #view.messages == 3 end, "The View did not show the agent's answer")
    test.equal(view.messages[3].text, "Build is green")

    -- Copy takes the selected message when the field has no selection.
    local clipboard = system.get_clipboard()
    view.selected = view.messages[3]
    test.ok(view:perform("copy"))
    test.equal(system.get_clipboard(), "Build is green")
    system.set_clipboard(clipboard or "")

    test.equal(external_agents.open("agy"), view, "A second open must show the open View")
    local restored = external_agents.View.from_state(view:get_state())
    test.equal(restored.agent, "agy")
    restored:on_close()
  end)

  test.it("keeps its Pane when the user opens another View there", function(context)
    local view = external_agents.open("agy")
    context.view = view
    local pane = panes.pane_for_view(view)
    -- A Sidebar Terminal row opens its Terminal in the current Pane this way.
    local other = panes.place(function() return View() end, { placement = "current", focus = true })
    test.ok(other, "The other View did not open")
    test.equal(pane.current_view, view, "The other View must not replace the thread")
    test.ok(panes.pane_for_view(other) ~= pane, "The other View must open in another Pane")
  end)

  test.it("writes lines with Shift+Enter, sends them with Enter, and keeps a draft", function(context)
    local view = external_agents.open("agy")
    context.view = view
    wait_until(function() return #view.messages == 1 end, "The View did not load the thread")
    view.field:on_text("First line")
    keymap.modkeys.shift = true
    local ok, err = pcall(view.on_key_pressed, view, "return")
    keymap.modkeys.shift = false
    test.ok(ok, err)
    view.field:on_text("Second line")
    test.equal(view.field:get_text(), "First line\nSecond line")
    test.ok(view:perform("move_to_previous_line"))
    test.equal(view.field.input.caret, #"First line")
    test.ok(view:perform("undo"))
    test.equal(view.field:get_text(), "First line\n")
    test.ok(view:perform("redo"))

    local restored = external_agents.View.from_state(view:get_state())
    test.equal(restored.field:get_text(), "First line\nSecond line", "The draft must stay with the Workspace")
    restored:on_close()

    test.ok(view:on_key_pressed("return"))
    test.equal(view.field:get_text(), "")
    wait_until(function() return #view.messages == 2 end, "The View did not show the sent message")
    test.equal(view.messages[2].text, "First line\nSecond line")
    -- The agent has not read it yet. Its next wait reads it.
    test.equal(view.unread, 1)
    request(context, "external.read", { agent = "agy", listen = true, after = 1 })
    wait_until(function() return view.unread == 0 end, "The View did not learn that the agent read the message")
  end)

  test.it("breaks lines at spaces, inside long words and at line breaks, without splitting characters", function()
    local font = require("core.ui").font()
    local width = font:get_width("abcdef")
    local function texts(text)
      local result = {}
      for i, line in ipairs(external_agents.break_lines(font, text, width)) do
        result[i] = text:sub(line[1] + 1, line[2])
      end
      return result
    end
    test.same(texts(""), { "" })
    test.same(texts("ab cd\n\nef"), { "ab cd", "", "ef" })
    test.same(texts("abc defgh"), { "abc ", "defgh" })
    local long = string.rep("\u{00e9}", 40)
    for _, line in ipairs(texts(long)) do
      test.ok(utf8.len(line), "A line must hold whole UTF-8 characters")
      test.ok(#line > 0)
    end
    test.equal(table.concat(texts(long)), long)
    local invalid = "\255\254" .. string.rep("x", 30)
    test.equal(table.concat(texts(invalid)), invalid, "Invalid bytes must stay")
  end)

  test.it("keeps an unsent message when the Machine refuses it", function(context)
    local view = external_agents.View("nobody")
    context.view = view
    wait_until(function() return view.status == "unknown" end, "The View did not report an unknown agent")
    view.field:on_text("Are you there?")
    test.ok(view:send())
    wait_until(function() return view.field.error ~= nil end, "The refused message did not show an error")
    test.equal(view.field:get_text(), "Are you there?")
  end)
end)
