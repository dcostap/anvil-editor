-- End-to-end Text Search on a real generated Project. Every action waits for
-- completion, including no-match and rapid query replacement.
local core = require "core"
local support = require "scenes.support"
local fuzzy = require "plugins.fuzzy_searcher"

local scene = {}
local ROWS = 2400
local cases = {
  { "#anvil_cafe", ROWS, "exact" },
  { "#anvil_café", ROWS, "exact" },
  { '#"anvil_cafe niño"', ROWS, "exact" },
  { "#anvil_cafe niño", ROWS, "fuzzy" },
  { "#anvil_cafe nino", 0, "fuzzy" },
  { "#anvil_missing_accent_result", 0, "exact" },
  { "#anvil_c", ROWS, "exact" },
  { "#anvil_cafe", ROWS, "exact", burst = true },
}

function scene.setup(context)
  local path = context.path(context.settings.targets[1])
  local file = assert(io.open(path, "wb"))
  local forms = { "anvil_café niño", "anvil_cafe nin\204\131o", "anvil_cafe\204\129 niño" }
  for i = 1, ROWS do file:write("-- ", forms[(i - 1) % #forms + 1], " ", tostring(i), "\n") end
  file:close()
  return assert(core.open_file(path, { placement = "current", focus = true }))
end

function scene.ready(context)
  if not context.picker then
    if not (support.git_settled(context.root, true) and support.background_settled(context)) then return false end
    fuzzy.open("#anvil_cafe")
    context.picker = assert(core.fuzzy_searcher_active_view)
    return false
  end
  return not context.picker:search_running() and context.picker.status == ROWS .. " exact matches"
end

function scene.action_name(_, index)
  local case = cases[(index - 1) % #cases + 1]
  return case.burst and "replace-query" or case[1]
end

function scene.dispatch(context, index)
  local case = cases[(index - 1) % #cases + 1]
  context.case = case
  local picker = context.picker
  if case.burst then
    for _, query in ipairs { "#anvil_", "#anvil_missing_accent_result" } do
      picker.input:set_text(query)
      picker:refresh(query)
    end
  end
  picker.input:set_text(case[1])
  picker:refresh(case[1])
end

function scene.action_ready(context)
  local picker, case = context.picker, context.case
  if picker:search_running() or picker.dirty or picker.loading_feedback_pending
    or (picker.status or ""):find("…", 1, true) then return false end
  local status = case[2] == 0 and "No " .. case[3] .. " matches"
    or case[2] .. " " .. case[3] .. " matches"
  assert(picker.status == status, case[1] .. ": " .. tostring(picker.status))
  if case[2] == 0 then assert(#picker.results == 0, "an old query supplied rows")
  else
    assert(#picker.results > 0, "the search has no rows")
    local result = picker:selected_result()
    assert(result and result.text:find("-- anvil_", 1, true), "unexpected source row")
    if case[3] == "exact" then
      local span = assert(result.content_selection_span, "missing selection")
      assert(span[1] == 4 and span[2] <= #result.text, "selection is outside the original text")
    end
  end
  return true, picker.status
end

return scene
