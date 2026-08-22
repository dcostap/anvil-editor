local core = require "core"
local command = require "core.command"
local style = require "core.style"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local Editor = require "core.editor"
local panes = require "core.panes"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local buffer = track(context, "buffers", core.open_buffer())
  if text and text ~= "" then buffer:text_input(text) end
  local view = track(context, "views", panes.place(function() return Editor(buffer) end,
    { placement = "new", focus = true }))
  return view, buffer
end

local function cleanup_editor_views(context)
  panes.reset_for_tests()
  for _, buffer in ipairs(context.buffers or {}) do
    if buffer:is_dirty() then buffer:clean() end
    remove_buffer(buffer)
  end
end

local function picker_text()
  local picker = core.fuzzy_searcher_active_view
  return picker and picker.input and picker.input:get_text() or nil
end

test.describe("Fuzzy Searcher mode switching", function()
  test.before_each(function()
    panes.reset_for_tests()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if core.active_view then core.clear_active_view(core.active_view) end
    fuzzy_searcher._test.clear_prompt_history()
  end)

  test.it("recognizes command mode prefixes in prompt text", function()
    local split = fuzzy_searcher._test.split_mode_prefix
    test.same({ split(">commands") }, { ">", "commands" })
    test.same({ split("@projects") }, { "@", "projects" })
    test.same({ split("@@files") }, { "@", "@files" })
    test.same({ split("#grep") }, { "#", "grep" })
    test.same({ split("$symbols") }, { "$", "symbols" })
    test.same({ split("$$buffer symbols") }, { "$$", "buffer symbols" })
    test.same({ split("files") }, { "", "files" })
  end)

  test.it("keeps the search prompt input on one visual row", function()
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    local textview = test.not_nil(picker.input and picker.input.textview)
    test.equal(textview:is_wrapping_enabled(), false)
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    cleanup_editor_views(context)
  end)

  test.it("migrates legacy inline grep history into exact grep restore points", function()
    local history, migrated = fuzzy_searcher._test.normalize_prompt_history({
      [""] = { "odin/parser #parse_package" },
    })

    test.ok(migrated)
    test.same(history["#"], { "odin/parser #parse_package" })
    test.is_nil(history[""])
  end)

  test.it("loads stored file queries alongside prefixed mode history", function()
    local history, migrated = fuzzy_searcher._test.normalize_prompt_history({
      version = 2,
      modes = {
        [""] = { "", "init.lua" },
        [">"] = { ">", ">build" },
      },
    })

    test.ok(not migrated)
    test.same(history[""], { "", "init.lua" })
    test.same(history[">"], { ">", ">build" })
  end)

  test.it("renders an inline path/content separator as a mode marker", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("odin\\parser #parse_package")

    local draws = {}
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x, _, color)
      draws[#draws + 1] = { text = text, color = color }
      return x + font:get_width(text)
    end
    local ok, err = pcall(function()
      picker.input.textview:draw_line_text(1, 0, 0)
    end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(draws[1].text, "odin\\parser ")
    test.equal(draws[2].text, "#")
    test.equal(draws[2].color, style.dim)
    test.equal(draws[3].text, "parse_package\n")
  end)

  test.it("renders an inline symbol separator as a mode marker", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("odin/parser $parse package")

    local draws = {}
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x, _, color)
      draws[#draws + 1] = { text = text, color = color }
      return x + font:get_width(text)
    end
    local ok, err = pcall(function()
      picker.input.textview:draw_line_text(1, 0, 0)
    end)
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end

    test.equal(draws[1].text, "odin/parser ")
    test.equal(draws[2].text, "$")
    test.equal(draws[2].color, style.dim)
    test.equal(draws[3].text, "parse package\n")
  end)

  test.it("places the caret after the initial mode prefix when opened", function()
    fuzzy_searcher.open("#")

    local picker = core.fuzzy_searcher_active_view

    test.same({ picker.input.textview.buffer:get_selection() }, { 1, 2, 1, 2 })
  end)

  test.it("preserves prompt text, replaces the mode prefix, and selects the query when another fuzzy mode is opened", function(context)
    local view, buffer = open_editor(context, "underlying selection should not be copied\n")
    buffer:set_selection(1, 1, 1, 20)
    core.set_active_view(view)

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("#typed query")
    picker.input.textview.buffer:set_selection(1, 8, 1, 8)

    test.ok(command.perform("fuzzy:open_paths"), "expected Path Search command to run")

    test.equal(picker_text(), "@typed query")
    test.equal(core.fuzzy_searcher_active_view, picker, "expected the existing picker to stay open")
    test.same({ picker.input.textview.buffer:get_selection() }, { 1, 2, 1, #"@typed query" + 1 })
  end)

  test.it("does not reseed grep mode from the underlying editor selection while the picker is active", function(context)
    local view, buffer = open_editor(context, "copy me from editor\n")
    buffer:set_selection(1, 1, 1, 8)
    core.set_active_view(view)

    fuzzy_searcher.open("@")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("@project query")

    command.perform("fuzzy:open_grep")

    test.equal(picker_text(), "#project query")
  end)

  test.it("adds the requested mode prefix when the active picker text has no mode prefix", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("plain query")

    command.perform("fuzzy:open_commands")

    test.equal(picker_text(), ">plain query")
  end)

  test.it("reopens file search with an empty prompt instead of its previous query", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("data/core/init.lua")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view

    test.equal(picker.input:get_text(), "")
    test.same({ picker.input.textview.buffer:get_selection() }, { 1, 1, 1, 1 })
  end)

  test.it("remembers a blank query in a prefixed mode", function()
    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">line wrapping")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")

    test.equal(picker_text(), ">")
    test.same(fuzzy_searcher._test.prompt_history(">"), { ">", ">line wrapping" })
  end)

  test.it("records file search prompt history", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("init.lua")
    core.fuzzy_searcher_active_view:close()

    test.same(fuzzy_searcher._test.prompt_history(""), { "init.lua" })
  end)

  test.it("cycles file search prompt history", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("first.lua")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("second.lua")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("draft.lua")

    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker.input:get_text(), "second.lua")
    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker.input:get_text(), "first.lua")
    command.perform("fuzzy:prompt_history_next")
    test.equal(picker.input:get_text(), "second.lua")
  end)

  test.it("clears the file search prompt when file search is triggered again", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("init.lua")

    command.perform("fuzzy:open_files")

    test.equal(core.fuzzy_searcher_active_view, picker)
    test.equal(picker_text(), "")
  end)

  test.it("restores an inline path/content grep prompt without moving its mode marker", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("odin/parser #parse_package")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("#")

    test.equal(picker_text(), "odin/parser #parse_package")
  end)

  test.it("navigates inline path/content grep history as exact prompt restore points", function()
    fuzzy_searcher.open("#")
    core.fuzzy_searcher_active_view.input:set_text("#first grep")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("odin/parser #parse_package")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    test.equal(picker_text(), "odin/parser #parse_package")
    picker.input:set_text("#draft")

    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker_text(), "odin/parser #parse_package")
    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker_text(), "#first grep")
    command.perform("fuzzy:prompt_history_next")
    test.equal(picker_text(), "odin/parser #parse_package")
    command.perform("fuzzy:prompt_history_next")
    test.equal(picker_text(), "#draft")
  end)

  test.it("keeps an inline grep prompt unchanged when grep mode is requested again", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("odin/parser #parse_package")

    command.perform("fuzzy:open_grep")

    test.equal(core.fuzzy_searcher_active_view, picker)
    test.equal(picker_text(), "odin/parser #parse_package")
  end)

  test.it("restores inline path/symbol prompts as exact symbol-mode history", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("odin/parser $parse package")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("$")

    test.equal(picker_text(), "odin/parser $parse package")
  end)

  test.it("does not replace an auto-seeded grep prompt with saved history", function(context)
    fuzzy_searcher.open("#")
    core.fuzzy_searcher_active_view.input:set_text("#old grep")
    core.fuzzy_searcher_active_view:close()

    local view, buffer = open_editor(context, "selected grep text\n")
    buffer:set_selection(1, 1, 1, #"selected grep text" + 1)
    core.set_active_view(view)

    fuzzy_searcher.open("#")

    test.equal(picker_text(), '#"selected grep text"')
  end)

  test.it("cycles current mode prompt history without wrapping and keeps current text", function()
    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">first")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">second")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open(">")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text(">draft")

    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker.input:get_text(), ">second")

    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker.input:get_text(), ">first")

    command.perform("fuzzy:prompt_history_previous")
    test.equal(picker.input:get_text(), ">first")

    command.perform("fuzzy:prompt_history_next")
    test.equal(picker.input:get_text(), ">second")

    command.perform("fuzzy:prompt_history_next")
    test.equal(picker.input:get_text(), ">draft")

    command.perform("fuzzy:prompt_history_next")
    test.equal(picker.input:get_text(), ">draft")
  end)

  test.it("records the previous mode prompt when switching modes before close", function()
    fuzzy_searcher.open(">")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text(">build")

    command.perform("fuzzy:open_paths")
    picker:close()

    fuzzy_searcher.open(">")
    picker = core.fuzzy_searcher_active_view

    test.equal(picker.input:get_text(), ">build")
    test.same(fuzzy_searcher._test.prompt_history(">"), { ">build" })
  end)

  test.it("restores target mode history when switching from an empty query", function()
    fuzzy_searcher.open(">")
    core.fuzzy_searcher_active_view.input:set_text(">build")
    core.fuzzy_searcher_active_view:close()

    fuzzy_searcher.open("")
    command.perform("fuzzy:open_commands")
    local picker = core.fuzzy_searcher_active_view

    test.equal(picker.input:get_text(), ">build")
    test.same({ picker.input.textview.buffer:get_selection() }, { 1, 2, 1, #">build" + 1 })
  end)
end)
