local core = require "core"
local command = require "core.command"
local terminal = require "plugins.terminal"
local support = require "scenes.support"
local quick_commands = require "plugins.quick_commands"

local scene = {}

function scene.setup(context)
  context.sessions, context.records = {}, {}
  terminal._set_native_for_tests(require("scenes.quick_command_terminal")(context))
  local shell = terminal.open { cwd = context.root, placement = "current", focus = true }
  context.shell = shell
  shell:service_session(true)
  assert(command.perform("quick_command:set_a"))
  core.global_prompt_bar:set_text("build")
  core.global_prompt_bar:submit()
  if not quick_commands.run(1, { focus = false }) then
    shell:on_close()
    error("Quick Command fixture could not start its command")
  end
  local target = assert(context.settings.targets[1])
  context.sessions[1].capture = "PS> build\n"
    .. string.rep("missing.lua:9:4 ", 22000) .. target .. ":2:1\nPS> "
  local view = assert(core.open_file(context.path(target), { placement = "current", focus = true }))
  view.buffer:set_selection(1, 1)
  context.target = view.buffer
  return view
end

function scene.ready(context)
  return support.background_settled(context)
end

function scene.dispatch(context)
  assert(command.perform("core:next_remote_point_of_interest"))
end

function scene.action_ready(context)
  local view = core.active_view
  local ready = view and view.buffer == context.target and view.buffer:get_selection() == 2
  if ready and not context.closed then
    context.shell:on_close()
    context.closed = true
  end
  return ready,
    "opened the file location after repeated missing paths"
end

return scene
