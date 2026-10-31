-- Real completion searches over a large, ready Odin index. No completion provider is faked.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local autocomplete = require "plugins.autocomplete"
local symbol_index = require "core.treesitter.symbol_index"
local registry = require "core.treesitter.registry"
local support = require "scenes.support"

local scene = {}
local PREFIX = "latency_completion_"
local TARGET = PREFIX .. "target"
local BURST_TARGET = "burst_" .. string.rep("x", 31) .. "_t"

local function parse_ready(buffer)
  return buffer.treesitter and buffer.treesitter.status == "ready"
end

function scene.setup(context)
  local mode = context.settings.mode
  assert(mode == "type" or mode == "members" or mode == "refresh" or mode == "burst")
  -- Fixture construction is not timed. A busy machine can suspend a worker past
  -- its normal query deadline even for these small generated source files.
  context.index_language = assert(registry.get(context.path("main.odin"), ""))
  context.outline_timeout = context.index_language.outline_query_timeout_ms
  context.usages_timeout = context.index_language.usages_query_timeout_ms
  context.index_language.outline_query_timeout_ms = 1000
  context.index_language.usages_query_timeout_ms = 1000
  local view = assert(core.open_file(context.path("main.odin"), { placement = "current", focus = true }))
  local buffer = view.buffer
  context.query = mode == "members" and "LatencyMode"
    or mode == "burst" and "burst_" or PREFIX .. "t"
  view:with_selection_state(function()
    buffer:set_selection(5, 1, 5, math.huge)
    buffer:text_input("    " .. context.query)
  end)
  view:scroll_to_line(1, false, true)
  autocomplete.close()
  symbol_index.ensure_scan(context.root)
  -- Observe the production draw paths. A changed Buffer alone is not a visible result.
  local draw_line_text = view.draw_line_text
  view.draw_line_text = function(self, line, ...)
    local result = draw_line_text(self, line, ...)
    if line == 5 then context.drawn_revision = self.buffer.text_revision end
    return result
  end
  local draw = autocomplete.draw
  autocomplete.draw = function(active, ...)
    local result = draw(active, ...)
    if active == view then
      local item = autocomplete.get_selected_suggestion()
      context.drawn_suggestion = item and item.text
      context.suggestion_revision = buffer.text_revision
      if parse_ready(buffer) then context.parsed_suggestion_revision = buffer.text_revision end
    end
    return result
  end
  return view
end

function scene.ready(context)
  local index = symbol_index.status(context.root)
  if index.symbol_status ~= "ready" or not index.native_snapshot or not parse_ready(context.view.buffer) then
    return false
  end
  local summary = index.native_snapshot:summary()
  local worker = index.diagnostics and index.diagnostics.worker
  assert(worker and worker.files_skipped == 0, string.format(
    "completion fixture index skipped source files: %s (%s)",
    tostring(worker and worker.first_skipped_reason), tostring(worker and worker.first_skipped_path)))
  assert(summary.symbols >= context.settings.symbols, "completion fixture did not index its symbol library")
  context.indexed_symbols = summary.symbols
  if not support.background_settled(context) then return false end
  if context.index_language then
    context.index_language.outline_query_timeout_ms = context.outline_timeout
    context.index_language.usages_query_timeout_ms = context.usages_timeout
    context.index_language = nil
  end
  return true
end

function scene.action_name(context, index)
  local mode = context.settings.mode
  if mode == "members" then
    return ({ "member-dot", "member-type", "member-backspace", "remove-receiver-dot" })[(index - 1) % 4 + 1]
  end
  if mode == "burst" then
    if index % 2 == 0 then return "burst-backspace" end
    return index % 4 == 1 and "burst-match" or "burst-no-match"
  end
  if mode == "type" then return index % 2 == 1 and "type-char" or "backspace" end
  return mode .. (index % 2 == 1 and "-type" or "-backspace")
end

function scene.dispatch(context, index)
  local view, mode = context.view, context.settings.mode
  assert(core.active_view == view, "completion input lost its Editor")
  context.drawn_suggestion, context.suggestion_revision = nil, nil
  context.parsed_suggestion_revision = nil
  context.drawn_revision = nil
  if mode == "refresh" and index % 2 == 1 then autocomplete.close() end
  context.no_matches = false
  context.expected = mode == "burst" and BURST_TARGET or TARGET
  local text, count = "a", 1
  local deleting = index % 2 == 0
  if mode == "members" then
    local phase = (index - 1) % 4 + 1
    deleting = phase >= 3
    text = phase == 1 and "." or "R"
    context.expected = "READY"
    if phase == 4 then context.expected = nil end
  elseif mode == "burst" then
    context.no_matches = index % 4 == 3
    text, count = context.no_matches and "z" or "x", 30
    if deleting or context.no_matches then context.expected = nil end
  end
  for _ = 1, count do
    if deleting then
      assert(command.perform("core:backspace"), "completion input did not delete text")
      context.query = context.query:sub(1, -2)
    else
      core.on_event("textinput", text)
      context.query = context.query .. text
    end
  end
  assert(view.buffer.lines[5] == "    " .. context.query .. "\n", "completion lost or changed typed text")
  context.revision = view.buffer.text_revision
end

function scene.action_ready(context)
  local buffer = context.view.buffer
  if not parse_ready(buffer) or autocomplete.is_pending() then return false end
  local item = autocomplete.get_selected_suggestion()
  if context.no_matches and autocomplete.is_open() then return false end
  if context.expected then
    if not item or item.text ~= context.expected or not item.icon then return false end
    local expected_path = context.path("library/targets.odin")
    assert(item.source_path and common.path_equals(item.source_path, expected_path),
      "completion did not use its real symbol source")
  end
  return true, context.expected or "text-updated"
end

function scene.action_drawn(context)
  if context.suggestion_revision ~= context.revision then return false end
  if context.expected and context.drawn_suggestion ~= context.expected then return false end
  if context.no_matches and context.drawn_suggestion ~= nil then return false end
  return context.settings.mode ~= "refresh" or context.parsed_suggestion_revision == context.revision
end

function scene.action_visible(context)
  return context.drawn_revision == context.revision
end

function scene.state(context)
  return { indexed_symbols = context.indexed_symbols, query = context.query,
    selected = context.drawn_suggestion or "", mode = context.settings.mode }
end

return scene
