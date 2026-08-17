-- mod-version:3
local command = require "core.command"

local findfile = {}

command.add(nil, {
  ["core:find-file"] = function()
    require("plugins.fuzzy_searcher").open("")
  end,
})

return findfile
