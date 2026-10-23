-- Audit probes. These use only the isolated test runner's user folder.
local test = require "core.test"
local common = require "core.common"
local worker_pool = require "core.worker_pool"
local process = require "core.process"

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  assert(f:write(text)); assert(f:close())
end

local function wait_until(fn, seconds, pump)
  local deadline = system.get_time() + (seconds or 30)
  repeat
    if pump then pump() end
    if fn() then return true end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  return fn()
end

test.describe("Essential path audit", function()
  test.it("reports retained worker bookkeeping after completed jobs", function()
    local pool = worker_pool.new { name = "audit-retention", worker_count = 1 }
    local complete = 0
    for _, target in ipairs { 1000, 3000 } do
      for _ = complete + 1, target do
        assert(pool:submit {
          native = true, kind = "test_echo", payload = { value = "audit" },
          on_complete = function() complete = complete + 1 end,
        })
      end
      assert(wait_until(function() return complete == target end, 60, function()
        pool:drain { max_ms = 5, max_messages = 256 }
      end))
      collectgarbage("collect")
      local retained, active, payloads = 0, 0, 0
      for _, job in pairs(pool.jobs) do
        retained = retained + 1
        if not job.finished_at then active = active + 1 end
        if job.spec then payloads = payloads + 1 end
      end
      print(string.format("AUDIT retention completed=%d retained=%d active=%d payloads=%d lua_kib=%.1f",
        complete, retained, active, payloads, collectgarbage("count")))
    end
    pool:shutdown { timeout_ms = 10000 }
  end)

  test.it("recursive removal does not delete a junction target", function(context)
    if PLATFORM ~= "Windows" then test.skip("Windows junction probe") end
    local root = USERDIR .. PATHSEP .. "audit-junction-" .. math.floor(system.get_time() * 1000000)
    context.root = root
    local tree, target = root .. PATHSEP .. "tree", root .. PATHSEP .. "target"
    test.ok(common.mkdirp(tree)); test.ok(common.mkdirp(target))
    local sentinel = target .. PATHSEP .. "keep.txt"
    write_file(sentinel, "This file is outside the removed tree.\n")
    local link = tree .. PATHSEP .. "link"
    context.link = link
    local function ps_quote(s) return "'" .. s:gsub("'", "''") .. "'" end
    local proc = assert(process.start { "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
      "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path " .. ps_quote(link)
        .. " -Target " .. ps_quote(target) .. " | Out-Null" })
    local code = proc:wait(process.WAIT_INFINITE, 0.01)
    test.equal(code, 0, proc:read_stderr() or "junction creation failed")
    local info = system.get_file_info(link)
    test.ok(info and info.symlink, "junction creation failed")
    local removed, err = common.rm(tree, true)
    local kept = system.get_file_info(sentinel) ~= nil
    print(string.format("AUDIT junction removed=%s target_sentinel_kept=%s error=%s",
      tostring(removed), tostring(kept), tostring(err)))
    test.ok(kept, "recursive removal deleted the junction target's file")
  end)

  test.after_each(function(context)
    if context.link and system.get_file_info(context.link) then system.rmdir(context.link) end
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)
end)
