local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"

local function wait_until(predicate)
  local deadline = system.get_time() + 3
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.03) end
  return predicate()
end

test.describe("Case-sensitive file search", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.cwd = system.getcwd()
    context.visited_files = core.visited_files
    core.visited_files = {}
    context.root = USERDIR .. PATHSEP .. "fuzzy-case-files-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    for _, dir in ipairs { "Upper", "lower" } do
      test.ok(common.mkdirp(context.root .. PATHSEP .. dir))
      local name = dir == "Upper" and "RenderWidget.lua" or "renderWidget.lua"
      local file = assert(io.open(context.root .. PATHSEP .. dir .. PATHSEP .. name, "wb"))
      file:write("-- fixture\n")
      file:close()
    end
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_workspace {}
    core.projects = context.projects
    core.visited_files = context.visited_files
    system.chdir(context.cwd)
    common.rm(context.root, true)
  end)

  test.it("keeps fuzzy file matches with the requested letter case", function()
    local function files(picker)
      local out = {}
      for _, row in ipairs(picker.results or {}) do
        if row.kind == "file" then out[#out + 1] = row end
      end
      return out
    end
    fuzzy_searcher.open("RW")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return #files(picker) == 2 end),
      "status=" .. tostring(picker.status) .. " input=" .. tostring(picker.input:get_text())
      .. " files=" .. tostring(#files(picker)))
    test.ok(command.perform("fuzzy:toggle_case_sensitive"))
    test.ok(wait_until(function()
      local results = files(picker)
      return #results == 1 and tostring(results[1].file):find("RenderWidget.lua", 1, true) ~= nil
    end), "status=" .. tostring(picker.status) .. " files=" .. tostring(#files(picker)))
  end)
end)
