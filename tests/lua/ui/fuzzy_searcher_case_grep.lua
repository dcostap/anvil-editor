local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"

local function wait_until(predicate)
  local deadline = system.get_time() + 8
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.03) end
  return predicate()
end

test.describe("Case-sensitive text search", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-case-grep-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
    local file = assert(io.open(context.root .. PATHSEP .. "search.txt", "wb"))
    file:write("RenderWidget\nrenderWidget\n")
    file:close()
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_workspace {}
    core.projects = context.projects
    system.chdir(context.cwd)
    common.rm(context.root, true)
  end)

  test.it("requires matching letter case for exact and fuzzy text matches", function()
    fuzzy_searcher.open("#Render")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return #(picker.results or {}) == 2 end))
    test.ok(command.perform("fuzzy:toggle_case_sensitive"))
    test.ok(wait_until(function()
      return #(picker.results or {}) == 1 and picker.results[1].text == "RenderWidget"
    end))
    picker.input:set_text("#Render Widget")
    picker:refresh(picker.input:get_text())
    test.ok(wait_until(function()
      return #(picker.results or {}) == 1 and picker.results[1].text == "RenderWidget"
    end))
  end)
end)
