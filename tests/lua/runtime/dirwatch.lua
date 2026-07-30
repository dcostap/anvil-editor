local common = require "core.common"
local DirWatch = require "core.dirwatch"
local test = require "core.test"

test.describe("core.dirwatch", function()
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
end)
