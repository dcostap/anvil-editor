local test = require "core.test"

local function wait_for(predicate)
  local deadline = system.get_time() + 30
  repeat
    if predicate() then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  test.fail("Terminal screen did not become ready")
end

test.describe("Terminal snapshot dimensions", function()
  test.it("keeps restored rows at their published size until a pending resize completes", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    local native = require "terminal_native"
    local source, err = native.new {
      cols = 240, rows = 12, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = [[powershell.exe -NoLogo -NoProfile -Command "$e=[char]27; [Console]::Write(('W'*230)+$e+']2;ANVIL_WIDE_READY'+[char]7); Start-Sleep -Seconds 60"]],
    }
    test.ok(source, err)
    local restored
    local ok, failure = pcall(function()
      wait_for(function()
        source:update()
        local screen = source:snapshot(nil, false)
        return screen and screen.title == "ANVIL_WIDE_READY"
      end)
      local id = source:stats().session_id
      local function record()
        return assert(load(assert(native.read_session_record(id)), "session record", "t", {}))()
      end
      source:detach()
      wait_for(function() return not record().attached end)
      local saved = record()
      restored, err = native.new {
        session_id = id, host_pid = saved.host_pid,
        host_creation_time = saved.host_creation_time, pipe_name = saved.pipe_name,
      }
      test.ok(restored, err)
      wait_for(function()
        local _, status = restored:update()
        return status.kind == "running"
      end)
      -- The connection is ready, but its saved screen still needs replay.
      test.ok(restored:resize(20, 6, 8, 16))
      local screen
      wait_for(function()
        restored:update()
        screen = restored:snapshot(nil, false)
        return screen and screen.title == "ANVIL_WIDE_READY"
      end)
      -- Check dimensions before requesting rows: an undersized row buffer can overwrite the heap.
      test.equal(screen.cols, 240)
      test.equal(screen.row_count, 12)
      screen = restored:snapshot()
      test.equal(#screen.rows, 12)
      local found = false
      for _, row in ipairs(screen.rows) do
        for _, run in ipairs(row.text_runs) do
          if run.text:find(string.rep("W", 230), 1, true) then found = true end
        end
      end
      test.ok(found, "restore lost the published wide row")
      wait_for(function()
        restored:update()
        screen = restored:snapshot(screen)
        return screen.cols == 20 and screen.row_count == 6
      end)
      test.equal(#screen.rows, 6)
    end)
    if restored then restored:close() end
    source:close()
    native.finish_close_commands()
    test.ok(ok, failure)
  end)
end)
