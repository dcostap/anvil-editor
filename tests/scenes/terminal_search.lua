-- Measure Text Search through a real Terminal's large history, including no matches.
local core = require "core"
local config = require "core.config"
local panes = require "core.panes"
local terminal = require "plugins.terminal"
local fuzzy = require "plugins.fuzzy_searcher"
local support = require "scenes.support"

local scene = {}
local cases = {
  { "#anvil_term_cafe", "1200 exact matches" },
  { "#anvil_term_café", "1200 exact matches" },
  { "#anvil_term_cafe niño", "1200 fuzzy matches" },
  { "#anvil_term_nino", "No exact matches" },
  { "#anvil_term_missing", "No exact matches" },
}

function scene.setup(context)
  local previous_limit = config.plugins.terminal.scrollback_lines
  config.plugins.terminal.scrollback_lines = 20000
  local view = assert(terminal.open {
    cwd = context.root,
    shell = [[powershell.exe -NoLogo -NoProfile -NoExit -Command "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); for ($i=1; $i -le 12000; $i++) { $text='history row'; if ($i % 10 -eq 0) { switch ($i % 30) { 0 { $text='anvil_term_café niño' } 10 { $text='anvil_term_cafe'+[char]0x301+' niño' } 20 { $text='anvil_term_cafe nin'+[char]0x303+'o' } } }; [Console]::WriteLine($text+' '+$i) }; [Console]::WriteLine('ANVIL_TERM_SEARCH_READY')"]],
  })
  local quit = core.quit
  core.quit = function(...)
    core.quit = quit
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.close(panes.pane_for_view(view), { force = true })
    config.plugins.terminal.scrollback_lines = previous_limit
    return quit(...)
  end
  return view
end

function scene.ready(context)
  if not context.picker then
    local session = context.view.session
    local text = session and session:plain_text()
    if not text or not text:find("ANVIL_TERM_SEARCH_READY", 1, true)
      or not support.background_settled(context) then return false end
    fuzzy.open(cases[1][1])
    context.picker = assert(core.fuzzy_searcher_active_view)
    return false
  end
  return not context.picker:search_running() and context.picker.status == cases[1][2]
end

function scene.action_name(_, index)
  return cases[(index - 1) % #cases + 1][1]
end

function scene.dispatch(context, index)
  context.case = cases[(index - 1) % #cases + 1]
  context.picker.input:set_text(context.case[1])
  context.picker:refresh(context.case[1])
end

function scene.action_ready(context)
  local picker = context.picker
  if picker:search_running() or picker.dirty or picker.loading_feedback_pending
    or (picker.status or ""):find("…", 1, true) then return false end
  assert(picker.status == context.case[2], context.case[1] .. ": " .. tostring(picker.status))
  if context.case[2] == "No exact matches" then
    assert(#picker.results == 0, "an old query supplied rows")
  else
    assert(#picker.results > 0, "the search has no rows")
    for _, result in ipairs(picker.results) do
      assert(result.terminal and result.terminal.id == context.view.session_id, "unexpected search source")
      assert(result.text:find("anvil_term_", 1, true), "unexpected Terminal text")
    end
  end
  return true, picker.status
end

return scene
