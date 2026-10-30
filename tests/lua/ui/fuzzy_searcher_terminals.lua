local ready = dofile("tests/fixtures/terminal_ready.lua")
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local terminal = require "plugins.terminal"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function wait_for(view, predicate, seconds)
  -- Shells start slowly on a loaded machine. The wait ends as soon as the predicate holds.
  local deadline = system.get_time() + (seconds or 30)
  repeat
    if view and view.session then view:service_session(true) end
    if predicate() then return true end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  return false
end

local function record(id)
  local text = assert(require("terminal_native").read_session_record(id))
  return assert(load(text, "session record", "t", {}))()
end

local function screen_text(view)
  local capture = view.session and view.session:text_capture()
  return capture and capture.text or ""
end

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function shell(marker)
  terminal._set_native_for_tests(nil)
  local view = ready(terminal.open { cwd = system.getcwd(), shell = "cmd.exe /D /Q" })
  test.ok(view.session:write("echo " .. marker .. "\r"))
  test.ok(wait_for(view, function()
    local _, count = screen_text(view):gsub(marker, "")
    return count >= 2
  end), "the shell did not print the marker")
  return view
end

local function terminal_results(picker)
  local out = {}
  for _, result in ipairs(picker.results or {}) do
    if result.terminal then out[#out + 1] = result end
  end
  return out
end

local function output_result(picker, marker)
  for _, result in ipairs(terminal_results(picker)) do
    if result.text == marker then return result end
  end
end

-- Headless tests have no window, so drawing goes to stubbed primitives. `texts` collects each drawn text.
local function draw_without_window(draw, texts)
  local renderer = require "renderer"
  local saved = {}
  for name, fn in pairs(renderer) do
    if type(fn) == "function" and (name:match("^draw_") or name:match("^push_")
      or name:match("^pop_") or name == "set_clip_rect") then
      saved[name] = fn
      renderer[name] = function() end
    end
  end
  renderer.draw_text = function(font, text, x)
    texts[#texts + 1] = text
    return x + font:get_width(text)
  end
  local ok, err = pcall(draw)
  for name, fn in pairs(saved) do renderer[name] = fn end
  return ok, err
end

local function select_result(picker, result)
  for index, candidate in ipairs(picker.results) do
    if candidate == result then picker.selected = index end
  end
end

test.describe("Text Search in Terminals", function()
  test.before_each(function(context)
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    context.projects = core.projects
    context.sidebar = core.project_sidebar
    context.cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-terminals-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    for _, view in ipairs(terminal.open_views()) do view:on_close() end
    core.project_sidebar = context.sidebar
    project_paths.configure_workspace {}
    core.projects = context.projects
    system.chdir(context.cwd)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("lists matching Terminal lines after a file line with the same score", function(context)
    local marker = "ANVIL_TERMINAL_SEARCH_LIVE"
    write_file(context.root .. PATHSEP .. "notes.txt", marker .. "\n")
    shell(marker)

    fuzzy_searcher.open("#" .. marker)
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_for(nil, function() return output_result(picker, marker) end, 10),
      "no Terminal result: " .. tostring(picker.status))
    test.equal(picker.results[1].text, marker)
    test.not_ok(picker.results[1].terminal, "a Terminal line went before the file line")
    test.equal(#terminal_results(picker), 2, "expected the command line and the output line")
  end)

  test.it("searches the saved screen of a Terminal that this Project does not show", function()
    local marker = "ANVIL_TERMINAL_SEARCH_SAVED"
    local view = shell(marker)
    local state = view:get_state()
    local path = record(state.session_id).snapshot_path
    test.ok(wait_for(view, function() return record(state.session_id).attached end))
    os.remove(path)
    view:detach_session()
    test.ok(wait_for(nil, function() return system.get_file_info(path) end), "the host did not save its screen")
    core.project_sidebar = {
      { path = core.root_project().path, state = "loaded", panes = {},
        terminals = { { id = state.session_id, state = "running", title = "Saved shell" } } },
    }

    local restored
    local ok, err = pcall(function()
      fuzzy_searcher.open("#" .. marker)
      local picker = test.not_nil(core.fuzzy_searcher_active_view)
      test.ok(wait_for(nil, function() return output_result(picker, marker) end, 10),
        "no saved Terminal result: " .. tostring(picker.status))
      test.equal(output_result(picker, marker).file, "Saved shell")
    end)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    restored = ready(terminal.from_state(state))
    restored:on_close()
    test.ok(ok, err)
  end)

  test.it("does not search the Terminals of another Project", function(context)
    local marker = "ANVIL_TERMINAL_SEARCH_OTHER"
    -- The other Project starts the shell, so its saved screen belongs to that Project.
    local root, other = core.projects[1], context.root .. PATHSEP .. "other"
    test.ok(common.mkdirp(other))
    core.projects = { Project(other) }
    system.chdir(other)
    local view = shell(marker)
    local state = view:get_state()
    local path = record(state.session_id).snapshot_path
    test.ok(wait_for(view, function() return record(state.session_id).attached end))
    os.remove(path)
    view:detach_session()
    test.ok(wait_for(nil, function() return system.get_file_info(path) end), "the host did not save its screen")
    core.projects = { root }
    system.chdir(context.root)
    core.project_sidebar = {
      { path = root.path, state = "loaded", panes = {}, terminals = {} },
      { path = other, state = "loaded", panes = {},
        terminals = { { id = state.session_id, state = "running", title = "Other shell" } } },
    }
    write_file(context.root .. PATHSEP .. "notes.txt", marker .. "\n")

    local ok, err = pcall(function()
      fuzzy_searcher.open("#" .. marker)
      local picker = test.not_nil(core.fuzzy_searcher_active_view)
      test.ok(wait_for(nil, function() return picker.results and picker.results[1] end, 10),
        "no file result: " .. tostring(picker.status))
      test.ok(wait_for(nil, function()
        return picker.status:find("exact matches", 1, true)
          and not picker.status:find("scanning", 1, true)
          and not picker.status:find("Searching", 1, true)
      end, 10), "the complete exact search did not finish: " .. tostring(picker.status))
      test.equal(#terminal_results(picker), 0, "Text Search listed a Terminal of another Project")
    end)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    ready(terminal.from_state(state)):on_close()
    test.ok(ok, err)
  end)

  test.it("opens a Terminal result at its line with the Terminal's find card", function()
    local marker = "ANVIL_TERMINAL_SEARCH_OPEN"
    local view = shell(marker)

    fuzzy_searcher.open("#" .. marker)
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_for(nil, function() return output_result(picker, marker) end, 10),
      "no Terminal result: " .. tostring(picker.status))
    local result = output_result(picker, marker)
    select_result(picker, result)
    command.perform("fuzzy:confirm")

    test.equal(core.active_view, view.find.input)
    test.equal(view.find:query(), marker)
    test.ok(wait_for(view, function()
      local position = view.find:position()
      return position and position.row == result.line - 1
    end, 10), "the find card did not select the result's line")
  end)

  test.it("shows a Terminal match that Text Search in another Project sends", function()
    local marker = "ANVIL_TERMINAL_SEARCH_REQUEST"
    local view = shell(marker)
    local text = view.session:plain_text()
    local line = 0
    for row in (text .. "\n"):gmatch("(.-)\n") do
      line = line + 1
      if row:gsub("\r$", "") == marker then break end
    end

    test.ok(require("core.pane_requests").perform(common.serialize({ action = "terminal_find",
      session = view.session_id, query = marker, case_sensitive = false, row = line - 1 }, { escape = true })))
    test.equal(core.active_view, view.find.input)
    test.ok(wait_for(view, function()
      local position = view.find:position()
      return position and position.row == line - 1
    end, 10), "the find card did not select the requested line")
  end)

  test.it("answers another Project's Text Search with its Terminal lines and the lines near them", function(context)
    local marker = "ANVIL_TERMINAL_SEARCH_ANSWER"
    local view = shell(marker)
    -- The shell is the boundary: record each request that would go to it.
    local answers, pane_request = {}, system.pane_request
    system.pane_request = function(_, _, text)
      local request = assert(load("return " .. text))()
      if request.action == "project_results" then answers[#answers + 1] = request end
      return true
    end
    local ok, err = pcall(function()
      test.ok(require("core.pane_requests").perform(common.serialize({ action = "project_search",
        from = context.root .. PATHSEP .. "other", id = 3, mode = "text", query = marker, case_sensitive = false,
        limit = 5 }, { escape = true })))
      test.ok(wait_for(nil, function() return #answers > 0 end, 10), "no answer was sent")
      local row
      for _, candidate in ipairs(answers[1].rows) do
        if candidate.terminal and candidate.text == marker then row = candidate end
      end
      test.not_nil(row, "the answer has no Terminal line")
      test.equal(row.terminal.id, view.session_id)
      local lines = {}
      for text in (row.terminal.context.text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = text end
      test.equal(lines[row.line - row.terminal.context.first + 1], marker)
    end)
    system.pane_request = pane_request
    test.ok(ok, err)
  end)

  test.it("finds Terminal lines for a query of several words", function()
    local marker = "ANVIL_TERMINAL_SEARCH_WORDS"
    shell(marker .. " alpha beta")

    fuzzy_searcher.open("#" .. marker .. " beta")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_for(nil, function() return output_result(picker, marker .. " alpha beta") end, 10),
      "no Terminal result: " .. tostring(picker.status))
  end)

  test.it("draws a Terminal result with its name and previews its lines", function()
    local marker = "ANVIL_TERMINAL_SEARCH_DRAW"
    shell(marker)

    fuzzy_searcher.open("#" .. marker)
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_for(nil, function() return output_result(picker, marker) end, 10),
      "no Terminal result: " .. tostring(picker.status))
    local result = output_result(picker, marker)
    select_result(picker, result)
    picker.position.x, picker.position.y = 0, 0
    picker:set_size(1400, 600)
    picker.open_transition_complete = true
    picker:update()
    local texts = {}
    local drawn, draw_error = draw_without_window(function() picker:draw() end, texts)
    test.ok(drawn, draw_error)
    local named = false
    for _, text in ipairs(texts) do named = named or text == result.file end
    test.ok(named, "the row did not show the Terminal's name " .. result.file)
    local preview = test.not_nil(picker.preview_view, "the Terminal result has no preview")
    test.equal(preview.buffer.lines[result.line], marker .. "\n")
  end)
end)
