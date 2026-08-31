local test = require "core.test"

local fake_server_path = "tests/fixtures/lsp/fake_server.lua"

test.describe("process stream buffering", function()
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
