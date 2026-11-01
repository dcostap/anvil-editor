local core = require "core"
local command = require "core.command"
local common = require "core.common"

command.add(nil, {
  ["core:create_directory"] = function()
    core.global_prompt_bar:enter("New directory name", {
      submit = function(text)
        local directory = common.home_expand(common.sanitize_prompt_path(text))
        local fs = require "core.fs"
        local file_ops = require "core.file_ops"
        -- This process's folder is not on the Machine, so a relative name starts at the Project.
        if fs.machine and not common.is_absolute_path(directory) then
          directory = core.project_absolute_path(directory)
        end
        file_ops.run(directory, function()
          local success, err, path = file_ops.mkdirp(directory)
          if not success then
            core.error("cannot create directory %q: %s", path, err)
          else
            command.perform("filetree:sync_path",
              not fs.on_machine(directory) and system.absolute_path(directory) or directory)
          end
        end)
      end
    })
  end,
})
