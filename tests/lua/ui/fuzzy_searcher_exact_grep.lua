local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

local function result_count_for_path(picker, path)
  local count = 0
  for _, result in ipairs(picker.results or {}) do
    if result.abs_path and common.path_equals(result.abs_path, path) then count = count + 1 end
  end
  return count
end

local function install_controlled_grep(context, filename, lines, pause_after)
  local released = false
  context.original_process_start = process.start
  process.start = function(args, options)
    local is_grep = false
    for _, argument in ipairs(args or {}) do
      if argument == "--vimgrep" or argument == "--line-number" then
        is_grep = true
        break
      end
    end
    if not is_grep then return context.original_process_start(args, options) end

    local next_line = 1
    local running = true
    return {
      stdout = {
        read = function()
          if next_line > pause_after and not released then error("timeout expired") end
          local text = lines[next_line]
          if not text then
            running = false
            return nil
          end
          local result = string.format("%s:%d:1:%s", filename, next_line, text)
          next_line = next_line + 1
          return result
        end,
      },
      running = function() return running end,
      kill = function() running = false end,
      wait = function() return running and nil or 0 end,
    }
  end
  return function() released = true end
end

test.describe("Fuzzy Searcher exact grep", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-exact-grep-" .. system.get_process_id()
    assert(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if context.original_process_start then process.start = context.original_process_start end
    project_paths.configure_workspace {}
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.root and system.get_file_info(context.root) then
      common.rm(context.root, true)
    end
  end)

  test.it("returns one result for each matching line", function(context)
    local path = context.root .. PATHSEP .. "repeated.txt"
    local file = assert(io.open(path, "wb"))
    file:write("ssss\none s\n")
    file:close()

    fuzzy_searcher.open("#s")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return result_count_for_path(picker, path) == 2
    end, 10), "expected both matching lines: " .. tostring(picker.status))
    test.equal(result_count_for_path(picker, path), 2)
  end)

  test.it("returns matches when the scope contains one file", function(context)
    local path = context.root .. PATHSEP .. "single-file.txt"
    local file = assert(io.open(path, "wb"))
    file:write("a paragraph in one file\n")
    file:close()

    fuzzy_searcher.open("single-file.txt #paragraph")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return result_count_for_path(picker, path) == 1
    end, 10), "expected the matching line: " .. tostring(picker.status))
    test.equal(result_count_for_path(picker, path), 1)
  end)

  test.it("describes a completed empty search without a numeric zero", function(context)
    local path = context.root .. PATHSEP .. "no-match.txt"
    local file = assert(io.open(path, "wb"))
    file:write("unrelated text\n")
    file:close()

    fuzzy_searcher.open("#absent-search-term")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return picker.status == "No exact matches"
    end, 10), "expected clear empty-search feedback: " .. tostring(picker.status))
    test.not_ok(picker.status:find("0 matches", 1, true))
  end)

  test.it("keeps published rows stable when an exact search completes", function(context)
    local path = context.root .. PATHSEP .. "stable-results.txt"
    local file = assert(io.open(path, "wb"))
    local lines = {}
    for i = 1, 80 do
      lines[i] = string.format("scratch result %05d with extra text", i)
      file:write(lines[i] .. "\n")
    end
    lines[81] = "scratch"
    file:write(lines[81] .. "\n")
    file:close()
    local finish_search = install_controlled_grep(context, "stable-results.txt", lines, 80)

    fuzzy_searcher.open("#scratch")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return #(picker.results or {}) >= 20
    end, 15), "expected exact results before completion: " .. tostring(picker.status))

    local published = {}
    for i = 1, 5 do published[i] = picker.results[i].line end
    command.perform("fuzzy:next")
    command.perform("fuzzy:next")
    finish_search()

    test.ok(wait_until(function()
      return picker.status == "81 exact matches"
    end, 20), "expected exact grep to finish: " .. tostring(picker.status))
    test.same(published, {
      picker.results[1].line,
      picker.results[2].line,
      picker.results[3].line,
      picker.results[4].line,
      picker.results[5].line,
    })
    test.equal(picker.selected, 3)
  end)

  test.it("keeps published rows stable when a fuzzy text search completes", function(context)
    local path = context.root .. PATHSEP .. "stable-fuzzy-results.txt"
    local file = assert(io.open(path, "wb"))
    local lines = {}
    for i = 1, 80 do
      lines[i] = string.format("alpha result %03d with many extra words before beta", i)
      file:write(lines[i] .. "\n")
    end
    lines[81] = "alpha beta"
    file:write(lines[81] .. "\n")
    file:close()
    local finish_search = install_controlled_grep(context, "stable-fuzzy-results.txt", lines, 80)

    fuzzy_searcher.open("#alpha beta")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function()
      return #(picker.results or {}) >= 5
    end, 30), "expected fuzzy results before completion: " .. tostring(picker.status))

    local published = {}
    for i = 1, 5 do published[i] = picker.results[i].line end
    command.perform("fuzzy:next")
    command.perform("fuzzy:next")
    finish_search()

    test.ok(wait_until(function()
      return picker.status == "81 fuzzy matches"
    end, 20), "expected fuzzy text search to finish: " .. tostring(picker.status))
    test.same(published, {
      picker.results[1].line,
      picker.results[2].line,
      picker.results[3].line,
      picker.results[4].line,
      picker.results[5].line,
    })
    test.equal(picker.selected, 3)
  end)

  test.it("keeps the UI scheduler responsive during a broad search", function(context)
    local path = context.root .. PATHSEP .. "many-lines.txt"
    local file = assert(io.open(path, "wb"))
    local line = "sample search line\n"
    for _ = 1, 20000 do file:write(line) end
    file:close()

    fuzzy_searcher.open("#s")
    local started = system.get_time()
    local heartbeat
    core.add_thread(function()
      coroutine.yield(0.05)
      heartbeat = system.get_time()
    end)

    test.ok(wait_until(function() return heartbeat ~= nil end, 2),
      "expected another UI task to run during exact grep")
    test.ok(heartbeat - started < 0.3, string.format(
      "exact grep blocked the UI scheduler for %.3f seconds", heartbeat - started
    ))
  end)
end)
