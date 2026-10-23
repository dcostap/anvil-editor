local storage = require "core.storage"
local common = require "core.common"
local test = require "core.test"

local core = require "core"

local MODULE = "storage-runtime-test"

local function has_key(keys, expected)
  for _, key in ipairs(keys or {}) do
    if key == expected then return true end
  end
  return false
end

test.describe("storage", function()
  test.after_each(function(context)
    if context.io_open then io.open = context.io_open end
    if context.replace_file then system.replace_file = context.replace_file end
    if context.core_error then core.error = context.core_error end
    if context.pool then context.pool:shutdown() end
    storage.clear(MODULE)
  end)

  test.test("saves and loads keys containing path and Windows filename separators", function()
    local key = [[C:\Users/Darius:repo*?"<>|]]
    test.equal(storage.save(MODULE, key, { value = 42 }), true)

    local loaded = storage.load(MODULE, key)
    test.type(loaded, "table")
    test.equal(loaded.value, 42)
    test.ok(has_key(storage.keys(MODULE), key), "storage.keys should return the original decoded key")
  end)

  test.test("does not collide with similarly named keys", function()
    storage.save(MODULE, "a/b", "slash")
    storage.save(MODULE, "a-b", "dash")
    storage.save(MODULE, "a%2Fb", "escaped")

    test.equal(storage.load(MODULE, "a/b"), "slash")
    test.equal(storage.load(MODULE, "a-b"), "dash")
    test.equal(storage.load(MODULE, "a%2Fb"), "escaped")
  end)

  test.it("loads a complete value while another process saves the same key", function(context)
    local key = "shared"
    storage.save(MODULE, key, { value = 0 })
    local errors = {}
    context.core_error = core.error
    core.error = function(...) errors[#errors + 1] = string.format(...) end
    context.pool = require("core.worker_pool").new { worker_count = 1 }
    local result
    context.pool:submit {
      kind = "worker_pool_test",
      payload = { op = "storage_save_loop", userdir = USERDIR, module = MODULE, key = key, count = 1000 },
      on_result = function(message) if message.type == "final" then result = message.payload end end,
      on_error = function(message) result = { failures = { tostring(message.error) } } end,
    }
    local loads, missing = 0, 0
    local deadline = system.get_time() + 120
    while not result do
      for _ = 1, 20 do
        local value = storage.load(MODULE, key)
        loads = loads + 1
        if type(value) ~= "table" then missing = missing + 1 end
      end
      context.pool:drain { budget_ms = 5, max_messages = 10 }
      test.ok(system.get_time() < deadline, "Storage save loop timed out")
      coroutine.yield(0)
    end
    test.ok(loads > 0)
    test.equal(missing, 0, "loads without a value")
    test.equal(table.concat(errors, "\n"), "")
    test.equal(table.concat(result.failures, "\n"), "")
    test.equal(storage.load(MODULE, key).value, 1000)
  end)

  for _, failure in ipairs { "open", "write", "replace" } do
    test.it("reports a failed " .. failure .. " and retains the saved value", function(context)
      local key = "retained"
      storage.save(MODULE, key, { value = "old" })
      local dir = USERDIR .. PATHSEP .. "storage" .. PATHSEP .. common.encode_filename_component(MODULE) .. PATHSEP
      local message = "Storage test: " .. failure .. " failed"
      context.io_open, context.replace_file = io.open, system.replace_file
      io.open = function(path, mode)
        if mode == "wb" and path:sub(1, #dir) == dir then
          if failure == "open" then return nil, message end
          if failure == "write" then
            local file, err = context.io_open(path, mode)
            if not file then return nil, err end
            return {
              write = function() return nil, message end,
              close = function() return file:close() end,
            }
          end
        end
        return context.io_open(path, mode)
      end
      system.replace_file = function(from, to)
        if failure == "replace" and from:sub(1, #dir) == dir then return false, message end
        return context.replace_file(from, to)
      end
      local ok, err = storage.save(MODULE, key, { value = "new" })
      test.equal(ok, false)
      test.ok(tostring(err):find(message, 1, true))
      test.equal(storage.load(MODULE, key).value, "old")
    end)
  end
end)
