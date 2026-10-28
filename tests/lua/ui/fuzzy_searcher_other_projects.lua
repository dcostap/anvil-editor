local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local pane_requests = require "core.pane_requests"
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

local function index_of(results, predicate)
  for index, result in ipairs(results or {}) do
    if predicate(result) then return index, result end
  end
end

local function file_index(results, path)
  return index_of(results, function(result)
    return not result.header and result.abs_path and common.path_equals(result.abs_path, path)
  end)
end

local function serialize(request)
  return common.serialize(request, { escape = true })
end

-- The requests that this Project sent to the shell, as {route, path, request}.
local function sent(context, action)
  local out = {}
  for _, item in ipairs(context.sent) do
    if item.request.action == action then out[#out + 1] = item end
  end
  return out
end

test.describe("Project File Search in other Projects", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.sidebar = core.project_sidebar
    context.visited_files = core.visited_files
    context.cwd = system.getcwd()
    context.everything_state = helpers.everything_state()
    helpers.set_everything_state("unavailable")
    context.root = USERDIR .. PATHSEP .. "fuzzy-other-projects-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    context.own = context.root .. PATHSEP .. "own"
    context.other = context.root .. PATHSEP .. "other"
    context.dormant = context.root .. PATHSEP .. "dormant"
    for _, path in ipairs { context.own, context.other, context.dormant } do test.ok(common.mkdirp(path)) end
    context.local_file = context.own .. PATHSEP .. "alpha-local.txt"
    write_file(context.local_file, "one\ntwo\nthree\n")
    core.projects = { Project(context.own) }
    core.visited_files = {}
    system.chdir(context.own)
    project_paths.configure_workspace {}
    core.project_sidebar = {
      { path = context.own, state = "ready", panes = {} },
      { path = context.other, state = "ready", panes = {} },
      { path = context.dormant, state = "dormant", exists = true },
    }

    -- The shell is the boundary: record each request that would go to it.
    context.sent = {}
    context.pane_request = system.pane_request
    context.is_hosted_surface = system.is_hosted_surface
    system.is_hosted_surface = function() return true end
    system.pane_request = function(route, path, text)
      context.sent[#context.sent + 1] = { route = route, path = path, request = assert(load("return " .. text))() }
      return true
    end

    test.ok(helpers.prewarm_file_index_for_test())
    test.ok(wait_until(function()
      local status = helpers.file_index_status()
      return status.native and not status.indexing
    end), "the Project file index did not become ready")
  end)

  test.after_each(function(context)
    helpers.cancel_file_index_for_test()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    system.pane_request = context.pane_request
    system.is_hosted_surface = context.is_hosted_surface
    helpers.set_everything_state(context.everything_state)
    core.project_sidebar = context.sidebar
    project_paths.configure_workspace {}
    core.projects = context.projects
    core.visited_files = context.visited_files
    system.chdir(context.cwd)
    test.ok(test.remove_tree(context.root))
  end)

  local function open_with_other_rows(context)
    fuzzy_searcher.open("alpha")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return file_index(picker.results, context.local_file) end),
      "this Project's file did not appear: " .. tostring(picker.status))
    local searches = sent(context, "project_search")
    test.equal(#searches, 1, "expected one request, to the other loaded Project")
    test.ok(common.path_equals(searches[1].path, context.other))
    local other_file = context.other .. PATHSEP .. "alpha-other.txt"
    test.ok(pane_requests.perform(serialize {
      action = "project_results", source = context.other, id = searches[1].request.id,
      rows = { { label = "alpha-other.txt", abs_path = other_file, spans = { { 1, 5 } } } },
    }))
    return picker, other_file, searches[1].request
  end

  test.it("lists another Project's files below this Project's files, under that Project", function(context)
    local picker, other_file = open_with_other_rows(context)
    local own_index = file_index(picker.results, context.local_file)
    local header_index, header = index_of(picker.results, function(result) return result.project ~= nil end)
    local other_index = file_index(picker.results, other_file)
    test.not_nil(header, "no header for the other Project")
    test.ok(common.path_equals(header.project.path, context.other))
    test.ok(own_index < header_index and header_index < other_index,
      "expected this Project's file, then the other Project's header, then its file")

    -- Headless tests have no window, so drawing goes to stubbed primitives.
    local renderer, saved, texts = require "renderer", {}, {}
    for name, fn in pairs(renderer) do
      if type(fn) == "function" and (name:match("^draw_") or name:match("^push_") or name:match("^pop_")
        or name == "set_clip_rect") then
        saved[name] = fn
        renderer[name] = function() end
      end
    end
    renderer.draw_text = function(font, text, x)
      texts[text] = true
      return x + font:get_width(text)
    end
    picker.position.x, picker.position.y = 0, 0
    picker:set_size(1400, 600)
    picker.open_transition_complete = true
    picker:update()
    local drawn, err = pcall(function() picker:draw() end)
    for name, fn in pairs(saved) do renderer[name] = fn end
    test.ok(drawn, err)
    test.ok(texts.other, "the header did not show the other Project's name")
  end)

  test.it("does not show rows that answer an earlier query", function(context)
    local picker, other_file, earlier = open_with_other_rows(context)
    picker.input:set_text("alph")
    test.ok(wait_until(function() return #sent(context, "project_search") == 2 end), "the new query was not sent")
    test.ok(wait_until(function() return not file_index(picker.results, other_file) end),
      "the earlier rows stayed after the query changed")
    test.ok(pane_requests.perform(serialize {
      action = "project_results", source = context.other, id = earlier.id,
      rows = { { label = "alpha-other.txt", abs_path = other_file } },
    }))
    test.is_nil(file_index(picker.results, other_file), "a reply to the earlier query was shown")
  end)

  test.it("opens another Project's file in that Project", function(context)
    local picker, other_file = open_with_other_rows(context)
    picker.selected = file_index(picker.results, other_file)
    picker:confirm(false)
    local opens = sent(context, "open_file")
    test.equal(#opens, 1)
    test.equal(opens[1].route, "select")
    test.ok(common.path_equals(opens[1].path, context.other))
    test.ok(common.path_equals(opens[1].request.file, other_file))
  end)

  test.it("answers another Project's File Search with its best files", function(context)
    test.ok(pane_requests.perform(serialize {
      action = "project_search", from = context.other, id = 7, mode = "files", query = "alpha",
      case_sensitive = false, limit = 5,
    }))
    test.ok(wait_until(function() return #sent(context, "project_results") > 0 end), "no answer was sent")
    local answer = sent(context, "project_results")[1]
    test.ok(common.path_equals(answer.path, context.other))
    test.equal(answer.request.id, 7)
    test.ok(common.path_equals(answer.request.source, context.own))
    test.ok(common.path_equals(answer.request.rows[1].abs_path, context.local_file))
  end)

  test.it("opens a file that another Project chose at its line", function(context)
    test.ok(pane_requests.perform(serialize { action = "open_file", file = context.local_file, line = 2, col = 1 }))
    local view = core.active_view
    test.ok(view.buffer and common.path_equals(view.buffer.abs_filename, context.local_file))
    test.equal(select(1, view.buffer:get_selection()), 2)
  end)

  local function open_text_search_with_other_rows(context, query)
    query = query or "three"
    fuzzy_searcher.open("#" .. query)
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    -- The answer can arrive before this Project's own lines.
    test.ok(wait_until(function() return #sent(context, "project_search") > 0 end), "no request was sent")
    local searches = sent(context, "project_search")
    test.equal(#searches, 1, "expected one request, to the other loaded Project")
    test.equal(searches[1].request.mode, "text")
    test.equal(searches[1].request.query, query)
    local other_file = context.other .. PATHSEP .. "notes.txt"
    test.ok(pane_requests.perform(serialize {
      action = "project_results", source = context.other, id = searches[1].request.id,
      rows = {
        { label = "notes.txt", abs_path = other_file, line = 4, col = 3, text = "  three", spans = { { 3, 7 } } },
        { label = "PowerShell", line = 2, col = 1, text = "three", spans = { { 1, 5 } },
          terminal = { id = "other-session", query = "three", item = { name = "pwsh", terminal = { session = "other-session" } },
            context = { first = 1, text = "echo three\nthree" } } },
      },
    }))
    test.ok(wait_until(function()
      return file_index(picker.results, context.local_file) and file_index(picker.results, other_file)
    end), "a line did not appear: " .. tostring(picker.status))
    return picker, other_file
  end

  test.it("lists another Project's text matches below this Project's matches, under that Project", function(context)
    local picker, other_file = open_text_search_with_other_rows(context)
    local own_index = file_index(picker.results, context.local_file)
    local header_index = index_of(picker.results, function(result) return result.project ~= nil end)
    local other_index, other_row = file_index(picker.results, other_file)
    local terminal_index = index_of(picker.results, function(result) return result.terminal ~= nil end)
    test.ok(own_index and header_index and other_index and terminal_index, "a row is missing")
    test.ok(own_index < header_index and header_index < other_index and header_index < terminal_index,
      "expected this Project's line, then the other Project's header, then its lines")
    test.equal(other_row.line, 4)
    test.equal(other_row.text, "  three")
  end)

  test.it("lists another Project's matches for a query of several words", function(context)
    local picker, other_file = open_text_search_with_other_rows(context, "thr ee")
    local own_index = file_index(picker.results, context.local_file)
    local other_index = file_index(picker.results, other_file)
    test.ok(own_index and other_index and own_index < other_index,
      "expected this Project's line, then the other Project's line")
  end)

  test.it("does not report no matches when only another Project has matches", function(context)
    fuzzy_searcher.open("#nowhere")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return (picker.status or ""):match("^No ") end),
      "this Project's search did not end: " .. tostring(picker.status))
    local search = sent(context, "project_search")[1]
    test.ok(pane_requests.perform(serialize {
      action = "project_results", source = context.other, id = search.request.id,
      rows = { { label = "notes.txt", abs_path = context.other .. PATHSEP .. "notes.txt", line = 1, col = 1,
        text = "nowhere", spans = { { 1, 7 } }, exact = true } },
    }))
    test.equal(picker:status_layout(require("core.style").font, 1000).status, "")
  end)

  test.it("shows another Project's Terminal match in that Project", function(context)
    local picker = open_text_search_with_other_rows(context)
    picker.selected = index_of(picker.results, function(result) return result.terminal ~= nil end)
    picker:confirm(false)
    local finds = sent(context, "terminal_find")
    test.equal(#finds, 1)
    test.equal(finds[1].route, "select")
    test.ok(common.path_equals(finds[1].path, context.other))
    test.equal(finds[1].request.session, "other-session")
    test.equal(finds[1].request.row, 1)
  end)

  test.it("answers another Project's Text Search with its matching lines", function(context)
    test.ok(pane_requests.perform(serialize {
      action = "project_search", from = context.other, id = 8, mode = "text", query = "two",
      case_sensitive = false, limit = 5,
    }))
    test.ok(wait_until(function() return #sent(context, "project_results") > 0 end), "no answer was sent")
    local answer = sent(context, "project_results")[1]
    test.equal(answer.request.id, 8)
    local row = answer.request.rows[1]
    test.ok(common.path_equals(row.abs_path, context.local_file))
    test.equal(row.line, 2)
    test.equal(row.text, "two")
  end)
end)
