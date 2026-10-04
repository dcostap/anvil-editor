local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"
local View = require "core.view"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local symbol_index = require "core.treesitter.symbol_index"
local treesitter = require "core.treesitter"
local worker_pool = require "core.worker_pool"

local PlaceView = View:extend()
function PlaceView:new(name)
  PlaceView.super.new(self)
  self.name, self.place = name, 1
end
function PlaceView:get_name() return self.name end
function PlaceView:get_navigation_state() return { place = self.place } end
function PlaceView:set_navigation_state(state) self.place = state.place end

local function editor_pane(context)
  local buffer = Buffer(nil, nil, true)
  buffer.lines = {}
  for line = 1, 100 do buffer.lines[line] = "source line " .. line .. "\n" end
  buffer.filename = "navigation-search.txt"
  buffer.abs_filename = context.root .. PATHSEP .. buffer.filename
  local editor = Editor(buffer)
  context.editors[#context.editors + 1] = editor
  local pane = panes.create { factory = function() return editor end }
  editor:set_navigation_state {
    selection_state = { selections = { 20, 3, 20, 7 }, last_selection = 1 },
    scroll = { x = 2, y = 400 },
  }
  panes.record_location(pane)
  editor:set_navigation_state {
    selection_state = { selections = { 70, 5, 70, 5 }, last_selection = 1 },
    scroll = { x = 0, y = 1400 },
  }
  panes.record_location(pane)
  panes.back(pane)
  return pane, editor, buffer
end

test.describe("Fuzzy Searcher Navigation History Search", function()
  test.before_each(function(context)
    context.editors = {}
    context.buffers = {}
    context.active_view = core.active_view
    context.projects, context.cwd = core.projects, system.getcwd()
    context.root = USERDIR .. PATHSEP .. "navigation-search-project"
    common.rm(context.root, true)
    test.ok(common.mkdirp(context.root))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {}
    symbol_index.reset_for_tests()
    context.navigation = config.plugins.navigation_history
    config.plugins.navigation_history = { enabled = false }
    panes.reset_for_tests()
    fuzzy_searcher._test.clear_prompt_history()
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close("replaced") end
    panes.reset_for_tests()
    for _, editor in ipairs(context.editors) do
      editor:on_close()
      core.buffer_registry:remove(editor.buffer, true)
    end
    for _, buffer in ipairs(context.buffers) do core.buffer_registry:remove(buffer, true) end
    symbol_index.reset_for_tests()
    project_paths.configure_workspace {}
    core.projects = context.projects
    system.chdir(context.cwd)
    common.rm(context.root, true)
    config.plugins.navigation_history = context.navigation
    core.active_view = context.active_view
  end)

  test.it("lists only the source Pane's places and selects its current entry", function()
    local source = PlaceView("File Tree")
    local pane = panes.create { factory = function() return source end }
    source.place = 2
    panes.record_location(pane)
    local terminal = PlaceView("Terminal")
    panes.present(terminal, { pane = pane })
    panes.back(pane)
    local other = panes.create { factory = function() return PlaceView("Other Pane") end }
    panes.focus(pane)

    test.ok(command.perform("fuzzy:open_navigation_history"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.equal(picker.input:get_text(), "^")
    test.equal(#picker.results, 3)
    test.equal(picker.results[1].view, terminal)
    test.equal(picker.results[2].view, source)
    test.equal(picker.selected, 2)
    test.ok(picker.results[2].current)
    test.equal(panes.active(), pane)
    test.equal(other.current_view:get_name(), "Other Pane")
    test.ok(command.get_metadata("fuzzy:open_navigation_history").palette)
  end)

  test.it("restores the exact selected history entry without removing forward entries", function(context)
    local pane, editor = editor_pane(context)
    local picker = fuzzy_searcher.open("^")
    picker:select_result(3)
    picker:confirm()
    test.equal(pane.current_view, editor)
    test.same(editor:get_selection_state().selections, { 1, 1, 1, 1 })
    test.equal(panes.history_length(pane), 3)
    panes.forward(pane)
    test.same(editor:get_selection_state().selections, { 20, 3, 20, 7 })
    panes.forward(pane)
    test.same(editor:get_selection_state().selections, { 70, 5, 70, 5 })
  end)

  test.it("shows the current entry immediately when it is outside the newest result page", function()
    local view = PlaceView("File Tree")
    local pane = panes.create { factory = function() return view end }
    for place = 2, 60 do
      view.place = place
      panes.record_location(pane)
    end
    for _ = 1, 59 do panes.back(pane) end
    local picker = fuzzy_searcher.open("^")
    test.equal(#picker.results, 60)
    test.ok(picker:selected_result().current)
    local first = picker:displayed_list_offset()
    local rows = picker:list_metrics().result_rows
    test.ok(picker.selected >= first and picker.selected < first + rows,
      "expected the current entry inside the visible results")
  end)

  test.it("previews current unsaved text without changing the source selection or history", function(context)
    local pane, editor, buffer = editor_pane(context)
    buffer:insert(70, 1, "unsaved ")
    local source_state = editor:get_selection_state()
    local picker = fuzzy_searcher.open("^")
    picker:select_result(1)
    local preview = test.not_nil(picker:update_selected_preview())
    test.equal(picker:selected_result().text, "unsaved source line 70")
    test.equal(preview.buffer.lines[70], "unsaved source line 70\n")
    test.not_ok(preview.interactive)
    local capture = picker:text_capture()
    test.ok(capture.text:find("Mode: Navigation History Search", 1, true))
    test.ok(capture.text:find("navigation-search.txt:70:", 1, true))
    test.same(editor:get_selection_state(), source_state)
    test.equal(panes.history_length(pane), 3)
    test.equal(pane.current_view, editor)
    picker:close("replaced")
    test.same(editor:get_selection_state(), source_state)
    test.equal(buffer.lines[70], "unsaved source line 70\n")
  end)

  test.it("restores the current checkpoint even when the live caret moved", function(context)
    local _, editor = editor_pane(context)
    editor:set_selection_state { selections = { 22, 1, 22, 1 }, last_selection = 1 }
    local picker = fuzzy_searcher.open("^")
    picker:confirm()
    test.same(editor:get_selection_state().selections, { 20, 3, 20, 7 })
    test.equal(editor.scroll.to.x, 2)
    test.equal(editor.scroll.to.y, 400)
  end)

  test.it("refreshes changed source text and added places while many Buffers are open", function(context)
    local pane, editor, buffer = editor_pane(context)
    for line = 2, 60 do
      editor:set_selection_state { selections = { line, 1, line, 1 }, last_selection = 1 }
      panes.record_location(pane, { no_merge = true })
    end
    for index = 1, 60 do
      local other = Buffer(nil, nil, true)
      other.filename = "unrelated-" .. index .. ".txt"
      other.abs_filename = context.root .. PATHSEP .. other.filename
      core.buffer_registry:register(other, other.abs_filename)
      context.buffers[#context.buffers + 1] = other
    end
    local picker = fuzzy_searcher.open("^")
    local count = #picker.results
    test.ok(count >= 60)
    -- Measure the public refresh operation without a machine-dependent limit.
    local started = system.get_time()
    for _ = 1, 5 do picker:refresh_navigation_history("^", false) end
    print(string.format("Navigation History unchanged refresh probe: %.3f ms",
      (system.get_time() - started) * 1000))
    buffer:insert(60, 1, "changed ")
    picker:refresh_navigation_history("^", false)
    local changed
    for _, row in ipairs(picker.results) do if row.line == 60 then changed = row end end
    test.equal(test.not_nil(changed).text, "changed source line 60")
    panes.present(PlaceView("Added View"), { pane = pane })
    picker:refresh_navigation_history("^", false)
    test.equal(#picker.results, count + 1)
    local added
    for _, row in ipairs(picker.results) do if row.label == "Added View" then added = row end end
    test.not_nil(added)
    picker.input:set_text("^changed source line 60")
    test.equal(#picker.results, 1)
    test.equal(picker.results[1].line, 60)
  end)

  test.it("switches previews between different Buffers with the same text revision", function(context)
    local pane = editor_pane(context)
    local buffer = Buffer(nil, nil, true)
    buffer.lines = { "different buffer\n" }
    buffer.filename = "other.txt"
    buffer.abs_filename = context.root .. PATHSEP .. buffer.filename
    local editor = Editor(buffer)
    context.editors[#context.editors + 1] = editor
    panes.present(editor, { pane = pane })
    local picker = fuzzy_searcher.open("^")
    test.equal(picker:update_selected_preview().buffer.lines[1], "different buffer\n")
    picker:select_result(#picker.results)
    test.equal(picker:update_selected_preview().buffer.lines[1], "source line 1\n")
  end)

  test.it("keeps repeated visits and restores the selected stateful View", function()
    local source = PlaceView("File Tree")
    local pane = panes.create { factory = function() return source end }
    source.place = 2
    panes.record_location(pane)
    local terminal = PlaceView("Terminal")
    panes.present(terminal, { pane = pane })
    source.place = 3
    panes.present(source, { pane = pane })
    local picker = fuzzy_searcher.open("^File Tree")
    test.equal(#picker.results, 3)
    picker:select_result(3)
    picker:confirm(true)
    test.equal(panes.count(), 1)
    test.equal(pane.current_view, source)
    test.equal(source.place, 1)
    test.equal(panes.history_length(pane), 4)
    panes.forward(pane)
    test.equal(source.place, 2)
    test.equal(panes.forward(pane), terminal)
    test.equal(panes.forward(pane), source)
    test.equal(source.place, 3)
  end)

  test.it("searches file paths and code text without interpreting other mode markers", function(context)
    local _, _, buffer = editor_pane(context)
    buffer:insert(70, 1, "size:20m #tag $value:12 ")
    local picker = fuzzy_searcher.open("^size:20m #tag $value:12")
    test.equal(#picker.results, 1)
    test.equal(picker.results[1].line, 70)
    picker.input:set_text("^navigation-search.txt")
    test.equal(#picker.results, 3)
    picker.input:set_text("^source line 20")
    test.equal(picker.results[1].line, 20)
  end)

  test.it("rejects a removed place instead of activating the replacement at its old index", function(context)
    local pane, editor = editor_pane(context)
    local picker = fuzzy_searcher.open("^")
    picker:select_result(1)
    local place = picker:selected_result().history_entry
    panes.close_view(pane, { view = editor, force = true })
    test.not_ok(picker:confirm())
    test.not_ok(picker.closed)
    test.ok(picker.status:find("no longer available", 1, true))
    test.is_nil(panes.go_to_history_entry(pane, place))
  end)

  test.it("finds and displays the enclosing Tree-sitter symbol from unsaved code", function(context)
    local path = context.root .. PATHSEP .. "history.c"
    local file = assert(io.open(path, "wb"))
    file:write("int old_name(void) {\n  return 1;\n}\n")
    file:close()
    local buffer = Buffer("history.c", path)
    buffer:remove(1, 5, 1, 13)
    buffer:insert(1, 5, "new_name")
    local editor = Editor(buffer)
    context.editors[#context.editors + 1] = editor
    local pane = panes.create { factory = function() return editor end }
    editor:set_selection_state { selections = { 2, 3, 2, 3 }, last_selection = 1 }
    panes.record_location(pane)
    local picker = fuzzy_searcher.open("^new_name")
    local found
    local deadline = system.get_time() + 10
    repeat
      treesitter.poll_buffer(buffer)
      local pool = worker_pool.current_system()
      if pool then pool:drain { max_ms = 5, max_messages = 64 } end
      picker:update()
      for _, row in ipairs(picker.results) do if row.line == 2 then found = row end end
      if found then break end
      coroutine.yield(0.02)
    until system.get_time() >= deadline
    local row = test.not_nil(found, "expected a match through the enclosing symbol name")
    test.equal(row.enclosing_symbol.name, "new_name")
    test.equal(row.enclosing_symbol.kind, "function")
    test.equal(row.file, "history.c")
    test.equal(row.text, "  return 1;")
    picker:select_result(1)
    test.equal(picker:selected_result().line, 2)
    test.not_nil(picker:update_selected_preview())
    picker:set_size(1600, 750)
    local saved, drawn = {}, {}
    for _, name in ipairs { "draw_rect", "draw_rounded_rect", "draw_text_known_bounds",
      "set_clip_rect", "draw_canvas", "draw_text" } do
      saved[name] = renderer[name]
      renderer[name] = function() end
    end
    renderer.draw_text = function(font, text, x)
      drawn[text] = true
      return x + font:get_width(text)
    end
    local ok, err = pcall(function() picker:draw_open_content() end)
    for name, method in pairs(saved) do renderer[name] = method end
    if not ok then error(err, 0) end
    test.ok(drawn["new_name"], "expected the enclosing symbol in the history row")
    test.ok(drawn["history.c"], "expected the filename in the history row")
    test.ok(drawn["return 1;"], "expected the source line in the history row")
    buffer:remove(1, 5, 1, 13)
    buffer:insert(1, 5, "later_name")
    picker:refresh_navigation_history("^new_name", false)
    test.equal(#picker.results, 0, "the old symbol must not match after an edit")
    picker.input:set_text("^later_name")
    found = nil
    deadline = system.get_time() + 10
    repeat
      treesitter.poll_buffer(buffer)
      local pool = worker_pool.current_system()
      if pool then pool:drain { max_ms = 5, max_messages = 64 } end
      picker:update()
      for _, result in ipairs(picker.results) do if result.line == 2 then found = result end end
      if found then break end
      coroutine.yield(0.02)
    until system.get_time() >= deadline
    test.equal(test.not_nil(found).enclosing_symbol.name, "later_name")
  end)
end)
