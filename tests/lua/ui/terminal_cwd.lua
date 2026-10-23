local ready = dofile("tests/fixtures/terminal_ready.lua")
local common = require "core.common"
local command = require "core.command"
local core = require "core"
local test = require "core.test"
local terminal = require "plugins.terminal"

local function wait_for(view, predicate, message)
  local deadline = system.get_time() + 30
  repeat
    view:service_session(true)
    if predicate() then return end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  test.fail(message)
end

local function ps_string(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

test.describe("Terminal current directory", function()
  test.it("copies and saves the changed directory reported by a PowerShell prompt", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    terminal._set_native_for_tests(nil)
    local native = require "terminal_native"
    local directory = USERDIR .. "/terminal cwd's %20"
    test.ok(system.mkdir(directory))
    local source = ready(terminal.open {
      cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile",
    })
    local duplicate
    local ok, err = pcall(function()
      -- Profiles can send OSC 7 followed by ConEmu's quoted OSC 9;9 path.
      local line = "Set-Location -LiteralPath " .. ps_string(directory)
        .. "; $p = $pwd.ProviderPath; $e = [char]27; "
        .. "[Console]::Write($e + ']7;' + ([Uri]::new($p)).AbsoluteUri + [char]7"
        .. " + $e + ']9;9;' + [char]34 + $p + [char]34 + [char]7)\r"
      test.ok(source.session:write(line))
      wait_for(source, function()
        return source.snapshot and source.snapshot.pwd
          and source.snapshot.pwd:sub(1, 1) == '"'
      end, "PowerShell did not report its quoted directory")
      test.ok(common.path_equals(source:get_cwd(), directory),
        "the Terminal ignored its changed directory: " .. source:get_cwd())
      core.set_active_view(source)
      test.ok(command.perform("pane:copy_view_to_split_right"))
      duplicate = ready(core.active_view)
      test.ok(duplicate ~= source)
      test.ok(common.path_equals(duplicate.launch_options.cwd, directory))
      test.ok(duplicate.session:write("[Console]::Write('COPY_CWD=' + ($pwd.ProviderPath -eq "
        .. ps_string(directory:gsub("/", "\\")) .. "))\r"))
      wait_for(duplicate, function()
        local capture = duplicate.session:text_capture()
        return capture and capture.text:find("COPY_CWD=True", 1, true)
      end, "the copied shell did not start in the changed directory")
      wait_for(source, function()
        local text = native.read_session_record(source.session_id)
        local record = text and assert(load(text, "record", "t", {}))()
        return record and common.path_equals(record.cwd, directory)
      end, "the session record did not save the changed directory")
    end)
    if duplicate then duplicate:on_close() end
    source:on_close()
    native.finish_close_commands()
    test.ok(test.remove_tree(directory))
    test.ok(ok, err)
  end)
end)
