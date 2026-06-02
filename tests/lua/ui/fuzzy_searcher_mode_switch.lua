local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  return view, doc
end

local function cleanup_editor_views(context)
  local root = core.root_panel.root_node
  for _, view in ipairs(context.views or {}) do
    local node = root:get_node_for_view(view)
    if node then node:remove_view(root, view) end
  end
  for _, doc in ipairs(context.docs or {}) do
    if doc:is_dirty() then doc:clean() end
    remove_doc(doc)
  end
end

local function picker_text()
  local picker = core.fuzzy_searcher_active_view
  return picker and picker.input and picker.input:get_text() or nil
end

test.describe("Fuzzy Searcher mode switching", function()
  test.after_each(function(context)
    if context.ctrl_wheel_handler then
      keymap.unbind("ctrl+wheelup", context.ctrl_wheel_handler)
    end
    if context.ctrl_shift_wheel_handler then
      keymap.unbind("ctrl+shift+wheelup", context.ctrl_shift_wheel_handler)
    end
    keymap.modkeys.ctrl = false
    keymap.modkeys.shift = false
    keymap.modkeys.alt = false
    keymap.modkeys.altgr = false
    keymap.modkeys.super = false
    keymap.modkeys.cmd = false
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    cleanup_editor_views(context)
  end)

  test.it("preserves prompt text and replaces the mode prefix when another fuzzy mode is opened", function(context)
    local view, doc = open_editor(context, "underlying selection should not be copied\n")
    doc:set_selection(1, 1, 1, 20)
    core.set_active_view(view)

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("#typed query")
    picker.input.textview.doc:set_selection(1, 8, 1, 8)

    test.ok(command.perform("fuzzy-searcher:open-projects"), "expected project mode command to run")

    test.equal(picker_text(), "@typed query")
    test.equal(core.fuzzy_searcher_active_view, picker, "expected the existing picker to stay open")
    test.same({ picker.input.textview.doc:get_selection() }, { 1, 8, 1, 8 })
  end)

  test.it("does not reseed grep mode from the underlying editor selection while the picker is active", function(context)
    local view, doc = open_editor(context, "copy me from editor\n")
    doc:set_selection(1, 1, 1, 8)
    core.set_active_view(view)

    fuzzy_searcher.open("@")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text("@project query")

    command.perform("fuzzy-searcher:open-grep")

    test.equal(picker_text(), "#project query")
  end)

  test.it("adds the requested mode prefix when the active picker text has no mode prefix", function()
    fuzzy_searcher.open("")
    core.fuzzy_searcher_active_view.input:set_text("plain query")

    command.perform("fuzzy-searcher:open-commands")

    test.equal(picker_text(), ">plain query")
  end)

  test.it("lets scale mouse-wheel shortcuts reach the global keymap", function(context)
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker:layout()
    picker.mouse.x = picker.position.x + 10
    picker.mouse.y = picker.position.y + 10

    local ctrl_wheel_handled = false
    context.ctrl_wheel_handler = function() ctrl_wheel_handled = true end
    keymap.add({ ["ctrl+wheelup"] = context.ctrl_wheel_handler })

    keymap.modkeys.ctrl = true
    test.equal(picker:on_mouse_wheel(1, 0), false)
    test.equal(keymap.on_key_pressed("wheelup"), true)
    test.equal(ctrl_wheel_handled, true)

    local ctrl_shift_wheel_handled = false
    context.ctrl_shift_wheel_handler = function() ctrl_shift_wheel_handled = true end
    keymap.add({ ["ctrl+shift+wheelup"] = context.ctrl_shift_wheel_handler })

    keymap.modkeys.shift = true
    test.equal(picker:on_mouse_wheel(1, 0), false)
    test.equal(keymap.on_key_pressed("wheelup"), true)
    test.equal(ctrl_shift_wheel_handled, true)

    keymap.modkeys.alt = true
    test.equal(picker:on_mouse_wheel(1, 0), true)
  end)
end)
