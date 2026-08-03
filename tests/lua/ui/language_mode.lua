local command = require "core.command"
local common = require "core.common"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local language_mode = require "core.language_mode"
local test = require "core.test"

require "core.commands.language"

local function mode_named(name)
  return function(item)
    return item and item.mode == name
  end
end

test.describe("Language Mode", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
    context.original_global_prompt_bar = core.global_prompt_bar
    context.original_save_workspace = core.save_workspace
    language_mode.load_workspace_state(nil)
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    core.global_prompt_bar = context.original_global_prompt_bar
    core.save_workspace = context.original_save_workspace
    language_mode.load_workspace_state(nil)
  end)

  test.it("overrides filename detection until Automatic is selected", function()
    local doc = Doc("notes.md", "notes.md", true)
    test.equal(doc.syntax.name, "Markdown")

    test.ok(doc:set_language_mode("Lua"))
    test.equal(doc.language_mode_override, "Lua")
    test.equal(doc.syntax.name, "Lua")

    doc:reset_syntax()
    test.equal(doc.syntax.name, "Lua")

    test.ok(doc:set_language_mode(nil))
    test.is_nil(doc.language_mode_override)
    test.equal(doc.syntax.name, "Markdown")
  end)

  test.it("round-trips named-file overrides through Project Workspace state", function()
    local first_path = common.normalize_path(core.root_project().path .. PATHSEP .. "language-mode.txt")
    local first = Doc("language-mode.txt", first_path, true)
    first:set_language_mode("Markdown")

    local state = language_mode.save_workspace_state()
    test.equal(#state.entries, 1)
    test.ok(common.path_equals(state.entries[1].path, first_path))
    test.equal(state.entries[1].mode, "Markdown")

    language_mode.load_workspace_state(nil)
    local automatic = Doc("language-mode.txt", first_path, true)
    test.equal(automatic.syntax.name, "Plain Text")

    language_mode.load_workspace_state(state)
    local restored = Doc("language-mode.txt", first_path, true)
    test.equal(restored.language_mode_override, "Markdown")
    test.equal(restored.syntax.name, "Markdown")
  end)

  test.it("moves a named-file override when the Document is renamed", function()
    local root = core.root_project().path
    local old_path = common.normalize_path(root .. PATHSEP .. "old-name.txt")
    local new_path = common.normalize_path(root .. PATHSEP .. "new-name.txt")
    local doc = Doc("old-name.txt", old_path, true)
    doc:set_language_mode("Lua")

    doc:set_filename("new-name.txt", new_path)
    local state = language_mode.save_workspace_state()
    test.equal(#state.entries, 1)
    test.ok(common.path_equals(state.entries[1].path, new_path))

    language_mode.load_workspace_state(state)
    test.equal(Doc("old-name.txt", old_path, true).syntax.name, "Plain Text")
    test.equal(Doc("new-name.txt", new_path, true).syntax.name, "Lua")
  end)

  test.it("restores an untitled Document override from its view state", function()
    local doc = Doc()
    doc:set_language_mode("Lua")
    local state = DocView(doc):get_state()
    test.equal(state.language_mode, "Lua")

    local restored = DocView.from_state(state)
    test.not_nil(restored)
    test.equal(restored.doc.language_mode_override, "Lua")
    test.equal(restored.doc.syntax.name, "Lua")
  end)

  test.it("sets a mode through the language:set-mode command", function()
    local doc = Doc("command.md", "command.md", true)
    local captured
    local workspace_saves = 0
    core.active_view = { doc = doc }
    core.global_prompt_bar = {
      enter = function(_, label, options)
        captured = { label = label, options = options }
      end,
    }
    core.save_workspace = function() workspace_saves = workspace_saves + 1 end

    test.ok(command.perform("language:set-mode"))
    test.equal(captured.label, "Language Mode")
    local suggestions = captured.options.suggest("Lua")
    local lua_item
    for _, item in ipairs(suggestions) do
      if mode_named("Lua")(item) then lua_item = item; break end
    end
    test.not_nil(lua_item)
    captured.options.submit(lua_item.text, lua_item)

    test.equal(doc.syntax.name, "Lua")
    test.equal(workspace_saves, 1)
  end)
end)
