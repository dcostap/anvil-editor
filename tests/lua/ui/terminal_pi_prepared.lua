local test = require "core.test"
local terminal = require "plugins.terminal"
local config = require "core.config"
local common = require "core.common"
local panes = require "core.panes"
local json = require "core.json"
local native

local function wait_for(predicate)
  local deadline = system.get_time() + 30
  repeat
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

local function text(view)
  return view.session:text_capture().text
end

local function service(view)
  view:service_session(true)
  return view.state == "running" and view.agent_app == "pi" and text(view):find("PREPARED_PI_READY", 1, true)
end

local dir, views, previous_path, previous_log, previous_prepare, previous_pi
local function open_pi(cwd)
  local view = terminal.open { cwd = cwd or dir, shell = "cmd.exe /D /Q", placement = "new" }
  views[#views + 1] = view
  test.ok(wait_for(function() view:service_session(true); return view.state == "running" end))
  test.ok(view:write_input("pi\r"))
  test.ok(wait_for(function() return service(view) end), "Pi did not start: " .. text(view))
  return view
end

local function copy(source)
  local view = panes.place(function() return source:duplicate() end, { placement = "new" })
  views[#views + 1] = view
  return view
end

local function launches()
  local result = {}
  for _, name in ipairs(system.list_dir(dir) or {}) do
    if name:find("%.json$") then
      local file = assert(io.open(dir .. "/" .. name, "rb"))
      local contents = file:read("*a"):gsub("^\239\187\191", "")
      file:close()
      result[#result + 1] = json.decode(contents)
    end
  end
  return result
end

test.describe("Pi Terminal copies", function()
  test.before_each(function()
    dir = nil
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    native = require "terminal_native"
    dir = USERDIR .. "/prepared pi " .. tostring(system.get_time()):gsub("%.", "-")
    test.ok(system.mkdir(dir))
    local fixture = system.getcwd() .. "/tests/fixtures/prepared-pi.ps1"
    local file = assert(io.open(dir .. "/pi.cmd", "wb"))
    file:write('@echo off\r\npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' .. fixture .. '" %*\r\n')
    file:close()
    previous_path, previous_log = os.getenv("PATH"), os.getenv("ANVIL_TEST_PI_LOG")
    system.setenv("PATH", dir .. ";" .. previous_path)
    system.setenv("ANVIL_TEST_PI_LOG", dir)
    previous_prepare, previous_pi = config.plugins.terminal.prepare_session, config.plugins.terminal.prepare_pi
    config.plugins.terminal.prepare_session, config.plugins.terminal.prepare_pi = false, true
    views = {}
    terminal._set_native_for_tests(nil)
  end)

  test.after_each(function()
    if not dir then return end
    for _, view in ipairs(views or {}) do view:on_close() end
    terminal._set_native_for_tests(nil)
    native.finish_close_commands()
    config.plugins.terminal.prepare_session, config.plugins.terminal.prepare_pi = previous_prepare, previous_pi
    system.setenv("PATH", previous_path or "")
    system.setenv("ANVIL_TEST_PI_LOG", previous_log or "")
    if dir then test.ok(test.remove_tree(dir)) end
  end)

  test.it("copies a running Pi into a fresh conversation in the same directory", function()
    config.plugins.terminal.prepare_pi = false
    local source = open_pi()
    local original = text(source):match("PREPARED_PI_READY ([%w]+)")
    local duplicate = copy(source)
    test.ok(wait_for(function() return service(duplicate) end), "Copy View opened only a shell: " .. text(duplicate))
    test.not_equal(duplicate.session_id, source.session_id)
    test.not_equal(text(duplicate):match("PREPARED_PI_READY ([%w]+)"), original)
    local started = launches()
    test.equal(#started, 2)
    for _, launch in ipairs(started) do
      test.ok(common.path_equals(launch.cwd, dir), "Pi started in another directory")
      test.equal(#launch.args, 0, "Copy View reused arguments or a conversation")
    end
    test.ok(source:write_input("still here\r"))
    test.ok(wait_for(function() source:service_session(true); return text(source):find("PI_INPUT " .. original .. ":still here", 1, true) end))
    test.ok(source:write_input("exit\r"))
    test.ok(wait_for(function() source:service_session(true); return source.agent_app == nil end))
    local shell = copy(source)
    test.ok(wait_for(function() shell:service_session(true); return shell.state == "running" end))
    test.is_nil(shell.agent_app, "a shell without Pi copied as Pi")
  end)

  test.it("uses a private prepared Pi without giving it to a normal Terminal", function()
    test.not_ok(terminal.prepare_pi_session(), "prepared Pi without a Pi Pane")
    local source = open_pi()
    local prepared
    terminal._set_native_for_tests {
      new = function(options)
        local session, err, code = native.new(options)
        if options.prepared then prepared = session end
        return session, err, code
      end,
    }
    test.ok(wait_for(function() return terminal.prepare_pi_session() end), "Pi preparation did not finish")
    local id = prepared:stats().session_id
    test.is_nil(native.read_session_record(id), "unused Pi appeared in the Sidebar's session records")
    local shell = terminal.open { cwd = dir, shell = "cmd.exe /D /Q", placement = "new" }
    views[#views + 1] = shell
    test.not_equal(shell.session, prepared, "normal Terminal received the prepared Pi")
    local started = system.get_time()
    local duplicate = copy(source)
    print(string.format("Prepared Pi copy: %.1fms", (system.get_time() - started) * 1000))
    test.equal(duplicate.session_id, id, "Copy View did not use the prepared Pi")
    test.ok(text(duplicate):find("PREPARED_PI_READY", 1, true), "prepared Pi screen was lost")
    test.ok(wait_for(function() return service(duplicate) and native.read_session_record(id) ~= nil end))
    test.ok(wait_for(function() return terminal.prepare_pi_session() end), "replacement Pi did not become ready")
    test.not_equal(prepared:stats().session_id, id, "preparation reused an accepted Pi")
    source:on_close()
    duplicate:on_close()
    test.not_ok(terminal.prepare_pi_session(), "kept preparation after the last Pi Pane closed")
    local _, status = prepared:update()
    test.equal(status.kind, "closed", "unused Pi stayed alive without a Pi Pane")
  end)

  test.it("does not use a prepared Pi from another directory", function()
    local source = open_pi()
    test.ok(wait_for(function() return terminal.prepare_pi_session() end))
    local other_dir = dir .. "/other"
    test.ok(system.mkdir(other_dir))
    local other = open_pi(other_dir)
    local duplicate = copy(other)
    test.ok(wait_for(function() return service(duplicate) end))
    local id = text(duplicate):match("PREPARED_PI_READY ([%w]+)")
    local found
    for _, launch in ipairs(launches()) do
      if launch.id == id then found = launch.cwd end
    end
    test.ok(found and common.path_equals(found, other_dir), "Copy View used Pi from another directory")
    source:on_close()
  end)

  for _, action in ipairs { "exit", "disable", "discard" } do
    test.it("closes the unused Pi on " .. action, function()
      local source = open_pi()
      local prepared
      terminal._set_native_for_tests {
        new = function(options)
          local session, err, code = native.new(options)
          if options.prepared then prepared = session end
          return session, err, code
        end,
      }
      test.ok(wait_for(function() return terminal.prepare_pi_session() end))
      local id = prepared:stats().session_id
      if action == "exit" then
        test.ok(source:write_input("exit\r"))
        test.ok(wait_for(function() source:service_session(true); return source.agent_app == nil end))
        test.not_ok(terminal.prepare_pi_session())
      elseif action == "disable" then
        config.plugins.terminal.prepare_pi = false
        test.not_ok(terminal.prepare_pi_session())
      else
        terminal.discard_prepared_session()
      end
      local _, status = prepared:update()
      test.equal(status.kind, "closed")
      test.is_nil(native.read_session_record(id), "unused Pi left a saved Terminal")
    end)
  end

  test.it("starts normally if the prepared Pi has exited", function()
    local source = open_pi()
    local prepared
    terminal._set_native_for_tests {
      new = function(options)
        local session, err, code = native.new(options)
        if options.prepared then prepared = session end
        return session, err, code
      end,
    }
    test.ok(wait_for(function() return terminal.prepare_pi_session() end))
    local id = prepared:stats().session_id
    test.ok(prepared:write("exit\r"))
    test.ok(wait_for(function()
      local _, status = prepared:update()
      return status.agent_app == nil and status.busy == false
    end), "prepared host kept Pi's old status after Pi exited")
    local duplicate = copy(source)
    test.ok(wait_for(function() return service(duplicate) end), "failed preparation blocked Copy View")
    test.not_equal(duplicate.session_id, id, "Copy View received the shell of a Pi that exited")
  end)
end)
