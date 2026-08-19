local core = require "core"
local command = require "core.command"
local common = require "core.common"

command.add("core.nagview", {
  ["core:select_previous_dialog_entry"] = function(v)
    local hover = v.hovered_item or 1
    v:change_hovered(hover == 1 and #v.options or hover - 1)
  end,
  ["core:select_next_dialog_entry"] = function(v)
    local hover = v.hovered_item or 1
    v:change_hovered(hover == #v.options and 1 or hover + 1)
  end,
  ["core:select_dialog_yes"] = function(v)
    if v ~= core.nag_view then return end
    v:change_hovered(common.find_index(v.options, "default_yes"))
    command.perform "core:select_dialog_entry"
  end,
  ["core:select_dialog_no"] = function(v)
    if v ~= core.nag_view then return end
    v:change_hovered(common.find_index(v.options, "default_no"))
    command.perform "core:select_dialog_entry"
  end,
  ["core:select_dialog_entry"] = function(v)
    if v.hovered_item then
      v.on_selected(v.options[v.hovered_item])
      v:next()
    end
  end
})
