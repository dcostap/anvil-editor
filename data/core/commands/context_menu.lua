local core = require "core"
local command = require "core.command"
local context_menu = require "core.context_menu"

-- A View offers a Context Menu through `view:context_menu(x, y)`, which returns its items.
-- Without a point, the menu opens at `view:context_menu_point()`, such as the caret.
command.add(function(x, y)
  local view = core.active_view
  if not (view and view.context_menu) then return false end
  if type(x) ~= "number" or type(y) ~= "number" then
    if view.context_menu_point then x, y = view:context_menu_point() end
    x = x or view.position.x + view.size.x / 2
    y = y or view.position.y + view.size.y / 2
    return true, view, x, y, nil
  end
  return true, view, x, y, "right"
end, {
  ["core:show_context_menu"] = function(view, x, y, button)
    context_menu.open(x, y, view:context_menu(x, y), { button = button })
  end,
})
