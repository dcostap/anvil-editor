local ready = dofile("tests/fixtures/terminal_ready.lua")
local test = require "core.test"
local terminal = require "plugins.terminal"

local function wait_for(view, predicate, seconds)
  -- Shells start slowly on a loaded machine. The wait ends as soon as the predicate holds.
  local deadline = system.get_time() + (seconds or 30)
  repeat
    view:service_session(true)
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return false
end

local function cursor_line(view)
  local capture = view.session:text_capture()
  if not capture then return "", "" end
  local lines = {}
  for line in (capture.text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  return lines[capture.cursor_line] or "", capture.text
end

-- Wrapped lines reflow to a different row count at a new width. ConPTY keeps
-- no history, so its prompt row moves, while the Terminal View keeps the
-- prompt at the bottom. Typed input must still appear on the visible prompt.
local function check_input_after(widths)
  test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
  terminal._set_native_for_tests(nil)
  local view = ready(terminal.open { cwd = system.getcwd(), shell = "powershell.exe -NoLogo -NoProfile" })
  local ok, err = pcall(function()
    test.ok(wait_for(view, function() return cursor_line(view):find("PS ", 1, true) end))
    test.ok(view.session:write("1..40 | % { 'w' * 300 }; 'ANVIL_DONE'\r"))
    test.ok(wait_for(view, function()
      local line, text = cursor_line(view)
      return line:find("PS ", 1, true) and text:find("ANVIL_DONE\n", 1, true)
    end))
    for _, cols in ipairs(widths) do
      test.ok(view.session:resize(cols, 30, 8, 16))
      -- ConPTY reads resizes and input from separate pipes.
      coroutine.yield(0.5)
    end
    test.ok(view.session:write("echo ANVIL_TYPED"))
    test.ok(wait_for(view, function()
      return cursor_line(view):find("PS .*ANVIL_TYPED")
    end, 10), "typed input left the prompt: " .. select(2, cursor_line(view)))
  end)
  view:on_close()
  test.ok(ok, err)
end

test.describe("Terminal prompt through width changes", function()
  test.it("keeps input on the prompt after the Terminal grows wider", function()
    check_input_after { 200 }
  end)

  test.it("keeps input on the prompt after the Terminal narrows and widens", function()
    check_input_after { 70, 140 }
  end)
end)
