local command = require "core.command"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local test = require "core.test"
local View = require "core.view"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function result_commands(picker)
  local result = {}
  for _, row in ipairs(picker.results or {}) do
    if row.command then result[row.command] = true end
  end
  return result
end

test.describe("Command Palette visibility", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.names = {
      visible = "test_palette:visible_action",
      hidden = "test_palette:hidden_primitive",
      invalid = "test_palette:wrong_context",
    }
    context.source = Editor(Buffer(nil, nil, true))
    panes.create { factory = function() return context.source end }

    command.add(function() return core.active_view == context.source end, {
      [context.names.visible] = command.palette(function() end, {
        keywords = { "discoverable_alias" },
      }),
    })
    command.add(nil, {
      [context.names.hidden] = function() end,
    })
    command.add(function() return false end, {
      [context.names.invalid] = command.palette(function() end),
    })
  end)

  test.it("shows raw identifiers and matches hidden keywords", function(context)
    fuzzy_searcher.open(">discoverable_alias")
    local row
    for _, candidate in ipairs(core.fuzzy_searcher_active_view.results or {}) do
      if candidate.command == context.names.visible then row = candidate break end
    end

    test.not_nil(row)
    test.equal(context.names.visible, row.label)
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    for _, name in pairs(context.names) do
      command.map[name] = nil
    end
    panes.reset_for_tests()
  end)

  test.it("shows only curated commands valid for the source View", function(context)
    fuzzy_searcher.open(">visible_action")
    local shown = result_commands(core.fuzzy_searcher_active_view)

    test.ok(shown[context.names.visible])
    test.not_ok(shown[context.names.hidden])
    test.not_ok(shown[context.names.invalid])
  end)

  test.it("hides keymap primitives while retaining useful editor actions", function()
    fuzzy_searcher.open(">previous word start")
    local movement = result_commands(core.fuzzy_searcher_active_view)
    test.not_ok(movement["core:move_to_previous_word_start"])
    test.not_ok(movement["core:select_to_previous_word_start"])
    test.not_ok(movement["core:delete_to_previous_word_start"])

    core.fuzzy_searcher_active_view:close()
    fuzzy_searcher.open(">save as")
    local actions = result_commands(core.fuzzy_searcher_active_view)
    test.ok(actions["editor:save_as"])
  end)
end)
