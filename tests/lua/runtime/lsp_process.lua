local test = require "core.test"
local jsonrpc = require "core.lsp.jsonrpc"
local lsp_json = require "core.lsp.json"
local lsp_process = require "core.lsp.process"

local fake_server_path = "tests/fixtures/lsp/fake_server.lua"

local function fake_command()
  return { EXEFILE, "run", fake_server_path }
end

local function fake_env(mode)
  return { ANVIL_LSP_FAKE_SERVER_MODE = mode }
end

local function start_raw(mode)
  local proc, err = process.start(fake_command(), {
    stdin = process.REDIRECT_PIPE,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
    env = fake_env(mode),
  })
  test.not_nil(proc, err)
  return proc
end

local function start_transport(mode)
  local transport, err = lsp_process.start(fake_command(), {
    env = fake_env(mode),
  })
  test.not_nil(transport, err)
  return transport
end

local function cleanup_proc(proc)
  if proc and proc:running() then
    proc:kill()
    proc:wait(1000, 0.01)
  end
end

local function cleanup_transport(transport)
  if transport and transport:running() then
    transport:kill()
    transport:wait(1000, 0.01)
  end
end

local function read_native_until(proc, fd, timeout)
  local chunks = {}
  local start = system.get_time()
  while system.get_time() - start < timeout do
    local chunk, err = proc.process:read(fd, 4096)
    if err then return nil, err end
    if chunk and #chunk > 0 then
      chunks[#chunks + 1] = chunk
      return table.concat(chunks), system.get_time() - start
    end
    system.sleep(0.01)
  end
  return table.concat(chunks), system.get_time() - start
end

local function poll_transport(transport, timeout, fn)
  local start = system.get_time()
  while system.get_time() - start < timeout do
    local done, result = fn()
    if done then return result end
    system.sleep(0.01)
  end
  return nil, "timeout"
end

test.describe("core.lsp.process stdio transport", function()
  test.test("native proc:read drains available stdout without waiting to fill requested size", function()
    local proc = start_raw("chunked_stdout")
    local output, elapsed = read_native_until(proc, process.STREAM_STDOUT, 1.5)
    cleanup_proc(proc)

    test.not_nil(output)
    test.contains(output, "lsp-chunk-one")
    test.not_ok(output:find("lsp-chunk-two", 1, true))
    test.ok(elapsed < 1.5, "native read waited too long for a partial stdout chunk")
  end)

  test.test("native stdout and stderr can be drained independently", function()
    local proc = start_raw("stdout_stderr")
    local stdout, stderr = "", ""
    local start = system.get_time()
    while system.get_time() - start < 2 do
      local out_chunk = proc.process:read(process.STREAM_STDOUT, 4096)
      local err_chunk = proc.process:read(process.STREAM_STDERR, 4096)
      if out_chunk and #out_chunk > 0 then stdout = stdout .. out_chunk end
      if err_chunk and #err_chunk > 0 then stderr = stderr .. err_chunk end
      if stdout:find("stdout-one", 1, true) and stderr:find("stderr-one", 1, true) then
        break
      end
      system.sleep(0.01)
    end
    cleanup_proc(proc)

    test.contains(stdout, "stdout-one")
    test.contains(stderr, "stderr-one")
  end)

  test.test("process exit can be detected reliably", function()
    local proc = start_raw("exit_code")
    local code = proc:wait(3000, 0.01)
    test.equal(code, 17)
    test.equal(proc:returncode(), 17)
    test.not_ok(proc:running())
  end)

  test.test("stdio transport returns empty string quickly when no stdout is available", function()
    local transport = start_transport("delayed_stdout")
    local start = system.get_time()
    local chunk, err = transport:read(4096)
    local elapsed = system.get_time() - start
    cleanup_transport(transport)

    test.not_nil(chunk, err)
    test.equal(chunk, "")
    test.ok(elapsed < 0.25, "read should poll available data without blocking for delayed stdout")
  end)

  test.test("stdio transport reads partial and multiple framed messages", function()
    local transport = start_transport("framed_partial_multiple")
    local parser = jsonrpc.new_parser()
    local messages = {}
    local result, err = poll_transport(transport, 3, function()
      local chunk, read_err = transport:read(4096)
      test.not_nil(chunk, read_err)
      if #chunk > 0 then
        local parsed, parse_err = parser:feed(chunk)
        test.not_nil(parsed, parse_err)
        for _, message in ipairs(parsed) do
          messages[#messages + 1] = message
        end
      end
      return #messages >= 2, messages
    end)
    cleanup_transport(transport)

    test.not_nil(result, err)
    test.equal(messages[1].kind, "notification")
    test.equal(messages[1].method, "fake/one")
    test.equal(messages[2].kind, "notification")
    test.equal(messages[2].method, "fake/two")
    test.ok(lsp_json.is_array(messages[2].params))
  end)

  test.test("stdio transport drains and captures stderr independently", function()
    local transport = start_transport("stdout_stderr")
    local stderr = ""
    local stdout = ""
    local result, err = poll_transport(transport, 3, function()
      local out_chunk = test.not_nil(transport:read(4096))
      local err_chunk = test.not_nil(transport:read_stderr(4096))
      if #out_chunk > 0 then stdout = stdout .. out_chunk end
      if #err_chunk > 0 then stderr = stderr .. err_chunk end
      return stdout:find("stdout-one", 1, true)
        and stderr:find("stderr-one", 1, true)
        and stderr:find("stderr-two", 1, true), true
    end)
    cleanup_transport(transport)

    test.not_nil(result, err)
    test.contains(stdout, "stdout-one")
    test.contains(stderr, "stderr-one")
    test.contains(stderr, "stderr-two")
    test.contains(transport.stderr_tail, "stderr-two")
  end)

  test.test("stdio transport chunks large writes", function()
    local calls = 0
    local native = {
      read = function() return "" end,
      write = function(_, bytes)
        calls = calls + 1
        test.ok(#bytes <= 4096, "write chunk was too large for pipe-safe LSP writes: " .. tostring(#bytes))
        return #bytes
      end,
      close_stream = function() return true end,
      running = function() return true end,
      returncode = function() return nil end,
      wait = function() return nil end,
    }
    local transport = lsp_process.new({ process = native })
    local payload = ("x"):rep(20000)
    local written, err = transport:write(payload)

    test.equal(written, #payload, err)
    test.ok(calls >= 3)
  end)

  test.test("stdio transport reports writes after stdin is closed", function()
    local transport = start_transport("echo_stdin")
    test.not_nil(transport:close_stdin())
    local written, err = transport:write("after-close")
    cleanup_transport(transport)

    test.is_nil(written)
    test.contains(err, "stdin closed")
  end)

  test.test("stdio transport waits for not-ready writes and resumes after backpressure", function()
    local calls = 0
    local native = {
      read = function() return "" end,
      write = function(_, bytes)
        calls = calls + 1
        if calls == 1 then return math.min(2, #bytes) end
        if calls <= 3 then return 0 end
        return #bytes
      end,
      close_stream = function() return true end,
      running = function() return true end,
      returncode = function() return nil end,
      wait = function() return nil end,
    }
    local transport = lsp_process.new({ process = native }, { write_stall_timeout = 0.25, write_scan = 0.001 })
    local written, err = transport:write("abcdef")

    test.equal(written, 6, err)
    test.ok(calls >= 4)
  end)

  test.test("stdio transport fails writes that remain not-ready", function()
    local calls = 0
    local native = {
      read = function() return "" end,
      write = function(_, bytes)
        calls = calls + 1
        if calls == 1 then return math.min(2, #bytes) end
        return 0
      end,
      close_stream = function() return true end,
      running = function() return true end,
      returncode = function() return nil end,
      wait = function() return nil end,
    }
    local transport = lsp_process.new({ process = native }, { write_stall_timeout = 0.01, write_scan = 0.001 })
    local written, err = transport:write("abcdef")

    test.is_nil(written)
    test.contains(err, "write stalled")
  end)

  test.test("stdio transport wait returns wrapped wait timeout without native fallback", function()
    local native = {
      read = function() return "" end,
      write = function() return 0 end,
      close_stream = function() return true end,
      running = function() return true end,
      returncode = function() return nil end,
      wait = function() error("native wait fallback should not be called") end,
    }
    local proc = {
      process = native,
      wait = function(_, timeout, scan)
        test.equal(timeout, 1)
        test.equal(scan, 0.01)
        return nil, "timeout"
      end,
    }
    local transport = lsp_process.new(proc)
    local code, err = transport:wait(1, 0.01)

    test.is_nil(code)
    test.equal(err, "timeout")
  end)
end)
