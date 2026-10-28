-- The Projects that Path Search lists, and their preview. They come from the Project Sidebar's model, so Path Search
-- shows the same Projects, names and states as the Sidebar.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local look = require "core.project_look"
local tab = require "core.tab"

local projects = {}

-- Path Search's order: Scratch, the loaded Projects in the Sidebar's order, then Dormant Projects by last activity.
-- Without a Sidebar model, such as outside the shell, the recent Projects. `opened_at` gives their last open times.
function projects.list(recent, opened_at)
  local model = core.project_sidebar
  if not model then
    local root = core.root_project and core.root_project()
    local out = {}
    for _, path in ipairs(recent) do
      local loaded = root and common.path_equals(root.path, path)
      out[#out + 1] = {path = path, state = loaded and "ready" or "dormant", exists = true, activity = opened_at[path]}
    end
    return out
  end
  local scratch, loaded, dormant, order = {}, {}, {}, {}
  for index, project in ipairs(model) do
    local list = project.scratch and scratch or project.state == "dormant" and dormant or loaded
    list[#list + 1], order[project] = project, index
  end
  table.sort(dormant, function(a, b)
    local a_activity, b_activity = look.activity(a), look.activity(b)
    if a_activity ~= b_activity then return a_activity > b_activity end
    return order[a] < order[b]
  end)
  local out = {}
  for _, list in ipairs {scratch, loaded, dormant} do
    for _, project in ipairs(list) do out[#out + 1] = project end
  end
  return out
end

-- The Sidebar record of a Project result. A result without one, such as a static result, gets a Dormant record.
function projects.of(result)
  return result.sidebar or {path = result.path or result.project, state = "dormant", exists = true}
end

-- The Sidebar record of this Project. Without a Sidebar model, such as outside the shell, a record of its path.
function projects.current()
  local root = core.root_project and core.root_project()
  if not root then return nil end
  for _, project in ipairs(core.project_sidebar or {}) do
    if common.path_equals(project.path, root.path) then return project end
  end
  return {path = root.path, state = "ready", exists = true, scratch = core.is_scratch_project(root.path)}
end

-- The Window that shows this Project, so its rows name only other Windows.
function projects.own_window()
  local project = projects.current()
  return project and project.window_id
end

-- What a Project row shows after the name: a Dormant Project's running Terminal Sessions, or a loaded Project's
-- Tab count, then the Sidebar's note.
function projects.details(project, now)
  local hint
  if project.state == "dormant" then
    hint = look.terminal_hint(project)
  elseif #(project.panes or {}) > 0 then
    local count = #project.panes
    hint = count .. (count == 1 and " tab" or " tabs")
  end
  return hint, look.note(project, projects.own_window(), now)
end

local bold_fonts = setmetatable({}, {__mode = "k"})
function projects.bold(font)
  if not bold_fonts[font] then bold_fonts[font] = font:copy(font:get_size(), {bold = true}) end
  return bold_fonts[font]
end

-- The chip at the left of the query: the Project's badge and name, at most `max_width` wide.
local function chip_name(project, max_width)
  local bold = projects.bold(style.font)
  return bold, tab.fit(bold, look.name(project), max_width - style.font:get_height() - style.padding.x / 2)
end

function projects.chip_width(project, max_width)
  local bold, name = chip_name(project, max_width)
  return style.font:get_height() + style.padding.x / 2 + bold:get_width(name)
end

function projects.draw_chip(project, x, y, max_width)
  local bold, name = chip_name(project, max_width)
  local size = style.font:get_height()
  look.draw_badge(project, x, y, size, bold, style.card)
  renderer.draw_text(bold, name, x + size + style.padding.x / 2, y + math.floor((size - bold:get_height()) / 2),
    style.text)
end

-- The Tabs and the Terminal Sessions that no Pane shows, as the Sidebar lists them under an expanded Project.
-- A Dormant Project has no Tabs, so it lists its running Terminal Sessions.
local function items(project)
  local out, records, shown = {}, {}, {}
  for _, terminal in ipairs(project.terminals or {}) do records[terminal.id] = terminal end
  for _, pane in ipairs(project.panes or {}) do
    local item = {}
    for field, value in pairs(pane) do item[field] = value end
    local record = pane.terminal and records[pane.terminal.session]
    if record then
      shown[record.id] = true
      if record.state == "running" then item.agent = tab.agent(record) end
    end
    out[#out + 1] = item
  end
  for _, terminal in ipairs(project.terminals or {}) do
    if not shown[terminal.id] and terminal.state == "running" then out[#out + 1] = tab.describe_session(terminal) end
  end
  return out
end

-- The preview: the Project's row at a larger size, its folder, and its Tabs and Terminal Sessions.
function projects.draw_preview(project, x, y, w, h)
  local pad, now = style.padding.x, os.time()
  local font, bold = style.font, projects.bold(style.font)
  local line = font:get_height()
  core.push_clip_rect(x, y, w, h)
  local bottom = y + h
  x, y, w = x + pad, y + pad, w - 2 * pad
  local size = math.floor(line + 3 * SCALE + 0.5)
  look.draw_badge(project, x, y, size, bold, style.background)
  local name_x, name_y = x + size + 8 * SCALE, y + math.floor((size - line) / 2)
  local _, note = projects.details(project, now)
  local note_w = note and font:get_width(note) + pad or 0
  local name_color = project.state == "dormant" and not project.exists and style.dim or style.text
  renderer.draw_text(bold, tab.fit(bold, look.name(project), x + w - note_w - name_x), name_x, name_y, name_color)
  if note then renderer.draw_text(font, note, x + w - font:get_width(note), name_y, style.dim) end
  y = y + size + 6 * SCALE
  local path = common.home_encode and common.home_encode(project.path) or project.path
  renderer.draw_text(font, tab.fit(font, path, w), x, y, style.dim)
  y = y + line + pad
  local row, agent_row = line + 9 * SCALE, 2 * line + 11 * SCALE
  for _, item in ipairs(items(project)) do
    if y >= bottom then break end
    local _, item_x = tab.draw(item, x, y, w, row, {name_color = style.text, now = now})
    if item.agent then tab.draw_agent(item.agent, item_x, y + row - 6 * SCALE, x + w - item_x, row, {now = now}) end
    y = y + (item.agent and agent_row or row)
  end
  core.pop_clip_rect()
end

return projects
