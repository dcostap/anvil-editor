local storage = require "core.storage"
local common = require "core.common"
local test = require "core.test"

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
    if context.os_rename then os.rename = context.os_rename end
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

  for _, failure in ipairs { "open", "write", "replace" } do
    test.it("reports a failed " .. failure .. " and retains the saved value", function(context)
      local key = "retained"
      storage.save(MODULE, key, { value = "old" })
      local dir = USERDIR .. PATHSEP .. "storage" .. PATHSEP .. common.encode_filename_component(MODULE) .. PATHSEP
      local message = "Storage test: " .. failure .. " failed"
      context.io_open, context.os_rename = io.open, os.rename
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
      os.rename = function(from, to)
        if failure == "replace" and from:sub(1, #dir) == dir then return nil, message end
        return context.os_rename(from, to)
      end
      local ok, err = storage.save(MODULE, key, { value = "new" })
      test.equal(ok, false)
      test.ok(tostring(err):find(message, 1, true))
      test.equal(storage.load(MODULE, key).value, "old")
    end)
  end
end)
