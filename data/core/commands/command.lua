local command = require "core.command"

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
    active_view:move_suggestion_idx(1)
  end,

  ["core:select_next_prompt_item"] = function(active_view)
    active_view:move_suggestion_idx(-1)
  end,
})
