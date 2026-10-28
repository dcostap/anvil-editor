local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local helpers = fuzzy_searcher._test

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 10)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

local function file_rows(picker)
  local count = 0
  for _, result in ipairs(picker.results or {}) do
    if result.kind == "file" then count = count + 1 end
  end
  return count
end

local function index_of_path(picker, path)
  for index, result in ipairs(picker.results or {}) do
    if result.abs_path and common.path_equals(result.abs_path, path) then return index end
  end
end

test.describe("Fuzzy Searcher scrolling and selection", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.visited_files = core.visited_files
    context.cwd = system.getcwd()
    context.everything_state = helpers.everything_state()
    helpers.set_everything_state("unavailable")
    context.root = USERDIR .. PATHSEP .. "fuzzy-scrolling-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.files = {}
    for index = 1, 60 do
      local path = string.format("%s%sitem-%02d.txt", context.root, PATHSEP, index)
      write_file(path)
      context.files[index] = path
    end
    core.projects = { Project(context.root) }
    core.visited_files = {}
    system.chdir(context.root)
    project_paths.configure_workspace {}
    test.ok(helpers.prewarm_file_index_for_test())
    test.ok(wait_until(function()
      local status = helpers.file_index_status()
      return status.native and not status.indexing
    end), "the Project file index did not become ready")
  end)

  test.after_each(function(context)
    helpers.cancel_file_index_for_test()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    helpers.set_everything_state(context.everything_state)
    project_paths.configure_workspace {}
    core.projects = context.projects
    core.visited_files = context.visited_files
    system.chdir(context.cwd)
    test.ok(test.remove_tree(context.root))
  end)

  local function open_files(query)
    fuzzy_searcher.open(query or "item")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:set_size(1400, 600)
    test.ok(wait_until(function() return file_rows(picker) > 0 end), "no file appeared: " .. tostring(picker.status))
    return picker
  end

  test.it("lists every File Search match at once", function()
    local picker = open_files()
    test.ok(wait_until(function() return file_rows(picker) == 60 end),
      "expected all 60 files, got " .. file_rows(picker))
    test.not_ok(picker:can_load_more(), "File Search still loads more rows")
  end)

  test.it("keeps the selected file selected when File Search results refresh", function(context)
    local picker = open_files()
    test.ok(wait_until(function() return index_of_path(picker, context.files[5]) end))
    picker.selected = index_of_path(picker, context.files[5])
    -- A recent file goes to the top, so every other row moves down.
    core.visited_files = { { path = context.files[40], last_viewed = 100 } }
    picker.force_refresh, picker.dirty = true, true
    picker:refresh(picker.input:get_text())
    test.ok(wait_until(function()
      for _, result in ipairs(picker.results) do
        if result.recent then return true end
      end
    end), "the recent file did not move to the top")
    test.ok(common.path_equals(picker.results[picker.selected].abs_path, context.files[5]),
      "the selection moved to another file")
  end)

  test.it("loads the next page before the selection reaches the end", function()
    fuzzy_searcher.open(">e")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:set_size(1400, 600)
    test.ok(wait_until(function() return #picker.results > 0 end))
    test.ok(picker:can_load_more(), "the Command list needs more than one page for this test")
    local loaded = #picker.results
    local rows = picker:list_metrics().result_rows
    picker.selected = loaded - rows + 1
    picker:select_delta(1)
    test.ok(wait_until(function() return #picker.results > loaded end), "the next page did not load")
    test.ok(picker.selected < loaded, "the selection reached the end before the next page")
  end)

  test.it("moves the selection one screen with the page commands", function()
    local picker = open_files()
    test.ok(wait_until(function() return file_rows(picker) == 60 end))
    local rows = picker:list_metrics().result_rows
    local start = picker.selected
    test.ok(command.perform("fuzzy:page_next"))
    test.ok(picker.selected >= start + rows - 1, "the selection moved less than one screen")
    test.ok(picker.selected >= picker.viewport_offset and picker.selected < picker.viewport_offset + rows,
      "the selected row is not on the screen")
    test.ok(command.perform("fuzzy:page_previous"))
    test.equal(picker.selected, start)
    test.ok(command.perform("fuzzy:last"))
    test.equal(picker.selected, #picker.results)
    test.ok(command.perform("fuzzy:first"))
    test.equal(picker.selected, start)
  end)

  test.it("selects the same row at the same place when the picker opens again with the same query", function()
    fuzzy_searcher.open("#test")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:set_size(1400, 600)
    test.ok(wait_until(function() return #picker.results >= 60 end), "expected a line from each file")
    -- A row on the second screen.
    for _ = 1, picker:list_metrics().result_rows + 5 do picker:select_delta(1) end
    local saved = picker:selected_result()
    local screen_row = picker.selected - picker.viewport_offset
    test.ok(screen_row > 0, "the selected row is at the top of the screen")
    picker:close()
    test.ok(wait_until(function() return core.fuzzy_searcher_active_view ~= picker end))

    fuzzy_searcher.open("#")
    local reopened = test.not_nil(core.fuzzy_searcher_active_view)
    reopened:set_size(1400, 600)
    test.equal(reopened.input:get_text(), "#test")
    test.ok(wait_until(function()
      local result = reopened:selected_result()
      return result and common.path_equals(result.abs_path, saved.abs_path) and result.line == saved.line
    end), "the picker did not select the same row again")
    test.equal(reopened.selected - reopened.viewport_offset, screen_row)
  end)
end)
