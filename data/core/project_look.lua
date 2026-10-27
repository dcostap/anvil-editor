-- How a Project row identifies a Project: its name, its coloured badge, and a note about its state.
-- The Project Sidebar and Path Search both use it, so a Project looks the same in both.
-- `project` is a record of the Project Sidebar model.
local style = require "core.style"
local tab = require "core.tab"

local look = {}

function look.name(project)
  if project.scratch then return "Scratch" end
  return project.path:match("([^/\\]+)[/\\]*$") or project.path
end

-- The latest activity of the Project or of one of its Terminal Sessions.
function look.activity(project)
  local activity = project.activity or 0
  for _, terminal in ipairs(project.terminals or {}) do
    activity = math.max(activity, terminal.activity or 0)
  end
  return activity
end

-- The colour of the dot on the badge, and the note for that state, or nil when the state needs no mark.
function look.status(project)
  if project.state == "failed" then return style.error, "failed" end
  if project.state == "dormant" then
    if not project.exists then return style.error, "unavailable" end
    return nil
  end
  if project.close_choice or project.deferred_dialog then return style.warn, "needs answer" end
  if project.state == "starting" then return style.warn, "starting" end
  if project.state == "closing" then return style.warn, "closing" end
  return nil
end

-- The note at the right of a Project row: its state, else the other Window that holds it, else a Dormant Project's
-- age. `window_id` is the viewer's Window.
function look.note(project, window_id, now)
  local _, note = look.status(project)
  if not note and project.window_id and project.window_id ~= 0 and window_id and project.window_id ~= window_id then
    note = "Window " .. project.window_id
  end
  if not note and project.state == "dormant" then note = tab.age_text(look.activity(project), now) end
  return note
end

-- The running Terminal Sessions of an unloaded Project, such as "3 terminals, 1 busy, 1 needs you", or nil when
-- none run. An agent that waits at its prompt is not busy. Shorter forms follow for a narrow row.
function look.terminal_hint(project)
  local running, busy, blocked = 0, 0, 0
  for _, terminal in ipairs(project.terminals or {}) do
    if terminal.state == "running" then
      running = running + 1
      local agent = tab.agent(terminal)
      if agent and agent.state == "blocked" then
        blocked = blocked + 1
      elseif tab.working(tab.describe_session(terminal).terminal, agent) then
        busy = busy + 1
      end
    end
  end
  if running == 0 then return nil end
  local count = running .. (running == 1 and " terminal" or " terminals")
  local needs = blocked > 0 and ", " .. blocked .. " needs you" or ""
  return count .. (busy > 0 and ", " .. busy .. " busy" or "") .. needs, count .. needs, count
end

-- One of the theme's bright terminal colours, chosen by the Project's name, so the Project keeps its colour in
-- every theme.
local function badge_color(name)
  local palette = style.terminal_palette
  local hash = 0
  for i = 1, #name do hash = (hash * 31 + name:byte(i)) % 65521 end
  return palette and palette[10 + hash % 6] or style.accent
end

local function initial(name)
  local first = name:match("[%w]") or name:match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
  return first:upper()
end

local function tint(color, alpha)
  return {color[1], color[2], color[3], alpha}
end

local function dot(x, cy, radius, color)
  renderer.draw_rounded_rect(x - radius, cy - radius, radius * 2, radius * 2, radius, color)
end

-- The badge: the name's initial in a square of the Project's colour, dimmer for a Dormant Project, and a dot for
-- its status. `bold` draws the letter. A ring in `background` separates the dot from the badge.
function look.draw_badge(project, x, y, size, bold, background)
  local name = look.name(project)
  local color = badge_color(name)
  local strength = project.state == "dormant" and 0.55 or 1
  renderer.draw_rounded_rect(x, y, size, size, math.floor(size * 0.3), tint(color, 64 * strength))
  -- The letter's ink centres in the badge. Its line box has room for descenders, so centring the line would put a
  -- capital too high.
  local letter = initial(name)
  local ink_top, ink_bottom = bold:get_ink_extent(letter)
  local ly = ink_top and y + (size - ink_top - ink_bottom) / 2 or y + (size - bold:get_height()) / 2
  renderer.draw_text(bold, letter, x + math.floor((size - bold:get_width(letter)) / 2), math.floor(ly + 0.5),
    tint(color, 255 * strength))
  local status = look.status(project)
  if status then
    dot(x + size - SCALE, y + size - SCALE, 5 * SCALE, background)
    dot(x + size - SCALE, y + size - SCALE, 3.5 * SCALE, status)
  end
end

return look
