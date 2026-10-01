local config = require "core.config"
local core = require "core"
local BufferRegistry = require "core.buffer_registry"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local panes = require "core.panes"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function save_view(view)
  return { module = view:get_module(), state = view:get_state() }
end

local function load_view(saved)
  return require(saved.module).from_state(saved.state)
end

local function visible_text(view, line)
  local rendered = view:get_line_render(line)
  if not rendered or rendered.raw_passthrough then
    return (view.buffer.lines[line] or ""):gsub("\n$", "")
  end
  local text = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(rendered)) do
    if not fragment.hidden then text[#text + 1] = fragment.text or "" end
  end
  return table.concat(text)
end

local function restore_markdown(context, source_mode)
  local markdown_view = Editor(core.open_buffer(context.markdown_path))
  markdown_view:set_selection_state { selections = { 3, 1, 3, 1 }, last_selection = 1 }
  markdown.live_render.set_source_mode(markdown_view, source_mode)
  local markdown_pane = panes.create { factory = function() return markdown_view end }
  local other = Editor(core.open_buffer(context.text_path))
  local focused = panes.split(markdown_pane, "right", { factory = function() return other end })
  panes.focus(focused)
  local state = panes.save_workspace_state(save_view)

  test.ok(panes.restore_workspace_state(state, load_view))
  local restored = panes.ordered()[1].current_view
  restored.size.x, restored.size.y = 500, 200
  test.equal(core.active_view, panes.ordered()[2].current_view)
  test.equal(core.active_view.buffer.abs_filename, context.text_path)
  return restored
end

test.describe("Markdown workspace restoration", function()
  test.before_each(function(context)
    context.old_buffers, context.old_registry = core.buffers, core.buffer_registry
    context.old_active_view = core.active_view
    context.old_enabled = config.markdown_live_editor
    panes.reset_for_tests()
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    config.markdown_live_editor = true
    local prefix = USERDIR .. PATHSEP .. "markdown-workspace-" .. system.get_process_id()
    context.markdown_path = system.absolute_path(prefix .. ".md")
    context.text_path = system.absolute_path(prefix .. ".txt")
    for path, text in pairs({
      [context.markdown_path] = "# Title\n**bold**\nplain\n",
      [context.text_path] = "other Pane\n",
    }) do
      local file = test.not_nil(io.open(path, "wb"))
      file:write(text)
      file:close()
    end
  end)

  test.after_each(function(context)
    panes.close_all { force = true }
    panes.reset_for_tests()
    core.buffers, core.buffer_registry = context.old_buffers, context.old_registry
    core.active_view = context.old_active_view
    config.markdown_live_editor = context.old_enabled
    os.remove(context.markdown_path)
    os.remove(context.text_path)
  end)

  test.it("renders restored Markdown while another Pane keeps focus", function(context)
    local restored = restore_markdown(context, false)
    test.ok(markdown.live_render.is_live_mode(restored), "restored Markdown must not require focus")
    local instance = test.not_nil(markdown.model.peek(restored.buffer))
    local deadline = system.get_time() + 5
    while instance.status ~= "ready" and system.get_time() < deadline do
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      coroutine.yield(0.01)
    end
    test.equal(instance.status, "ready", instance.reason)
    test.equal(visible_text(restored, 1), "Title")
    test.equal(visible_text(restored, 2), "bold")
    test.equal(core.active_view, panes.ordered()[2].current_view)
  end)

  test.it("keeps restored Markdown Source Mode while another Pane keeps focus", function(context)
    local restored = restore_markdown(context, true)
    test.ok(markdown.live_render.is_source_mode(restored))
    test.equal(visible_text(restored, 1), "# Title")
    test.equal(visible_text(restored, 2), "**bold**")
    test.equal(core.active_view, panes.ordered()[2].current_view)
  end)
end)
