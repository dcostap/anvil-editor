local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local http = require "core.http"
local fuzzy = require "plugins.fuzzy_searcher"

local function write_file(root, name, text)
  local path = root .. PATHSEP .. name
  if not system.get_file_info(common.dirname(path)) then assert(common.mkdirp(common.dirname(path))) end
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
  return path
end

local function wait_until(predicate)
  local deadline = system.get_time() + 10
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.01) end
  return predicate()
end

test.describe("Fuzzy Searcher query modifiers", function()
  test.before_each(function(context)
    context.projects, context.cwd, context.recents = core.projects, system.getcwd(), core.visited_files
    context.root = USERDIR .. PATHSEP .. "query-modifiers-" .. math.floor(system.get_time() * 1000000)
    assert(common.mkdirp(context.root))
    core.projects, core.visited_files = { Project(context.root) }, {}
    system.chdir(context.root)
    project_paths.configure_workspace {}
    context.http_get, context.everything = http.get, fuzzy._test.everything_state()
    context.file_info = system.get_file_info
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    fuzzy._test.cancel_file_index_for_test()
    http.get, system.get_file_info = context.http_get, context.file_info
    fuzzy._test.set_everything_state(context.everything)
    project_paths.configure_workspace {}
    core.projects, core.visited_files = context.projects, context.recents
    system.chdir(context.cwd)
    common.rm(context.root, true)
  end)

  test.it("filters and sorts all matching files before limiting results", function(context)
    fuzzy.open("")
    local limit = core.fuzzy_searcher_active_view:result_limit()
    core.fuzzy_searcher_active_view:close()
    for i = 1, limit + 3 do
      write_file(context.root, string.format("file-%03d.txt", i), "small\n")
    end
    write_file(context.root, "file-z-largest.txt", string.rep("x", 2048))
    fuzzy.open("file sort:size size:>=1k")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return #picker.results == 1 and picker.results[1].file == "file-z-largest.txt"
    end), "expected the largest file beyond the normal result limit: " .. tostring(picker.status))
    test.equal(picker.results[1].file_size, 2048)
    test.equal(picker.input:get_text(), "file sort:size size:>=1k")
    picker.input:set_text("file sort:size")
    test.ok(wait_until(function()
      return #picker.results > 1 and picker.results[1].file == "file-z-largest.txt"
    end), "expected sorting before the result limit")
    test.ok(picker.has_more)
  end)

  test.it("filters Text Search by file size and orders file groups by name", function(context)
    write_file(context.root, "z-small.txt", "alpha beta\n")
    write_file(context.root, "b-large.txt", "alpha beta\n" .. string.rep("x", 1024))
    write_file(context.root, "a-large.txt", "alpha beta\nother alpha beta\n" .. string.rep("x", 1024))
    fuzzy.open('size:>=1k #alpha beta sort:name')
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "3 matches" end), tostring(picker.status))
    test.same({ picker.results[1].file, picker.results[2].file, picker.results[3].file },
      { "a-large.txt", "a-large.txt", "b-large.txt" })
    test.equal(picker.results[2].line, 2)
    test.equal(picker.results[2].text, "other alpha beta")
    test.ok(#picker.results[2].content_spans > 0)
  end)

  test.it("sorts Path Search through Everything before retrieving a limited page", function()
    local request
    http.get = function(_, params, options)
      request = params
      options.on_done(true, nil, { totalResults = 1, results = {
        { type = "file", path = "C:\\elsewhere", name = "large.txt", size = "2048", date_modified = "133000000000000000" },
      } })
    end
    fuzzy._test.set_everything_state("available")
    fuzzy.open("@large size:>=1k sort:size")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return #picker.results == 1 end), tostring(picker.status))
    test.equal(picker.results[1].file_size, 2048)
    test.equal(picker.results[1].file, "C:\\elsewhere\\large.txt")
    test.equal(request.sort, "size")
    test.equal(request.ascending, "0")
    test.ok(request.search:find("size:>=1024", 1, true))
    test.not_ok(request.search:find("sort:", 1, true))
  end)

  test.it("uses modification time for date sorting", function(context)
    local older = write_file(context.root, "a-older.txt", "older\n")
    local newer = write_file(context.root, "z-newer.txt", "newer\n")
    system.get_file_info = function(path)
      local info = context.file_info(path)
      if info and common.path_equals(path, older) then info.modified = 1000 end
      if info and common.path_equals(path, newer) then info.modified = 2000 end
      return info
    end
    fuzzy.open(".txt sort:date")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "2 matches" end), tostring(picker.status))
    test.same({ picker.results[1].file, picker.results[2].file }, { "z-newer.txt", "a-older.txt" })
  end)

  test.it("refreshes cached sizes after a file changes", function(context)
    write_file(context.root, "a-growing.txt", string.rep("a", 1024))
    write_file(context.root, "b-fixed.txt", string.rep("b", 2048))
    fuzzy.open("size:>=1k sort:size")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return #picker.results == 2 and picker.results[1].file == "b-fixed.txt"
    end))
    write_file(context.root, "a-growing.txt", string.rep("a", 4096))
    test.ok(wait_until(function()
      return #picker.results == 2 and picker.results[1].file == "a-growing.txt"
    end), "expected file changes to refresh the size order")
  end)

  test.it("preserves the sorted page order returned by Everything", function()
    http.get = function(_, _, options)
      options.on_done(true, nil, { totalResults = 2, results = {
        { type = "file", path = "C:\\other", name = "report2.txt", size = "1" },
        { type = "file", path = "C:\\other", name = "report10.txt", size = "1" },
      } })
    end
    fuzzy._test.set_everything_state("available")
    fuzzy.open("@report sort:name")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "2 matches" end))
    test.same({ picker.results[1].file, picker.results[2].file },
      { "C:\\other\\report2.txt", "C:\\other\\report10.txt" })
  end)

  test.it("keeps quoted modifier text literal and preserves modifiers when filling the prompt", function(context)
    write_file(context.root, "literal.txt", "look for size:20m here\n")
    fuzzy.open('sort:name #"size:20m" size:<1k')
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 match" end), tostring(picker.status))
    test.equal(picker.results[1].text, "look for size:20m here")
    picker.input:set_text("literal size:<1k sort:name")
    test.ok(wait_until(function() return #picker.results == 1 and picker.results[1].kind == "file" end))
    test.ok(picker:fill_prompt_from_selected())
    local text = picker.input:get_text()
    test.ok(text:find("size:<1k", 1, true))
    test.ok(text:find("sort:name", 1, true))
    test.ok(text:find("literal.txt", 1, true))
  end)

  test.it("clears results for invalid modifiers instead of ignoring them", function(context)
    write_file(context.root, "file.txt", "contents\n")
    fuzzy.open("sort:name")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 match" end))
    picker.input:set_text("sort:unknown")
    test.equal(#picker.results, 0)
    test.equal(picker.status, "Sort must be name, size, or date")
    picker.input:set_text("size:")
    test.equal(#picker.results, 0)
    test.equal(picker.status, "Enter a value for size:")
  end)

  test.it("filters direct folder contents when Everything is unavailable", function(context)
    write_file(context.root, "small.txt", "small\n")
    local large = write_file(context.root, "large.txt", string.rep("x", 2048))
    fuzzy._test.set_everything_state("unavailable")
    fuzzy.open("@" .. context.root .. PATHSEP .. " size:>=1k sort:size")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return #picker.results == 1 end), tostring(picker.status))
    test.ok(common.path_equals(picker.results[1].file, large))
  end)

  test.it("ignores results from a cancelled Path Search", function()
    local requests = {}
    http.get = function(_, params, options) requests[params.search] = options end
    fuzzy._test.set_everything_state("available")
    fuzzy.open("@first sort:name")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return requests.first end))
    picker.input:set_text("@second sort:name")
    test.ok(wait_until(function() return requests.second end))
    test.ok(requests.first.is_cancelled())
    requests.second.on_done(true, nil, { totalResults = 1, results = {
      { type = "file", path = "C:\\other", name = "second.txt", size = "1" },
    } })
    test.ok(wait_until(function() return #picker.results == 1 end))
    requests.first.on_done(true, nil, { totalResults = 1, results = {
      { type = "file", path = "C:\\other", name = "first.txt", size = "1" },
    } })
    coroutine.yield(0.05)
    test.equal(picker.results[1].file, "C:\\other\\second.txt")
  end)

  test.it("keeps input text and selection intact while drawing modifiers", function()
    local text = "sort:name #needle size:<1k"
    fuzzy.open(text)
    local input = core.fuzzy_searcher_active_view.input.textview
    input:with_selection_state(function() input.buffer:set_selection(1, 1, 1, 10) end)
    renderer.begin_frame(core.window)
    local ok, err = xpcall(function() input:draw_line_text(1, 0, 0) end, debug.traceback)
    renderer.end_frame()
    test.ok(ok, err)
    test.equal(input:get_text(), text)
    test.same(input:get_selection_state().selections, { 1, 1, 1, 10 })
  end)
end)
