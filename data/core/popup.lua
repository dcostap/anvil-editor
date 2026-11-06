local common = require "core.common"

---Placement and hit testing for popups: cards that float over a host, such as the Context Menu and the
---autocomplete list. The host has `position` and `size`: the Root Panel, or a Project Sidebar's surface.
---In a hosted shell, the Root Panel is the Project's area right of the Sidebar. The shell shows the Sidebar
---over the Project's surface left of that area, so a popup that left its host would show under the Sidebar.
local popup = {}

---True when the point is inside the rectangle `{x, y, w, h}`.
---@param rect table?
---@param x number
---@param y number
function popup.contains(rect, x, y)
  return rect ~= nil and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end

---The host's area: x, y, w, h.
function popup.bounds(host)
  return host.position.x, host.position.y, host.size.x, host.size.y
end

---Places a popup of size w, h with its top left corner near (x, y), inside the host and `margin` from its edges.
---A popup that does not fit right of x goes left of `flip_x` instead, or left of x without it.
---A popup wider than the host gets the host's width. Returns x, y, w.
function popup.place(host, x, y, w, h, flip_x, margin)
  local bx, by, bw, bh = popup.bounds(host)
  margin = margin or 0
  w = math.max(0, math.min(w, bw - margin * 2))
  if x + w > bx + bw - margin then x = (flip_x or x) - w end
  x = common.clamp(x, bx + margin, bx + bw - margin - w)
  if y + h > by + bh - margin then y = by + bh - margin - h end
  y = math.max(y, by + margin)
  return x, y, w
end

return popup
