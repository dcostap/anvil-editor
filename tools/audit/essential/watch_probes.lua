local test = require "core.test"
local common = require "core.common"
local DirWatch = require "core.dirwatch"
local function write_file(path, text)
  local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end

test.describe("Directory watch audit", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "audit-watch-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
  end)
  test.after_each(function(context)
    for _, path in ipairs(context.paths or {}) do context.watch:unwatch(path) end
    if context.native then context.native:unwatch(1) end
    context.watch, context.native = nil, nil
    collectgarbage("collect")
    test.ok(test.remove_tree(context.root))
  end)
  test.it("watches a directory with a non-ASCII name", function(context)
    if PLATFORM ~= "Windows" then test.skip("Windows native path probe") end
    local path = context.root .. PATHSEP .. "notes-測試"
    test.ok(common.mkdirp(path))
    context.native = dirmonitor.new("win32")
    local result = context.native:watch(path)
    print("AUDIT unicode native_watch_result=" .. tostring(result))
    test.ok(result and result >= 0, "native watch rejected an existing Unicode path")
  end)
  test.it("watches sibling directories whose names share a prefix", function(context)
    local first, second = context.root .. PATHSEP .. "notes", context.root .. PATHSEP .. "notes-extra"
    test.ok(common.mkdirp(first)); test.ok(common.mkdirp(second))
    local path = second .. PATHSEP .. "changed.txt"
    local control = first .. PATHSEP .. "control.txt"
    write_file(path, "old\n")
    write_file(control, "old\n")
    context.watch = DirWatch()
    context.paths = { first, second }
    context.watch:watch(first); context.watch:watch(second)
    coroutine.yield(0.1)
    write_file(control, "new content\n")
    write_file(path, "new content\n")
    local seen, control_seen = false, false
    local deadline = system.get_time() + 5
    repeat
      context.watch:check(function(_, changed)
        if changed and common.path_equals(changed, path) then seen = true end
        if changed and common.path_equals(changed, control) then control_seen = true end
      end)
      if not seen then coroutine.yield(0.01) end
    until (seen and control_seen) or system.get_time() >= deadline
    print("AUDIT sibling_watch_saw_second=" .. tostring(seen) .. " control=" .. tostring(control_seen))
    test.ok(control_seen, "the control change was not reported")
    test.ok(seen, "the second sibling's file change was not reported")
  end)
end)
