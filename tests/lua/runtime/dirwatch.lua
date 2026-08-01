local common = require "core.common"
local DirWatch = require "core.dirwatch"
local test = require "core.test"
local dirmonitor = require "dirmonitor"

test.describe("core.dirwatch", function()
  test.after_each(function(context)
    if context.monitor and context.watch_id then
      pcall(context.monitor.unwatch, context.monitor, context.watch_id)
    end
    if context.temp_root then common.rm(context.temp_root, true) end
  end)

  test.it("resolves multiple-backend leaf events against their watched directory", function()
    local watch = DirWatch()
    local watched = common.normalize_path(USERDIR .. PATHSEP .. "dirwatch-leaf-root")
    local watch_id = 41
    watch.reverse_watched[watch_id] = watched
    watch.watched[watched] = watch_id
    watch.monitor = {
      mode = function() return "multiple" end,
      check = function(_, callback)
        callback("active-session.log", watch_id)
      end,
      unwatch = function() end,
    }

    local parent, changed
    watch:check(function(path, changed_path)
      parent, changed = path, changed_path
    end)

    test.equal(parent, watched)
    test.equal(changed, common.normalize_path(watched .. PATHSEP .. "active-session.log"))
  end)

  test.it("queues one native wake notification for an unread change batch", function(context)
    local root = common.normalize_path(USERDIR .. PATHSEP .. "dirmonitor-notification-test")
    context.temp_root = root
    common.rm(root, true)
    test.ok(common.mkdirp(root))

    local monitor = dirmonitor.new()
    context.monitor = monitor
    local watch_id = monitor:watch(root)
    context.watch_id = watch_id
    test.ok(watch_id and watch_id >= 0)
    coroutine.yield(0.02)

    local path = root .. PATHSEP .. "changed.txt"
    local file = assert(io.open(path, "wb"))
    file:write("changed")
    file:close()

    local deadline = system.get_time() + 2
    local diagnostics
    repeat
      diagnostics = monitor:diagnostics()
      if diagnostics.notifications_pushed == 0 then coroutine.yield(0.01) end
    until diagnostics.notifications_pushed > 0 or system.get_time() >= deadline
    test.equal(diagnostics.notifications_pushed, 1)
    test.ok(diagnostics.notification_pending)
    test.ok(diagnostics.has_changes)

    -- Leaving a detected batch unread used to enqueue another no-op SDL event
    -- every millisecond. It must remain represented by the original wakeup.
    coroutine.yield(0.08)
    diagnostics = monitor:diagnostics()
    test.equal(diagnostics.notifications_pushed, 1)

    local changed = false
    monitor:check(function() changed = true end)
    test.ok(changed)
    monitor:unwatch(watch_id)
    context.watch_id = nil
    common.rm(root, true)
    context.temp_root = nil
  end)
end)
