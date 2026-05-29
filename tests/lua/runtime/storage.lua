local storage = require "core.storage"
local test = require "core.test"

local MODULE = "storage-runtime-test"

local function has_key(keys, expected)
  for _, key in ipairs(keys or {}) do
    if key == expected then return true end
  end
  return false
end

test.describe("storage", function()
  test.after_each(function()
    storage.clear(MODULE)
  end)

  test.test("saves and loads keys containing path and Windows filename separators", function()
    local key = [[C:\Users/Darius:repo*?"<>|]]
    storage.save(MODULE, key, { value = 42 })

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
end)
