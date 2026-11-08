local common = require "core.common"
local config = require "core.config"
local core = require "core"
local command = require "core.command"
local fuzzy = require "plugins.fuzzy_searcher"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"

local function results(count)
  local list = {}
  for i = 1, count do
    list[i] = { kind = "file", file = "result-" .. i .. ".lua" }
  end
  return list
end

local function click_result(picker, index, modifier)
  local metrics = picker:list_metrics()
  local x = metrics.x + 20
  local y = metrics.results_top + (index - picker.viewport_offset + 0.5) * metrics.lh
  if modifier then keymap.modkeys[modifier] = true end
  picker:on_mouse_pressed("left", x, y, 1)
  picker:on_mouse_released("left", x, y)
  if modifier then keymap.modkeys[modifier] = false end
end

local function row_point(picker, index)
  local metrics = picker:list_metrics()
  return metrics.x + 20, metrics.results_top + (index - picker.viewport_offset + 0.5) * metrics.lh
end

local function drag_result(picker, index)
  local x, y = row_point(picker, index)
  picker:on_mouse_pressed("left", x, y, 1)
  picker:on_mouse_moved(x + 1, y + 1, 1, 1)
  local before = #picker.test_drags
  picker:on_mouse_moved(x + 40 * SCALE, y + 40 * SCALE, 40 * SCALE, 40 * SCALE)
  picker:on_mouse_released("left", x + 40 * SCALE, y + 40 * SCALE)
  return #picker.test_drags > before and picker.test_drags[#picker.test_drags] or nil
end

local function file_results(count)
  local list = {}
  for i = 1, count do
    list[i] = { kind = "file", file = "drag-" .. i .. ".txt", abs_path = common.normalize_path(USERDIR .. PATHSEP .. "drag-" .. i .. ".txt") }
  end
  return list
end

