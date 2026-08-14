local BufferRegistry = require "core.buffer_registry"
local test = require "core.test"

local function buffer(name, dirty)
  return {
    abs_filename = name,
    dirty = dirty,
    closes = 0,
    is_dirty = function(self) return self.dirty end,
    on_close = function(self) self.closes = self.closes + 1 end,
  }
end

test.describe("Buffer Registry", function()
  test.it("uses one Buffer identity for one file", function()
    local registry = BufferRegistry()
    local created = 0
    local one = registry:open("C:/Work/File.lua", function()
      created = created + 1
      return buffer("C:/Work/File.lua")
    end)
    local same = registry:open("c:\\work\\file.lua", function()
      created = created + 1
      return buffer("c:/work/file.lua")
    end)
    test.equal(same, one)
    test.equal(created, 1)
    test.equal(#registry:list(), 1)
  end)

  test.it("gives each Untitled Buffer a distinct identity", function()
    local registry = BufferRegistry()
    local one, two = buffer(), buffer()
    registry:register(one)
    registry:register(two)
    test.not_equal(registry:identity(one), registry:identity(two))
    test.equal(#registry:list(), 2)
  end)

  test.it("counts live and retained owners", function()
    local registry = BufferRegistry()
    local value = buffer("a.lua")
    local current, retained = {}, {}
    registry:register(value)
    registry:retain(value, current)
    registry:retain(value, retained)
    test.equal(registry:reference_count(value), 2)
    registry:release(value, current)
    test.equal(registry:reference_count(value), 1)
  end)

  test.it("collects only clean unreferenced Buffers", function()
    local registry = BufferRegistry()
    local clean = buffer("clean.lua", false)
    local dirty = buffer("dirty.lua", true)
    registry:register(clean)
    registry:register(dirty)
    test.equal(registry:collect(), 1)
    test.equal(clean.closes, 1)
    test.equal(dirty.closes, 0)
    test.same(registry:list(), { dirty })
  end)

  test.it("keeps a Buffer while a persistent holder retains it", function()
    local registry = BufferRegistry()
    local value = buffer("held.lua", false)
    local recovery = {}
    registry:register(value)
    registry:retain(value, recovery)
    test.equal(registry:collect(), 0)
    registry:release(value, recovery)
    test.equal(registry:collect(), 1)
  end)

  test.it("updates the file identity after Save As", function()
    local registry = BufferRegistry()
    local value = buffer()
    registry:register(value)
    value.abs_filename = "C:/work/saved.lua"
    registry:update_identity(value)
    test.equal(registry:find("c:/WORK/saved.lua"), value)
  end)
end)
