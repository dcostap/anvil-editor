local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local style = require "core.style"
local test = require "core.test"

local function ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

local function make_view(context, text)
  local buffer = Buffer("blank-background.md", nil, true)
  buffer:insert(1, 1, text)
  local view = Editor(buffer)
  context.views[#context.views + 1] = view
  view.size.x, view.size.y = 900, 600
  core.active_view = view
  buffer:set_selection(2, 1)
  markdown.live_render.refresh_view(view)
  ready(view)
  for _, entry in ipairs(view:decoration_provider_entries()) do
    if entry.id == "markdown-live" then return view, buffer, entry.provider end
  end
  error("Markdown Live Preview decoration is missing")
end

test.describe("Markdown blank line backgrounds", function()
  test.before_each(function(context)
    context.active, context.live = core.active_view, config.markdown_live_editor
    context.views = {}
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view, config.markdown_live_editor = context.active, context.live
  end)

  test.it("does not paint blank lines after a preview-only nested bullet", function(context)
    local view, buffer, decoration = make_view(context,
      "- test\n- test2\n    - \n                - test\n\n\n\n\n\n")
    test.equal(decoration:line_background(view, 4), nil)
    for line = 5, #buffer.lines do
      test.equal(decoration:line_background(view, line), nil,
        "trailing blank line " .. line .. " has a code background")
    end

    buffer:set_selection(2, #buffer.lines[2])
    view:on_text_input("x")
    test.equal(test.not_nil(model.peek(buffer)).status, "pending")
    for line = 5, #buffer.lines do
      test.equal(decoration:line_background(view, line), nil,
        "pending blank line " .. line .. " has a code background")
    end
    ready(view)
    for line = 5, #buffer.lines do
      test.equal(decoration:line_background(view, line), nil,
        "published blank line " .. line .. " has a code background")
    end
  end)

  test.it("keeps blank lines inside actual indented code painted", function(context)
    local view, _, decoration = make_view(context,
      "intro\n\n    first\n\n    second\nplain")
    test.equal(decoration:line_background(view, 3), style.markdown_live_code_background)
    test.equal(decoration:line_background(view, 4), style.markdown_live_code_background)
    test.equal(decoration:line_background(view, 5), style.markdown_live_code_background)
  end)
end)
