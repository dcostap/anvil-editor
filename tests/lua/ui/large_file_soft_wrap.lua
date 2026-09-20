local Buffer = require "core.buffer"
local config = require "core.config"
local Editor = require "core.editor"
local test = require "core.test"

local TWO_MIB = 2 * 1024 * 1024

local function write_file(path, size)
  local file = assert(io.open(path, "wb"))
  file:write(string.rep("a", size))
  file:close()
end

test.describe("large file wrapping", function()
  test.before_each(function(context)
    context.paths = {}
    context.views = {}
    context.buffers = {}
    context.enable_by_default = config.plugins.linewrapping.enable_by_default
    context.max_default_file_size = config.plugins.linewrapping.max_default_file_size
    config.plugins.linewrapping.enable_by_default = true
    config.plugins.linewrapping.max_default_file_size = TWO_MIB
  end)

  test.after_each(function(context)
    config.plugins.linewrapping.enable_by_default = context.enable_by_default
    config.plugins.linewrapping.max_default_file_size = context.max_default_file_size
    for _, view in ipairs(context.views) do view:on_close() end
    for _, buffer in ipairs(context.buffers) do buffer:on_close() end
    for _, path in ipairs(context.paths) do os.remove(path) end
  end)

  local function open_sized_file(context, name, size)
    local path = USERDIR .. PATHSEP .. name
    context.paths[#context.paths + 1] = path
    write_file(path, size)
    local buffer = Buffer(path, path, false)
    context.buffers[#context.buffers + 1] = buffer
    local view = Editor(buffer)
    context.views[#context.views + 1] = view
    return view
  end

  test.it("disables default wrapping only above two MiB", function(context)
    local boundary = open_sized_file(
      context, "linewrap-boundary.txt", TWO_MIB
    )
    local large = open_sized_file(
      context, "linewrap-large.txt", TWO_MIB + 1
    )

    test.ok(boundary:is_wrapping_enabled())
    test.equal(large:is_wrapping_enabled(), false)

    large:set_wrapping_enabled(true)
    test.ok(large:is_wrapping_enabled())
  end)
end)
