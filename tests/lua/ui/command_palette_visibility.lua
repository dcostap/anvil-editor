local command = require "core.command"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local storage = require "core.storage"
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

local function palette_position(picker, name)
  for index, row in ipairs(picker.results or {}) do
    if row.command == name then return index end
  end
end

local function run_from_palette(name)
  fuzzy_searcher.open(">" .. name)
  local picker = test.not_nil(core.fuzzy_searcher_active_view)
  picker.selected = test.not_nil(palette_position(picker, name), name)
  picker:confirm(false)
end

test.describe("Command Palette visibility", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.names = {
      visible = "test_palette:visible_action",
      hidden = "test_palette:hidden_primitive",
      invalid = "test_palette:wrong_context",
      opener = "test_palette:open_target_view",
      non_opener = "test_palette:target_action",
      alphabetic_first = "test_palette:alpha_extremely_long_command",
      alphabetic_second = "test_palette:beta_command",
      fuzzy_compact = "test_palette:alpha_a_b_c_command",
      fuzzy_contiguous = "test_palette:zeta_abc",
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
    command.add(nil, {
      [context.names.opener] = command.palette(function() end, {
        keywords = { "target" },
        opens_view = true,
      }),
      [context.names.non_opener] = command.palette(function() end),
      [context.names.alphabetic_first] = command.palette(function() end, {
        keywords = { "extra hidden command search words" },
      }),
      [context.names.alphabetic_second] = command.palette(function() end),
      [context.names.fuzzy_compact] = command.palette(function() end),
      [context.names.fuzzy_contiguous] = command.palette(function() end),
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

  test.it("ranks View Openers before other matching commands", function(context)
    fuzzy_searcher.open(">target")
    local positions = {}
    for index, row in ipairs(core.fuzzy_searcher_active_view.results or {}) do
      positions[row.command] = index
    end

    test.not_nil(positions[context.names.opener])
    test.not_nil(positions[context.names.non_opener])
    test.ok(positions[context.names.opener] < positions[context.names.non_opener])
  end)

  test.it("sorts equal command matches by identifier", function(context)
    fuzzy_searcher.open(">test_palette:")
    local positions = {}
    for index, row in ipairs(core.fuzzy_searcher_active_view.results or {}) do
      positions[row.command] = index
    end

    test.not_nil(positions[context.names.alphabetic_first])
    test.not_nil(positions[context.names.alphabetic_second])
    test.ok(positions[context.names.alphabetic_first]
      < positions[context.names.alphabetic_second])
  end)

  test.it("keeps stronger fuzzy command matches above alphabetical matches", function(context)
    fuzzy_searcher.open(">abc")
    local positions = {}
    for index, row in ipairs(core.fuzzy_searcher_active_view.results or {}) do
      positions[row.command] = index
    end

    test.not_nil(positions[context.names.fuzzy_compact])
    test.not_nil(positions[context.names.fuzzy_contiguous])
    test.ok(positions[context.names.fuzzy_contiguous]
      < positions[context.names.fuzzy_compact])
  end)

  test.it("counts only commands run from the Command Palette", function(context)
    local name = context.names.visible
    local before = (storage.load("fuzzy_searcher", "command_usage") or {})[name] or 0
    test.ok(command.perform(name))
    test.equal((storage.load("fuzzy_searcher", "command_usage") or {})[name] or 0, before)

    run_from_palette(name)
    test.equal((storage.load("fuzzy_searcher", "command_usage") or {})[name], before + 1)
  end)

  test.it("ranks frequent Palette commands above newer ones with equal text matches", function(context)
    local suffix = tostring(math.floor(system.get_time() * 1000000))
    local frequent = "test_palette:bravo_rank_" .. suffix
    local newer = "test_palette:alpha_rank_" .. suffix
    context.names.frequent = frequent
    context.names.newer = newer
    command.add(nil, {
      [frequent] = command.palette(function() end),
      [newer] = command.palette(function() end),
    })

    for _ = 1, 3 do run_from_palette(frequent) end
    run_from_palette(newer)

    fuzzy_searcher.open(">")
    local picker = core.fuzzy_searcher_active_view
    picker.input:set_text(">")
    picker.current_query_key = nil
    picker.force_refresh = true
    picker:refresh(">")
    local frequent_position = test.not_nil(palette_position(picker, frequent),
      "missing frequent command for " .. picker.input:get_text())
    local newer_position = test.not_nil(palette_position(picker, newer),
      "missing newer command for " .. picker.input:get_text())
    test.ok(frequent_position < newer_position)
    picker:close()

    fuzzy_searcher.open(">test_palette:")
    picker = core.fuzzy_searcher_active_view
    frequent_position = test.not_nil(palette_position(picker, frequent),
      "missing frequent command for " .. picker.input:get_text())
    newer_position = test.not_nil(palette_position(picker, newer),
      "missing newer command for " .. picker.input:get_text())
    test.ok(frequent_position < newer_position)
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
