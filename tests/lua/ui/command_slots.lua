local core = require "core"
local command = require "core.command"
local config = require "core.config"
local process = require "core.process"
local sidepanel = require "core.sidepanel"
local storage = require "core.storage"
local test = require "core.test"
local View = require "core.view"

local command_slots = require "plugins.command_slots"

local function clear_prompt()
  if core.active_view == core.global_prompt_bar then
    core.global_prompt_bar:exit(false)
  end
end

test.describe("Command Slots", function()
  test.before_each(function(context)
    context.previous_active_view = core.active_view
    context.previous_powershell_candidates = config.plugins.command_slots.powershell_candidates
    clear_prompt()
    storage.clear("command-slots")
    command_slots._reset_for_tests()
  end)

  test.after_each(function(context)
    clear_prompt()
    command_slots._reset_for_tests()
    storage.clear("command-slots")
    config.plugins.command_slots.powershell_candidates = context.previous_powershell_candidates
    if context.previous_active_view then
      core.set_active_view(context.previous_active_view)
    end
  end)

  test.it("ignores blank prompt submissions without clearing the stored command", function()
    local runs = {}
    command_slots._run_command_impl = function(slot, text)
      runs[#runs + 1] = { slot = slot.index, text = text }
    end

    command_slots.set_command(1, "Write-Output 'old'")
    test.ok(command.perform("command-slots:edit-a"))
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "Write-Output 'old'")

    core.global_prompt_bar:set_text("")
    core.global_prompt_bar:submit()

    test.equal(command_slots.get_command(1), "Write-Output 'old'")
    test.equal(#runs, 0)
  end)

  test.it("stores and runs a nonblank command submitted from the prompt", function()
    local runs = {}
    command_slots._run_command_impl = function(slot, text)
      runs[#runs + 1] = { slot = slot.index, text = text }
    end

    test.ok(command.perform("command-slots:run-a"), "empty slot should open the prompt")
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "")

    core.global_prompt_bar:set_text("Write-Output 'new'")
    core.global_prompt_bar:submit()

    test.equal(command_slots.get_command(1), "Write-Output 'new'")
    test.equal(#runs, 1)
    test.equal(runs[1].slot, 1)
    test.equal(runs[1].text, "Write-Output 'new'")
  end)

  test.it("shares command history suggestions across slots", function()
    command_slots.set_command(2, "Write-Output 'slot-s'")
    command_slots.record_history("Write-Output 'from-a'")
    command_slots.record_history("Get-ChildItem")

    local suggestions = command_slots.suggest_commands("Write")
    test.equal(#suggestions, 2)
    test.equal(suggestions[1].text, "Write-Output 'from-a'")
    test.equal(suggestions[2].text, "Write-Output 'slot-s'")
  end)

  test.it("keeps Command Output View text read-only while allowing internal appends", function()
    local doc = command_slots.CommandOutputDoc()
    doc:set_text("first\n")
    local original = doc:get_text(1, 1, math.huge, math.huge)

    doc:insert(1, 1, "typed ")
    doc:remove(1, 1, 1, 3)
    doc:text_input("typed")
    doc:delete_to_cursor()

    test.equal(doc:get_text(1, 1, math.huge, math.huge), original)
    doc:append("second\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first\nsecond\n")
    test.not_ok(doc:is_dirty())
  end)

  test.it("keeps Command Output View measurement caches valid after read-only text refreshes", function()
    config.plugins.command_slots.powershell_candidates = {}

    test.ok(command_slots.run_command(1, "Write-Output 'cache cache'"))
    local view = command_slots.slots[1].view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 500, 200
    view.doc:set_selection(1, 1, 1, 6)

    local col1, col2 = view:get_visible_cols_range(1, 300)
    test.ok(col1 <= col2)
    test.ok(view:get_col_x_offset(1, 2) >= 0)

    view:append_text("cache cache\n")
    col1, col2 = view:get_visible_cols_range(1, 300)
    test.ok(col1 <= col2)
    test.ok(view:get_col_x_offset(1, 2) >= 0)
  end)

  test.it("only advances command output carets that were on the trailing blank line", function()
    local doc = command_slots.CommandOutputDoc()
    doc:set_text("first")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first\n")
    test.same({ 2, 1, 2, 1 }, doc.selections)

    doc:append(" second")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first second\n")
    test.same({ 2, 1, 2, 1 }, doc.selections)

    doc:append("\nthird\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first second\nthird\n")
    test.same({ 3, 1, 3, 1 }, doc.selections)

    doc:set_selection(1, 3, 1, 3)
    doc:append("fourth\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "first second\nthird\nfourth\n")
    test.same({ 1, 3, 1, 3 }, doc.selections)
    test.not_ok(doc:is_dirty())
  end)

  test.it("preserves command output horizontal scroll while following appended output", function()
    local view = command_slots.CommandOutputView({ label = "T" })
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 120, 60
    view.doc:set_text("first")
    view.scroll.x, view.scroll.to.x = 80, 80

    view:append_text(" second\nthird\n")

    test.equal(view.scroll.x, 80)
    test.equal(view.scroll.to.x, 80)
    test.same({ 3, 1, 3, 1 }, view.doc.selections)
  end)

  test.it("does not scroll command output when the caret is not on the trailing blank line", function()
    local view = command_slots.CommandOutputView({ label = "T" })
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 120, 60
    view.doc:set_text("one\ntwo")
    view.doc:set_selection(1, 2, 1, 2)
    view.scroll.x, view.scroll.to.x = 80, 80
    view.scroll.y, view.scroll.to.y = 40, 40

    view:append_text("\nthree\n")

    test.equal(view.scroll.x, 80)
    test.equal(view.scroll.to.x, 80)
    test.equal(view.scroll.y, 40)
    test.equal(view.scroll.to.y, 40)
    test.same({ 1, 2, 1, 2 }, view.doc.selections)
  end)

  test.it("shows one tabbed Command Output panel without stealing Main Panel focus", function()
    config.plugins.command_slots.powershell_candidates = {}
    if sidepanel.is_side_view(core.active_view) then
      sidepanel.focus_main(false)
    end
    local previous = core.active_view

    test.ok(command_slots.run_command(1, "Write-Output 'one'"))

    test.equal(core.active_view, previous)
    test.ok(command_slots.output_panel and command_slots.output_panel.command_output_panel)
    test.ok(sidepanel.contains_view(command_slots.output_panel))
    test.equal(command_slots.output_panel.active_slot_index, 1)
    test.equal(command_slots.slots[1].view:get_name(), "A: Write-Output 'one'")
    test.equal(command_slots.output_panel:slot_view(command_slots.slots[2]):get_name(), "S: No commands")
  end)

  test.it("focuses Command Output panel on demand", function()
    if sidepanel.is_side_view(core.active_view) then
      sidepanel.focus_main(false)
    end

    test.ok(command.perform("command-slots:focus-output"))

    test.ok(command_slots.output_panel and command_slots.output_panel.command_output_panel)
    test.ok(sidepanel.contains_view(command_slots.output_panel))
    test.ok(core.active_view and core.active_view.command_output_view)
    test.equal(core.active_view.slot.index, command_slots.output_panel.active_slot_index)
  end)

  test.it("focuses Command Output when a command is run from another Side Panel view", function()
    config.plugins.command_slots.powershell_candidates = {}
    local dummy = View()
    sidepanel.register_panel("command-slots-test-side", dummy)
    sidepanel.show("command-slots-test-side", { focus = true })
    test.equal(core.active_view, dummy)

    test.ok(command_slots.run_command(2, "Write-Output 'side'"))

    test.ok(core.active_view and core.active_view.command_output_view)
    test.equal(core.active_view.slot.index, 2)
    test.equal(command_slots.output_panel.active_slot_index, 2)
    sidepanel.remove_view(dummy, false)
  end)

  test.it("navigates per-slot Command Output History and new runs switch to newest", function()
    config.plugins.command_slots.powershell_candidates = {}

    test.ok(command_slots.run_command(1, "Write-Output 'first'"))
    test.ok(command_slots.run_command(1, "Write-Output 'second'"))
    local slot = command_slots.slots[1]
    core.set_active_view(slot.view)

    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "second")
    test.ok(command.perform("command-slots:history-previous"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "first")
    test.equal(slot.output_history_index, 1)

    test.ok(command.perform("command-slots:history-next"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "second")
    test.equal(slot.output_history_index, 2)

    test.ok(command.perform("command-slots:history-previous"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "first")
    test.ok(command_slots.run_command(1, "Write-Output 'third'"))
    test.contains(slot.view.doc:get_text(1, 1, math.huge, math.huge), "third")
    test.equal(slot.output_history_index, #slot.output_history)
  end)

  test.it("root tab switching commands switch Command Output tabs internally", function()
    config.plugins.command_slots.powershell_candidates = {}

    test.ok(command_slots.run_command(1, "Write-Output 'first'"))
    local panel = command_slots.output_panel
    panel:select_slot(1, { focus = true })
    test.equal(core.active_view, command_slots.slots[1].view)

    test.ok(command.perform("root:switch-to-next-tab"))

    test.equal(panel.active_slot_index, 2)
    test.equal(core.active_view, command_slots.slots[2].view)
    test.equal(command_slots.slots[2].view:get_name(), "S: No commands")
  end)

  test.it("sends payloads to disposable warm PowerShell workers and closes stdin", function()
    test.skip_if(PLATFORM ~= "Windows", "Command Slots use PowerShell on Windows")

    local token = "warm-test"
    local marker = "__ANVIL_COMMAND_SLOT_DONE__" .. token .. ":"
    local proc = process.start({ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command_slots._build_powershell_controller() }, {
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_STDOUT,
    })
    test.not_nil(proc, "expected Windows PowerShell to start")

    local payload = command_slots._build_powershell_payload("cmd.exe /d /s /c sort; Write-Output 'slot-payload-ok'", core.root_project().path, token)
    test.not_nil(proc.stdin:write(payload))
    test.not_nil(proc.stdin:close())

    local output = ""
    local deadline = system.get_time() + 4
    while system.get_time() < deadline and not output:find(marker, 1, true) do
      local chunk = proc:read_stdout(4096)
      if chunk and chunk ~= "" then
        output = output .. chunk
      elseif chunk == nil and not proc:running() then
        break
      else
        coroutine.yield(0.01)
      end
    end
    pcall(proc.kill, proc)

    test.contains(output, "slot-payload-ok")
    test.contains(output, marker .. "0")
  end)

  test.it("strips ANSI control sequences from command output", function()
    local slot = command_slots.slots[1]
    local chunks = {}
    slot.view = {
      append_text = function(_, text)
        chunks[#chunks + 1] = text
      end,
    }
    slot.running = true
    slot.token = "ansi"
    slot.start_time = system.get_time()
    slot.pending_output = ""
    slot.output_bytes = 0
    slot.truncated = false

    test.ok(command_slots._process_worker_output(slot, "\27[32;1mgreen\27[0m\n__ANVIL_COMMAND_SLOT_DONE__ansi:0\n"))

    local output = table.concat(chunks)
    test.contains(output, "green\n")
    test.is_nil(output:find("\27", 1, true))
    test.is_nil(output:find("[32;1m", 1, true))
  end)

  test.it("strips the private completion marker and appends an exit footer", function()
    local slot = command_slots.slots[1]
    local chunks = {}
    slot.view = {
      append_text = function(_, text)
        chunks[#chunks + 1] = text
      end,
    }
    slot.running = true
    slot.token = "tok"
    slot.start_time = system.get_time()
    slot.pending_output = ""
    slot.output_bytes = 0
    slot.truncated = false

    local marker = "__ANVIL_COMMAND_SLOT_DONE__tok:"
    test.not_ok(command_slots._process_worker_output(slot, "hello\n" .. marker:sub(1, 12)))
    test.ok(slot.running)
    test.ok(command_slots._process_worker_output(slot, marker:sub(13) .. "7\n"))

    local output = table.concat(chunks)
    test.contains(output, "hello\n")
    test.contains(output, "exited with code 7")
    test.is_nil(output:find("__ANVIL_COMMAND_SLOT_DONE__", 1, true))
    test.not_ok(slot.running)
  end)
end)
