-- Isolate preview replacement from search ranking. Use real picker commands.
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local model = require "core.markdown.model"
local TextView = require "core.textview"
local scene = {}

local function current(context)
  local picker = context.picker
  local view = picker and picker.preview_view
  local result = picker and picker:selected_result()
  if not (view and view.buffer and result) or picker.preview_loading_buffer
    or picker.preview_probe and picker.preview_probe.pending
    or view.buffer.abs_filename ~= result.file
    or picker.preview_target_line ~= (result.line or 1)
  then return nil end
  return view
end

local function presented(context, view, line)
  if context.settings.source then return true end
  local semantic = model.peek(view.buffer)
  local plan = view:get_line_render(line)
  if not (semantic and semantic.status == "ready" and plan
    and plan.markdown_semantic_revision == view.buffer.text_revision) then return false end
  for _, fragment in ipairs(view:iter_line_render_fragments(plan)) do
    if fragment.hidden then return true end
  end
  return false
end

function scene.setup(context)
  config.fuzzy_searcher_markdown_preview = not context.settings.source
  config.plugins.terminal.prepare_session = false
  config.plugins.terminal.prepare_pi = false
  context.results = {}
  local section = "## Section\n\nA paragraph with **strong text**, *emphasis*, `code`, and a [link](https://example.com).\n\n- First item\n- Second item\n\n> A quoted paragraph.\n\nPlain text ends this section.\n"
  for index = 1, 9 do
    local path = context.root .. PATHSEP .. string.format("preview-%02d.md", index)
    local file = assert(io.open(path, "wb"))
    file:write("# Preview ", index, "\n\n", section:rep(context.settings.sections or 8))
    file:close()
    context.results[index] = { kind = "file", file = path, text = path }
  end
  if context.settings.same_file then
    for index = 1, 9 do
      context.results[index] = { kind = "file", file = context.results[1].file,
        text = "Section", line = 3 + (index - 1) * 10 }
    end
  end
  -- Install once. Observe the selected line's actual committed presentation.
  local draw = TextView.draw_line_text
  TextView.draw_line_text = function(view, line, ...)
    local result = draw(view, line, ...)
    if view == current(context) and line == (context.picker:selected_result().line or 1)
      and presented(context, view, line)
    then
      context.drawn_serial = context.serial
    end
    return result
  end
  context.setup_at = system.get_time()
  return core.active_view
end

function scene.ready(context)
  if not context.picker then
    if system.get_time() - context.setup_at < 3 then return false end
    require("plugins.fuzzy_searcher").open_static_results("Preview", context.results)
    context.picker = assert(core.fuzzy_searcher_active_view)
    context.serial = 0
    return false
  end
  local view = current(context)
  return view and context.picker.open_transition_complete and context.drawn_serial == 0
    and (context.settings.source or view.wrapped_settings and not view.__async_wrap_reconstruction)
end

function scene.action_name(context, index)
  if context.settings.burst then return "navigation-burst" end
  if context.settings.same_file then return "prepared-location" end
  return index <= 8 and "first-visit" or "return"
end

local function move(context, index)
  context.serial = context.serial + 1
  assert(command.perform(index <= 8 and "fuzzy:next" or "fuzzy:previous"))
end

function scene.dispatch(context, index)
  move(context, index)
  if context.settings.burst then
    context.burst_step, context.next_move = 1, system.get_time() + 0.02
  end
end

function scene.action_ready(context)
  if context.settings.burst and context.burst_step < 12 then
    if system.get_time() >= context.next_move then
      context.burst_step = context.burst_step + 1
      move(context, context.burst_step)
      context.next_move = system.get_time() + 0.02
    end
    return false
  end
  local view = current(context)
  return view ~= nil, "selected=" .. context.picker.selected
end

function scene.action_drawn(context)
  return context.drawn_serial == context.serial
end

scene.action_visible = scene.action_drawn

function scene.state(context)
  local view = assert(current(context))
  assert(context.drawn_serial == context.serial, "selected Markdown did not draw")
  return { selected = context.picker.selected, lines = #view.buffer.lines }
end

return scene
