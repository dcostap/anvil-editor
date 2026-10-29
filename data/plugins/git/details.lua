-- The commit card at the top of the Git Log details pane: the commit's title, author, refs, message,
-- identity fields and a summary of its changed files. Each part is one Buffer line, so find and copy
-- still work, but each part draws its own layout at its own height. Text wraps to the pane width.

local core = require "core"
local config = require "core.config"
local style = require "core.style"
local path_tree = require "plugins.path_tree"

local details = {}

local derived = setmetatable({}, { __mode = "k" })

-- Fonts derived from the pane's font: a bold title, a bold name and small secondary text.
local function fonts(view)
  local base = view:get_font()
  local set = derived[base]
  if not set or set.code_base ~= style.code_font then
    local size = base:get_size()
    set = {
      base = base,
      title = base:copy(math.floor(size * 1.35 + 0.5), { bold = true }),
      bold = base:copy(size, { bold = true }),
      small = base:copy(math.max(1, math.floor(size * 0.88 + 0.5))),
      code_base = style.code_font,
      code = style.code_font:copy(math.max(1, math.floor(style.code_font:get_size() * 0.9 + 0.5))),
    }
    derived[base] = set
  end
  return set
end

local function pad() return style.padding.y end
local function line_step(font) return math.floor(font:get_height() * config.line_height) end

---The width that header rows wrap to. Header rows do not scroll sideways.
local function content_width(view)
  local _, _, scrollbar_w = view.v_scrollbar:get_track_rect()
  return math.max(40 * SCALE, view.size.x - view:get_gutter_width() - math.max(style.padding.x, scrollbar_w or 0))
end

local function with_alpha(color, alpha)
  return { color[1], color[2], color[3], math.floor((color[4] or 255) * alpha) }
end

