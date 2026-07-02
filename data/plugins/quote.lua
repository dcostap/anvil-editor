-- mod-version:3
local command = require "core.command"
local keymap = require "core.keymap"


local escapes = {
  ["\\"] = "\\\\",
  ["\""] = "\\\"",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["\b"] = "\\b",
}

local function replace(chr)
  return escapes[chr] or string.format("\\x%02x", chr:byte())
end


command.add("core.docview", {
  ["quote:quote"] = function(dv)
    if dv.can_edit and not dv:can_edit("quote", { warn = true }) then return end
    dv.doc:replace(function(text)
      return '"' .. text:gsub("[%z\001-\031\\\"]", replace) .. '"'
    end)
  end,
})

keymap.add {
  ["ctrl+'"] = "quote:quote",
}
