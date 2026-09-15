local test = require "core.test"

local fake_server_path = "tests/fixtures/lsp/fake_server.lua"

test.describe("process stream buffering", function()
  test.it("collects both output streams while the caller does not poll", function()
    local marker = USERDIR .. PATHSEP .. "process-output-complete"
    os.remove(marker)
    local proc = assert(process.start({ EXEFILE, "run", "tests/fixtures/process_output.lua" }, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env = { ANVIL_PROCESS_OUTPUT_MARKER = marker },
    }))
    local ok, err = pcall(function()
      local deadline = system.get_time() + 3
      local complete = false
      repeat
        local file = io.open(marker, "rb")
        if file then file:close(); complete = true; break end
        -- Do not poll the process or run Lua threads during this wait.
        system.sleep(0.01)
      until system.get_time() >= deadline
      test.ok(complete, "child output blocked while the caller did not poll")
      test.equal(proc:wait(process.WAIT_INFINITE, 0.01), 0)
      test.equal(proc.stdout:read("all"), string.rep("out!", 48 * 1024))
      test.equal(proc.stderr:read("all"), string.rep("err!", 48 * 1024))
    end)
    if proc:running() then
      proc:kill()
      proc:wait(3000, 0.01)
    end
    os.remove(marker)
    if not ok then error(err, 0) end
  end)

  test.it("allows output streams to close while a child runs", function()
    local proc = assert(process.start({ EXEFILE, "run", fake_server_path }, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env = { ANVIL_LSP_FAKE_SERVER_MODE = "stdout_stderr" },
    }))
    test.not_nil(proc:close_stream(process.STREAM_STDOUT))
    test.not_nil(proc:close_stream(process.STREAM_STDERR))
    test.type(proc:wait(3000, 0.01), "number")
    test.is_nil(proc:read_stdout())
    test.is_nil(proc:read_stderr())
  end)

  test.it("reads completed line output without copying the full remainder", function()
    local proc, err = process.start({ EXEFILE, "run", fake_server_path }, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
      env = { ANVIL_LSP_FAKE_SERVER_MODE = "many_long_lines" },
    })
    test.not_nil(proc, err)
    test.type(proc:wait(process.WAIT_INFINITE, 0.001), "number")

    local started = system.get_time()
    local lines = 0
    while true do
      local line, read_err = proc.stdout:read("line")
      test.is_nil(read_err)
      if not line then break end
      lines = lines + 1
    end
    local elapsed = system.get_time() - started

    test.equal(lines, 2048)
    test.ok(elapsed < 0.25, string.format(
      "line reads copied buffered output for %.3f seconds", elapsed
    ))
  end)
end)
