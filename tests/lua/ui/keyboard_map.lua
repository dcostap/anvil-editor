local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local panes = require "core.panes"
local test = require "core.test"
local KeyboardMap = require "plugins.keyboard_map"

local function spec(id)
  for _, candidate in ipairs(KeyboardMap.layout) do
    if candidate.id == id and not candidate.part then return candidate end
  end
  test.fail("no key " .. id)
end

local function press(binding)
  local parts = {}
  for part in binding:gmatch("[^+]+") do parts[#parts + 1] = part end
  local key = table.remove(parts)
  local event = { modifiers = 0, ctrl = false, shift = false, alt = false, altgr = false, super = false, gui = false }
  for _, mod in ipairs(parts) do event[mod] = true end
  local result = core.on_event("keypressed", key, event)
  core.on_event("keyreleased", key, event)
  return result
end

local function type_text(text)
  for char in text:gmatch(".") do
    if not press(char == " " and "space" or char) then core.on_event("textinput", char) end
  end
end

-- One frame, so the View lays out its keys and rows.
local function draw(view)
  core.root_panel:update()
  renderer.begin_frame(core.window)
  view:draw()
  renderer.end_frame()
end

local function click(x, y)
  core.on_event("mousepressed", "left", x, y, 1)
  core.on_event("mousereleased", "left", x, y)
end

local function click_key(view, id)
  local x, y, w, h = view:key_rect(spec(id))
  click(x + w / 2, y + h / 2)
  draw(view)
end

local function has(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then return true end
  end
  return false
end

test.describe("Keyboard Map", function()
  local bindings = {
    ["ctrl+f9"] = "keyboard_map_test:on_ctrl_f9",
    ["alt+j"] = "keyboard_map_test:hidden_by_alt_navigation",
  }

  test.before_each(function()
    panes.reset_for_tests()
    core.root_panel.size.x, core.root_panel.size.y = 1400, 1000
    keymap.add(bindings)
  end)

  test.after_each(function()
    for stroke, name in pairs(bindings) do keymap.unbind(stroke, name) end
  end)

  local function open()
    test.ok(command.perform("keyboard_map:open"))
    local view = core.active_view
    test.ok(view:is(KeyboardMap))
    draw(view)
    return view
  end

  test.it("resolves a physical key to the keymap commands of its layer", function()
    local entry = KeyboardMap.resolve("f9", "f9", 1, true)
    test.equal(entry.stroke, "ctrl+f9")
    test.ok(has(entry.commands, "keyboard_map_test:on_ctrl_f9"))
    test.equal(#KeyboardMap.resolve("f9", "f9", 0, true).commands, 0)
  end)

  test.it("shows an Alt Navigation chord as the stroke that it types", function()
    local entry = KeyboardMap.resolve("j", "j", 4, true)
    test.equal(entry.target, "ctrl+left")
    test.same(entry.commands, keymap.map["ctrl+left"])
    test.ok(has(entry.hidden, "keyboard_map_test:hidden_by_alt_navigation"))
    -- Without Alt Navigation, Alt+J runs its own binding.
    entry = KeyboardMap.resolve("j", "j", 4, false)
    test.equal(entry.target, nil)
    test.ok(has(entry.commands, "keyboard_map_test:hidden_by_alt_navigation"))
  end)

  test.it("changes the layer with a click on a modifier key", function()
    local view = open()
    click_key(view, "left ctrl")
    test.equal(view:current_layer(), 1)
    click_key(view, "left shift")
    test.equal(view:current_layer(), 3)
    click_key(view, "right ctrl")
    test.equal(view:current_layer(), 2)
  end)

  test.it("filters bindings by command and shows a match on its key and layer", function()
    local view = open()
    type_text("on ctrl f99")
    test.ok(press("backspace"))
    draw(view)
    test.equal(view.field:get_text(), "on ctrl f9")
    test.equal(#view.matches, 1)
    local row = view.matches[1]
    test.equal(row.stroke, "ctrl+f9")
    click(row.x + 4, row.y + 2)
    draw(view)
    test.equal(view.selected, "f9")
    test.equal(view:current_layer(), 1)
    test.ok(press("escape"))
    test.equal(view.field:get_text(), "")
  end)
end)