-- Greedy word wrap. A list item or indented line continues under its own text.
local function wrap(font, text, width)
  text = text:gsub("	", "    ")
  local lead = text:match("^%s*[-*+] ") or text:match("^%s*%d+[.)] ") or text:match("^%s*")
  local hang = font:get_width(lead)
  local space = font:get_width(" ")
  local rows, current, current_w = {}, nil, 0
  for word in text:sub(#lead + 1):gmatch("%S+") do
    local w = font:get_width(word)
    if not current then
      current, current_w = lead .. word, hang + w
    elseif current_w + space + w > width then
      rows[#rows + 1] = { text = current, x = #rows == 0 and 0 or hang }
      current, current_w = word, hang + w
    else
      current, current_w = current .. " " .. word, current_w + space + w
    end
  end
  rows[#rows + 1] = { text = current or "", x = #rows == 0 and 0 or hang }
  return rows
end

-- A role's layout depends on the pane width and font. Keep it on the line's metadata until either changes.
local function cached_layout(meta, key_font, width, build)
  local cached = meta.layout
  if cached and cached.width == width and cached.font == key_font and cached.theme == core.color_theme_generation then
    return cached
  end
  cached = build()
  cached.width, cached.font, cached.theme = width, key_font, core.color_theme_generation
  meta.layout = cached
  return cached
end

local function text_rows(meta, font, width)
  return cached_layout(meta, font, width, function()
    return { rows = wrap(font, meta.text or "", width) }
  end).rows
end

local function relative_time(timestamp, now)
  local age = math.max(0, now - timestamp)
  local function unit(value, name)
    value = math.floor(value)
    return value .. " " .. name .. (value == 1 and "" or "s") .. " ago"
  end
  if age < 60 then return "just now" end
  if age < 60 * 60 then return unit(age / 60, "minute") end
  if age < 24 * 60 * 60 then return unit(age / (60 * 60), "hour") end
  if age < 2 * 24 * 60 * 60 then return "yesterday" end
  if age < 7 * 24 * 60 * 60 then return unit(age / (24 * 60 * 60), "day") end
  if age < 30 * 24 * 60 * 60 then return unit(age / (7 * 24 * 60 * 60), "week") end
  if age < 365 * 24 * 60 * 60 then return unit(age / (30 * 24 * 60 * 60), "month") end
  return unit(age / (365 * 24 * 60 * 60), "year")
end

-- The relative time changes once a minute. Format it again only then.
local function when_text(meta)
  local minute = math.floor(os.time() / 60)
  if meta.when_minute ~= minute then
    meta.when_minute = minute
    meta.when = relative_time(meta.timestamp, os.time()) .. "  ·  " .. meta.date
  end
  return meta.when
end

local function initials(name)
  local letters = {}
  for word in name:gmatch("[%w\128-\255]+") do
    letters[#letters + 1] = word:match("^[%z\1-\127\194-\244][\128-\191]*")
    if #letters == 2 then break end
  end
  return table.concat(letters):upper()
end

local function avatar_color(seed)
  local colors = style.git_graph_colors or { style.accent, style.good, style.warn }
  local hash = 0
  for i = 1, #seed do hash = (hash * 31 + seed:byte(i)) % 2147483647 end
  return colors[hash % #colors + 1]
end

local function draw_centered(font, text, x, y, w, h, color)
  renderer.draw_text(font, text, x + (w - font:get_width(text)) / 2, y + (h - font:get_height()) / 2, color)
end

local roles = {}

roles.title = {
  height = function(view, meta, f, width)
    return #text_rows(meta, f.title, width) * line_step(f.title) + pad() * 0.5
  end,
  draw = function(view, meta, f, x, y, width)
    local step = line_step(f.title)
    for index, row in ipairs(text_rows(meta, f.title, width)) do
      renderer.draw_text(f.title, row.text, x + row.x, y + (index - 1) * step + (step - f.title:get_height()) / 2,
        style.text)
    end
  end,
}

local function avatar_size(f) return math.floor(f.base:get_height() * 2.2) end

roles.byline = {
  height = function(_, _, f) return avatar_size(f) + pad() end,
  draw = function(_, meta, f, x, y, width)
    local d = avatar_size(f)
    local top = y + pad() * 0.5
    if meta.avatar_theme ~= core.color_theme_generation or not meta.avatar_fill then
      meta.avatar_theme = core.color_theme_generation
      meta.avatar_color = avatar_color(meta.avatar_seed)
      meta.avatar_fill = with_alpha(meta.avatar_color, 0.22)
    end
    local color = meta.avatar_color
    renderer.draw_rounded_rect(x, top, d, d, d / 2, meta.avatar_fill)
    draw_centered(f.bold, meta.initials, x, top, d, d, color)
    local tx = x + d + style.padding.x * 0.75
    local gap = 2 * SCALE
    local name_h, info_h = f.bold:get_height(), f.small:get_height()
    local ty = top + (d - name_h - gap - info_h) / 2
    local after = renderer.draw_text(f.bold, meta.author, tx, ty, style.text)
    if meta.email ~= "" then
      renderer.draw_text(f.small, meta.email, after + style.padding.x * 0.5, ty + (name_h - info_h) / 2, style.dim)
    end
    if meta.timestamp then
      renderer.draw_text(f.small, when_text(meta), tx, ty + name_h + gap, style.dim)
    end
  end,
}

local function ref_color(kind)
  if kind == "head" then return style.git_ref_head or style.good end
  if kind == "tag" then return style.git_ref_tag or style.warn end
  if kind == "remote" then return style.git_ref_remote or style.accent end
  return style.git_ref_branch or style.accent
end

local function pill_metrics(f)
  return f.small:get_height() + 6 * SCALE, 8 * SCALE, 6 * SCALE
end

-- Ref pills flow left to right and wrap to new rows.
local function ref_layout(meta, f, width)
  return cached_layout(meta, f.small, width, function()
    local h, inner, gap = pill_metrics(f)
    local pills, px, row = {}, 0, 0
    for _, ref in ipairs(meta.refs) do
      local w = f.small:get_width(ref.text) + inner * 2
      if px > 0 and px + w > width then px, row = 0, row + 1 end
      local color = ref_color(ref.kind)
      pills[#pills + 1] = { x = px, row = row, w = w, text = ref.text, color = color, fill = with_alpha(color, 0.16) }
      px = px + w + gap
    end
    return { pills = pills, rows = row + 1, h = h, gap = gap, inner = inner }
  end)
end

roles.refs = {
  height = function(_, meta, f, width)
    local layout = ref_layout(meta, f, width)
    return layout.rows * (layout.h + layout.gap) - layout.gap + pad()
  end,
  draw = function(_, meta, f, x, y, width)
    local layout = ref_layout(meta, f, width)
    local top = y + pad() * 0.5
    for _, pill in ipairs(layout.pills) do
      local py = top + pill.row * (layout.h + layout.gap)
      renderer.draw_rounded_rect(x + pill.x, py, pill.w, layout.h, layout.h / 2, pill.fill)
      draw_centered(f.small, pill.text, x + pill.x, py, pill.w, layout.h, pill.color)
    end
  end,
}

roles.body = {
  height = function(_, meta, f, width)
    if (meta.text or ""):find("%S") == nil then return math.floor(line_step(f.base) * 0.6) end
    return #text_rows(meta, f.base, width) * line_step(f.base)
  end,
  draw = function(_, meta, f, x, y, width)
    if (meta.text or ""):find("%S") == nil then return end
    local step = line_step(f.base)
    for index, row in ipairs(text_rows(meta, f.base, width)) do
      renderer.draw_text(f.base, row.text, x + row.x, y + (index - 1) * step + (step - f.base:get_height()) / 2,
        style.text)
    end
  end,
}

roles.gap = {
  height = function() return pad() end,
  draw = function() end,
}

roles.rule = {
  height = function() return pad() * 2 end,
  draw = function(_, _, _, x, y, width)
    renderer.draw_rect(x, math.floor(y + pad()), width, math.max(1, math.floor(SCALE)), style.divider)
  end,
}

local FIELD_LABELS = { "Commit", "Parents", "Committer", "Range" }

local function label_width(f)
  if f.label_w then return f.label_w end
  local w = 0
  for _, label in ipairs(FIELD_LABELS) do w = math.max(w, f.small:get_width(label)) end
  f.label_w = w + style.padding.x
  return f.label_w
end

roles.field = {
  height = function(_, _, f) return line_step(f.base) end,
  draw = function(_, meta, f, x, y, width)
    local step = line_step(f.base)
    renderer.draw_text(f.small, meta.label, x, y + (step - f.small:get_height()) / 2, style.dim)
    local vx = x + label_width(f)
    for _, part in ipairs(meta.values) do
      local font = part.code and f.code or f.base
      vx = renderer.draw_text(font, part.text, vx, y + (step - font:get_height()) / 2, part.color or style.text)
      vx = vx + (part.gap or 0)
    end
  end,
}

roles.message = {
  height = function(_, _, f) return line_step(f.base) end,
  draw = function(_, meta, f, x, y)
    local step = line_step(f.base)
    renderer.draw_text(f.base, meta.text or "", x, y + (step - f.base:get_height()) / 2,
      meta.error and style.error or style.dim)
  end,
}

-- At most this many blocks show the share of added and deleted lines, as on GitHub.
local STAT_BLOCKS = 5

roles.files = {
  height = function(_, _, f) return line_step(f.base) + pad() * 0.5 end,
  draw = function(_, meta, f, x, y, width)
    local step = line_step(f.base)
    local ty = y + (step - f.small:get_height()) / 2
    -- The line totals and their blocks sit at the right. The file counts use the space left of them.
    local limit = x + width
    if meta.total and meta.total > 0 then
      local block = math.floor(f.small:get_height() * 0.55)
      local block_gap = math.max(1, math.floor(2 * SCALE))
      local right = x + width - STAT_BLOCKS * (block + block_gap) + block_gap
      local by = y + (step - block) / 2
      for i = 1, STAT_BLOCKS do
        local color = i <= meta.added_blocks and style.filetree_git_line_additions
          or i <= meta.added_blocks + meta.deleted_blocks and style.filetree_git_line_deletions
          or style.divider
        renderer.draw_rounded_rect(right + (i - 1) * (block + block_gap), by, block, block, math.max(1, SCALE), color)
      end
      local cy = y + (step - f.code:get_height()) / 2
      local sx = right - style.padding.x * 0.75 - f.code:get_width(meta.deletions_text)
      renderer.draw_text(f.code, meta.deletions_text, sx, cy, style.filetree_git_line_deletions)
      sx = sx - style.padding.x * 0.5 - f.code:get_width(meta.additions_text)
      renderer.draw_text(f.code, meta.additions_text, sx, cy, style.filetree_git_line_additions)
      limit = sx - style.padding.x
    end
    local tx = renderer.draw_text(f.small, meta.count, x, ty, style.text)
    for _, part in ipairs(meta.kinds) do
      local sep_w = f.small:get_width("  ·  ")
      if tx + sep_w + f.small:get_width(part.text) > limit then break end
      tx = renderer.draw_text(f.small, "  ·  ", tx, ty, style.dim)
      tx = renderer.draw_text(f.small, part.text, tx, ty, path_tree.git_text_color(part.kind) or style.dim)
    end
  end,
}

local function role_of(view, line)
  local meta = view.git_detail_line_meta and view.git_detail_line_meta[line]
  return meta and roles[meta.role] and meta, meta and roles[meta.role]
end

---The height of a card line, or nil for the changed-file rows.
function details.row_height(view, line)
  local meta, role = role_of(view, line)
  if not meta then return nil end
  return math.max(1, math.floor(role.height(view, meta, fonts(view), content_width(view))))
end

---Draw a card line at the pane's left edge. Returns the row height, or nil for the changed-file rows.
function details.draw(view, line, x, y)
  local meta, role = role_of(view, line)
  if not meta then return nil end
  -- Card lines wrap to the pane, so they stay in place when wide changed-file rows scroll sideways.
  role.draw(view, meta, fonts(view), x + view.scroll.x, y, content_width(view))
  return view:get_position_visual_row_height(line, 1)
end

---A metric generation: card rows change height only when the pane width or font changes.
function details.metric_generation(view)
  return content_width(view) * 1000 + fonts(view).base:get_size()
end

local function short(hash) return tostring(hash or ""):sub(1, 8) end

local function block_counts(additions, deletions)
  local total = additions + deletions
  if total == 0 then return 0, 0 end
  local blocks = math.min(STAT_BLOCKS, total)
  local added = math.floor(blocks * additions / total + 0.5)
  if additions > 0 and added == 0 then added = 1 end
  if deletions > 0 and added == blocks then added = blocks - 1 end
  return added, blocks - added
end

---Append the card lines for a commit, a Commit Range or Local Changes through `add(text, meta)`.
function details.append_card(commit, add)
  local subject = commit.subject ~= "" and commit.subject or "(no subject)"
  add(subject, { role = "title", text = subject })
  if commit.kind == "commit_range" then
    add("", { role = "gap" })
    local value = short(commit.left) .. " → " .. short(commit.right)
    add("Range " .. value, { role = "field", label = "Range", values = {
      { text = short(commit.left), code = true, color = style.accent },
      { text = "  →  ", color = style.dim },
      { text = short(commit.right), code = true, color = style.accent },
    } })
  elseif commit.kind ~= "working_tree" then
    local author = commit.author_name ~= "" and commit.author_name or "Unknown author"
    local timestamp = tonumber(commit.author_time or commit.commit_time)
    if timestamp and timestamp <= 0 then timestamp = nil end
    local date = timestamp and os.date("%a %d %b %Y, %H:%M", timestamp) or ""
    local email = commit.author_email or ""
    add(author .. (email ~= "" and " <" .. email .. ">" or "") .. (date ~= "" and "  " .. date or ""), {
      role = "byline", author = author, email = email, timestamp = timestamp, date = date,
      initials = initials(author), avatar_seed = email ~= "" and email:lower() or author,
    })
    if commit.ref_labels and #commit.ref_labels > 0 then
      local refs, labels = {}, {}
      for _, ref in ipairs(commit.ref_labels) do
        local marker = (ref.kind == "tag" or ref.kind == "remote") and "◇ " or "● "
        refs[#refs + 1] = { kind = ref.kind, text = marker .. tostring(ref.label or "") }
        labels[#labels + 1] = ref.label
      end
      add(table.concat(labels, ", "), { role = "refs", refs = refs })
    end
    if commit.body and commit.body:find("%S") then
      add("", { role = "gap" })
      local body = commit.body:gsub("%s+$", "")
      for text in (body .. "\n"):gmatch("(.-)\r?\n") do add(text, { role = "body", text = text }) end
    end
    add("", { role = "rule" })
    local hash = tostring(commit.hash or "")
    add("Commit " .. hash, { role = "field", label = "Commit", values = {
      { text = hash, code = true, color = style.accent },
    } })
    local parents = commit.parents or {}
    if #parents > 0 then
      local values, texts = {}, {}
      for index, parent in ipairs(parents) do
        values[#values + 1] = { text = short(parent), code = true, color = style.accent,
          gap = index < #parents and style.padding.x or 0 }
        texts[#texts + 1] = short(parent)
      end
      add("Parents " .. table.concat(texts, " "), { role = "field", label = "Parents", values = values })
    end
    local committer = commit.committer_name or ""
    if committer ~= "" and committer ~= commit.author_name then
      add("Committer " .. committer, { role = "field", label = "Committer", values = { { text = committer } } })
    end
  end
  add("", { role = "rule" })
end

-- File counts in the changed-files header, in this order. Copies count as renames and type changes as modifications.
local FILE_KINDS = { "added", "modified", "renamed", "deleted", "unmerged" }
local FILE_KIND = { added = "added", modified = "modified", typechange = "modified", renamed = "renamed",
  copied = "renamed", deleted = "deleted", unmerged = "unmerged" }

---The summary line above the changed-file rows: the file counts and the line totals.
function details.files_meta(files)
  local additions, deletions = 0, 0
  for _, file in ipairs(files) do
    local stat = file.stat
    if stat then additions, deletions = additions + (stat.additions or 0), deletions + (stat.deletions or 0) end
  end
  local added_blocks, deleted_blocks = block_counts(additions, deletions)
  local counts = {}
  for _, file in ipairs(files) do
    local kind = FILE_KIND[file.status] or "modified"
    counts[kind] = (counts[kind] or 0) + 1
  end
  local kinds = {}
  for _, kind in ipairs(FILE_KINDS) do
    if counts[kind] then kinds[#kinds + 1] = { kind = kind, text = counts[kind] .. " " .. kind } end
  end
  local count = #files == 1 and "1 file" or #files .. " files"
  local text = { count }
  for _, part in ipairs(kinds) do text[#text + 1] = part.text end
  return {
    role = "files", count = count, kinds = kinds,
    text = table.concat(text, " · ") .. "  +" .. additions .. " −" .. deletions,
    total = additions + deletions,
    additions_text = "+" .. additions, deletions_text = "−" .. deletions,
    added_blocks = added_blocks, deleted_blocks = deleted_blocks,
  }
end

return details
