local common = require "core.common"
local command = require "core.command"
local core = require "core"
local fs = require "core.fs"
local MachineClient = require "core.machine_client"
local markdown_model = require "core.markdown.model"
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
    context.server, context.discovery = machine_server.start(context.user, { context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
    wait_until(function() return fs.machine.state == "ready" end, "The Machine did not connect")
  end)

  local function greet(context)
    -- The agent's first wait creates it, as Antigravity's first call does.
    request(context, "external.read", { agent = "agy", listen = true })
    request(context, "external.post", { agent = "agy", text = "Hello from agy", from = { kind = "self" } })
  end

  test.after_each(function(context)
    if core.active_view == core.global_prompt_bar then core.global_prompt_bar:exit(false) end
    if context.view and context.view ~= context.chat then context.view:on_close() end
    if context.chat then context.chat:on_close() end
    panes.reset_for_tests()
    fs.use_local()
    if context.pair_path then test.ok(os.remove(context.pair_path)) end
    core.projects = context.projects
    if context.cwd then system.chdir(context.cwd) end
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("shows the thread, sends a message and follows the agent's answer", function(context)
    greet(context)
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

    -- After a click in a message, Copy takes its selection, or the whole message without one.
    local clipboard = system.get_clipboard()
    local text = view:text_of(view.messages[3])
    view:focus_text(text)
    test.ok(view:perform("copy"))
    test.equal(system.get_clipboard(), "Build is green")
    text.buffer:set_selection(1, 1, 1, 6)
    test.ok(view:perform("copy"))
    test.equal(system.get_clipboard(), "Build")
    view:copy_message(view.messages[2])
    test.equal(system.get_clipboard(), "Check the build")
    system.set_clipboard(clipboard or "")

    test.equal(external_agents.open("agy"), view, "A second open must show the open View")
    local restored = external_agents.View.from_state(view:get_state())
    test.equal(restored.agent, "agy")
    restored:on_close()
  end)

  test.it("puts answers under their question, and quotes the question of a late answer", function(context)
    local view = external_agents.View("agy")
    context.view = view
    view.closed = true
    local now = os.time()
    view:receive({ listening = true, cursor = 5, seq = 5, messages = {
      { seq = 1, time = now, from = { kind = "user" }, request = "u1", text = "Run the tests" },
      { seq = 2, time = now, from = { kind = "self" }, reply_to = "u1", text = "Running them" },
      { seq = 3, time = now, from = { kind = "agent", name = "brave-otter" }, request = "p1", text = "Which fixture?" },
      { seq = 4, time = now, from = { kind = "self" }, reply_to = "u1", text = "All green" },
      { seq = 5, time = now, from = { kind = "self" }, reply_to = "p1", text = "paths.lua" },
    } })
    view:layout(600)
    local cards = view.cards
    test.equal(#cards, 4, "Each question and each late answer must start a card")
    test.same({ cards[1].messages[1].text, cards[1].messages[2].text }, { "Run the tests", "Running them" })
    test.equal(cards[1].messages[1].depth, 0)
    test.equal(cards[1].messages[2].depth, 1, "An answer must sit under its question")
    test.equal(cards[2].messages[1].text, "Which fixture?")
    test.is_nil(cards[2].quote)
    -- The thread keeps time order, so a late answer quotes its question.
    test.equal(cards[3].messages[1].text, "All green")
    test.equal(cards[3].quote, "You: Run the tests")
    test.equal(cards[4].quote, "brave-otter: Which fixture?")
  end)

  test.it("keeps the final line of a wrapped Markdown answer inside its card", function(context)
    local sections = {}
    for i = 1, 12 do
      sections[i] = ("## Section %d\n\n- **Result:** %s\n"):format(i, ("a wrapped `value` "):rep(16))
    end
    local body = table.concat(sections, "\n") .. "\nFinal result"
    request(context, "external.read", { agent = "agy", listen = true })
    request(context, "external.post", { agent = "agy", text = body, from = { kind = "self" } })
    local view = external_agents.open("agy")
    context.view = view
    wait_until(function()
      local text = view.messages[1] and view.messages[1].text_view
      if not (text and text.text_h and markdown_model.get(text.buffer).status == "ready") then return false end
      if text.__async_wrap_reconstruction then return false end
      local _, y = text:get_line_screen_position(#text.buffer.lines, 1)
      return text:contains(text.position.x, y + text:get_line_height() - 1)
    end, "The card clips the final line")
  end)

  test.it("selects a message's text with the mouse and copies it", function(context)
    greet(context)
    request(context, "external.post", { agent = "agy", text = "Use **bold** text", from = { kind = "self" } })
    local view = external_agents.open("agy")
    context.view = view
    wait_until(function() return #view.messages == 2 end, "The View did not load the thread")
    local text
    wait_until(function()
      text = view.messages[2].text_view
      return text and text.text_h ~= nil
    end, "The View did not draw the message")
    local x, y = text.position.x + 1, text.position.y + text:get_line_height()
    test.ok(view:on_mouse_pressed("left", x, y, 1))
    local stop = text:get_line_screen_position(1, 4)
    view:on_mouse_moved(stop, y, stop - x, 0)
    view:on_mouse_released("left", stop, y)
    local clipboard = system.get_clipboard()
    test.ok(view:perform("copy"))
    test.equal(system.get_clipboard(), "Use", "Copy must use the dragged range, not the whole message")
    local cx, cy, size = view:copy_rect(view.messages[2])
    cx, cy = cx + size / 2, cy + size / 2
    view:on_mouse_moved(cx, cy, 0, 0)
    view:on_mouse_pressed("left", cx, cy, 1)
    view:on_mouse_released("left", cx, cy)
    test.equal(system.get_clipboard(), "Use **bold** text", "The copy button must ignore the partial selection")
    -- Typing goes back to the message box, and the message loses its selection.
    view:on_text_input("x")
    test.equal(view.field:get_text(), "x")
    test.is_nil(text:get_selected_text())
    system.set_clipboard(clipboard or "")
  end)

  local function open_project_chat(context)
    test.ok(command.perform("project:open_chat"))
    local view = core.active_view
    test.equal(view:get_name(), "Project Chat")
    context.chat = view
    return view
  end

  local function click_external_agents(view)
    local button = test.not_nil(view.recipient_button, "Project Chat has no recipient selector")
    wait_until(function() return button.w > 0 end, "The recipient selector did not show")
    local x, y = button.x + button.w / 2, button.y + button.h / 2
    view:on_mouse_pressed("left", x, y, 1)
    view:on_mouse_released("left", x, y)
  end

  test.it("starts a conversation with a silent External Agent from Project Chat", function(context)
    local chat = open_project_chat(context)
    chat:on_text_input("Check the build")
    test.not_ok(chat:send(), "A draft without a recipient must not send")
    click_external_agents(chat)
    wait_until(function()
      return core.get_log():find("No agents are available", 1, true)
    end, "The user did not get setup guidance")
    test.equal(core.active_view, chat)
    request(context, "external.read", { agent = "agy", listen = true })
    click_external_agents(chat)
    wait_until(function() return chat.recipient ~= nil end, "The selector did not choose the only agent")
    test.equal(core.active_view, chat)
    test.equal(#chat.messages, 0)
    test.ok(chat:on_key_pressed("return"))
    wait_until(function() return #chat.messages == 1 and chat.field:get_text() == "" end, "The first message did not send")
    test.equal(chat.messages[1].text, "Check the build")
    test.equal(chat.messages[1].to.name, "agy")
    test.is_nil(chat.messages[1].reply_to)
    local result = request(context, "external.read", { agent = "agy", listen = true })
    test.equal(result.messages[1].text, "Check the build")
    test.equal(open_project_chat(context), chat, "The command must show the open Project Chat")
    test.equal(chat.recipient.name, "agy")
  end)

  test.it("restores the Project Chat Pane and its draft from the Workspace", function(context)
    require "plugins.workspace"
    context.cwd = system.getcwd()
    greet(context)
    local chat = open_project_chat(context)
    click_external_agents(chat)
    wait_until(function() return chat.recipient ~= nil end, "The selector did not choose the only agent")
    local pane_id = panes.pane_for_view(chat).id
    chat:on_text_input("And run the tests")

    test.ok(core.set_project(context.root))
    wait_until(function() return core.workspace_restored end, "The other Project did not open")
    panes.reset_for_tests()
    test.ok(core.set_project(context.project))
    wait_until(function() return core.workspace_restored end, "The Workspace did not load")

    local pane = test.not_nil(panes.find(pane_id), "The Workspace lost the Project Chat Pane")
    local restored = pane.current_view
    test.not_ok(restored == chat, "The Workspace must create a new View")
    test.equal(restored:get_name(), "Project Chat")
    test.equal(restored.recipient.name, "agy")
    test.equal(restored.field:get_text(), "And run the tests")
    wait_until(function() return #restored.messages > 0 end, "The restored View did not load messages")
  end)

  test.it("switches the composer recipient with the picker or a profile click", function(context)
    greet(context)
    request(context, "external.read", { agent = "reviewer", listen = true })
    local chat = open_project_chat(context)
    test.ok(chat:on_key_pressed("tab"), "Tab did not focus the recipient selector")
    test.ok(chat:on_key_pressed("return"))
    local prompt = core.global_prompt_bar
    wait_until(function() return core.active_view == prompt end, "The agent picker did not open")
    prompt:set_text("reviewer")
    prompt:submit()
    test.equal(core.active_view, chat)
    test.equal(chat.recipient.name, "reviewer")
    chat:on_text_input("Check the updated tests")
    wait_until(function() return #chat.messages == 1 and chat.messages[1].y end, "The agent's message did not show")
    local x = chat:column() + require("core.ui").metrics().pad_x + 1
    local y = chat:thread_top() + chat.messages[1].y + 1
    chat:on_mouse_pressed("left", x, y, 1)
    chat:on_mouse_released("left", x, y)
    test.equal(chat.field:get_text(), "Check the updated tests")
    test.equal(chat.recipient.name, "agy")
    test.ok(chat:send())
    wait_until(function() return #chat.messages == 2 end, "The switched message did not send")
    test.equal(chat.messages[2].to.name, "agy")
    test.equal(#request(context, "external.read", { agent = "reviewer" }).messages, 0)
  end)

  test.it("opens an External Agent thread with View access even when the Project feed is unavailable", function(context)
    greet(context)
    local pairing = request(context, "pairing.start", { level = "view" })
    local done, err
    MachineClient.pair("127.0.0.1", context.discovery.port, pairing.code, "Reader", function(e, path)
      done, err, context.pair_path = true, e, path
    end)
    wait_until(function() return done end, "The device did not pair")
    test.is_nil(err, err and err.message)
    fs.use_machine(context.pair_path, { context.project })
    wait_until(function() return fs.machine.state == "ready" end, "The View device did not connect")
    test.equal(fs.machine.level, "view")
    local chat = open_project_chat(context)
    wait_until(function() return chat.error ~= nil end, "The Project feed did not report the access limit")
    click_external_agents(chat)
    wait_until(function() return core.active_view:get_name() == "agy" end, "The View device could not open the thread")
    context.view = core.active_view
    wait_until(function() return #context.view.messages == 1 end, "The View device could not read the thread")
    test.equal(context.view.messages[1].text, "Hello from agy")
  end)

  test.it("replies from a Project result to its author's own thread", function(context)
    request(context, "external.read", { agent = "reviewer", listen = true })
    local project_view = open_project_chat(context)
    click_external_agents(project_view)
    wait_until(function() return project_view.recipient ~= nil end, "The default recipient did not show")
    greet(context)
    wait_until(function() return #project_view.messages == 1 and project_view.messages[1].y end, "No Project result")
    local answer = project_view.messages[1]
    local cx, cy, h = project_view:copy_rect(answer)
    project_view:on_mouse_pressed("left", cx - 2, cy + h / 2, 1)
    project_view:on_text_input("Check Android")
    test.ok(project_view:send(), "Reply did not choose the message's author")
    wait_until(function() return #project_view.messages == 2 end, "Missing question in Project chat")
    local thread = request(context, "external.read", {agent = "agy"})
    test.equal(thread.messages[2].text, "Check Android")
    test.equal(project_view.messages[2].reply_to, answer.request)
    wait_until(function() return project_view.field:get_text() == "" end, "The reply did not finish")
    project_view:on_text_input("Check the build")
    test.ok(project_view:send())
    wait_until(function() return #project_view.messages == 3 end, "The next message did not send")
    test.equal(project_view.messages[3].to.name, "reviewer")
    test.is_nil(project_view.messages[3].reply_to)
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
    greet(context)
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
