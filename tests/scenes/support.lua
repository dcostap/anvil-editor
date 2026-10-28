-- Shared setup and readiness helpers for scenes.
-- Scenario runs and Lua tests use the same helpers, so both reach a state the same way.
local core = require "core"
local common = require "core.common"
local command = require "core.command"

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

---Put the caret on the last line that `view` shows, so each move down scrolls it,
---as when the user holds an arrow key.
function support.caret_to_bottom(view)
  local line = view:resolve_screen_position(view.position.x + view.size.x / 2,
    view.position.y + view.size.y - view:get_line_height())
  view:with_selection_state(function() view.buffer:set_selection(line, 1) end)
  return line
end

---Move the caret one line with the editor's command. Returns the line it left.
function support.move_caret(view, down)
  local line = view.buffer:get_selection()
  assert(command.perform(down and "core:move_to_next_line" or "core:move_to_previous_line"),
    "the view did not accept the caret move")
  return line
end

---Return the kinds of queued or running worker jobs, or nil when every pool is idle.
function support.busy_workers()
  local worker_pool = package.loaded["core.worker_pool"]
  if not worker_pool then return nil end
  local kinds
  for _, pool in ipairs(worker_pool.open_pools()) do
    -- Pools keep a small record of finished jobs so their status stays readable.
    for _, job in pairs(pool.jobs) do
      if job.finished_at then goto continue end
      kinds = kinds or {}
      local kind = job.handle and job.handle.kind or job.spec and job.spec.kind
      kinds[#kinds + 1] = string.format("%s:%s#%s(%s)", pool.name, tostring(kind), tostring(job.id),
        tostring(job.status))
      ::continue::
    end
  end
  return kinds
end

---Report whether background work has been idle for `seconds` (2 by default), such as the
---startup file scan and indexes. A Project that keeps polling settles after `limit`.
function support.background_settled(context, seconds, limit)
  local now = system.get_time()
  context.settle_started = context.settle_started or now
  local busy = support.busy_workers()
  if busy then
    context.idle_since = nil
  else
    context.idle_since = context.idle_since or now
  end
  if context.idle_since and now - context.idle_since >= (seconds or 2) then
    core.log_quiet("Scene: background work settled after %.1f s", now - context.settle_started)
    return true
  end
  if now - context.settle_started >= (limit or 60) then
    if not context.settle_timed_out then
      context.settle_timed_out = true
      core.log_quiet("Scene: background work did not settle within %.0f s: %s", limit or 60,
        table.concat(busy or {}, ", "))
    end
    return true
  end
  return false
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
