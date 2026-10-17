-- Type file queries into the Fuzzy Searcher over the Project.
-- An action is complete when the target file is a visible result.
-- The first query also waits for the Project's file index.
local core = require "core"
local common = require "core.common"

local scene = {}

-- Fixture paths use "/" on every platform.
local function parts(path)
  local parent, name = path:match("([^/\\]*)[/\\]([^/\\]+)$")
  return parent or "", ((name or path):gsub("%.[^.]*$", ""))
end

function scene.setup(context)
  return core.active_view
end

function scene.action_name(_, index)
  return index == 1 and "first-query" or "query"
end

function scene.dispatch(context, index)
  local targets = context.settings.targets
  local target = targets[(index - 1) % #targets + 1]
  context.target = common.path_compare_key(context.path(target))
  -- The parent folder and the stem identify the file among same-named files.
  local parent, stem = parts(target)
  context.query = parent .. "/" .. stem
  local fuzzy = require "plugins.fuzzy_searcher"
  if not context.picker then
    fuzzy.open(context.query)
    context.picker = assert(core.fuzzy_searcher_active_view, "the Fuzzy Searcher did not open")
  else
    context.picker.input:set_text("")
    context.picker:on_text_input(context.query)
  end
end

function scene.action_ready(context)
  local picker = context.picker
  assert(core.fuzzy_searcher_active_view == picker, "the Fuzzy Searcher closed during a query")
  if picker.input:get_text() ~= context.query then return false end
  local first = picker.viewport_offset or 1
  local rows = picker:list_metrics().result_rows
  for index, result in ipairs(picker.results or {}) do
    local path = result.abs_path or result.file
    if path and common.path_compare_key(path) == context.target then
      if index >= first and index < first + rows then return true, context.query end
      break
    end
  end
  local now = system.get_time()
  if now - (context.logged_at or 0) > 2 then
    context.logged_at = now
    local shown = {}
    for index = first, math.min(#(picker.results or {}), first + 4) do
      local result = picker.results[index]
      shown[#shown + 1] = tostring(result.abs_path or result.file or result.label)
    end
    core.log_quiet("Fuzzy scene: query=%s target=%s results=%d first=%s", context.query,
      context.target, #(picker.results or {}), table.concat(shown, " | "))
  end
  return false
end

return scene
