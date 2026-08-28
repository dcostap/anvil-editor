local command = require "core.command"
local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local language_mode = require "core.language_mode"
local syntax = require "core.syntax"
local test = require "core.test"
local untitled = require "plugins.untitled_tabs"

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
    context.original_clipboard = system.get_clipboard()
    context.original_cursor_clipboard = core.cursor_clipboard
    context.original_cursor_clipboard_whole_line = core.cursor_clipboard_whole_line
    language_mode.load_workspace_state(nil)
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    core.global_prompt_bar = context.original_global_prompt_bar
    core.save_workspace = context.original_save_workspace
    system.set_clipboard(context.original_clipboard or "")
    core.cursor_clipboard = context.original_cursor_clipboard
    core.cursor_clipboard_whole_line = context.original_cursor_clipboard_whole_line
    for _, buffer in ipairs(context.buffers or {}) do buffer:on_close() end
    language_mode.load_workspace_state(nil)
  end)

  local function new_untitled_editor(context)
    local buffer = untitled.tag_buffer(Buffer(nil, nil, true))
    local editor = Editor(buffer)
    context.buffers = context.buffers or {}
    context.buffers[#context.buffers + 1] = buffer
    core.set_active_view(editor)
    return buffer, editor
  end

  local function paste(text)
    system.set_clipboard(text)
    core.cursor_clipboard = { full = "different" }
    core.cursor_clipboard_whole_line = {}
    return command.perform("core:paste")
  end

  test.it("overrides filename detection until Automatic is selected", function()
    local buffer = Buffer("notes.md", "notes.md", true)
    test.equal(buffer.syntax.name, "Markdown")

    test.ok(buffer:set_language_mode("Lua"))
    test.equal(buffer.language_mode_override, "Lua")
    test.equal(buffer.syntax.name, "Lua")

    buffer:reset_syntax()
    test.equal(buffer.syntax.name, "Lua")

    test.ok(buffer:set_language_mode(nil))
    test.is_nil(buffer.language_mode_override)
    test.equal(buffer.syntax.name, "Markdown")
  end)

  test.it("round-trips named-file overrides through Project Workspace state", function()
    local first_path = common.normalize_path(core.root_project().path .. PATHSEP .. "language-mode.txt")
    local first = Buffer("language-mode.txt", first_path, true)
    first:set_language_mode("Markdown")

    local state = language_mode.save_workspace_state()
    test.equal(#state.entries, 1)
    test.ok(common.path_equals(state.entries[1].path, first_path))
    test.equal(state.entries[1].mode, "Markdown")

    language_mode.load_workspace_state(nil)
    local automatic = Buffer("language-mode.txt", first_path, true)
    test.equal(automatic.syntax.name, "Plain Text")

    language_mode.load_workspace_state(state)
    local restored = Buffer("language-mode.txt", first_path, true)
    test.equal(restored.language_mode_override, "Markdown")
    test.equal(restored.syntax.name, "Markdown")
  end)

  test.it("moves a named-file override when the Buffer is renamed", function()
    local root = core.root_project().path
    local old_path = common.normalize_path(root .. PATHSEP .. "old-name.txt")
    local new_path = common.normalize_path(root .. PATHSEP .. "new-name.txt")
    local buffer = Buffer("old-name.txt", old_path, true)
    buffer:set_language_mode("Lua")

    buffer:set_filename("new-name.txt", new_path)
    local state = language_mode.save_workspace_state()
    test.equal(#state.entries, 1)
    test.ok(common.path_equals(state.entries[1].path, new_path))

    language_mode.load_workspace_state(state)
    test.equal(Buffer("old-name.txt", old_path, true).syntax.name, "Plain Text")
    test.equal(Buffer("new-name.txt", new_path, true).syntax.name, "Lua")
  end)

  test.it("restores an untitled Buffer override from its view state", function()
    local buffer = Buffer()
    buffer:set_language_mode("Lua")
    local state = Editor(buffer):get_state()
    test.equal(state.language_mode, "Lua")

    local restored = Editor.from_state(state)
    test.not_nil(restored)
    test.equal(restored.buffer.language_mode_override, "Lua")
    test.equal(restored.buffer.syntax.name, "Lua")
  end)

  test.it("restores an inferred Language Mode from Untitled view state", function()
    local buffer = Buffer(nil, nil, true)
    buffer:insert(1, 1, '{"restored":true}')
    language_mode.set_buffer_inference(buffer, "JSON")
    local state = Editor(buffer):get_state()
    test.equal(state.inferred_language_mode, "JSON")

    local restored = Editor.from_state(state)
    test.not_nil(restored)
    test.equal(restored.buffer.language_mode_inferred, "JSON")
    test.equal(restored.buffer.syntax.name, "JSON")
  end)

  test.it("infers JSON from a complete Untitled Buffer paste", function(context)
    local buffer = new_untitled_editor(context)
    test.ok(language_mode.can_infer_complete_paste(buffer))

    test.ok(paste('{"name":"Anvil","enabled":true}'))

    local detected, confidence = syntax.detect_content(buffer:get_text(1, 1, math.huge, math.huge))
    test.equal(detected and detected.name, "JSON")
    test.equal(confidence, 1)
    test.equal(buffer.language_mode_inferred, "JSON")
    test.equal(buffer.syntax.name, "JSON")
  end)

  test.it("does not infer a Language Mode from typing or a partial paste", function(context)
    local buffer, editor = new_untitled_editor(context)
    editor:on_text_input('{"typed":true}')
    test.equal(buffer.syntax.name, "Plain Text")

    buffer:set_selection(1, 2)
    test.ok(paste('{"pasted":true}'))

    test.is_nil(buffer.language_mode_inferred)
    test.equal(buffer.syntax.name, "Plain Text")
  end)

  test.it("does not infer a Language Mode for a named Buffer", function(context)
    local buffer = Buffer("pasted.txt", "pasted.txt", true)
    local editor = Editor(buffer)
    context.buffers = context.buffers or {}
    context.buffers[#context.buffers + 1] = buffer
    core.set_active_view(editor)

    test.ok(paste('{"named":true}'))

    test.is_nil(buffer.language_mode_inferred)
    test.equal(buffer.syntax.name, "Plain Text")
  end)

  test.it("redetects after a paste replaces the complete Untitled Buffer", function(context)
    local buffer = new_untitled_editor(context)
    test.ok(paste('{"kind":"json"}'))
    test.equal(buffer.syntax.name, "JSON")

    test.ok(command.perform("core:select_all"))
    test.ok(paste('<?xml version="1.0"?><root/>'))
    test.equal(buffer.language_mode_inferred, "XML")
    test.equal(buffer.syntax.name, "XML")

    test.ok(command.perform("core:select_all"))
    test.ok(paste("ordinary prose"))
    test.is_nil(buffer.language_mode_inferred)
    test.equal(buffer.syntax.name, "Plain Text")
  end)

  test.it("keeps inferred and explicit Language Modes sticky", function(context)
    local buffer = new_untitled_editor(context)
    test.ok(paste('{"kind":"json"}'))
    buffer:insert(1, 1, "not json ")
    test.equal(buffer.syntax.name, "JSON")

    buffer:set_language_mode("Markdown")
    test.ok(command.perform("core:select_all"))
    test.ok(paste('{"still":"explicit"}'))
    test.equal(buffer.language_mode_override, "Markdown")
    test.equal(buffer.syntax.name, "Markdown")

    buffer:set_language_mode(nil)
    test.equal(buffer.syntax.name, "JSON")
  end)

  test.it("sets a mode through the language:set-mode command", function()
    local buffer = Buffer("command.md", "command.md", true)
    local captured
    local workspace_saves = 0
    core.active_view = { buffer = buffer }
    core.global_prompt_bar = {
      enter = function(_, label, options)
        captured = { label = label, options = options }
      end,
    }
    core.save_workspace = function() workspace_saves = workspace_saves + 1 end

    test.ok(command.perform("editor:set_language_mode"))
    test.equal(captured.label, "Language Mode")
    local suggestions = captured.options.suggest("Lua")
    local lua_item
    for _, item in ipairs(suggestions) do
      if mode_named("Lua")(item) then lua_item = item; break end
    end
    test.not_nil(lua_item)
    captured.options.submit(lua_item.text, lua_item)

    test.equal(buffer.syntax.name, "Lua")
    test.equal(workspace_saves, 1)
  end)
end)
