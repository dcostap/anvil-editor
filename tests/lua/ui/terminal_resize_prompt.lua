local ready = dofile("tests/fixtures/terminal_ready.lua")
local test = require "core.test"
local terminal = require "plugins.terminal"
local next_id = 0

local function console_width(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local width = file:read("*n")
  file:close()
  return width
end

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
  next_id = next_id + 1
  local root = USERDIR .. PATHSEP .. "terminal-resize-" .. next_id
  test.ok(system.mkdir(root))
  local width_path = root .. PATHSEP .. "width.txt"
  local view
  local ok, err = pcall(function()
    view = terminal.open {
      cwd = system.getcwd(),
      shell = 'powershell.exe -NoLogo -NoProfile -NoExit -File tests/fixtures/terminal_resize_prompt.ps1 -WidthFile "'
        .. width_path .. '"',
    }
    ready(view)
    test.ok(wait_for(view, function() return cursor_line(view):find("PS ", 1, true) end))
    test.ok(view.session:resize(80, 24, 8, 16))
    test.ok(wait_for(view, function() return console_width(width_path) == 80 end),
      "the shell did not receive the initial width")
    test.ok(view.session:write("1..40 | % { 'w' * 300 }; 'ANVIL_DONE'\r"))
    test.ok(wait_for(view, function()
      local line, text = cursor_line(view)
      return line:find("PS ", 1, true) and text:find("ANVIL_DONE\n", 1, true)
    end))
    -- Start an input line before resizing. Seeing the prompt text alone does not
    -- mean that PowerShell has finished positioning its line editor.
    test.ok(view.session:write("echo ANVIL_"))
    test.ok(wait_for(view, function() return cursor_line(view):find("PS .*ANVIL_$") end))
    for _, cols in ipairs(widths) do
      test.ok(view.session:resize(cols, 30, 8, 16))
      -- The shell's width changes before its repaint reaches the output pipe.
      local snapshot
      test.ok(wait_for(view, function()
        snapshot = view.session:snapshot(snapshot)
        return console_width(width_path) == cols and snapshot.title == "ANVIL_WIDTH_" .. cols
      end), "the resized shell did not publish width " .. cols)
    end
    test.ok(view.session:write("TYPED"))
    test.ok(wait_for(view, function()
      return cursor_line(view):find("PS .*ANVIL_TYPED")
    end, 10), "typed input left the prompt: " .. select(2, cursor_line(view)))
  end)
  if view then view:on_close() end
  test.ok(test.remove_tree(root))
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
