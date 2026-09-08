-- mod-version:3
-- Shared file metadata presentation. Callers supply filesystem and Git data.
local common = require "core.common"
local core = require "core"
local style = require "core.style"
local icons = require "core.recent_file_icons"
local path_tree = require "plugins.path_tree"
local metadata = {}

function metadata.format_age(ts, now)
  ts = tonumber(ts)
  if not ts then return nil end
  local elapsed = math.max(0, (tonumber(now) or os.time()) - ts)
  if elapsed < 3600 then return tostring(math.floor(elapsed / 60)) .. "m" end
  if elapsed < 86400 then return tostring(math.floor(elapsed / 3600)) .. "h" end
  if elapsed < 31536000 then return tostring(math.floor(elapsed / 86400)) .. "d" end
  return tostring(math.floor(elapsed / 31536000)) .. "yr"
end

function metadata.recent_times(path)
  local key = common.path_compare_key(path)
  for _, recent in ipairs(core.visited_files or {}) do
    if type(recent) == "table" and common.path_compare_key(core.recent_file_path(recent)) == key then
      return recent.last_edited, recent.last_viewed
    end
  end
end

function metadata.parts(info)
  local git = info.git
  local stat = git and git.stat
  if stat and (stat.additions or 0) == 0 and (stat.deletions or 0) == 0 then stat = nil end
  local parts = {
    { id = "additions", text = stat and ("+" .. tostring(stat.additions or 0)) or "",
      color = style.filetree_git_line_additions, sample = "+999" },
    { id = "deletions", text = stat and ("−" .. tostring(stat.deletions or 0)) or "",
      color = style.filetree_git_line_deletions, sample = "−999", separator = " " },
  }
  if git and git.kind == "ignored" then
    parts[#parts + 1] = { id = "ignored", text = "ignored", sample = "ignored",
      color = style.filetree_git_status_ignored }
  end
  local size = ""
  if info.type == "dir" then
    size = info.count ~= nil and tostring(info.count) or (info.count_pending and "…" or "")
  elseif info.size then
    size = path_tree.format_file_size(info.size)
  end
  parts[#parts + 1] = { id = "size", text = size, sample = "999M" }
  parts[#parts + 1] = { id = "edited", icon = "pencil",
    text = metadata.format_age(info.last_edited or info.modified, info.now) or "", sample = "99yr" }
  parts[#parts + 1] = { id = "viewed", icon = "eye",
    text = metadata.format_age(info.last_viewed, info.now) or "", sample = "99yr" }
  return parts
end

function metadata.font(font)
  return style.get_small_font(style.get_small_font(font))
end

function metadata.include_columns(columns, font, parts)
  font = metadata.font(font)
  for _, part in ipairs(parts) do
    columns[part.id] = math.max(columns[part.id] or 0,
      font:get_width(part.sample), font:get_width(part.text))
  end
end

function metadata.draw(font, parts, x, y, width, columns)
  local small_font = metadata.font(font)
  local text_y = y + math.max(0, math.floor((font:get_height() - small_font:get_height()) / 2))
  local row_height = small_font:get_height()
  local icon_size = icons.size_for_row(row_height)
  local icon_gap = math.max(2 * (SCALE or 1), style.padding.x / 4)
  local total = 0
  local widths = {}
  for index, part in ipairs(parts) do
    widths[index] = columns and columns[part.id]
      or math.max(small_font:get_width(part.sample), small_font:get_width(part.text))
    total = total + widths[index] + (part.icon and icon_size + icon_gap or 0)
    if index > 1 then total = total + small_font:get_width(part.separator or "  ") end
  end
  local outer_gap = style.padding.x
  if total + outer_gap >= width then return width end
  local cx = x + width - total
  for index, part in ipairs(parts) do
    if index > 1 then
      cx = renderer.draw_text(small_font, part.separator or "  ", cx, text_y, style.dim)
    end
    if part.icon then
      icons.draw(part.icon, cx, text_y, row_height, icon_size)
      cx = cx + icon_size + icon_gap
    end
    renderer.draw_text(small_font, part.text,
      cx + widths[index] - small_font:get_width(part.text), text_y, part.color or style.dim)
    cx = cx + widths[index]
  end
  return math.max(0, width - total - outer_gap)
end

function metadata.line_hint(font, parts, columns)
  return { draw = function(x, y, width) return metadata.draw(font, parts, x, y, width, columns) end }
end

return metadata