test.describe("Fuzzy Searcher result selection", function()
  test.before_each(function(context)
    context.transitions = config.transitions
    context.modkeys = {}
    for key, value in pairs(keymap.modkeys) do
      context.modkeys[key] = value
      keymap.modkeys[key] = false
    end
    config.transitions = false
    context.drag_files = system.drag_files
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    for key in pairs(keymap.modkeys) do keymap.modkeys[key] = nil end
    for key, value in pairs(context.modkeys) do keymap.modkeys[key] = value end
    config.transitions = context.transitions
    system.drag_files = context.drag_files
    if context.file then
      for _, pane in ipairs(panes.ordered()) do
        for _, view in ipairs(panes.views(pane)) do
          if view.buffer and common.path_equals(view.buffer.abs_filename, context.file) then
            panes.close_view(pane, { view = view, force = true })
          end
        end
      end
      os.remove(context.file)
    end
  end)

  test.it("selects separate rows with mouse and keyboard without losing marks", function()
    local picker = fuzzy.open_static_results("Results", results(8))
    click_result(picker, 2)
    click_result(picker, 4, "ctrl")
    test.same(picker:get_selected_result_indices(), { 2, 4 })

    test.ok(command.perform("fuzzy:select_next"))
    test.same(picker:get_selected_result_indices(), { 2, 4, 5 })
    test.ok(command.perform("fuzzy:next"))
    test.same(picker:get_selected_result_indices(), { 2, 4, 6 })

    click_result(picker, 4, "ctrl")
    test.same(picker:get_selected_result_indices(), { 2, 4, 6 })
    test.ok(command.perform("fuzzy:next"))
    test.same(picker:get_selected_result_indices(), { 2, 5, 6 })

    test.ok(command.perform("fuzzy:toggle_result_marks"))
    command.perform("fuzzy:next")
    test.same(picker:get_selected_result_indices(), { 2, 5, 6 })
  end)

  test.it("drags the pressed file row out of the editor after the pointer moves", function()
    local picker = fuzzy.open_static_results("Results", file_results(3))
    picker.test_drags = {}
    system.drag_files = function(window, paths)
      test.equal(window, core.window)
      picker.test_drags[#picker.test_drags + 1] = paths
      return true
    end

    local x, y = row_point(picker, 2)
    picker:on_mouse_pressed("left", x, y, 1)
    picker:on_mouse_moved(x + 1, y, 1, 0)
    picker:on_mouse_released("left", x + 1, y)
    test.same(picker.test_drags, {}, "a click with a small move does not drag")

    test.same(drag_result(picker, 3), { file_results(3)[3].abs_path })
    test.same(picker:get_selected_result_indices(), { 3 })
    test.ok(picker:is_visible(), "the picker stays open after a drag")
  end)

  test.it("drags all selected rows when the drag starts on one of them", function()
    local picker = fuzzy.open_static_results("Results", file_results(4))
    picker.test_drags = {}
    system.drag_files = function(_, paths)
      picker.test_drags[#picker.test_drags + 1] = paths
      return true
    end
    click_result(picker, 1)
    click_result(picker, 3, "ctrl")

    local rows = file_results(4)
    test.same(drag_result(picker, 3), { rows[1].abs_path, rows[3].abs_path })
    test.same(picker:get_selected_result_indices(), { 1, 3 })
    test.same(drag_result(picker, 2), { rows[2].abs_path }, "a drag from another row takes only that row")

    click_result(picker, 1, "ctrl")
    click_result(picker, 4, "ctrl")
    click_result(picker, 4)
    test.same(picker:get_selected_result_indices(), { 4 }, "a click on a selected row selects only it")
  end)

  test.it("scrolls the list without moving focus and returns to focus on keyboard movement", function()
    local picker = fuzzy.open_static_results("Results", results(80))
    local metrics = picker:list_metrics()
    picker.mouse.x, picker.mouse.y = metrics.x + 20, metrics.results_top + metrics.lh / 2
    local viewport_before_scroll = picker.viewport_offset
    picker:on_mouse_wheel(-1, 0)
    test.equal(picker.selected, 1)
    test.not_equal(picker.viewport_offset, viewport_before_scroll,
      "scrolling should move the result viewport without changing selection")
    picker:update()
    local opened
    picker.activate_selected_result = function(self) opened = self:selected_result().file end
    picker:confirm(false)
    test.equal(opened, "result-1.lua")

    local viewport_before_key = picker.viewport_offset
    command.perform("fuzzy:next")
    test.equal(picker.selected, 2)
    test.not_equal(picker.viewport_offset, viewport_before_key,
      "keyboard movement should bring selection back into view")
  end)

  test.it("keeps marks on results after a refresh and drops missing results", function()
    local picker = fuzzy.open_static_results("Results", results(3))
    click_result(picker, 2, "ctrl")
    picker:set_static_results({
      { kind = "file", file = "result-2.lua" },
      { kind = "file", file = "result-1.lua" },
      { kind = "file", file = "result-3.lua" },
    })
    picker:update()
    test.same(picker:get_selected_result_indices(), { 1, 2 })

    picker:set_static_results({
      { kind = "file", file = "result-3.lua" },
      { kind = "file", file = "result-2.lua" },
    })
    picker:update()
    test.same(picker:get_selected_result_indices(), { 2 })
  end)

  test.it("keeps equal display names from separate Project roots distinct", function()
    local picker = fuzzy.open_static_results("Results", {
      { kind = "file", file = "src/main.lua", abs_path = "C:\\first\\src\\main.lua" },
      { kind = "file", file = "src/main.lua", abs_path = "C:\\second\\src\\main.lua" },
    })
    click_result(picker, 2, "ctrl")
    test.same(picker:get_selected_result_indices(), { 1, 2 })
    click_result(picker, 1, "ctrl")
    command.perform("fuzzy:next")
    test.same(picker:get_selected_result_indices(), { 2 })
  end)

  test.it("opens two selected locations in one file in separate Panes without splits", function(context)
    context.file = common.normalize_path(USERDIR .. PATHSEP .. "fuzzy-multi-" .. system.get_process_id() .. ".txt")
    local file = assert(io.open(context.file, "wb"))
    file:write("first\nsecond\nthird\n")
    file:close()
    local before = panes.count()
    local picker = fuzzy.open_static_results("Results", {
      { kind = "grep", file = context.file, line = 1, col = 1 },
      { kind = "grep", file = context.file, line = 3, col = 1 },
    })
    click_result(picker, 2, "ctrl")
    test.same(picker:get_selected_result_indices(), { 1, 2 })

    picker:confirm(false)

    test.equal(panes.count(), before + 2)
    local opened = {}
    for _, pane in ipairs(panes.ordered()) do
      if pane.current_view.buffer and common.path_equals(pane.current_view.buffer.abs_filename, context.file) then
        test.equal(pane.group.root.kind, "pane")
        opened[#opened + 1] = pane.current_view:get_selection_state().selections[1]
      end
    end
    table.sort(opened)
    test.same(opened, { 1, 3 })
    test.equal(core.active_view:get_selection_state().selections[1], 3)
  end)
end)
