-- Type into a task note while other notes from the same vault stay open.
-- Each typed character moves a wikilink on the edited line. The other notes
-- do not depend on that, so typing must not make them redo their layout.
local core = require "core"
local support = require "scenes.support"
local vault_index = require "core.markdown.vault_index"

local scene = {}
local TYPED_TEXT = "a b c d e f g h i j "

-- Live Preview is ready when the published parse matches the text and wrapping is complete.
local function preview_ready(view)
  local model = require("core.markdown.model").peek(view.buffer)
  return view.__markdown_live_attached and model and model.status == "ready"
    and model.published_revision == view.buffer.text_revision
    and view.wrapped_settings ~= nil and view.__async_wrap_reconstruction == nil
end

-- Live Preview attaches when a note becomes active, and a note lays out when it is shown.
-- Each note is shown until it is laid out, as a user visits it, before the next opens.
local function open(context, path)
  local view = assert(core.open_file(context.path(path), { placement = "new", focus = true }))
  view:set_wrapping_enabled(true)
  return view
end

local function focus_typing_line(context, view)
  local line = context.settings.line
  local col = assert(view.buffer.lines[line]:find("[[", 1, true), "the typing line has no wikilink")
  view:with_selection_state(function() view.buffer:set_selection(line, col) end)
  view:scroll_to_line(line, false, true)
end

-- The task note opens last, so it is the measured View.
function scene.setup(context)
  context.others, context.pending = {}, {}
  for _, path in ipairs(context.settings.notes) do context.pending[#context.pending + 1] = path end
  context.pending[#context.pending + 1] = context.settings.note
  local view = open(context, table.remove(context.pending, 1))
  context.index = vault_index.index_for_path(view.buffer.abs_filename)
  return view
end

function scene.ready(context)
  if not preview_ready(context.view) then return false end
  if #context.pending == 0 then
    if not context.typing then
      context.typing = true
      focus_typing_line(context, context.view)
    end
    return context.index.status == "ready" and support.background_settled(context)
  end
  context.others[#context.others + 1] = context.view
  context.view = open(context, table.remove(context.pending, 1))
  return false
end

function scene.action_name()
  return "type-char"
end

function scene.dispatch(context, index)
  local view = context.view
  assert(core.active_view == view, "the editor lost input focus")
  context.revision = view.buffer.text_revision
  context.vault_updates = context.index.diagnostics.buffer_updates
  local offset = (index - 1) % #TYPED_TEXT + 1
  core.on_event("textinput", TYPED_TEXT:sub(offset, offset))
end

-- A keystroke completes when Live Preview shows it and the vault index holds
-- the edited note. Waiting for the index paces keys like a typist does, so
-- each one publishes to the vault instead of coalescing with the next.
function scene.action_ready(context)
  local view = context.view
  if view.buffer.text_revision == context.revision or not preview_ready(view) then return false end
  if context.index.diagnostics.buffer_updates == context.vault_updates then return false end
  return true, "typed"
end

function scene.state(context)
  return {
    open_notes = #context.others + 1,
    vault_updates = context.index.diagnostics.buffer_updates,
  }
end

return scene
