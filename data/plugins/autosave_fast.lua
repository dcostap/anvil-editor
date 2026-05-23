-- mod-version:3
local core = require "core"
local Doc = require "core.doc"
local command = require "core.command"
-- this is used to detect the wait time
local last_keypress = system.get_time()
-- this exists so that we don't end up with multiple copies of the loop running at once
local looping = false
local on_text_change = Doc.on_text_change

local autosave_fast = {
  enabled = true,
  -- the approximate amount of time, in seconds, that it takes to trigger an autosave
  timeout = 0.5,
}


local function loop_for_save()
    while looping do
      if system.get_time() - last_keypress >= autosave_fast.timeout then
        command.perform "doc:save"
        -- stop loop
        looping = false
      end
      -- wait a short interval so sub-second timeouts work.
      coroutine.yield(math.min(autosave_fast.timeout, 0.1))
    end
end


local function updatepress()
  -- set last keypress time to now
  last_keypress = system.get_time()
  -- put loop in coroutine so it doesn't lag out this script
  if not looping then
    looping = true
    core.add_thread(loop_for_save)
  end
end


function Doc:on_text_change(type)
  -- check if file is saved
  if autosave_fast.enabled and self.filename
    and self.abs_filename ~= system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
    and self.abs_filename ~= system.absolute_path(".anvil_project.lua")
    then
    updatepress()
  end
  return on_text_change(self, type)
end
