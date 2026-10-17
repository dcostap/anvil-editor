-- Shared setup and readiness helpers for scenes.
-- Scenario runs and Lua tests use the same helpers, so both reach a state the same way.
local core = require "core"
local common = require "core.common"

local support = {}

---Return the context a scene module receives.
---@param settings table scene settings; `root` is the fixture root
---@param root string?
function support.context(settings, root)
  local context = { settings = settings or {}, root = root or (settings and settings.root) }
  function context.path(relative)
    return context.root .. PATHSEP .. relative:gsub("[/\\]", PATHSEP)
  end
  return context
end

---Wait inside a coroutine until `predicate` returns a truthy value.
---Tests use this. Scenario runs check `ready` once per frame instead.
function support.wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 10)
  while true do
    local value = predicate()
    if value then return value end
    if system.get_time() > deadline then error(message or "scene wait timed out", 2) end
    coroutine.yield(0.01)
  end
end

function support.scroll_settled(view)
  local scroll = view and view.scroll
  return not scroll or (math.abs(scroll.y - scroll.to.y) < 0.5 and math.abs(scroll.x - scroll.to.x) < 0.5)
end

---Move the pointer to the center of `view`, as a user does before scrolling it.
function support.hover(view)
  local x = view.position.x + view.size.x / 2
  local y = view.position.y + view.size.y / 2
  core.on_event("mousemoved", x, y, 0, 0)
end

---Send wheel ticks through the window event path. Positive ticks scroll down.
function support.wheel(ticks)
  core.on_event("mousewheel", -ticks, 0)
end

function support.git_settled(path, is_directory)
  local git_status = package.loaded["plugins.file_git_status"]
  return not git_status or git_status:is_settled(path, is_directory)
end

---Open a File Tree at `root` in the current Pane and focus it.
function support.open_file_tree(root)
  local filetree = require "plugins.filetree"
  local view = assert(filetree.open(root, { placement = "current", focus = true }))
  core.set_active_view(view)
  return view
end

---Expand File Tree folders breadth-first, up to `max_level`, until it shows `rows` rows.
function support.expand_file_tree(view, rows, max_level)
  local level = 0
  while #view.buffer.lines < rows and level <= max_level do
    local line = 1
    while line <= #view.buffer.lines and #view.buffer.lines < rows do
      local entry = view:entry_for_line(line)
      local meta = view.line_meta[line]
      if entry and entry.type == "dir" and entry.level == level
          and not (type(meta) == "table" and meta.expanded) then
        view:expand_folder(line, entry, false)
      end
      line = line + 1
    end
    level = level + 1
  end
  return #view.buffer.lines
end

---Report whether every visible File Tree folder has its file count.
function support.file_tree_counts_ready(view)
  local folder_counts = require "plugins.folder_counts"
  local show_hidden = require("core.config").plugins.filetree.show_hidden
  local first, last = view:get_visible_line_range()
  for line = first, last do
    local entry = view:entry_for_line(line)
    local info = entry and entry.cached_info
    if entry and entry.type == "dir" and info then
      local _, pending = folder_counts.get(entry.abs, info.modified, show_hidden)
      if pending then return false end
    end
  end
  return true
end

function support.basename(path)
  return common.basename(path)
end

return support
