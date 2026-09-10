local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

require "core.commands.text"

local function ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function check_completion(view, line, text, checked)
  local visible = {}
  for _, fragment in ipairs(view:get_line_render(line).fragments) do
    if not fragment.hidden and not fragment.widget and fragment.text ~= "" then
      visible[#visible + 1] = fragment.text
      test.equal(fragment.strikethrough == true, checked,
        "task text changed its completion style on line " .. line)
    end
  end
  test.equal(table.concat(visible), text)
end

test.describe("Markdown task completion during edits", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    if context.other_view then context.other_view:on_close() end
    if context.view then
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
    core.active_view, config.markdown_live_editor = context.active, context.live
  end)

  for _, wrapped in ipairs({ false, true }) do
    test.it("keeps the completed item struck through when Enter adds a checkbox / "
      .. (wrapped and "wrapped" or "unwrapped"), function(context)
      local filename = USERDIR .. PATHSEP .. "markdown-task-completion.md"
      local buffer = Buffer(filename, filename, true)
      buffer:insert(1, 1, "- [x] completed item\n\nplain")
      buffer:clear_undo_redo()
      local view = Editor(buffer)
      context.view = view
      view.size.x, view.size.y = wrapped and 100 or 700, 600
      view:set_wrapping_enabled(wrapped)
      core.active_view = view
      buffer:set_selection(1, #buffer.lines[1])
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(model.peek(buffer))
      ready(instance)
      core.set_active_view(view)
      check_completion(view, 1, "completed item", true)

      test.ok(command.perform("core:newline"))
      test.equal(buffer.lines[1], "- [x] completed item\n")
      test.equal(buffer.lines[2], "- [ ] \n")
      test.equal(instance.status, "pending")
      check_completion(view, 1, "completed item", true)
      view:on_text_input("new item")
      test.equal(instance.status, "pending")
      check_completion(view, 1, "completed item", true)
      check_completion(view, 2, "new item", false)
      local other = Editor(buffer)
      context.other_view = other
      other.size.x, other.size.y = view.size.x, view.size.y
      other:set_wrapping_enabled(wrapped)
      markdown.live_render.refresh_view(other)
      check_completion(other, 1, "completed item", true)
      ready(instance)
      check_completion(other, 1, "completed item", true)
      check_completion(view, 1, "completed item", true)
      check_completion(view, 2, "new item", false)
    end)

    test.it("keeps completion style when a new checkbox moves the completed item / "
      .. (wrapped and "wrapped" or "unwrapped"), function(context)
      local filename = USERDIR .. PATHSEP .. "markdown-task-completion.md"
      local buffer = Buffer(filename, filename, true)
      buffer:insert(1, 1, "- [x] completed item\n\nplain")
      local view = Editor(buffer)
      context.view = view
      view.size.x, view.size.y = wrapped and 100 or 700, 600
      view:set_wrapping_enabled(wrapped)
      buffer:set_selection(3, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(model.peek(buffer))
      ready(instance)
      check_completion(view, 1, "completed item", true)
      buffer:insert(1, 1, "- [ ] new item\n")
      test.equal(instance.status, "pending")
      check_completion(view, 2, "completed item", true)
      ready(instance)
      check_completion(view, 2, "completed item", true)
    end)
  end
end)
