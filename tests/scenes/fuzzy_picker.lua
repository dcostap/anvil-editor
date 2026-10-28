-- Use the Fuzzy Searcher with its preview over another View, as a user does.
-- Settings:
--   mode    "files", "symbols" or "text": the search mode.
--   query   the query to search for. A "type" action types it one character at a time.
--   behind  "filetree" or "editor": the View that the picker covers.
--   action  "navigate" moves the selection; "type" types the query again and again.
-- A "navigate" action is complete when the preview shows the newly selected result.
-- A "type" action is complete when the search for the new text has ended and its preview shows.
-- Text Search ends the action at its first rows, because it can search for a long time.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local support = require "scenes.support"

local scene = {}
local PREFIXES = { files = "", symbols = "$", text = "#" }
-- Moves down this many rows, then back up, so the selection stays among the first results.
local NAVIGATE_STEPS = 8

local function prefix(context)
  return assert(PREFIXES[context.settings.mode or "files"], "unknown Fuzzy Searcher mode")
end

local function picker()
  return core.fuzzy_searcher_active_view
end

-- Each running search shows a status that ends with "…".
local function search_settled(view, text)
  if view.input:get_text() ~= text then return false end
  if view.dirty or view.force_refresh or view.loading_feedback_pending or view.loading_more then return false end
  if view.symbol_search_request then return false end
  local status = view.status or ""
  return status:sub(-#"…") ~= "…"
end

-- Text Search shows its first rows while it still searches, so a user sees results then.
-- Each new Text Search clears `own_results` and sets it with its first match.
local function results_shown(context, view)
  if search_settled(view, context.text) then return true end
  if context.settings.mode ~= "text" or view.input:get_text() ~= context.text then return false end
  if view.dirty or view.force_refresh then return false end
  return view.own_results ~= nil and #view.results > 0
end

local function preview_ready(view)
  local result = view:selected_result()
  if not result or not result.file or result.is_folder or view.preview_blocked then return true end
  local preview = view.preview_view
  if not preview or view.preview_loading_buffer then return false end
  local target = common.clamp(result.line or 1, 1, #preview.buffer.lines)
  return view.preview_target_line == target
end

local function open_behind(context)
  local settings = context.settings
  if settings.behind == "editor" then
    local path = context.path(settings.targets[1])
    return assert(core.open_file(path, { placement = "current", focus = true }))
  end
  local view = support.open_file_tree(context.root)
  context.rows = support.expand_file_tree(view, settings.rows or 600, settings.max_level or 3)
  view:scroll_to_line(1, false, true)
  return view
end

function scene.setup(context)
  return open_behind(context)
end

-- The picker opens after the Project's scans and indexes finish, so a search
-- does not wait for them. Then the first search and its preview must show.
function scene.ready(context)
  if not context.picker then
    if not (support.git_settled(context.root, true) and support.background_settled(context)) then return false end
    local fuzzy = require "plugins.fuzzy_searcher"
    fuzzy.open(prefix(context))
    context.picker = assert(picker(), "the Fuzzy Searcher did not open")
    context.text = prefix(context) .. context.settings.query
    context.picker.input:set_text("")
    context.picker:on_text_input(context.text)
    return false
  end
  local view = context.picker
  if not view.open_transition_complete or not search_settled(view, context.text) then return false end
  if #view.results < NAVIGATE_STEPS + 1 then
    error(string.format("the query %q found %d results", context.text, #view.results))
  end
  return preview_ready(view)
end

local function navigate_down(index)
  return (index - 1) % (2 * NAVIGATE_STEPS) < NAVIGATE_STEPS
end

function scene.action_name(context, index)
  if context.settings.action == "type" then return "type-char" end
  return navigate_down(index) and "next" or "previous"
end

function scene.dispatch(context, index)
  local view = context.picker
  assert(picker() == view, "the Fuzzy Searcher closed")
  if context.settings.action == "type" then
    -- Each pass types the whole query after the mode prefix.
    local query = context.settings.query
    local offset = (index - 1) % #query + 1
    -- A new pass clears the input and types the prefix with the first character, as `ready` does.
    -- The picker drops a prefix that is set alone.
    local typed = query:sub(offset, offset)
    if offset == 1 then
      view.input:set_text("")
      typed = prefix(context) .. typed
    end
    context.text = prefix(context) .. query:sub(1, offset)
    view:on_text_input(typed)
    return
  end
  local before = view.selected
  assert(command.perform(navigate_down(index) and "fuzzy:next" or "fuzzy:previous"),
    "the Fuzzy Searcher did not accept the move")
  assert(view.selected ~= before, "the selection did not move")
  context.selected = view.selected
end

function scene.action_ready(context)
  local view = context.picker
  assert(picker() == view, "the Fuzzy Searcher closed")
  if context.settings.action == "type" then
    if not results_shown(context, view) or not preview_ready(view) then return false end
    return true, string.format("%s:%d", context.text, #view.results)
  end
  if view.selected ~= context.selected or not preview_ready(view) then return false end
  local result = view:selected_result()
  return true, result and (result.label or result.name or result.file) or "none"
end

function scene.state(context)
  local view = context.picker
  return { rows = context.rows, results = view and #view.results or 0, selected = view and view.selected or 0 }
end

return scene
