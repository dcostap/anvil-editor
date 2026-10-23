local command = require "core.command"
local keymap = require "core.keymap"

command.add("core.global_prompt_bar", {
  ["core:submit_prompt"] = function(active_view)
    active_view:submit()
  end,

  ["core:complete_prompt"] = function(active_view)
    active_view:complete()
  end,

  ["core:close_prompt"] = function(active_view)
    active_view:exit()
  end,

  ["core:select_previous_prompt_item"] = function(active_view)
    -- Visible lists run downward; hidden history keeps older entries on Up.
    active_view:move_suggestion_idx(active_view.state.show_suggestions and -1 or 1)
  end,

  ["core:select_next_prompt_item"] = function(active_view)
    active_view:move_suggestion_idx(active_view.state.show_suggestions and 1 or -1)
  end,
})

keymap.add {
  ["alt+r"] = "core:submit_prompt",
}
