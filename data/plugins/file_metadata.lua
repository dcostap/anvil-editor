-- mod-version:3
-- Shared file metadata presentation. Callers supply filesystem and Git data.
local common = require "core.common"
local core = require "core"
local style = require "core.style"
local icons = require "core.recent_file_icons"
local path_tree = require "plugins.path_tree"
local metadata = {}
local recent_source, recent_by_path
local font_widths = setmetatable({}, { __mode = "k" })

local function widths_for(font)
  local frame = core.render_frame_active and core.render_frame_id
  local cache = font_widths[font]
  if frame and cache and cache.frame == frame then return cache end
  local size = font:get_size()
  local generation = font:get_generation()
  local scale = font:get_surface_scale()
  if type(generation) == "table" then generation = table.concat(generation, ":") end
  if type(scale) == "table" then scale = table.concat(scale, ":") end
  if not cache or cache.size ~= size or cache.generation ~= generation or cache.scale ~= scale then
    cache = { size = size, generation = generation, scale = scale, values = {}, count = 0 }
    font_widths[font] = cache
  end
  cache.frame = frame
  return cache
end

local function text_width(font, cache, text)
  local width = cache.values[text]
  if width == nil then
    -- Bound storage when file sizes, counts, or ages keep changing.
    if cache.count >= 512 then cache.values, cache.count = {}, 0 end
    width = font:get_width(text)
    cache.values[text] = width
    cache.count = cache.count + 1
  end
  return width
end

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
  local source = core.visited_files
  if recent_source ~= source or not recent_by_path then
    recent_source, recent_by_path = source, {}
    for _, recent in ipairs(source or {}) do
      if type(recent) == "table" then
        local key = common.path_compare_key(core.recent_file_path(recent))
        if key and not recent_by_path[key] then recent_by_path[key] = recent end
      end
    end
  end
  local key = common.path_compare_key(path)
  -- Core replaces the list after visits and pruning. Edits update these entries in place.
  local recent = recent_by_path[key]
  if recent then return recent.last_edited, recent.last_viewed end
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
  if git and git.error then
    local text = git.stale and "Git status stale" or "Git unavailable"
    parts[#parts + 1] = { id = "git_status", text = text, sample = text, color = style.warn }
  end
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
  return parts
end

function metadata.font(font)
  return style.get_small_font(style.get_small_font(font))
end

function metadata.include_columns(columns, font, parts)
  font = metadata.font(font)
  local cache = widths_for(font)
  for _, part in ipairs(parts) do
    columns[part.id] = math.max(columns[part.id] or 0,
      text_width(font, cache, part.sample), text_width(font, cache, part.text))
  end
end

local function layout(font, parts, columns, reclaim_empty)
  reclaim_empty = reclaim_empty ~= false
  local small_font = metadata.font(font)
  local cache = widths_for(small_font)
  local row_height = small_font:get_height()
  local icon_size = icons.size_for_row(row_height)
  local icon_gap = -math.max(3, 2 * (SCALE or 1))
  local total = 0
  local widths = {}
  local leading_empty = 0
  local leading = true
  for index, part in ipairs(parts) do
    widths[index] = columns and columns[part.id]
      or math.max(text_width(small_font, cache, part.sample), text_width(small_font, cache, part.text))
    local part_width = widths[index] + (part.icon and icon_size + icon_gap or 0)
    local separator = part.separator or "  "
    local separator_width = index > 1 and text_width(small_font, cache, separator) or 0
    total = total + part_width + separator_width
    if reclaim_empty and leading then
      local has_content = part.icon or part.text ~= ""
      if has_content then
        leading = false
        -- The separator is whitespace in the shared metadata schema. Do not
        -- reclaim it for custom metadata if it contains visible characters.
        if index > 1 and not separator:find("%S") then
          leading_empty = leading_empty + separator_width
        end
      else
        leading_empty = leading_empty + part_width + separator_width
      end
    end
  end
  local outer_gap = math.max(1, math.floor(style.padding.x / 2))
  return small_font, cache, widths, total, leading_empty, outer_gap,
    icon_size, icon_gap
end

function metadata.required_width(font, parts, columns)
  local _, _, _, total, _, outer_gap = layout(font, parts, columns, false)
  return total + outer_gap + 1
end

function metadata.draw(font, parts, x, y, width, columns, reclaim_empty)
  local small_font, cache, widths, total, leading_empty, outer_gap,
    icon_size, icon_gap = layout(font, parts, columns, reclaim_empty)
  local text_y = y + math.max(0, math.floor((font:get_height() - small_font:get_height()) / 2))
  local row_height = small_font:get_height()
  if total + outer_gap >= width then return width end
  local cx = x + width - total
  for index, part in ipairs(parts) do
    if index > 1 then
      local separator = part.separator or "  "
      if separator:find("%S") then
        renderer.draw_text(small_font, separator, cx, text_y, style.dim)
      end
      cx = cx + text_width(small_font, cache, separator)
    end
    if part.icon then
      icons.draw(part.icon, cx, text_y, row_height, icon_size)
      cx = cx + icon_size + icon_gap
    end
    if part.text ~= "" then
      renderer.draw_text(small_font, part.text,
        cx + widths[index] - text_width(small_font, cache, part.text), text_y, part.color or style.dim)
    end
    cx = cx + widths[index]
  end
  -- Keep global columns aligned, but let the row text use leading columns
  -- that have no content in this row.
  return math.max(0, width - total - outer_gap + leading_empty)
end

function metadata.line_hint(font, parts, columns, reclaim_empty)
  return {
    draw = function(x, y, width)
      return metadata.draw(font, parts, x, y, width, columns, reclaim_empty)
    end,
  }
end

return metadata
