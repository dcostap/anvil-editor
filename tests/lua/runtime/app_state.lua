local core = require "core"
local common = require "core.common"
local test = require "core.test"

local function app_state_path()
  return USERDIR .. PATHSEP .. "appstate.lua"
end

local function write_recents(recents)
  local fp = assert(io.open(app_state_path(), "wb"))
  fp:write("return " .. common.serialize({recents = recents}))
  fp:close()
end

local function saved_recents()
  return dofile(app_state_path()).recents
end

test.describe("App State recent Projects", function()
  test.before_each(function(context)
    context.original_recent_projects = core.recent_projects
    context.root = USERDIR .. PATHSEP .. "app-state-tests-" .. math.floor(system.get_time() * 1000000)
    context.dirs = {}
    for _, name in ipairs {"a", "b", "c", "d"} do
      local dir = context.root .. PATHSEP .. name
      test.ok(common.mkdirp(dir))
      context.dirs[name] = common.normalize_volume(system.absolute_path(dir))
    end
    -- Save once, so the changes of this process's startup are already in the file.
    core.save_app_state()
  end)

  test.after_each(function(context)
    core.recent_projects = context.original_recent_projects
    os.remove(app_state_path())
    test.ok(test.remove_tree(context.root))
  end)

  test.test("keeps Projects that another process saved after this process loaded its list", function(context)
    local d = context.dirs
    write_recents {d.a, d.b, d.c}
    core.recent_projects = {d.b}
    test.ok(core.save_app_state())
    test.same(saved_recents(), {d.a, d.b, d.c})
  end)

  test.test("puts this process's opened Project first in the current saved list", function(context)
    local d = context.dirs
    write_recents {d.a, d.b}
    core.update_recent_projects("add", d.c)
    write_recents {d.d, d.a, d.b}
    test.ok(core.save_app_state())
    test.same(saved_recents(), {d.c, d.d, d.a, d.b})
  end)
end)
