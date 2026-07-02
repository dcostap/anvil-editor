local core = require "core"
local command = require "core.command"
local common = require "core.common"
local StatusBar = require "core.statusbar"

local function status_bar_item_names()
  local items = core.status_bar:get_items_list()
  local names = {}
  for _, item in ipairs(items) do
    table.insert(names, item.name)
  end
  return names
end

local function status_bar_items_data(names)
  local data = {}
  for _, name in ipairs(names) do
    local item = core.status_bar:get_item(name)
    table.insert(data, {
      text = command.prettify_name(item.name),
      info = item.alignment == StatusBar.Item.LEFT and "Left" or "Right",
      name = item.name
    })
  end
  return data
end

local function status_bar_get_items(text)
  local names = status_bar_item_names()
  local results = common.fuzzy_match(names, text)
  results = status_bar_items_data(results)
  return results
end

command.add_toggle("status-bar:toggle", {
  get = function()
    return core.status_bar.visible
  end,
  set = function(enabled)
    if enabled then core.status_bar:show() else core.status_bar:hide() end
  end,
})

command.add_toggle("status-bar:toggle-messages", {
  get = function()
    return not core.status_bar.hide_messages
  end,
  set = function(enabled)
    core.status_bar:display_messages(enabled)
  end,
})

command.add(nil, {
  ["status-bar:hide-item"] = function()
    core.global_prompt_bar:enter("Status bar item to hide", {
      submit = function(text, item)
        core.status_bar:hide_items(item.name)
      end,
      suggest = status_bar_get_items
    })
  end,
  ["status-bar:show-item"] = function()
    core.global_prompt_bar:enter("Status bar item to show", {
      submit = function(text, item)
        core.status_bar:show_items(item.name)
      end,
      suggest = status_bar_get_items
    })
  end,
  ["status-bar:reset-items"] = function()
    core.status_bar:show_items()
  end,
})
