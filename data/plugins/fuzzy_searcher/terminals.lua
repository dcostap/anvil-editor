-- Text Search also searches the plain text of Terminal Sessions. A Terminal that this Project shows gives its live
-- text. Another Terminal gives the screen that its host saved last, which can be some seconds old. A worker reads
-- that file, so the search does not wait for it on the UI thread. Line N of a text is row N - 1 from the top of
-- the Terminal's scrollback.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local panes = require "core.panes"
local tab = require "core.tab"

local terminals = {}

-- Each text by Terminal Session ID, while a Text Search uses it. A saved text stays until its file changes.
local texts = {}

-- Rows past this length are long output, such as encoded data. File search skips such lines too.
local MAX_LINE = 1200
-- The longest wait for saved texts before a search continues without them.
local READ_TIMEOUT = 3

local function snapshot_path(id)
  return USERDIR .. "/terminal-sessions/" .. id .. ".snapshot"
end

-- The Terminal Sessions to search: each one that the Project Sidebar lists for this Project, and each Terminal View
-- of this Project. `item` describes the Terminal as a Tab does.
function terminals.sessions()
  local live = {}
  for _, view in ipairs(require("plugins.terminal").open_views()) do
    if view.session_id and view.session then live[view.session_id] = view end
  end
  local out, seen = {}, {}
  local function add(id, project, item)
    if not id or seen[id] then return end
    seen[id] = true
    out[#out + 1] = {id = id, project = project, item = item, view = live[id]}
  end
  local root = core.root_project and core.root_project()
  for _, project in ipairs(core.project_sidebar or {}) do
    if root and common.path_equals(project.path, root.path) then
      for _, pane in ipairs(project.panes or {}) do
        if pane.terminal then add(pane.terminal.session, project.path, pane) end
      end
      for _, record in ipairs(project.terminals or {}) do
        if record.state == "running" then add(record.id, project.path, tab.describe_session(record)) end
      end
    end
  end
  for id, view in pairs(live) do
    local pane = panes.pane_for_view(view)
    if pane then add(id, root and root.path, tab.describe(pane)) end
  end
  return out
end

-- The text of a session: at once for a live Terminal, else an entry that is `pending` until a worker reads the
-- saved screen. A text that cannot be read is `failed`.
local function read(session)
  local view = session.view
  if view and view.session then
    -- Output changes the generation, so an unchanged Terminal keeps its text.
    local generation = view.session:stats().render_generation
    local entry = texts[session.id]
    if entry and entry.view == view and entry.generation == generation then return entry end
    local text = view.session:plain_text()
    entry = text and {text = text, view = view, generation = generation} or {failed = true}
    texts[session.id] = entry
    return entry
  end
  local path = snapshot_path(session.id)
  local info = system.get_file_info(path)
  if not info or not session.project then return {failed = true} end
  local stamp = tostring(info.modified) .. ":" .. tostring(info.size)
  local entry = texts[session.id]
  if entry and entry.stamp == stamp then return entry end
  entry = {stamp = stamp, pending = true}
  texts[session.id] = entry
  local _, err = require("core.worker_pool").system():submit {
    kind = "terminal-text", native = true, native_kind = "terminal_snapshot_text",
    native_payload = {path = path, text = session.project, value = session.id},
    on_result = function(message)
      -- The pool also reports the job's end here, without a value.
      if message.type == "result" then entry.text, entry.pending = message.value or "", nil end
    end,
    on_error = function(message)
      entry.failed, entry.pending = true, nil
      core.log_quiet("Text Search: cannot read the saved screen of Terminal Session %s: %s", session.id,
        tostring(message.error))
    end,
  }
  if err then
    entry.failed, entry.pending = true, nil
    core.log_quiet("Text Search: cannot start reading Terminal Session %s: %s", session.id, tostring(err))
  end
  return entry
end

-- The byte offset where each line of the text starts.
local function line_starts(entry)
  if entry.starts then return entry.starts end
  local starts, text, position = {1}, entry.text, 1
  while true do
    local newline = text:find("\n", position, true)
    if not newline then break end
    position = newline + 1
    starts[#starts + 1] = position
  end
  entry.starts = starts
  return starts
end

local function line_at(starts, offset)
  local low, high = 1, #starts
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    if starts[middle] <= offset then low = middle else high = middle - 1 end
  end
  return low
end

-- The text of line `line`, without its line end.
function terminals.line(entry, line)
  local starts = line_starts(entry)
  local first = starts[line]
  if not first then return nil end
  local last = starts[line + 1] and starts[line + 1] - 2 or #entry.text
  return (entry.text:sub(first, last):gsub("\r$", ""))
end

-- Calls `add(source)` for each line of the session's text that `matcher` accepts, up to `limit` lines. A source
-- has the fields of a ripgrep line, and `terminal` for the Terminal it came from. Yields to keep frames short.
local function find(session, entry, matcher, add, limit)
  local seed = matcher.seed
  if not seed or seed == "" then return end
  local haystack, needle = entry.text, seed
  if not matcher.case_sensitive then
    entry.lower = entry.lower or entry.text:lower()
    haystack, needle = entry.lower, seed:lower()
  end
  local starts, position, count = line_starts(entry), 1, 0
  -- The find card searches for the seed. Each matching line contains it, also for a query of several words.
  local terminal = {id = session.id, project = session.project, item = session.item, entry = entry, query = seed}
  local name = tab.display_name(session.item)
  local slice = system.get_time()
  while count < limit do
    local found = haystack:find(needle, position, true)
    if not found then break end
    local line = line_at(starts, found)
    position = starts[line + 1] or #haystack + 1
    local text = terminals.line(entry, line)
    local match = #text <= MAX_LINE and matcher.match(text)
    if match then
      count = count + 1
      add({kind = "grep", file = name, abs_path = "terminal:" .. session.id, terminal = terminal,
        line = line, col = match.content_match_start or 1, text = text})
    end
    if system.get_time() - slice > 0.004 then
      coroutine.yield(0)
      slice = system.get_time()
    end
  end
end

-- Searches every Terminal Session for `matcher` and calls `add(source)` for each matching line. Runs in a thread
-- and returns when it searched each text that arrived in time. `alive()` returning false stops it.
function terminals.search(matcher, add, alive, limit)
  local pending = {}
  for _, session in ipairs(terminals.sessions()) do pending[#pending + 1] = session end
  local deadline = system.get_time() + READ_TIMEOUT
  while #pending > 0 and alive() do
    local waiting = {}
    for _, session in ipairs(pending) do
      local entry = read(session)
      if entry.pending then
        waiting[#waiting + 1] = session
      elseif entry.text then
        find(session, entry, matcher, add, limit)
        if not alive() then return end
      end
    end
    pending = waiting
    if #pending > 0 then
      if system.get_time() > deadline then
        core.log_quiet("Text Search: %d Terminal texts did not arrive in time", #pending)
        return
      end
      coroutine.yield(0.01)
    end
  end
end

-- Releases the texts when Text Search closes.
function terminals.forget()
  texts = {}
end

-- The width of a Terminal's location: the prefix, its icon, its name and the line suffix.
function terminals.location_width(font, result, prefix, suffix)
  local h = font:get_height()
  return font:get_width(prefix) + tab.icon_width(result.terminal.item, h) + style.padding.x / 2
    + style.view_text_font:get_width(result.file) + font:get_width(suffix)
end

-- Draws a Terminal's location in a Text Search row: its icon and name where a file shows its path. Returns the
-- x position of the line suffix.
function terminals.draw_location(font, result, prefix, suffix, x, y, width)
  local right, h = x + width, font:get_height()
  x = renderer.draw_text(font, prefix, x, y, style.dim)
  x = x + tab.draw_icon(result.terminal.item, x, y, h, style.text) + style.padding.x / 2
  local name_font = style.view_text_font
  local name_y = y + math.floor((h - name_font:get_height()) / 2)
  local name = tab.fit(name_font, result.file, math.max(0, right - x - font:get_width(suffix)))
  local line_x = renderer.draw_text(name_font, name, x, name_y, style.text)
  renderer.draw_text(font, suffix, line_x, y, style.dim)
  return line_x
end

-- The preview's text: the lines near the match, at their own line numbers. Other lines stay empty, so a large
-- scrollback fits the preview.
function terminals.preview_text(result, around)
  local entry, line = result.terminal.entry, result.line
  local starts = line_starts(entry)
  local first, last = math.max(1, line - around), math.min(#starts, line + around)
  local from = starts[first]
  local to = starts[last + 1] and starts[last + 1] - 1 or #entry.text
  return string.rep("\n", first - 1) .. entry.text:sub(from, to) .. string.rep("\n", #starts - last)
end

-- The lines near `line` for the preview of another Project: `first` is the number of the first line. The text stays
-- below 4 KB, so the rows of one Project fit in one Pane request.
function terminals.excerpt(entry, line)
  for around = 8, 0, -1 do
    local first, lines = math.max(1, line - around), {}
    for index = first, line + around do lines[#lines + 1] = terminals.line(entry, index) end
    local text = table.concat(lines, "\n")
    if #text <= 4096 or around == 0 then return {first = first, text = text} end
  end
end

-- Shows the Terminal at the match, as a Sidebar click does, with its find card on the query's seed.
function terminals.open(result)
  local terminal = result.terminal
  local row = result.line - 1
  local root = core.root_project and core.root_project()
  local case_sensitive = result.case_sensitive == true
  if not terminal.project or not system.is_hosted_surface()
    or root and common.path_equals(root.path, terminal.project) then
    local shown, err = require("plugins.terminal").show_match(terminal.id, terminal.query, case_sensitive, row)
    if not shown then core.warn("Cannot open the Terminal: %s", tostring(err)) end
    return shown
  end
  local request = common.serialize({action = "terminal_find", session = terminal.id, query = terminal.query,
    case_sensitive = case_sensitive, row = row}, {escape = true})
  core.log_quiet("Text Search: showing Terminal Session %s in %s", terminal.id, terminal.project)
  return system.pane_request("select", terminal.project, request)
end

return terminals
