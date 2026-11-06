local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"

local function wait_until(predicate)
  local deadline = system.get_time() + 30
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
    test.ok(test.remove_tree(context.root))
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

  test.it("finds accented file text and selects its original bytes", function(context)
    local file = assert(io.open(context.root .. PATHSEP .. "search.txt", "wb"))
    file:write("un café\nun cafe\nun cafe\204\129\n")
    file:close()
    fuzzy_searcher.open("#cafe")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "3 exact matches" end),
      "expected three accent-equivalent lines: " .. tostring(picker.status))
    local ranges = {}
    for _, result in ipairs(picker.results) do ranges[result.line] = result.content_selection_span end
    test.same(ranges, { {4, 8}, {4, 7}, {4, 9} })
    for _, query in ipairs { "#café", '#"cafe"', "search.txt #café", "#café sort:name" } do
      picker.input:set_text(query)
      picker:refresh(query)
      test.ok(wait_until(function()
        return not picker:search_running() and #picker.results == 3
      end), query .. ": " .. tostring(picker.status))
      for _, result in ipairs(picker.results) do
        test.same(result.content_selection_span, ranges[result.line])
      end
    end
    picker.input:set_text('#" cafe "')
    picker:refresh('#" cafe "')
    test.ok(wait_until(function() return picker.status == "No exact matches" end),
      "quoted spaces must stay part of the query")
  end)

  test.it("keeps enye distinct in file scans and quoted multi-term searches", function(context)
    local file = assert(io.open(context.root .. PATHSEP .. "search.txt", "wb"))
    file:write("niño café\nnin\204\131o cafe\nnino cafe\nNIÑO CAFÉ\n")
    file:close()
    fuzzy_searcher.open("#nino")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 exact matches" end), tostring(picker.status))
    test.equal(picker.results[1].line, 3)
    for _, query in ipairs { "#niño", '#niño "cafe"', '#"niño cafe"', "#nin\204\131o cafe" } do
      picker.input:set_text(query)
      picker:refresh(query)
      test.ok(wait_until(function()
        return not picker:search_running() and #picker.results == 3
      end), query .. ": " .. tostring(picker.status))
      local lines = {}
      for _, result in ipairs(picker.results) do lines[#lines + 1] = result.line end
      table.sort(lines)
      test.same(lines, {1, 2, 4})
    end
    test.ok(command.perform("fuzzy:toggle_case_sensitive"))
    test.ok(wait_until(function() return not picker:search_running() and #picker.results == 2 end))
  end)

  test.it("does not interpret search text as a regular expression", function(context)
    local file = assert(io.open(context.root .. PATHSEP .. "search.txt", "wb"))
    file:write("café.*[x](y)\\z+?\ncafe anything\n")
    file:close()
    fuzzy_searcher.open("#cafe.*[x](y)\\z+?")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 exact matches" end), tostring(picker.status))
    test.equal(picker.results[1].line, 1)
  end)

  test.it("checks the whole pasted query after the bounded file filter", function(context)
    local file = assert(io.open(context.root .. PATHSEP .. "search.txt", "wb"))
    file:write(string.rep("á", 600), "end\n", string.rep("á", 600), "other\n")
    file:close()
    fuzzy_searcher.open("#" .. string.rep("a", 600) .. "end")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 exact matches" end), tostring(picker.status))
    test.equal(picker.results[1].line, 1)
    test.same(picker.results[1].content_selection_span, {1, 1203})
  end)
end)
