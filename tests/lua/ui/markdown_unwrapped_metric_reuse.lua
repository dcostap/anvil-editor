local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready")
end

local function make_view(context, text)
  local buffer = Buffer("unwrapped-metrics-" .. #context.views .. ".md", nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 900, 700
  view:set_wrapping_enabled(false)
  markdown.live_render.refresh_view(view)
  ready(view)
  return view, buffer
end

local function geometry(view)
  local positions = {}
  for line = 1, #view.buffer.lines do
    local _, y = view:get_line_screen_position(line, 1)
    positions[line] = y
  end
  return positions
end

test.describe("Markdown unwrapped metrics after edits", function()
  test.before_each(function(context)
    context.views = {}
    context.active = core.active_view
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view = context.active
    config.markdown_live_editor = context.live
  end)

  local cases = {
    {
      name = "updates the paragraph above a new setext underline",
      text = "Paragraph above\nnext\n\nafter one\nafter two\n",
      line = 2, replacement = "---",
    },
    {
      name = "updates lines below a new fence opener",
      text = "alpha\nbeta\ngamma\ndelta\n",
      line = 1, replacement = "```",
    },
  }

  for _, case in ipairs(cases) do
    test.it(case.name, function(context)
      local view, buffer = make_view(context,
        case.text .. string.rep("filler paragraph line\n\n", 40))
      geometry(view)
      core.active_view = view
      view:with_selection_state(function()
        buffer:set_selection(case.line, 1, case.line, #buffer.lines[case.line])
        buffer:text_input(case.replacement)
      end)
      ready(view)
      -- Use the same caret position to compare formatted text, not source reveal.
      view:with_selection_state(function() buffer:set_selection(#buffer.lines, 1) end)
      ready(view)
      local actual = geometry(view)
      local fresh = make_view(context, table.concat(buffer.lines):sub(1, -2))
      fresh:with_selection_state(function()
        fresh.buffer:set_selection(#fresh.buffer.lines, 1)
      end)
      ready(fresh)
      local expected = geometry(fresh)
      test.equal(#actual, #expected)
      for line = 1, #expected do
        test.equal(actual[line], expected[line], "line " .. line .. " screen y")
      end
    end)
  end
end)
