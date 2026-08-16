-- mod-version:3
local command = require "core.command"
local keymap = require "core.keymap"

local findfile = {}

command.add(nil, {
  ["core:find-file"] = function()
    require("plugins.fuzzy_searcher").open("")
  end,
})

keymap.add({
  [PLATFORM == "Mac OS X" and "cmd+p" or "ctrl+p"] = "core:find-file",
})

return findfile
