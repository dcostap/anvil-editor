local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Editor = require "core.editor"
local panes = require "core.panes"
local test = require "core.test"
local treesitter = require "core.treesitter"
local autocomplete = require "plugins.autocomplete"

local method = "setVisibleAndLoadInitialSize"

local function wait_until(predicate, message)
  local deadline = system.get_time() + 3
  repeat
    if predicate() then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail(message)
end

local function wait_ready(buffer)
  wait_until(function()
    treesitter.poll_buffer(buffer)
    return buffer.treesitter and buffer.treesitter.status == "ready"
  end, "expected Kotlin parsing to finish")
end

local function open_editor(context)
  local path = core.root_project().path .. PATHSEP .. "completion-parse-" .. system.get_process_id()
    .. "-" .. math.floor(system.get_time() * 1000000) .. ".txt"
  context.path = path
  local file = assert(io.open(path, "wb"))
  file:write("object MainWindow {\n  private fun " .. method .. "() {\n    setvisib\n  }\n}\n")
  file:close()
  local buffer = core.open_buffer(path)
  context.buffer = buffer
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view:with_selection_state(function() buffer:set_selection(3, 13) end)
  return view, buffer
end

test.describe("completion after parsing", function()
  test.before_each(function(context)
    context.scope = config.plugins.autocomplete.suggestions_scope
    context.active_view = core.active_view
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    autocomplete.close()
    panes.reset_for_tests()
    if context.buffer then
      context.buffer:clean()
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == context.buffer then table.remove(core.buffers, i) end
      end
      context.buffer:on_close()
    end
    if context.path then
      os.remove(context.path)
      os.remove(context.path .. ".kt")
    end
    config.plugins.autocomplete.suggestions_scope = context.scope
    if context.active_view then core.set_active_view(context.active_view) end
  end)

  for _, words in ipairs({ true, false }) do
    local name = words and "replaces a Buffer word with symbol details after parsing"
      or "shows symbols after parsing when no Buffer word was available"
    test.it(name, function(context)
      config.plugins.autocomplete.suggestions_scope = words and "local" or "none"
      local view, buffer = open_editor(context)
      if words then
        -- Learn the word through the ordinary text completion source first.
        wait_until(function()
          core.set_active_view(view)
          autocomplete.open()
          local item = autocomplete.get_selected_suggestion()
          return item and item.text == method
        end, "expected Buffer Word Completion to learn the method name")
        autocomplete.close()
      end
      buffer:set_filename(context.path .. ".kt", context.path .. ".kt")
      wait_ready(buffer)
      core.set_active_view(view)

      core.root_panel:on_text_input("l")
      wait_ready(buffer)
      core.root_panel:update()

      local item = test.not_nil(autocomplete.get_selected_suggestion(), "expected completion after parsing")
      test.equal(item.text, method)
      test.not_nil(item.icon, "expected a symbol icon after parsing")
      test.contains(item.preview_text, method)
    end)
  end

  test.it("shows current Buffer members after parsing a receiver dot", function(context)
    config.plugins.autocomplete.suggestions_scope = "local"
    local view, buffer = open_editor(context)
    buffer:replace(function()
      return "object MainWindow {\n  fun " .. method .. "() {}\n}\nfun main() {\n    setvisib\n}\n"
    end)
    view:with_selection_state(function() buffer:set_selection(5, 13) end)
    wait_until(function()
      core.set_active_view(view)
      autocomplete.open()
      local item = autocomplete.get_selected_suggestion()
      return item and item.text == method
    end, "expected Buffer Word Completion to learn the method name")
    autocomplete.close()
    buffer:set_filename(context.path .. ".kt", context.path .. ".kt")
    wait_ready(buffer)
    core.set_active_view(view)
    view:with_selection_state(function() buffer:set_selection(5, 5, 5, 13) end)
    core.root_panel:on_text_input("MainWindow.")
    test.not_ok(autocomplete.is_open(), "a receiver dot must not show unrelated Buffer words while parsing")
    wait_ready(buffer)
    core.root_panel:update()
    local item = test.not_nil(autocomplete.get_selected_suggestion(), "expected member completion after parsing")
    test.equal(item.text, method)
    test.contains(item.preview_text, "MainWindow." .. method)
  end)

  for _, action in ipairs({ "close", "move caret", "change View" }) do
    test.it("does not reopen completion after " .. action, function(context)
      config.plugins.autocomplete.suggestions_scope = "none"
      local view, buffer = open_editor(context)
      buffer:set_filename(context.path .. ".kt", context.path .. ".kt")
      wait_ready(buffer)
      core.set_active_view(view)
      core.root_panel:on_text_input("l")
      if action == "close" then
        test.ok(command.perform("autocomplete:cancel"), "expected cancellation while completion waits for parsing")
      elseif action == "move caret" then
        test.ok(command.perform("core:move_to_start_of_line"))
      else
        -- A second Editor can show the same Buffer and caret.
        panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      end
      core.root_panel:update()
      wait_ready(buffer)
      core.root_panel:update()
      test.not_ok(autocomplete.is_open(), "a completed parse must not restore a dismissed completion")
    end)
  end
end)
