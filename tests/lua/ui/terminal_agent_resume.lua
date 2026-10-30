local ready = dofile("tests/fixtures/terminal_ready.lua")
local test = require "core.test"
local terminal = require "plugins.terminal"
local core = require "core"
local json = require "core.json"
local panes = require "core.panes"

local function wait_for(view, predicate, seconds)
  local deadline = system.get_time() + (seconds or 10)
  repeat
    if view and view.session then view:service_session(true) end
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

local function record(id)
  local text = assert(require("terminal_native").read_session_record(id))
  return assert(load(text, "session record", "t", {}))()
end

local function screen_text(view)
  local capture = view.session and view.session:text_capture()
  return capture and capture.text or ""
end

local function checkpoint_on_detach(view, state)
  local path = record(state.session_id).snapshot_path
  test.ok(wait_for(view, function() return record(state.session_id).attached end))
  os.remove(path)
  view:detach_session()
  test.ok(wait_for(nil, function() return not record(state.session_id).attached end))
  test.ok(system.get_file_info(path), "host acknowledged detach without saving its screen")
end

-- The Meson test PATH omits user installs, so look where Node and Bun install themselves.
local function find_runtime(name)
  local localappdata, home = os.getenv("LOCALAPPDATA") or "", os.getenv("USERPROFILE") or ""
  local candidates = {}
  if name == "node" then
    candidates[1] = (os.getenv("ProgramFiles") or "") .. "/nodejs/node.exe"
    for _, entry in ipairs(system.list_dir(localappdata .. "/Programs") or {}) do
      if entry:find("^node%-") then candidates[#candidates + 1] = localappdata .. "/Programs/" .. entry .. "/node.exe" end
    end
  else
    candidates[1] = home .. "/.bun/bin/bun.exe"
    candidates[2] = localappdata .. "/Microsoft/WinGet/Links/bun.exe"
  end
  for _, path in ipairs(candidates) do
    if system.get_file_info(path) then return path end
  end
end

local function launches(dir)
  local file = io.open(dir .. "/launches.log", "rb")
  if not file then return {} end
  local result = {}
  for line in file:lines() do result[#result + 1] = json.decode(line) end
  file:close()
  return result
end

-- A launch's arguments without the status extension that Anvil's preload adds.
local function without_extension(args)
  local result = {}
  local i = 1
  while args[i] do
    if args[i] == "--extension" then i = i + 2 else result[#result + 1] = args[i]; i = i + 1 end
  end
  return result
end

local function session_file_name(dir)
  for _, entry in ipairs(system.list_dir(dir) or {}) do
    if entry:find("%.jsonl$") then return entry end
  end
end

test.describe("Terminal agent resume", function()
  for _, runtime in ipairs { "node", "bun" } do
    test.it("resumes the Pi session that a Pi on " .. runtime .. " had open when its host ended", function()
      test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
      local exe = find_runtime(runtime)
      test.skip_if(not exe, runtime .. " is not installed")
      terminal._set_native_for_tests(nil)
      local dir = USERDIR .. "/pi sessions " .. runtime
      system.mkdir(dir)
      local cli = system.getcwd() .. "/tests/fixtures/fake-pi/dist/cli.js"
      local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
      local state = view:get_state()
      local ffi = require "ffi"
      pcall(ffi.cdef, [[
        void * __stdcall OpenProcess(unsigned long access, int inherit, unsigned long pid);
        int __stdcall TerminateProcess(void *process, unsigned int code);
        unsigned long __stdcall WaitForSingleObject(void *handle, unsigned long milliseconds);
        int __stdcall CloseHandle(void *handle);
      ]])
      local kernel = ffi.load("kernel32")
      local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
      local restored
      local ok, err = pcall(function()
        test.ok(view.session:write(string.format('"%s" "%s" --session-dir "%s"\r', exe, cli, dir)))
        test.ok(wait_for(view, function()
          local saved = record(state.session_id)
          return screen_text(view):find("FAKE_PI_READY", 1, true)
            and saved.interrupted_command and saved.interrupted_command:find("cli.js", 1, true)
        end), "Pi did not start: " .. screen_text(view))
        checkpoint_on_detach(view, state)
        kernel.TerminateProcess(handle, 99); kernel.WaitForSingleObject(handle, 5000)
        restored = panes.place(function() return terminal.from_state(state) end, { placement = "current" })
        test.ok(wait_for(restored, function() return #launches(dir) == 2 end, 15),
          "revival did not resume Pi: " .. screen_text(restored))
        local resumed = without_extension(launches(dir)[2])
        test.equal(#resumed, 2)
        test.equal(resumed[1], "--session")
        test.equal(resumed[2]:match("[^/\\]+$"), session_file_name(dir))
        local option = core.nag_view.options and core.nag_view.options[1]
        test.ok(not (option and option.rerun), "revival asked before resuming Pi")
      end)
      if core.nag_view.options and core.nag_view.options[1] and core.nag_view.options[1].rerun then
        core.nag_view.hovered_item = 2; require("core.command").perform("core:select_dialog_entry")
      end
      if restored then restored:on_close() end
      view:on_close()
      if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
      kernel.CloseHandle(handle)
      test.ok(ok, err)
    end)

    test.it("reports the step of a Pi on " .. runtime .. " but gives a Pi subcommand no extension", function()
      test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
      local exe = find_runtime(runtime)
      test.skip_if(not exe, runtime .. " is not installed")
      terminal._set_native_for_tests(nil)
      local dir = USERDIR .. "/pi status " .. runtime
      system.mkdir(dir)
      local cli = system.getcwd() .. "/tests/fixtures/fake-pi/dist/cli.js"
      local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
      local state = view:get_state()
      local ok, err = pcall(function()
        -- `pi update` reads --extension as a package to install.
        test.ok(view.session:write(string.format('"%s" "%s" update --session-dir "%s"\r', exe, cli, dir)))
        test.ok(wait_for(view, function() return #launches(dir) == 1 end), "pi update did not run")
        test.same(launches(dir)[1], {"update", "--session-dir", dir})
        test.ok(view.session:write(string.format('"%s" "%s" --session-dir "%s" --model-events\r', exe, cli, dir)))
        local saved
        test.ok(wait_for(view, function()
          saved = record(state.session_id)
          return saved.agent_step ~= nil
        end, 15), "Pi's step is missing: " .. screen_text(view))
        test.equal(saved.agent_step, "bash: npm test")
        test.equal(saved.agent_state, "working")
        test.ok(wait_for(view, function()
          saved = record(state.session_id)
          return saved.agent_model == "GPT Test" and view.agent_model == "GPT Test"
        end, 15), "Pi's selected model is missing")
        for _, name in ipairs {"Claude Test", "Fable Test", "Other Model"} do
          test.ok(view.session:write(name .. "\r"))
          test.ok(wait_for(view, function()
            saved = record(state.session_id)
            return saved.agent_model == name and view.agent_model == name
          end, 15), "Pi's selected model did not change to " .. name)
          test.equal(saved.agent_state, "working", "A model change changed Pi's run status")
          test.equal(saved.agent_step, "bash: npm test")
          local item = require("core.tab").describe({current_view=view}, 1)
          test.equal(item.terminal.model, name)
        end
        test.ok(view.session:write("idle\r"))
        test.ok(wait_for(view, function() return record(state.session_id).agent_state == "idle" end, 15))
        test.equal(record(state.session_id).agent_model, "Other Model", "An idle Pi lost its selected model")
        local args = launches(dir)[2]
        test.equal(args[1], "--extension")
        test.equal(args[2]:match("[^/\\]+$"), "pi-status.cjs")
      end)
      view:on_close()
      test.ok(ok, err)
    end)
  end

  test.it("resumes the same idle Pi conversation when its closed Pane reopens", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local exe = find_runtime("node")
    test.skip_if(not exe, "node is not installed")
    terminal._set_native_for_tests(nil)
    local dir = USERDIR .. "/pi closed pane"
    system.mkdir(dir)
    local cli = system.getcwd() .. "/tests/fixtures/fake-pi/dist/cli.js"
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local id = view.session_id
    local restored
    local ok, err = pcall(function()
      test.ok(view:write_input(string.format('"%s" "%s" --session-dir "%s" --model-events\r', exe, cli, dir)))
      test.ok(wait_for(view, function()
        return screen_text(view):find("FAKE_PI_READY", 1, true)
          and record(id).interrupted_pid > 0
      end, 30), "Pi did not start: " .. screen_text(view))
      test.ok(view:write_input("idle\r"))
      test.ok(wait_for(view, function() return record(id).agent_state == "idle" end, 30))
      test.ok(panes.close(panes.pane_for_view(view)), "closing idle Pi asked for confirmation")
      test.not_ok(terminal.session_available(id), "a closed Terminal stayed available outside Reopen")
      test.ok(require("core.command").perform("core:reopen_last_closed_pane"))
      restored = panes.active().current_view
      test.ok(wait_for(restored, function() return #launches(dir) == 2 end, 30),
        "Reopen did not resume Pi: " .. screen_text(restored))
      test.equal(restored.session_id, id)
      local resumed = without_extension(launches(dir)[2])
      test.equal(#resumed, 2)
      test.equal(resumed[1], "--session")
      test.equal(resumed[2]:match("[^/\\]+$"), session_file_name(dir))
    end)
    if restored then restored:on_close() end
    view:on_close()
    require("terminal_native").finish_close_commands()
    test.ok(test.remove_tree(dir))
    test.ok(ok, err)
  end)

  test.it("resumes the Pi session after quit's End answer ends its Terminal", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local exe = find_runtime("node")
    test.skip_if(not exe, "node is not installed")
    terminal._set_native_for_tests(nil)
    local dir = USERDIR .. "/pi sessions ended"
    system.mkdir(dir)
    local cli = system.getcwd() .. "/tests/fixtures/fake-pi/dist/cli.js"
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    local state = view:get_state()
    local kernel = require("ffi").load("kernel32")
    local handle = kernel.OpenProcess(0x100001, 0, view.session:stats().host_pid)
    local previous_quit = core.quit_request
    local restored
    local ok, err = pcall(function()
      test.ok(view.session:write(string.format('"%s" "%s" --session-dir "%s"\r', exe, cli, dir)))
      test.ok(wait_for(view, function()
        local saved = record(state.session_id)
        return screen_text(view):find("FAKE_PI_READY", 1, true)
          and saved.interrupted_command and saved.interrupted_command:find("cli.js", 1, true)
      end), "Pi did not start: " .. screen_text(view))
      core.quit(true)
      test.ok(core.nag_view.visible, "quit did not ask about the Terminal")
      for i, option in ipairs(core.nag_view.options) do
        if option.action == "end" then
          core.nag_view:change_hovered(i)
          test.ok(require("core.command").perform "core:select_dialog_entry")
          break
        end
      end
      test.ok(core.quit_request ~= previous_quit, "the End answer did not accept quit")
      core.quit_request = previous_quit
      require("terminal_native").finish_close_commands()
      test.equal(kernel.WaitForSingleObject(handle, 10000), 0, "End did not end the host")
      restored = panes.place(function() return terminal.from_state(state) end, { placement = "current" })
      test.ok(wait_for(restored, function() return #launches(dir) == 2 end, 15),
        "the ended Terminal did not resume Pi: " .. screen_text(restored))
      test.equal(restored.session_id, state.session_id)
      local resumed = without_extension(launches(dir)[2])
      test.equal(resumed[1], "--session")
      test.equal(resumed[2]:match("[^/\\]+$"), session_file_name(dir))
    end)
    core.quit_request = previous_quit
    if restored then restored:on_close() end
    view:on_close()
    if kernel.WaitForSingleObject(handle, 0) == 258 then kernel.TerminateProcess(handle, 99) end
    kernel.CloseHandle(handle)
    test.ok(ok, err)
  end)

  test.it("reports Pi's step in an Anvil that a Terminal Session started", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local exe = find_runtime("node")
    test.skip_if(not exe, "node is not installed")
    terminal._set_native_for_tests(nil)
    local dir = USERDIR .. "/pi nested"
    system.mkdir(dir)
    local fixtures = system.getcwd() .. "/tests/fixtures/fake-pi"
    local inherited = os.getenv("NODE_OPTIONS") or ""
    system.setenv("NODE_OPTIONS", string.format('--require "%s/inherited-preload.cjs"', (fixtures:gsub("\\", "/"))))
    local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
    system.setenv("NODE_OPTIONS", inherited)
    local state = view:get_state()
    local ok, err = pcall(function()
      test.ok(view.session:write(string.format('"%s" "%s/dist/cli.js" --session-dir "%s"\r', exe, fixtures, dir)))
      test.ok(wait_for(view, function() return record(state.session_id).agent_step ~= nil end, 15),
        "Pi's step is missing: " .. screen_text(view))
    end)
    view:on_close()
    test.ok(ok, err)
  end)
end)
