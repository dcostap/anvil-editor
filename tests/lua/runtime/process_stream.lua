local test = require "core.test"
local process_stream = require "core.process_stream"

local function lua_command(code)
  return { EXEFILE, "run", "-e", code }
end

-- Windows children write stdout in text mode, so "\n" arrives as "\r\n".
local function next_line(stream)
  local line = stream:read_line()
  return line and line:gsub("\r$", "")
end

local function read_all_lines(stream, timeout)
  local lines = {}
  local deadline = system.get_time() + (timeout or 10)
  while system.get_time() < deadline do
    local line = next_line(stream)
    if line then
      lines[#lines + 1] = line
    elseif stream.done then
      return lines
    else
      coroutine.yield(0.005)
    end
  end
  test.fail("Timed out waiting for the process stream to finish")
end

test.describe("process stream", function()
  test.it("delivers stdout lines in order, including an unterminated last line", function()
    local stream = test.not_nil(process_stream.start(lua_command(
      "io.stdout:write('first\\nsecond\\nlast') io.stderr:write('warned')"
    ), { stderr = true }))
    test.same(read_all_lines(stream), { "first", "second", "last" })
    test.equal(stream.exit_code, 0)
    test.is_nil(stream.error)
    test.equal(stream:take_stderr(), "warned")
  end)

  test.it("delivers all output when it exceeds the unread output window", function()
    local stream = test.not_nil(process_stream.start(lua_command(
      "for i = 1, 5000 do io.stdout:write(('line %05d\\n'):format(i)) end"
    ), { window_bytes = 1024 }))
    local lines = read_all_lines(stream)
    test.equal(#lines, 5000)
    test.equal(lines[1], "line 00001")
    test.equal(lines[5000], "line 05000")
  end)

  test.it("finishes a process that writes no output", function()
    local stream = test.not_nil(process_stream.start(lua_command("local quiet = true")))
    test.same(read_all_lines(stream), {})
    test.equal(stream.exit_code, 0)
  end)

  test.it("reports a command that cannot start", function()
    local stream = test.not_nil(process_stream.start({ USERDIR .. PATHSEP .. "missing-program.exe" }))
    test.same(read_all_lines(stream), {})
    test.not_nil(stream.error)
  end)

  test.it("stops a running process without waiting for it", function()
    local stream = test.not_nil(process_stream.start(lua_command(
      "io.stdout:setvbuf('no') while true do io.stdout:write('tick\\n') system.sleep(0.02) end"
    )))
    local deadline = system.get_time() + 10
    local first
    repeat
      first = next_line(stream)
      if not first then coroutine.yield(0.005) end
    until first or stream.done or system.get_time() >= deadline
    test.equal(first, "tick")
    local started = system.get_time()
    stream:cancel()
    test.ok(system.get_time() - started < 0.05, "cancel waited for the process")
    test.ok(stream.done)
    coroutine.yield(0.1)
    test.is_nil(stream:read_line())
  end)
end)
