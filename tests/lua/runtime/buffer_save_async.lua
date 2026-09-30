local core = require "core"
local test = require "core.test"
local Buffer = require "core.buffer"
local pool = require "core.worker_pool"

test.describe("asynchronous safe writes", function()
  test.after_each(function(context)
    if context.buffer then context.buffer:on_close() end
    if context.path then os.remove(context.path) end
  end)
  local function open(context)
    context.path = USERDIR .. PATHSEP .. "async-save-" .. system.get_process_id() .. ".txt"
    local f = assert(io.open(context.path, "wb")); f:write("original\n"); f:close()
    local buffer = Buffer(context.path, context.path)
    context.buffer = buffer
    buffer:insert(1, 1, "saved ")
    return buffer
  end
  local function wait(request)
    local deadline = system.get_time() + 10
    repeat
      pool.system():drain { max_ms = 5 }
      if request.status ~= "pending" then return end
      coroutine.yield(.001)
    until system.get_time() > deadline
    error("save did not finish")
  end
  local function contents(context)
    local f = assert(io.open(context.path, "rb")); local text = f:read("*a"); f:close(); return text
  end
  test.it("keeps edits made during a save dirty and on the next save", function(context)
    local buffer = open(context)
    local request = assert(buffer:save_async())
    buffer:insert(1, 1, "later ")
    wait(request)
    test.equal(request.status, "saved", request.error)
    test.equal(contents(context), "saved original\n")
    test.ok(buffer:is_dirty(), "later edits must remain dirty")
    wait(assert(buffer:save_async()))
    test.equal(contents(context), "later saved original\n")
    test.equal(buffer:is_dirty(), false)
  end)
  test.it("never replaces a newer synchronous save with an older result", function(context)
    local buffer = open(context)
    local request = assert(buffer:save_async())
    buffer:insert(1, 1, "newest ")
    buffer:save()
    wait(request)
    test.equal(contents(context), "newest saved original\n")
    test.equal(buffer:is_dirty(), false)
  end)
  test.it("runs the save guard before replacing the file", function(context)
    local buffer = open(context)
    local allow = true
    local request = assert(buffer:save_async(nil, function() return allow, "disk changed" end))
    allow = false
    wait(request)
    test.equal(request.status, "failed")
    test.equal(contents(context), "original\n")
    test.ok(buffer:is_dirty())
  end)
  test.it("preserves the BOM and CRLF bytes", function(context)
    local buffer = open(context)
    buffer.crlf, buffer.bom = true, "\239\187\191"
    wait(assert(buffer:save_async()))
    test.equal(contents(context), "\239\187\191saved original\r\n")
    test.equal(buffer:is_dirty(), false)
  end)
  test.it("rejects a file that gains another link during preparation", function(context)
    local buffer = open(context)
    local request = assert(buffer:save_async())
    local get_info = system.get_file_info
    system.get_file_info = function(path)
      local info = get_info(path)
      if path == context.path and info then info.link_count = 2 end
      return info
    end
    local ok, err = pcall(wait, request)
    system.get_file_info = get_info
    if not ok then error(err) end
    test.equal(request.status, "failed")
    test.equal(contents(context), "original\n")
    test.ok(buffer:is_dirty())
  end)
  test.it("keeps the file and dirty text when the replacement guard rejects it", function(context)
    local buffer = open(context)
    local request = assert(buffer:save_async())
    local replace = system.atomic_replace_file
    system.atomic_replace_file = function(source, target, ...)
      if target == context.path then return nil, "replacement denied", "changed" end
      return replace(source, target, ...)
    end
    local ok, err = pcall(wait, request)
    system.atomic_replace_file = replace
    if not ok then error(err) end
    test.equal(request.status, "failed")
    test.equal(contents(context), "original\n")
    test.ok(buffer:is_dirty())
  end)
  test.it("keeps later merged text input dirty", function(context)
    local buffer = open(context)
    buffer:set_selection(1, 1)
    buffer:text_input("before ")
    local request = assert(buffer:save_async())
    buffer:text_input("later ")
    wait(request)
    test.equal(contents(context), "before saved original\n")
    test.ok(buffer:is_dirty())
  end)
end)
