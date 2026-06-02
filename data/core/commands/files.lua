local core = require "core"
local command = require "core.command"
local common = require "core.common"

command.add(nil, {
  ["files:create-directory"] = function()
    core.global_prompt_bar:enter("New directory name", {
      submit = function(text)
        local directory = common.home_expand(common.sanitize_prompt_path(text))
        local success, err, path = common.mkdirp(directory)
        if not success then
          core.error("cannot create directory %q: %s", path, err)
        else
          command.perform("filetree:sync-path", system.absolute_path(directory) or directory)
        end
      end
    })
  end,
})
