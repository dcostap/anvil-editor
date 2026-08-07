local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local attachments = require "core.markdown.attachments"
local images = require "core.markdown.images"
local fence_highlight = require "core.markdown.fence_highlight"
local link_completion = require "core.markdown.completion"
local linewrapping = require "core.linewrapping"
local markdown_links = require "core.markdown.links"
local markdown_model = require "core.markdown.model"
local pending_projection = require "core.markdown.pending_projection"
local pending_renderer = require "core.markdown.pending_render"
local markdown_tables = require "core.markdown.tables"
local tokenizer = require "core.tokenizer"
local vault_index = require "core.markdown.vault_index"
local style = require "core.style"

local live = {}

local PROVIDER_ID = "markdown-live"
local MARKDOWN_EXTENSIONS = { md = true, markdown = true, mdown = true }
local IMAGE_EXTENSIONS = { avif = true, bmp = true, gif = true, jpeg = true, jpg = true, png = true, svg = true, webp = true }
local AUDIO_EXTENSIONS = { flac = true, mp3 = true, ogg = true, wav = true }
local VIDEO_EXTENSIONS = { mov = true, mp4 = true, webm = true }
local PROSE_FONT_ROLE_NAMES = {
  "prose_font", "prose_strong_font", "prose_emphasis_font",
  "prose_strong_emphasis_font", "prose_heading_font",
  "prose_heading_emphasis_font",
}

local function extension(path)
  return (path or ""):match("%.([^.\\/]+)$") and (path or ""):match("%.([^.\\/]+)$"):lower() or nil
end

function live.is_markdown_doc(doc)
  if not doc then return false end
  if MARKDOWN_EXTENSIONS[extension(doc.abs_filename or doc.filename or "") or ""] then return true end
  local syntax_name = doc.syntax and doc.syntax.name
  return type(syntax_name) == "string" and syntax_name:lower():find("markdown", 1, true) ~= nil
end

local function line_is_wrapped(view, line)
  if not view.wrapped_settings then return false end
  local ok, _, _, count = pcall(linewrapping.get_line_idx_col_count, view, line)
  return ok and (count or 1) > 1
end

local function fence_marker(line)
  local indent, ticks = line:match("^(%s*)(`+)")
  if ticks and #indent <= 3 and #ticks >= 3 then return "`", #ticks end
  local tildes
  indent, tildes = line:match("^(%s*)(~+)")
  if tildes and #indent <= 3 and #tildes >= 3 then return "~", #tildes end
end

local function closes_fence(line, marker, count)
  local indent, run, rest = line:match("^(%s*)(" .. (marker == "`" and "`+" or "~+") .. ")(%s*)$")
  return run and #indent <= 3 and #run >= count and rest ~= nil
end

local semantic_line

local function line_in_raw_block(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "code_fenced" or node.type == "code_indented" or node.type == "html" then
      return true
    end
  end
  return false
end

local function current_selection_state(view)
  if view.get_line_render_selection_state then return view:get_line_render_selection_state() end
  return view.selection_state or { selections = view.doc.selections }
end

local function heading_for_line(line_text, line)
  local indent, marks = line_text:match("^(%s*)(#+)%s+")
  if not marks or #marks > 6 then return nil end
  local content_col1 = #indent + #marks + 1
  while line_text:sub(content_col1, content_col1):match("%s") do content_col1 = content_col1 + 1 end
  local content_col2 = #line_text + 1
  local before_closing = line_text:match("^(.-)%s+#+%s*$")
  if before_closing and #before_closing >= content_col1 then
    content_col2 = #before_closing + 1
  else
    while content_col2 > content_col1 and line_text:sub(content_col2 - 1, content_col2 - 1):match("%s") do
      content_col2 = content_col2 - 1
    end
  end
  return {
    level = #marks,
    line = line,
    marker_col1 = #indent + 1,
    content_col1 = content_col1,
    content_col2 = content_col2,
    text = line_text:sub(content_col1, content_col2 - 1),
  }
end

local function current_semantic_model(view)
  local instance = markdown_model.peek(view.doc)
  if instance and instance.status == "ready"
    and instance.published_revision == view.doc.text_revision
  then
    return instance
  end
end

local function render_semantic_model(view, line)
  local instance = current_semantic_model(view)
  if instance then return instance end
  local owner = view.__markdown_live_owner
  if owner and owner.semantic_pending_line and line >= owner.semantic_pending_line then return nil end
  instance = markdown_model.peek(view.doc)
  if instance and instance.can_render_published_line
    and instance:can_render_published_line(line)
  then
    return instance
  end
end

semantic_line = function(view, line)
  local instance = render_semantic_model(view, line)
  if not instance then return nil end
  local cache = view.__markdown_live_semantic_line_cache
  if not cache or cache.generation ~= instance.generation then
    cache = { generation = instance.generation, lines = {} }
    view.__markdown_live_semantic_line_cache = cache
  end
  if cache.lines[line] == nil then
    local nodes, reason = instance:nodes_for_lines(line, line, {
      limit = 512, allow_pending_result = instance.status == "pending",
    })
    if reason == "limit" then
      core.log_quiet("Markdown semantic render query was truncated on line %d; using fallback", line)
      nodes = nil
    end
    cache.lines[line] = nodes or false
  end
  local nodes = cache.lines[line]
  return nodes ~= false and nodes or nil, instance.generation
end

local function line_in_semantic_comment(view, line)
  local nodes = semantic_line(view, line)
  for _, node in ipairs(nodes or {}) do
    if node.type == "comment" and line >= node.source.line1 and line <= node.source.line2 then
      return true
    end
  end
  return false
end

local REVEAL_TYPES = {
  heading = true,
  strong = true,
  emphasis = true,
  strikethrough = true,
  highlight = true,
  code = true,
  escape = true,
  comment = true,
  link = true,
  image = true,
  wiki_link = true,
  embed = true,
  tag = true,
  hard_break = true,
  math = true,
}

local function list_marker_for_line(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "list" or node.type == "list_item" then
      local marker = node.attributes and node.attributes.list
      if marker and marker.line1 == line then
        local text = (view.doc.lines[line] or ""):gsub("\n$", "")
        local raw = text:sub(marker.col1, marker.col2 - 1)
        local _, token_end = raw:find("%S+")
        return marker, node, marker.col1 + (token_end or #raw)
      end
    end
  end
end

local function source_task_marker(line_text, marker)
  if not marker then return nil end
  local col = marker.col2
  while col <= #line_text and line_text:sub(col, col):match("[ \t]") do
    col = col + 1
  end
  if line_text:sub(col, col) ~= "[" then return nil end
  local state = line_text:sub(col + 1, col + 1)
  if (state ~= " " and state ~= "x" and state ~= "X")
    or line_text:sub(col + 2, col + 2) ~= "]"
  then
    return nil
  end
  local after = col + 3
  if after <= #line_text then
    local next_char = line_text:sub(after, after)
    if not next_char:match("[ \t\r\n]") then return nil end
  end
  return {
    line1 = marker.line1, line2 = marker.line1,
    col1 = col, col2 = after,
  }, state ~= " "
end

local function task_marker_for_line(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    local attributes = node.attributes or {}
    local marker = attributes.task_checked or attributes.task_unchecked
    local source_checked
    if not marker then
      marker, source_checked = source_task_marker(
        view.doc.lines[line] or "", attributes.list
      )
    end
    if marker and marker.line1 == line then
      return marker, node, source_checked
    end
  end
end

local function source_line_length(text)
  local length = #(text or "")
  if length > 0 and text:byte(length) == 10 then
    return length - 1
  end
  return length
end

local function node_line_range(node, line, line_length)
  if line < node.source.line1 or line > node.source.line2 then return nil end
  return line == node.source.line1 and node.source.col1 or 1,
    line == node.source.line2 and node.source.col2 or line_length + 1
end

local function position_before(line1, col1, line2, col2)
  return line1 < line2 or (line1 == line2 and col1 < col2)
end

local function ordered_selection(line1, col1, line2, col2)
  if position_before(line2, col2, line1, col1) then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end

local function source_intersects_selection(source, line1, col1, line2, col2)
  line1, col1, line2, col2 = ordered_selection(line1, col1, line2, col2)
  return position_before(source.line1, source.col1, line2, col2)
    and position_before(line1, col1, source.line2, source.col2)
end

local function selection_touches_line(line, line_length, line1, col1, line2, col2)
  line1, col1, line2, col2 = ordered_selection(line1, col1, line2, col2)
  if line < line1 or line > line2 then return false end
  local from = line == line1 and col1 or 1
  local to = line == line2 and col2 or line_length + 1
  return from < to
end

local function reveal_units_for_line(view, line, state)
  state = state or current_selection_state(view)
  local selections = state and state.selections or view.doc.selections or {}
  local line_length = source_line_length(view.doc.lines[line] or "")
  local units = {}
  for i = 1, #selections, 4 do
    local line1, col1 = selections[i], selections[i + 1]
    local line2, col2 = selections[i + 2], selections[i + 3]
    if line1 and line2 then
      local collapsed = line1 == line2 and col1 == col2
      if not collapsed then
        local touches_line = selection_touches_line(
          line, line_length, line1, col1, line2, col2
        )
        local has_localized_reveal, added = false, {}
        for _, node in ipairs(semantic_line(view, line) or {}) do
          if REVEAL_TYPES[node.type] then
            -- A heading is a block-level presentation. Its marker ranges
            -- decide whether its source is revealed, but the heading itself
            -- must not suppress the ordinary whole-line fallback for a
            -- selection in otherwise plain heading text. Keep this aligned
            -- with the collapsed-caret path below.
            if node.type ~= "heading" then has_localized_reveal = true end
            local intersects = false
            if node.type == "heading" then
              for _, marker in ipairs(node.marker_ranges or {}) do
                if source_intersects_selection(marker, line1, col1, line2, col2) then
                  intersects = true
                  break
                end
              end
            else
              intersects = source_intersects_selection(
                node.source, line1, col1, line2, col2
              )
            end
            if intersects and not added[node.id] then
              local unit_col1, unit_col2 = node_line_range(node, line, line_length)
              units[#units + 1] = {
                type = node.type, id = node.id, col1 = unit_col1, col2 = unit_col2,
                line1 = node.source.line1, line2 = node.source.line2,
              }
              added[node.id] = true
            end
          end
        end
        local list_marker, list_node, list_marker_token_col2 = list_marker_for_line(view, line)
        if list_marker then
          local marker_source = {
            line1 = line, col1 = list_marker.col1,
            line2 = line, col2 = list_marker_token_col2,
          }
          if source_intersects_selection(marker_source, line1, col1, line2, col2) then
            units[#units + 1] = {
              type = "list_marker", id = list_node.id,
              col1 = list_marker.col1, col2 = list_marker.col2,
              line1 = line, line2 = line,
            }
          end
        end
        local task_marker, task_node = task_marker_for_line(view, line)
        if task_marker and source_intersects_selection(
          task_marker, line1, col1, line2, col2
        ) then
          units[#units + 1] = {
            type = "task_marker", id = task_node.id .. ":task",
            col1 = task_marker.col1, col2 = task_marker.col2,
            line1 = line, line2 = line,
          }
        end
        if touches_line and not has_localized_reveal and not list_marker then
          units[#units + 1] = { type = "line", col1 = 1, col2 = line_length + 1, whole_line = true }
        end
      elseif config.markdown_live_reveal_mode == "line" then
        if line == line1 then
          units[#units + 1] = { type = "line", col1 = 1, col2 = line_length + 1, whole_line = true }
        end
      else
        local cursor_length = source_line_length(view.doc.lines[line1] or "")
        local best, best_size, best_contains, has_localized_reveal
        for _, node in ipairs(semantic_line(view, line1) or {}) do
          if REVEAL_TYPES[node.type] then
            if node.type ~= "heading" then has_localized_reveal = true end
            local node_col1, node_col2 = node_line_range(node, line1, cursor_length)
            local contains = node_col1 and col1 >= node_col1 and col1 < node_col2
            local inclusive_right_edge = node_col1 and col1 == node_col2
            if contains or inclusive_right_edge then
              local size = (node.source.end_byte or 0) - (node.source.start_byte or 0)
              if not best_size or size < best_size
                or size == best_size and contains and not best_contains
              then
                best, best_size, best_contains = node, size, contains
              end
            end
          end
        end
        local list_marker, list_node, list_marker_token_col2 = list_marker_for_line(view, line1)
        local task_marker, task_node = task_marker_for_line(view, line1)
        if line == line1 and list_marker
          and col1 >= list_marker.col1 and col1 <= list_marker_token_col2
        then
          units[#units + 1] = {
            type = "list_marker", id = list_node.id,
            col1 = list_marker.col1, col2 = list_marker.col2,
            line1 = line1, line2 = line1,
          }
        elseif line == line1 and task_marker
          and col1 >= task_marker.col1 and col1 <= task_marker.col2
        then
          units[#units + 1] = {
            type = "task_marker", id = task_node.id .. ":task",
            col1 = task_marker.col1, col2 = task_marker.col2,
            line1 = line1, line2 = line1,
          }
        elseif best and line >= best.source.line1 and line <= best.source.line2 then
          local unit_col1, unit_col2 = node_line_range(best, line, line_length)
          units[#units + 1] = {
            type = best.type, id = best.id, col1 = unit_col1, col2 = unit_col2,
            line1 = best.source.line1, line2 = best.source.line2,
          }
        elseif not best and not list_marker and not has_localized_reveal and line == line1 then
          units[#units + 1] = { type = "line", col1 = 1, col2 = line_length + 1, whole_line = true }
        end
      end
    end
  end
  return units
end

local function reveal_unit_matches(units, semantic_id, col1, col2)
  for _, unit in ipairs(units or {}) do
    if unit.whole_line or unit.id == semantic_id
      or unit.col1 == col1 and unit.col2 == col2
      or unit.type == "heading" and unit.col1 <= col1 and unit.col2 >= col2
    then
      return true
    end
  end
  return false
end

local function semantic_heading_for_line(view, line_text, line)
  local nodes, generation = semantic_line(view, line)
  for _, node in ipairs(nodes or {}) do
    if node.type == "heading" and node.source.line1 == line then
      local suppressed = false
      for _, comment in ipairs(nodes or {}) do
        if comment.type == "comment" and line >= comment.source.line1 and line <= comment.source.line2 then
          local col1 = line == comment.source.line1 and comment.source.col1 or 1
          local col2 = line == comment.source.line2 and comment.source.col2 or #line_text + 1
          if col1 <= node.source.col1 and col2 > node.source.col1 then suppressed = true break end
        end
      end
      if suppressed then return nil end
      local heading = heading_for_line(line_text, line)
      if not heading and node.source.line2 > node.source.line1 then
        local underline = (view.doc.lines[line + 1] or ""):gsub("\n$", "")
        local indent, marks = underline:match("^( *)(=+)[ \t]*$")
        local level = 1
        if not marks then
          indent, marks = underline:match("^( *)(%-+)[ \t]*$")
          level = 2
        end
        if marks and #indent <= 3 then
          local content_col1 = line_text:find("%S") or 1
          local content_col2 = #line_text + 1
          while content_col2 > content_col1
            and line_text:sub(content_col2 - 1, content_col2 - 1):match("%s")
          do
            content_col2 = content_col2 - 1
          end
          heading = {
            level = level, line = line, marker_col1 = content_col1,
            content_col1 = content_col1, content_col2 = content_col2,
            text = line_text:sub(content_col1, content_col2 - 1), setext = true,
          }
        end
      end
      if heading then
        heading.semantic_id = node.id
        heading.semantic_generation = generation
        heading.source_col1 = node.source.col1
        heading.source_col2 = #line_text + 1
        return heading
      end
    end
  end
end

local function semantic_setext_marker_for_line(view, line_text, line)
  local indent, marks = line_text:match("^( *)(=+)[ \t]*$")
  if not marks then indent, marks = line_text:match("^( *)(%-+)[ \t]*$") end
  if not marks or #indent > 3 then return nil end
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "heading" and node.source.line1 < line and node.source.line2 >= line then
      return node
    end
  end
end

local FORMATTING_TYPES = {
  strong = true,
  emphasis = true,
  strikethrough = true,
  highlight = true,
  code = true,
}

local function semantic_formatting_spans(view, line_text, line)
  local nodes, generation = semantic_line(view, line)
  if not nodes then return nil end
  local spans = {}
  for _, node in ipairs(nodes) do
    if FORMATTING_TYPES[node.type] and node.source.line1 == line and node.source.line2 == line then
      local markers = {}
      for _, marker in ipairs(node.marker_ranges or {}) do markers[#markers + 1] = marker end
      table.sort(markers, function(a, b) return a.col1 < b.col1 end)
      local content_col1, content_col2 = node.source.col1, node.source.col2
      local advanced = true
      while advanced do
        advanced = false
        for _, marker in ipairs(markers) do
          if marker.col1 == content_col1 then content_col1, advanced = marker.col2, true end
        end
      end
      advanced = true
      while advanced do
        advanced = false
        for _, marker in ipairs(markers) do
          if marker.col2 == content_col2 then content_col2, advanced = marker.col1, true end
        end
      end
      spans[#spans + 1] = {
        type = node.type,
        line = line,
        col1 = node.source.col1,
        col2 = node.source.col2,
        markers = markers,
        text = line_text:sub(content_col1, content_col2 - 1),
        content_ranges = { { line = line, col1 = content_col1, col2 = content_col2 } },
        semantic_id = node.id,
        semantic_generation = generation,
      }
    end
  end
  return spans
end

local function markdown_live_scaled_font(view, source, size)
  size = size or view:get_font():get_size()
  if source:get_size() == size then return source end
  local cache = view.__markdown_live_scaled_fonts or {}
  view.__markdown_live_scaled_fonts = cache
  local fonts = cache[source]
  if not fonts then
    fonts = {}
    cache[source] = fonts
  end
  if not fonts[size] then fonts[size] = source:copy(size) end
  return fonts[size]
end

local function markdown_live_body_font(view)
  return markdown_live_scaled_font(view, style.prose_font)
end

local function markdown_live_body_line_height(view)
  return math.floor(markdown_live_body_font(view):get_height() * config.line_height)
end

local function heading_font(view, level)
  view.__markdown_live_heading_fonts = view.__markdown_live_heading_fonts or {}
  local cache = view.__markdown_live_heading_fonts
  local font = markdown_live_scaled_font(view, style.prose_heading_font)
  local size = font:get_size()
  local scale = ({ 1.65, 1.45, 1.30, 1.18, 1.08, 1.0 })[level] or 1
  local key = tostring(font) .. ":" .. tostring(size) .. ":" .. tostring(level)
  if not cache[key] then
    cache[key] = font:copy(math.max(1, math.floor(size * scale)))
  end
  return cache[key]
end

local function heading_italic_font(view, level)
  return markdown_live_scaled_font(
    view, style.prose_heading_emphasis_font,
    heading_font(view, level):get_size()
  )
end

local function heading_text_row_height(view, level)
  local font_height = heading_font(view, level):get_height()
  return math.max(
    font_height,
    math.floor(font_height * config.markdown_live_heading_line_height + 0.5)
  )
end

local function markdown_block_gap(view)
  return math.max(1, math.floor(markdown_live_body_font(view):get_height() * 0.7))
end

local function inline_style_font(
  view, span_type, base_font, base_bold, base_italic_font
)
  view.__markdown_live_inline_fonts = view.__markdown_live_inline_fonts or {}
  local cache = view.__markdown_live_inline_fonts
  local font
  if span_type == "code" then
    font = style.code_font
  elseif base_bold and (span_type == "emphasis" or span_type == "strong_emphasis")
    and base_italic_font
  then
    font = base_italic_font
  elseif base_bold and span_type == "strong" and base_font then
    font = base_font
  elseif span_type == "strong_emphasis" or base_bold and span_type == "emphasis" then
    font = style.prose_strong_emphasis_font
  elseif span_type == "strong" then
    font = style.prose_strong_font
  elseif span_type == "emphasis" then
    font = style.prose_emphasis_font
  else
    font = base_font or style.prose_font
  end
  local size = base_font and base_font:get_size() or view:get_font():get_size()
  local key = tostring(font) .. ":" .. tostring(size) .. ":" .. tostring(span_type)
  if not cache[key] then
    cache[key] = font:copy(size)
  end
  return cache[key]
end

local function normal_text_color()
  return style.text or style.syntax.normal
end

local function formatting_spans_share_delimiter_run(a, b)
  if a.type ~= b.type or a.line ~= b.line then return false end
  local outer, inner = a, b
  if inner.col1 < outer.col1 or inner.col2 > outer.col2 then
    outer, inner = inner, outer
  end
  if outer.col1 >= inner.col1 or outer.col2 <= inner.col2 then return false end
  local adjacent_open, adjacent_close = false, false
  for _, marker in ipairs(outer.markers or {}) do
    if marker.col1 == outer.col1 and marker.col2 == inner.col1 then
      adjacent_open = true
    elseif marker.col1 == inner.col2 and marker.col2 == outer.col2 then
      adjacent_close = true
    end
  end
  return adjacent_open and adjacent_close
end

local function semantic_formatting_fragments(view, line_text, line, reveal_units, opts)
  opts = opts or {}
  local spans = semantic_formatting_spans(view, line_text, line) or {}
  local nodes = semantic_line(view, line) or {}
  local specials = {}
  for _, node in ipairs(nodes) do
    if node.type == "escape" and node.source.line1 == line and node.source.line2 == line then
      specials[#specials + 1] = {
        type = "escape", id = node.id,
        col1 = node.source.col1, col2 = node.source.col2,
      }
    elseif node.type == "comment" and line >= node.source.line1 and line <= node.source.line2 then
      local markers = {}
      for _, marker in ipairs(node.marker_ranges or {}) do
        if marker.line1 == line then markers[#markers + 1] = marker end
      end
      local comment_col1 = line == node.source.line1 and node.source.col1 or 1
      local comment_col2 = line == node.source.line2 and node.source.col2 or #line_text + 1
      if line == node.source.line1 and line_text:sub(comment_col1, comment_col1 + 1) == "%%" then
        markers[#markers + 1] = { col1 = comment_col1, col2 = comment_col1 + 2 }
      end
      if line == node.source.line2 and line_text:sub(comment_col2 - 2, comment_col2 - 1) == "%%" then
        markers[#markers + 1] = { col1 = comment_col2 - 2, col2 = comment_col2 }
      end
      specials[#specials + 1] = {
        type = "comment", id = node.id, markers = markers,
        col1 = comment_col1, col2 = comment_col2,
      }
    end
  end
  if #spans == 0 and #specials == 0 then return {} end
  local revealed_spans = {}
  for _, span in ipairs(spans) do
    if reveal_unit_matches(reveal_units, span.semantic_id, span.col1, span.col2) then
      revealed_spans[span] = true
    end
  end
  local expanded = true
  while expanded do
    expanded = false
    for _, revealed in ipairs(spans) do
      if revealed_spans[revealed] then
        for _, candidate in ipairs(spans) do
          if not revealed_spans[candidate]
            and formatting_spans_share_delimiter_run(revealed, candidate)
          then
            revealed_spans[candidate] = true
            expanded = true
          end
        end
      end
    end
  end
  local range_col1 = opts.col1 or 1
  local range_col2 = opts.col2 or #line_text + 1
  local boundaries = { [range_col1] = true, [range_col2] = true }
  for _, special in ipairs(specials) do
    boundaries[math.max(range_col1, special.col1)] = true
    boundaries[math.min(range_col2, special.col2)] = true
    for _, marker in ipairs(special.markers or {}) do
      boundaries[math.max(range_col1, marker.col1)] = true
      boundaries[math.min(range_col2, marker.col2)] = true
    end
    if special.type == "escape" then
      boundaries[math.max(range_col1, math.min(special.col2, special.col1 + 1))] = true
    end
  end
  for _, span in ipairs(spans) do
    local content = span.content_ranges[1]
    boundaries[math.max(range_col1, span.col1)] = true
    boundaries[math.min(range_col2, span.col2)] = true
    boundaries[math.max(range_col1, content.col1)] = true
    boundaries[math.min(range_col2, content.col2)] = true
    for _, marker in ipairs(span.markers or {}) do
      boundaries[math.max(range_col1, marker.col1)] = true
      boundaries[math.min(range_col2, marker.col2)] = true
    end
  end
  local cols = {}
  for col in pairs(boundaries) do
    if col >= range_col1 and col <= range_col2 then cols[#cols + 1] = col end
  end
  table.sort(cols)
  local fragments = {}
  for i = 1, #cols - 1 do
    local col1, col2 = cols[i], cols[i + 1]
    if col1 < col2 then
      local marker, marker_revealed, active_spans = false, false, {}
      local comment, comment_marker, escape_marker, escape_content
      for _, special in ipairs(specials) do
        if special.col1 <= col1 and special.col2 >= col2 then
          if special.type == "comment" then
            comment = special
            for _, range in ipairs(special.markers or {}) do
              if range.col1 <= col1 and range.col2 >= col2 then comment_marker = true break end
            end
          end
          if special.type == "escape" then
            if col2 <= special.col1 + 1 then escape_marker = special else escape_content = special end
          end
        end
      end
      for _, span in ipairs(spans) do
        for _, range in ipairs(span.markers or {}) do
          if range.col1 <= col1 and range.col2 >= col2 then
            marker = true
            marker_revealed = marker_revealed or revealed_spans[span]
            break
          end
        end
        local content = span.content_ranges[1]
        if content.col1 <= col1 and content.col2 >= col2 then active_spans[#active_spans + 1] = span end
      end
      local function composed_fragment(extra_id)
        local bold, italic, strike, highlight, code = false, false, false, false, false
        local ids = {}
        for _, span in ipairs(active_spans) do
          bold = bold or span.type == "strong"
          italic = italic or span.type == "emphasis"
          strike = strike or span.type == "strikethrough"
          highlight = highlight or span.type == "highlight"
          code = code or span.type == "code"
          ids[#ids + 1] = span.semantic_id
        end
        if extra_id then ids[#ids + 1] = extra_id end
        local font_type = bold and italic and "strong_emphasis"
          or bold and "strong" or italic and "emphasis" or "normal"
        return {
          source_col1 = col1, source_col2 = col2,
          text = line_text:sub(col1, col2 - 1),
          font = code and inline_style_font(
            view, "code", opts.base_font, opts.base_bold, opts.base_italic_font
          )
            or font_type ~= "normal"
              and inline_style_font(
                view, font_type, opts.base_font, opts.base_bold,
                opts.base_italic_font
              )
            or opts.base_font,
          color = opts.color or normal_text_color(),
          strikethrough = strike or nil,
          background = code and style.markdown_live_inline_code_bg
            or highlight and style.markdown_live_highlight_bg or nil,
          semantic_id = table.concat(ids, "+"),
        }
      end
      local comment_revealed = comment
        and reveal_unit_matches(reveal_units, comment.id, comment.col1, comment.col2)
      local escape_revealed = (escape_marker or escape_content)
        and reveal_unit_matches(
          reveal_units, (escape_marker or escape_content).id,
          (escape_marker or escape_content).col1, (escape_marker or escape_content).col2
        )
      if comment then
        if comment_revealed then
          local fragment = composed_fragment(comment.id)
          if comment_marker then fragment.color = style.markdown_live_hidden_syntax end
          fragments[#fragments + 1] = fragment
        else
          fragments[#fragments + 1] = {
            source_col1 = col1, source_col2 = col2,
            hidden = true, semantic_id = comment.id,
          }
        end
      elseif marker or escape_marker then
        local revealed = marker_revealed or escape_revealed
        fragments[#fragments + 1] = {
          source_col1 = col1, source_col2 = col2,
          text = revealed and line_text:sub(col1, col2 - 1) or nil,
          hidden = not revealed,
          font = opts.base_font,
          color = style.markdown_live_hidden_syntax,
          semantic_id = escape_marker and escape_marker.id or nil,
        }
      elseif #active_spans > 0 or escape_content then
        fragments[#fragments + 1] = composed_fragment(escape_content and escape_content.id)
      end
    end
  end
  local merged = {}
  for _, fragment in ipairs(fragments) do
    local previous = merged[#merged]
    if previous and previous.source_col2 == fragment.source_col1
      and previous.hidden == fragment.hidden and previous.font == fragment.font
      and previous.color == fragment.color and previous.background == fragment.background
      and previous.strikethrough == fragment.strikethrough
      and previous.overdraw == fragment.overdraw and previous.semantic_id == fragment.semantic_id
    then
      previous.source_col2 = fragment.source_col2
      previous.text = (previous.text or "") .. (fragment.text or "")
    else
      merged[#merged + 1] = fragment
    end
  end
  return merged
end

local function target_extension(path)
  local ext = ((path or ""):match("^[^#?]+") or (path or "")):match("%.([^%.?#/\\]+)$")
  return ext and ext:lower() or nil
end

local function is_image_target(path)
  return IMAGE_EXTENSIONS[target_extension(path) or ""] == true
end

local function attachment_kind(path)
  local ext = target_extension(path)
  if ext == "pdf" then return "pdf", "▣" end
  if AUDIO_EXTENSIONS[ext or ""] then return "audio", "♪" end
  if VIDEO_EXTENSIONS[ext or ""] then return "video", "▶" end
end

local function image_vertical_padding()
  return math.max(1, math.floor(6 * SCALE))
end

local function image_available_width(view)
  -- Block images use the presentation viewport rather than the prose wrap
  -- column. A narrow prose guide must not shrink an image block or make its
  -- editable source occupy phantom rows above the image.
  local scrollbar_width = view.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local width = view:get_presentation_viewport_width()
    - view:get_gutter_width() - scrollbar_width
  return math.max(1, math.floor(width))
end

local function perf_frame_add(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.frame_add then perf.frame_add(key, amount or 1) end
end

local function perf_detail(key, amount)
  local perf = package.loaded["core.perf"]
  if perf and perf.is_recording and perf.is_recording() and perf.add_detail then
    perf.add_detail(key, amount or 1)
  end
end

local function active_perf()
  local perf = package.loaded["core.perf"]
  return perf and perf.is_recording and perf.is_recording() and perf or nil
end

local function elapsed_ms(started)
  return started and (system.get_time() - started) * 1000 or 0
end

local function add_fragment(fragments, occupied, fragment)
  local col1 = fragment.source_col1 or 1
  local col2 = fragment.source_col2 or col1
  for _, range in ipairs(occupied) do
    if col1 < range[2] and range[1] < col2 then return false end
  end
  fragments[#fragments + 1] = fragment
  occupied[#occupied + 1] = { col1, col2 }
  return true
end

local resolve_live_link

local function remote_image_allowed(view, url, project)
  if not images.is_remote(url) then return false end
  if config.markdown_live_download_remote_images == true then return true end
  local owner = view.__markdown_live_owner
  if owner and owner.one_shot_remote_images and owner.one_shot_remote_images[url] then return true end
  local root = project and project.path
  local key = root and common.path_compare_key(common.normalize_path(root))
  return key and config.markdown_live_trusted_remote_image_projects
    and config.markdown_live_trusted_remote_image_projects[key] == true or false
end

local function image_fragment(view, span, opts)
  perf_frame_add("markdown_live_image_fragment_calls", 1)
  opts = opts or {}
  if config.markdown_live_render_images ~= true then return nil end
  local link = span.link
  if not (link and (link.kind == "image" or link.kind == "embed") and is_image_target(link.path)) then return nil end
  view.__markdown_live_image_cache = view.__markdown_live_image_cache or {}
  view.__markdown_live_image_references = view.__markdown_live_image_references or {}
  local project = core.current_project(view.doc.abs_filename)
  local owner = view.__markdown_live_owner
  local resolution = resolve_live_link(view, link)
  local image_source = resolution.status == "resolved" and resolution.kind == "attachment"
    and resolution.path or link.path
  local asset_opts = {
    alt = link.alias or link.alt,
    source_path = view.doc.abs_filename,
    project_root = project and project.path,
    download_remote = remote_image_allowed(view, image_source, project),
    retry_generation = owner and owner.link_index and owner.link_index.generation or 0,
  }
  -- get_asset already resolves the source path while deriving its cache key.
  -- Reuse that key instead of repeating the filesystem/vault search here.
  local entry = images.get_asset(image_source, asset_opts)
  local key = entry.key or images.asset_key(image_source, asset_opts)
  local reference_id = link.semantic_id or table.concat({ span.line, span.col1, span.col2 }, ":")
  local old_key = view.__markdown_live_image_references[reference_id]
  if old_key and old_key ~= key then
    local old_record = view.__markdown_live_image_cache[old_key]
    if old_record then
      old_record.consumers[reference_id] = nil
      if not next(old_record.consumers) then
        images.unsubscribe(old_record.entry, view)
        view.__markdown_live_image_cache[old_key] = nil
      end
    end
  end
  view.__markdown_live_image_references[reference_id] = key

  local record = view.__markdown_live_image_cache[key]
  if not record or record.entry ~= entry then
    if record then images.unsubscribe(record.entry, view) end
    record = { entry = entry, consumers = {} }
    view.__markdown_live_image_cache[key] = record
    images.subscribe(entry, view, function()
      local lines = {}
      for _, line in pairs(record.consumers) do lines[line] = true end
      for line in pairs(lines) do
        view:invalidate_line_render(PROVIDER_ID, line, line)
        view:invalidate_visual_metrics(PROVIDER_ID, line, line)
      end
      core.redraw = true
    end)
  end
  record.consumers[reference_id] = span.line

  if entry.status == "ready" and entry.image then
    local natural_w, natural_h = entry.image:get_size()
    local width, height
    if opts.block then
      local available_width = math.max(1, math.floor(opts.available_width or image_available_width(view)))
      width, height = images.scale_size(
        natural_w, natural_h, available_width, link.resize, false
      )
    else
      width, height = images.scale_size(
        natural_w, natural_h, 320 * SCALE, link.resize, false
      )
    end
    local padding = image_vertical_padding()
    return {
      source_col1 = span.col1,
      source_col2 = span.col2,
      width = opts.width or width,
      image_path = entry.path,
      widget = {
        type = "image",
        width = width,
        height = height + padding * 2,
        image_height = height,
        padding = padding,
        cursor = "hand",
        on_mouse_pressed = function(_, owner, hit, button)
          if button ~= "left" then return false end
          owner.doc:set_selection(hit.line, 1)
          return common.open_in_system(hit.fragment.image_path)
        end,
        draw = function(_, fragment, x, y, row_height)
          local image = entry.image
          if width ~= natural_w or height ~= natural_h then
            if not entry.scaled_image or entry.scaled_width ~= width or entry.scaled_height ~= height then
              entry.scaled_image = image:scaled(width, height, "linear")
              entry.scaled_width, entry.scaled_height = width, height
            end
            image = entry.scaled_image
          end
          local image_x = x + (fragment.draw_x_offset or 0)
          local image_y
          if fragment.draw_y_offset then
            image_y = y + fragment.draw_y_offset
          else
            image_y = y + math.max(0, (row_height - height) / 2)
          end
          renderer.draw_canvas(image, image_x, image_y)
        end,
      },
    }
  end

  local label = link.alias or link.alt
  if not label or label == "" then label = link.path or link.raw_target or "" end
  local status_text, color = "image unavailable", style.markdown_live_image_error
  -- Obsidian-style embeds depend on the vault index to find attachments by
  -- name. The local-path fallback may miss while that index is still being
  -- built, but that is not a failed image load: its ready notification will
  -- invalidate this row and retry resolution.
  local display_status = entry.status
  if display_status == "error" and resolution.status == "pending" then
    display_status = "loading"
  end
  if display_status == "loading" then
    status_text, color = "loading image", style.markdown_live_image_loading
  elseif display_status == "remote-disabled" then
    status_text, color = "remote image blocked", style.markdown_live_image_blocked
  end
  return {
    source_col1 = span.col1,
    source_col2 = span.col2,
    text = "[" .. status_text .. ": " .. label .. "]",
    color = color,
    image_status = display_status,
  }
end

local function semantic_range_text_from_doc(view, range)
  if not range or range.line1 ~= range.line2 then return nil end
  local text = (view.doc.lines[range.line1] or ""):gsub("\n$", "")
  return text:sub(range.col1, range.col2 - 1)
end

local function normalize_reference_label(value)
  value = (value or ""):gsub("^%[", ""):gsub("%]$", "")
  return value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):lower()
end

local function prepare_reference_definitions(view, instance)
  instance = instance or current_semantic_model(view)
  if not instance or instance.status ~= "ready" then return {} end
  local cache = view.__markdown_live_reference_cache
  if cache and cache.generation == instance.generation then return cache.definitions end
  local nodes, reason = instance:nodes_for_lines(1, #view.doc.lines, { limit = 8192 })
  local definitions = {}
  if reason ~= "limit" then
    for _, node in ipairs(nodes or {}) do
      if node.type == "link_reference" then
        local attributes = node.attributes or {}
        local label = semantic_range_text_from_doc(view, attributes.reference_label)
        local destination = semantic_range_text_from_doc(view, attributes.reference_destination)
        local key = normalize_reference_label(label)
        if key ~= "" and destination and destination ~= "" and not definitions[key] then
          if destination:sub(1, 1) == "<" and destination:sub(-1) == ">" then
            destination = destination:sub(2, -2)
          end
          definitions[key] = {
            label = (label or ""):gsub("^%[", ""):gsub("%]$", ""),
            destination = destination,
            node = node,
          }
        end
      end
    end
  else
    core.log_quiet("Markdown reference definitions exceeded capture bound for %s", view.doc:get_name())
  end
  cache = { generation = instance.generation, definitions = definitions }
  view.__markdown_live_reference_cache = cache
  return definitions
end

local function reference_definitions(view)
  local instance = current_semantic_model(view)
  if not instance then return {} end
  local cache = view.__markdown_live_reference_cache
  if cache and cache.generation == instance.generation then return cache.definitions end
  if not view.__markdown_live_reference_prepare_pending then
    view.__markdown_live_reference_prepare_pending = instance.generation
    core.add_thread(function()
      coroutine.yield(0)
      if view.__markdown_live_attached and current_semantic_model(view) == instance then
        prepare_reference_definitions(view, instance)
        view:invalidate_line_render(PROVIDER_ID)
        core.redraw = true
      end
      if view.__markdown_live_reference_prepare_pending == instance.generation then
        view.__markdown_live_reference_prepare_pending = nil
      end
    end)
  end
  return {}
end

local function reference_link_from_node(view, line_text, line, node)
  local attributes = node.attributes or {}
  local label_source = semantic_range_text_from_doc(view, attributes.reference_label)
  local text_source = semantic_range_text_from_doc(view, attributes.link_text)
  local display = (text_source or label_source or ""):gsub("^%[", ""):gsub("%]$", "")
  local key = normalize_reference_label(label_source or text_source)
  if key:sub(1, 1) == "^" then return nil end
  local definition = reference_definitions(view)[key]
  if not definition then return nil end
  return markdown_links.from_target("reference", definition.destination, display, {
    source_line = line,
    source_col1 = node.source.col1,
    source_col2 = node.source.col2,
    semantic_id = node.id,
    reference_label = key,
  })
end

local function semantic_link_spans(view, line_text, line)
  local nodes = semantic_line(view, line)
  local by_range = {}
  for _, node in ipairs(nodes or {}) do
    if node.type == "link" or node.type == "image" or node.type == "link_reference"
      or node.type == "wiki_link" or node.type == "embed"
    then
      local link = node.type == "link_reference"
        and reference_link_from_node(view, line_text, line, node)
        or markdown_links.from_semantic_node(line_text, line, node)
      if link then
        local key = node.source.col1 .. ":" .. node.source.col2
        local current = by_range[key]
        if not current or node.type == "embed" or current.type == "image" then
          by_range[key] = {
            type = node.type,
            line = line,
            col1 = node.source.col1,
            col2 = node.source.col2,
            link = link,
            text = link.display,
            semantic_id = node.id,
            attributes = node.attributes,
          }
        end
      end
    end
  end
  local spans = {}
  for _, span in pairs(by_range) do spans[#spans + 1] = span end
  table.sort(spans, function(a, b) return a.col1 < b.col1 end)
  return spans
end

local function semantic_comment_overlaps(view, line, col1, col2)
  local nodes = semantic_line(view, line)
  for _, node in ipairs(nodes or {}) do
    if node.type == "comment" and line >= node.source.line1 and line <= node.source.line2 then
      local comment_col1 = line == node.source.line1 and node.source.col1 or 1
      local comment_col2 = line == node.source.line2 and node.source.col2 or math.huge
      if comment_col1 < col2 and comment_col2 > col1 then return true end
    end
  end
  return false
end

local function image_only_span(view, line_text, line)
  local trimmed_start = line_text:find("%S")
  if not trimmed_start then return nil end
  local trimmed_end = line_text:match("^.*%S()")
  for _, span in ipairs(semantic_link_spans(view, line_text, line)) do
    local link = span.link
    if link and (link.kind == "image" or link.kind == "embed") and is_image_target(link.path)
    and span.col1 == trimmed_start and span.col2 == trimmed_end
    and not semantic_comment_overlaps(view, line, span.col1, span.col2) then
      return span
    end
  end
end

local revealed_link_fragments

local function image_only_render_line(view, text, line, span, active)
  local body_font = markdown_live_body_font(view)
  local leading_width = span.col1 > 1
    and body_font:get_width(text:sub(1, span.col1 - 1)) or 0
  local image = image_fragment(view, span, {
    block = true,
    available_width = image_available_width(view) - leading_width,
    width = active and 0 or nil,
  })
  if not image then return nil end
  image.semantic_id = span.semantic_id
  image.image_anchor = true
  if active then
    local fragments = revealed_link_fragments(view, text, line, span, {
      base_font = body_font,
    })
    if image.widget then
      image.source_col1 = #text + 1
      image.source_col2 = #text + 1
      image.draw_x_offset = leading_width - body_font:get_width(text)
      image.draw_y_offset = markdown_live_body_line_height(view) + image_vertical_padding()
      image.widget.height = image.widget.height + markdown_live_body_line_height(view)
      fragments[#fragments + 1] = image
    end
    return {
      source_text = text,
      caret_height = markdown_live_body_line_height(view),
      fragments = fragments,
    }
  end
  if image.widget and span.col1 > 1 then
    image.draw_x_offset = markdown_live_body_font(view):get_width(text:sub(1, span.col1 - 1))
  end
  return {
    source_text = text,
    disable_wrapping = true,
    fragments = {
      { source_col1 = 1, source_col2 = span.col1, hidden = true },
      image,
      { source_col1 = span.col2, source_col2 = #text + 1, hidden = true },
    },
  }
end

resolve_live_link = function(view, link)
  local owner = view.__markdown_live_owner
  local index = owner and owner.link_index
  local target = link.raw_target or link.path or ""
  if not common.is_absolute_path(target) and target:match("^[%a][%w+.-]*:") then
    return { status = "external", target = target, path = target }
  elseif index and index:can_resolve() then
    return index:resolve(link, view.doc.abs_filename)
  end
  if owner then owner.link_resolution_pending = true end
  return { status = "pending", target = target, reason = "indexing" }
end

local function decorate_link_fragment(view, line, span, fragment, opts)
  opts = opts or {}
  if semantic_comment_overlaps(view, line, span.col1, span.col2) then return nil end
  local resolution = resolve_live_link(view, span.link)
  fragment.link = span.link
  fragment.link_resolution = resolution
  fragment.cursor = "hand"
  fragment.on_mouse_pressed = function(self, owner, _, button)
    if button ~= "left" then return false end
    owner:set_selection_state({
      selections = { line, span.col1, line, span.col1 },
      last_selection = 1,
    })
    return live.open_link(owner, { link = self.link, resolution = self.link_resolution })
  end
  if not fragment.widget and not fragment.image_status then
    fragment.color = style.markdown_live_link
    fragment.underline = true
  end
  local bold, italic, strike, highlight, code = false, false, false, false, false
  local ids = { span.semantic_id }
  for _, formatting in ipairs(semantic_formatting_spans(view, "", line) or {}) do
    local content = formatting.content_ranges[1]
    if content.col1 <= span.col1 and content.col2 >= span.col2 then
      bold = bold or formatting.type == "strong"
      italic = italic or formatting.type == "emphasis"
      strike = strike or formatting.type == "strikethrough"
      highlight = highlight or formatting.type == "highlight"
      code = code or formatting.type == "code"
      ids[#ids + 1] = formatting.semantic_id
    end
  end
  local font_type = bold and italic and "strong_emphasis"
    or bold and "strong" or italic and "emphasis" or "normal"
  fragment.font = code and inline_style_font(
    view, "code", opts.base_font, opts.base_bold, opts.base_italic_font
  )
    or font_type ~= "normal"
      and inline_style_font(
        view, font_type, opts.base_font, opts.base_bold, opts.base_italic_font
      )
    or opts.base_font or fragment.font
  fragment.strikethrough = strike or nil
  fragment.background = code and style.markdown_live_inline_code_bg
    or highlight and style.markdown_live_highlight_bg or fragment.background
  fragment.semantic_id = #ids > 0 and table.concat(ids, "+") or fragment.semantic_id
  return fragment
end

local function textual_link_label(link)
  if link.alias and link.alias ~= "" then return link.alias end
  if link.kind == "wiki" or link.kind == "embed" then
    return link.raw_target or link.display or ""
  end
  return link.display ~= "" and link.display or link.raw_target or ""
end

revealed_link_fragments = function(view, line_text, line, span, opts)
  local linked_col1, linked_col2
  if span.type == "wiki_link" or span.type == "embed" then
    local marker_width = line_text:sub(span.col1, span.col1) == "!" and 3 or 2
    linked_col1, linked_col2 = span.col1 + marker_width, span.col2 - 2
  else
    local attributes = span.attributes or {}
    local range = attributes.link_text or attributes.image_alt or attributes.reference_label
      or attributes.link_destination
    if range and range.line1 == line and range.line2 == line then
      linked_col1, linked_col2 = range.col1, range.col2
    end
  end
  if not linked_col1 or linked_col2 <= linked_col1 then
    linked_col1, linked_col2 = span.col1, span.col2
  end

  local fragments = {}
  local function marker(col1, col2)
    if col2 <= col1 then return end
    fragments[#fragments + 1] = {
      source_col1 = col1, source_col2 = col2,
      text = line_text:sub(col1, col2 - 1),
      color = style.markdown_live_hidden_syntax,
      font = opts and opts.base_font or nil,
      semantic_id = span.semantic_id .. ":syntax:" .. col1,
    }
  end
  marker(span.col1, linked_col1)
  local linked = decorate_link_fragment(view, line, span, {
    source_col1 = linked_col1, source_col2 = linked_col2,
    text = line_text:sub(linked_col1, linked_col2 - 1),
    semantic_id = span.semantic_id,
  }, opts)
  if linked then fragments[#fragments + 1] = linked end
  marker(linked_col2, span.col2)
  return fragments
end

local function embed_preview_for_resolution(resolution)
  if not (resolution and resolution.status == "resolved" and resolution.kind == "note")
    or resolution.subtarget_missing
  then
    return nil
  end
  if resolution.block then return resolution.block.embed_preview end
  if resolution.heading then return resolution.heading.embed_preview end
  return resolution.entry and resolution.entry.embed_preview
end

local function embed_preview_fragment(view, line_text, span)
  local link = span.link
  if not (link and link.kind == "embed") or is_image_target(link.path)
    or attachment_kind(link.path) or semantic_comment_overlaps(view, span.line, span.col1, span.col2)
  then
    return nil
  end
  local resolution = resolve_live_link(view, link)
  local preview = embed_preview_for_resolution(resolution)
  if not preview or #preview == 0 then return nil end
  local body_font = markdown_live_body_font(view)
  local line_height = markdown_live_body_line_height(view)
  local padding = math.max(2, math.floor(4 * SCALE))
  return {
    source_col1 = #line_text + 1, source_col2 = #line_text + 1,
    width = 0, draw_x_offset = 0,
    draw_y_offset = line_height,
    semantic_id = span.semantic_id .. ":preview",
    embed_preview = true, preview_lines = preview,
    widget = {
      type = "markdown-embed-preview",
      width = math.max(1, view.size.x),
      height = line_height + #preview * line_height + padding * 2,
      cursor = "hand",
      draw = function(_, fragment, x, y)
        local card_x = x - body_font:get_width(line_text)
        local card_y = y + (fragment.draw_y_offset or line_height)
        local width = math.max(1, view.size.x)
        renderer.draw_rect(card_x, card_y, width, #preview * line_height + padding * 2,
          style.markdown_live_embed_background)
        for i, text in ipairs(preview) do
          renderer.draw_text(body_font, text, card_x + padding,
            card_y + padding + (i - 1) * line_height, style.markdown_live_embed_text)
        end
      end,
      on_mouse_pressed = function(_, owner, _, button)
        if button ~= "left" then return false end
        return live.open_link(owner, { link = link, resolution = resolution })
      end,
    },
  }
end

local function link_text_source_range(line_text, span, label)
  if not label or label == "" then return nil end
  local attributes = span.attributes or {}
  local candidate_names = {
    "alias", "target", "link_text", "image_alt",
    "reference_label", "link_destination",
  }
  for _, name in ipairs(candidate_names) do
    local range = attributes[name]
    if range and (not range.line1 or range.line1 == span.line)
      and (not range.line2 or range.line2 == span.line)
    then
      local col1 = math.max(span.col1, range.col1 or span.col1)
      local col2 = math.min(span.col2, range.col2 or span.col2)
      local source = col2 > col1 and line_text:sub(col1, col2 - 1) or ""
      local offset = source:find(label, 1, true)
      if offset then
        local text_col1 = col1 + offset - 1
        return text_col1, text_col1 + #label
      end
    end
  end
end

local function semantic_link_fragments(view, line_text, line, reveal_units, opts)
  local fragments = {}
  for _, span in ipairs(semantic_link_spans(view, line_text, line)) do
    local revealed = reveal_unit_matches(reveal_units, span.semantic_id, span.col1, span.col2)
    local image_link = span.link
      and (span.link.kind == "image" or span.link.kind == "embed")
      and is_image_target(span.link.path)
    if image_link and revealed then
      for _, fragment in ipairs(revealed_link_fragments(view, line_text, line, span, opts)) do
        fragments[#fragments + 1] = fragment
      end
      local image = image_fragment(view, span, { block = true, width = 0 })
      if image and image.widget then
        image.source_col1, image.source_col2 = span.col2, span.col2
        image.semantic_id = span.semantic_id
        image.image_anchor = true
        image.image_block = true
        image.image_block_col1, image.image_block_col2 = span.col1, span.col2
        image.image_block_active = true
        fragments[#fragments + 1] = image
      end
    elseif span.link and revealed then
      for _, fragment in ipairs(revealed_link_fragments(view, line_text, line, span, opts)) do
        fragments[#fragments + 1] = fragment
      end
    elseif span.link then
      local fragment = image_fragment(view, span, image_link and { block = true } or nil)
      if not fragment then
        local link = span.link
        local kind, icon = attachment_kind(link.path or link.raw_target)
        local label = textual_link_label(link)
        if kind then
          fragment = {
            source_col1 = span.col1,
            source_col2 = span.col2,
            text = icon .. " " .. label,
            color = style.markdown_live_link,
            background = style.markdown_live_attachment_bg,
            attachment_chip = true,
            attachment_kind = kind,
          }
        else
          fragment = {
            source_col1 = span.col1,
            source_col2 = span.col2,
            text = label,
            color = style.markdown_live_link,
          }
        end
        local text_col1, text_col2 = link_text_source_range(line_text, span, fragment.text)
        if text_col1 then
          fragment.text_source_col1 = text_col1
          fragment.text_source_col2 = text_col2
        end
      end
      fragment = decorate_link_fragment(view, line, span, fragment, opts)
      if fragment then
        if image_link and fragment.widget then
          fragment.width = 0
          fragment.image_anchor = true
          fragment.image_block = true
          fragment.image_block_col1, fragment.image_block_col2 = span.col1, span.col2
          fragment.image_block_active = false
        end
        fragments[#fragments + 1] = fragment
        local preview = embed_preview_fragment(view, line_text, span)
        if preview then fragments[#fragments + 1] = preview end
      end
    end
  end
  return fragments
end

local CALLOUT_TYPES = {
  abstract = true, attention = true, bug = true, caution = true, check = true,
  danger = true, done = true, error = true, example = true, fail = true,
  failure = true, faq = true, help = true, hint = true, info = true,
  missing = true, note = true, question = true, quote = true, success = true,
  summary = true, tip = true, todo = true, tldr = true, warning = true,
}

local function parse_callout_header(text)
  local col1, col2, kind, fold, spacing = text:find("^%s*>%s*%[!([%w_-]+)%]([+-]?)(%s*)")
  if not col1 then return nil end
  kind = kind:lower()
  local title = text:sub(col2 + 1)
  local display_type = kind:gsub("[_-]+", " "):gsub("^%l", string.upper)
  return {
    col1 = col1,
    col2 = col2 + 1,
    type = kind,
    known_type = CALLOUT_TYPES[kind] == true,
    fold = fold ~= "" and fold or nil,
    title = title,
    display_type = display_type,
    spacing = spacing,
  }
end

local function callout_for_line(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "quote" then
      local line2 = node.source.line2
      if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
      if line >= node.source.line1 and line <= line2 then
        local text = (view.doc.lines[node.source.line1] or ""):gsub("\n$", "")
        local header = parse_callout_header(text)
        if header then
          header.line1, header.line2, header.semantic_id = node.source.line1, line2, node.id
          return header
        end
      end
    end
  end
end

local function table_for_line(view, line)
  local nodes, semantic_generation = semantic_line(view, line)
  local cache_key = table.concat({
    tostring(view.doc.text_revision or 0),
    tostring(semantic_generation or 0),
    tostring(view.__line_render_invalidation_generation or 0),
  }, ":")
  local cache = view.__markdown_live_table_line_cache
  if not cache or cache.key ~= cache_key then
    cache = { key = cache_key, lines = {} }
    view.__markdown_live_table_line_cache = cache
  end
  local cached = cache.lines[line]
  if cached ~= nil then return cached ~= false and cached or nil end

  local table_node
  for _, node in ipairs(nodes or {}) do
    if node.type == "table" then
      local line2 = node.source.line2
      if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
      if line >= node.source.line1 and line <= line2 then
        table_node = node
        break
      end
    end
  end
  table_node = markdown_tables.extend_semantic_table(view, line, table_node)
  cache.lines[line] = table_node or false
  return table_node
end

local TABLE_MAX_PRESENTATION_ROWS = markdown_tables.MAX_PRESENTATION_ROWS
local TABLE_MAX_PRESENTATION_COLUMNS = markdown_tables.MAX_PRESENTATION_COLUMNS
local TABLE_MAX_CELL_PRESENTATION_BYTES = 4096
local TABLE_LAYOUT_GEOMETRY_CACHE_LIMIT = 4

local table_source_row = markdown_tables.source_row

local function table_cell_content(text, cell)
  local raw = text:sub(cell.col1, cell.col2 - 1)
  local leading = #(raw:match("^%s*") or "")
  local trailing = #(raw:match("%s*$") or "")
  local source_col1, source_col2 = cell.col1 + leading, cell.col2 - trailing
  if source_col1 > source_col2 then
    local empty_col = common.clamp(
      cell.col1 + math.floor(#raw / 2), cell.col1, cell.col2
    )
    return "", empty_col, empty_col
  end
  return raw:sub(leading + 1, #raw - trailing), source_col1, source_col2
end

local function table_cell_text(text, cell)
  return (table_cell_content(text, cell))
end

local function table_cell_presentation(view, text, source_col1, source_col2, header)
  local image_alt = text:match("^!%[([^%]]*)%]%(%s*data:image/[%w%+%.%-]+[;,]")
  if image_alt or #text > TABLE_MAX_CELL_PRESENTATION_BYTES then
    local display
    if image_alt then
      display = image_alt ~= "" and ("[Embedded image: " .. image_alt .. "]")
        or "[Embedded image]"
    else
      local parts, bytes = {}, 0
      for char in common.utf8_chars(text) do
        if bytes + #char > TABLE_MAX_CELL_PRESENTATION_BYTES then break end
        parts[#parts + 1] = char
        bytes = bytes + #char
      end
      display = table.concat(parts) .. "… [cell content truncated]"
    end
    perf_frame_add("markdown_live_table_cell_elisions", 1)
    return {
      text = display,
      source_col1 = source_col1,
      source_col2 = source_col2,
      font = header and inline_style_font(view, "strong") or markdown_live_body_font(view),
      color = header and style.markdown_live_table_header or style.markdown_live_table_cell,
      nowrap = true,
      source_elided = true,
    }
  end
  if not header then
    local ticks = text:match("^(`+)")
    if ticks and #text >= #ticks * 2 and text:sub(-#ticks) == ticks then
      return {
        text = text:sub(#ticks + 1, -#ticks - 1),
        source_col1 = source_col1 + #ticks,
        source_col2 = source_col2 - #ticks,
        font = inline_style_font(view, "code"),
        color = style.markdown_live_table_cell,
        background = style.markdown_live_inline_code_bg,
        nowrap = true,
        literal_breaks = true,
      }
    end
  end
  return {
    text = text,
    source_col1 = source_col1,
    source_col2 = source_col2,
    font = header and inline_style_font(view, "strong") or markdown_live_body_font(view),
    color = header and style.markdown_live_table_header or style.markdown_live_table_cell,
  }
end

local function table_wrap_text(font, text, width)
  if text == "" then return { { text = "", col1 = 1, col2 = 1 } } end
  width = math.max(1, width)
  if font.text_layout then
    local layout = font:text_layout(text)
    local starts = layout:wrap(width, "word")
    local lines = {}
    for index, zero_start in ipairs(starts) do
      local col1 = zero_start + 1
      local col2 = (starts[index + 1] or #text) + 1
      while col1 < col2 and text:sub(col1, col1):match("%s") do col1 = col1 + 1 end
      while col2 > col1 and text:sub(col2 - 1, col2 - 1):match("%s") do col2 = col2 - 1 end
      lines[#lines + 1] = {
        text = text:sub(col1, col2 - 1),
        col1 = col1,
        col2 = col2,
      }
    end
    if #lines == 0 then lines[1] = { text = "", col1 = 1, col2 = 1 } end
    return lines
  end
  local lines = {}
  local line_start, line_end
  local function push_line()
    if line_start then
      lines[#lines + 1] = {
        text = text:sub(line_start, line_end),
        col1 = line_start,
        col2 = line_end + 1,
      }
      line_start, line_end = nil, nil
    end
  end

  local search = 1
  while true do
    local word_start, word_end = text:find("%S+", search)
    if not word_start then break end
    if line_start and font:get_width(text:sub(line_start, word_end)) <= width then
      line_end = word_end
    else
      push_line()
      local word = text:sub(word_start, word_end)
      if font:get_width(word) <= width then
        line_start, line_end = word_start, word_end
      else
        local chunk_start, chunk_end = word_start, word_start - 1
        local chunk = ""
        for char in common.utf8_chars(word) do
          if chunk ~= "" and font:get_width(chunk .. char) > width then
            lines[#lines + 1] = {
              text = chunk, col1 = chunk_start, col2 = chunk_end + 1,
            }
            chunk_start, chunk = chunk_end + 1, ""
          end
          chunk = chunk .. char
          chunk_end = chunk_end + #char
        end
        if chunk ~= "" then
          line_start, line_end = chunk_start, chunk_end
        end
      end
    end
    search = word_end + 1
  end
  push_line()
  if #lines == 0 then lines[1] = { text = "", col1 = 1, col2 = 1 } end
  return lines
end

local TABLE_BREAK_PATTERN = "<[bB][rR]%s*/?%s*>"

local function next_table_break(text, start)
  local escaped, ticks = false, 0
  local col = 1
  while col <= #text do
    local char = text:sub(col, col)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "`" then
      local finish = col
      while text:sub(finish + 1, finish + 1) == "`" do finish = finish + 1 end
      local count = finish - col + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      col = finish
    elseif ticks == 0 and col >= start and char == "<" then
      local col1, col2 = text:find(TABLE_BREAK_PATTERN, col)
      if col1 == col then return col1, col2 end
    end
    col = col + 1
  end
end

local function table_wrap_cell_text(font, text, width, literal_breaks)
  if literal_breaks then return table_wrap_text(font, text, width) end
  local lines = {}
  local start = 1
  while true do
    local break_col1, break_col2 = next_table_break(text, start)
    local finish = break_col1 or (#text + 1)
    local segment = text:sub(start, finish - 1)
    local wrapped = table_wrap_text(font, segment, width)
    for _, visual in ipairs(wrapped) do
      lines[#lines + 1] = {
        text = visual.text,
        col1 = start + (visual.col1 or 1) - 1,
        col2 = start + (visual.col2 or 1) - 1,
      }
    end
    if not break_col1 then break end
    start = break_col2 + 1
    if start > #text then
      lines[#lines + 1] = { text = "", col1 = start, col2 = start }
      break
    end
  end
  if #lines == 0 then lines[1] = { text = "", col1 = 1, col2 = 1 } end
  return lines
end

local function table_cell_natural_width(font, text, literal_breaks)
  if literal_breaks then return font:get_width(text) end
  local width, start = 0, 1
  while true do
    local break_col1, break_col2 = next_table_break(text, start)
    local finish = break_col1 or (#text + 1)
    width = math.max(width, font:get_width(text:sub(start, finish - 1)))
    if not break_col1 then return width end
    start = break_col2 + 1
  end
end

local function table_available_width(view)
  -- Tables may use the full editor viewport even when prose has a narrower
  -- configured wrap column. This matches reading-mode table layout and avoids
  -- wrapping an otherwise fitting grid merely because of the prose guide.
  local scrollbar_width = view.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local width = view:get_presentation_viewport_width()
    - view:get_gutter_width() - scrollbar_width - style.padding.x
  return math.max(math.floor(SCALE * 160), width)
end

local function table_geometry_key(font, available_width)
  return table.concat({
    tostring(font), tostring(font:get_size()), tostring(available_width),
  }, ":")
end

local function table_layout(view, table_node, allow_pending)
  local instance = render_semantic_model(view, table_node.source.line1)
  if not instance and allow_pending then instance = markdown_model.peek(view.doc) end
  if not instance then return nil end
  local font = markdown_live_body_font(view)
  local available_width = table_available_width(view)
  local line2 = table_node.source.line2
  if table_node.source.col2 == 1 and line2 > table_node.source.line1 then line2 = line2 - 1 end
  local line1 = table_node.source.line1
  if line2 - line1 + 1 > TABLE_MAX_PRESENTATION_ROWS then
    core.log_quiet("Markdown table presentation kept raw beyond %d rows at %s:%d",
      TABLE_MAX_PRESENTATION_ROWS, view.doc:get_name(), line1)
    return nil
  end
  local theme_generation = core.color_theme_generation or 0
  local cache = view.__markdown_live_table_layout_cache
  -- Table presentations retain resolved style colors, so do not reuse the
  -- semantic geometry cache across a theme reload.
  if not cache or cache.generation ~= instance.generation
    or cache.theme_generation ~= theme_generation
  then
    cache = {
      generation = instance.generation,
      theme_generation = theme_generation,
      buckets = {},
      bucket_order = {},
    }
    view.__markdown_live_table_layout_cache = cache
  end
  local geometry_key = table_geometry_key(font, available_width)
  local bucket = cache.buckets[geometry_key]
  if not bucket then
    bucket = {
      font = font, font_size = font:get_size(), available_width = available_width,
      layouts = {},
    }
    cache.buckets[geometry_key] = bucket
  end
  for index = #cache.bucket_order, 1, -1 do
    if cache.bucket_order[index] == geometry_key then table.remove(cache.bucket_order, index) end
  end
  cache.bucket_order[#cache.bucket_order + 1] = geometry_key
  while #cache.bucket_order > TABLE_LAYOUT_GEOMETRY_CACHE_LIMIT do
    local evicted = table.remove(cache.bucket_order, 1)
    cache.buckets[evicted] = nil
    perf_frame_add("markdown_live_table_geometry_bucket_evictions", 1)
  end
  cache.layouts = bucket.layouts
  local layouts = bucket.layouts
  if layouts[table_node.id] ~= nil then
    return layouts[table_node.id] or nil
  end

  local rows, columns, canonical = {}, nil, true
  for line = line1, line2 do
    local text = (view.doc.lines[line] or ""):gsub("\n$", "")
    local row = table_source_row(text)
    if not row or #row.cells == 0 or #row.cells > TABLE_MAX_PRESENTATION_COLUMNS then
      layouts[table_node.id] = false
      core.log_quiet("Markdown table presentation fell back to source at %s:%d",
        view.doc:get_name(), line)
      return nil
    end
    columns = columns or #row.cells
    if #row.cells ~= columns then
      layouts[table_node.id] = false
      core.log_quiet("Markdown table presentation found inconsistent columns at %s:%d",
        view.doc:get_name(), line)
      return nil
    end
    row.line, row.text = line, text
    canonical = canonical and row.canonical
    rows[line] = row
  end

  local pad = math.max(font:get_width(" ") * 1.5, SCALE * 6)
  local vertical_pad = math.max(math.floor(SCALE * 5), 2)
  local widths, presentations, active_presentations = {}, {}, {}
  local minimums = {}
  local selection_stable_layout = true
  for column = 1, columns do widths[column] = pad * 4 end
  for line = line1, line2 do
    if line ~= line1 + 1 then
      local row = rows[line]
      presentations[line] = {}
      active_presentations[line] = {}
      for column, cell in ipairs(row.cells) do
        local text, source_col1, source_col2 = table_cell_content(row.text, cell)
        local presentation = table_cell_presentation(
          view, text, source_col1, source_col2, line == line1
        )
        presentations[line][column] = presentation
        if presentation.source_elided then
          selection_stable_layout = false
        else
          active_presentations[line][column] = {
            text = text,
            source_col1 = source_col1,
            source_col2 = source_col2,
            font = line == line1 and inline_style_font(view, "strong") or font,
          }
        end
        widths[column] = math.max(
          widths[column], table_cell_natural_width(
            presentation.font, presentation.text, presentation.literal_breaks
          ) + pad * 2
        )
        local active = active_presentations[line][column]
        if active then
          widths[column] = math.max(
            widths[column],
            table_cell_natural_width(active.font, active.text) + pad * 2
          )
        end
      end
    end
  end
  for column = 1, columns do
    local header_text = table_cell_text(rows[line1].text, rows[line1].cells[column])
    minimums[column] = math.max(
      pad * 2 + inline_style_font(view, "strong"):get_width(header_text),
      -- Below this floor dense grids become columns of individually wrapped
      -- glyphs. Keep a readable cell width and let Document View expose the
      -- table's horizontal overflow instead of crushing every column.
      pad * 2 + font:get_width("MMMMMMMM")
    )
    for row_line = line1, line2 do
      local presentation = presentations[row_line] and presentations[row_line][column]
      if presentation and presentation.nowrap then
        minimums[column] = math.max(
          minimums[column], presentation.font:get_width(presentation.text) + pad * 2
        )
      end
    end
    widths[column] = math.max(widths[column], minimums[column])
  end
  local alignments = {}
  for column, cell in ipairs(rows[line1 + 1].cells) do
    local marker = table_cell_text(rows[line1 + 1].text, cell)
    local left, right = marker:sub(1, 1) == ":", marker:sub(-1) == ":"
    alignments[column] = left and right and "center" or right and "right" or "left"
  end
  local separator_width = math.max(font:get_width(" "), math.max(1, SCALE * 3))
  local chrome_width = separator_width * (columns + 1)
  local content_budget = math.max(1, available_width - chrome_width)
  local natural_content_width, minimum_content_width = 0, 0
  for column, width in ipairs(widths) do
    natural_content_width = natural_content_width + width
    minimum_content_width = minimum_content_width + minimums[column]
  end
  if natural_content_width > content_budget then
    local target = math.max(content_budget, minimum_content_width)
    local flexible = math.max(1, natural_content_width - minimum_content_width)
    local shrink = natural_content_width - target
    for column, width in ipairs(widths) do
      local share = (width - minimums[column]) / flexible
      widths[column] = math.max(minimums[column], width - shrink * share)
    end
  end
  local total_width = chrome_width
  for _, width in ipairs(widths) do total_width = total_width + width end
  local row_heights, wrapped_cells = {}, {}
  local text_line_height = markdown_live_body_line_height(view)
  for row_line = line1, line2 do
    if row_line ~= line1 + 1 then
      wrapped_cells[row_line] = {}
      local row = rows[row_line]
      local max_lines = 1
      for column, cell in ipairs(row.cells) do
        local presentation = presentations[row_line][column]
        local wrapped = table_wrap_cell_text(
          presentation.font, presentation.text, widths[column] - pad * 2,
          presentation.literal_breaks
        )
        wrapped_cells[row_line][column] = wrapped
        max_lines = math.max(max_lines, #wrapped)
        local active = active_presentations[row_line][column]
        if active then
          max_lines = math.max(
            max_lines,
            #table_wrap_cell_text(
              active.font, active.text, widths[column] - pad * 2
            )
          )
        end
      end
      row_heights[row_line] = max_lines * text_line_height + vertical_pad * 2
    end
  end
  local layout = {
    id = table_node.id, line1 = line1, line2 = line2,
    delimiter_line = line1 + 1, rows = rows, columns = columns,
    widths = widths, alignments = alignments, padding = pad,
    vertical_padding = vertical_pad, text_line_height = text_line_height,
    row_heights = row_heights, wrapped_cells = wrapped_cells,
    presentations = presentations,
    active_presentations = active_presentations,
    selection_stable_layout = selection_stable_layout,
    separator_width = separator_width, total_width = total_width,
    canonical = canonical,
  }
  layouts[table_node.id] = layout
  return layout
end

local function cached_table_horizontal_extent(view)
  local cache = view.__markdown_live_table_layout_cache
  if not cache then return 0 end
  local font = markdown_live_body_font(view)
  local bucket = cache.buckets[table_geometry_key(font, table_available_width(view))]
  local width = 0
  for _, layout in pairs(bucket and bucket.layouts or {}) do
    if layout then width = math.max(width, tonumber(layout.total_width) or 0) end
  end
  return width
end

local function table_row_fragments(view, table_node, line, allow_pending)
  local layout = table_layout(view, table_node, allow_pending)
  if not layout then return nil end
  local row = layout.rows[line]
  if not row then return nil end
  if line == layout.delimiter_line then
    local thickness = math.max(1, math.floor(SCALE))
    return {
      {
        source_col1 = 1, source_col2 = #row.text + 1,
        width = layout.total_width,
        semantic_id = table_node.id .. ":delimiter",
        table_separator = true,
        widget = {
          width = layout.total_width,
          height = thickness,
          draw = function(_, _, x, y)
            renderer.draw_rect(x, y, layout.total_width, thickness,
              style.markdown_live_table_separator)
          end,
        },
      },
    }, layout
  end

  local fragments = {}
  local header = line == layout.line1
  local row_height = layout.row_heights[line] or markdown_live_body_line_height(view)
  local row_presentations, row_wrapped = {}, {}
  local selection_state = current_selection_state(view)
  local function cell_active(cell)
    for index = 1, #(selection_state and selection_state.selections or {}), 4 do
      local line1, col1 = selection_state.selections[index], selection_state.selections[index + 1]
      local line2, col2 = selection_state.selections[index + 2], selection_state.selections[index + 3]
      if line1 == line and col1 >= cell.col1 and col1 <= cell.col2 then return true end
      if line2 == line and col2 >= cell.col1 and col2 <= cell.col2 then return true end
    end
    return false
  end
  local max_lines = 1
  for column, cell in ipairs(row.cells) do
    local presentation = layout.presentations[line][column]
    local wrapped = layout.wrapped_cells[line][column]
    if cell_active(cell) then
      local text, source_col1, source_col2 = table_cell_content(row.text, cell)
      presentation = {
        text = text,
        source_col1 = source_col1,
        source_col2 = source_col2,
        font = header and inline_style_font(view, "strong") or markdown_live_body_font(view),
        color = header and style.markdown_live_table_header or style.markdown_live_table_cell,
      }
      wrapped = table_wrap_cell_text(
        presentation.font, text, layout.widths[column] - layout.padding * 2,
        presentation.literal_breaks
      )
    end
    row_presentations[column], row_wrapped[column] = presentation, wrapped
    max_lines = math.max(max_lines, #wrapped)
  end
  row_height = math.max(
    row_height,
    max_lines * layout.text_line_height + layout.vertical_padding * 2
  )
  local function border_fragment(separator, id, first)
    local line_width = math.max(1, math.floor(SCALE))
    return {
      source_col1 = separator.col1, source_col2 = separator.col2,
      text = "", width = layout.separator_width,
      semantic_id = id,
      table_border = true,
      widget = {
        width = layout.separator_width,
        height = row_height,
        draw = function(_, _, x, y, row_height)
          renderer.draw_rect(x, y, layout.separator_width, row_height,
            style.markdown_live_table_background)
          renderer.draw_rect(
            x + math.floor((layout.separator_width - line_width) / 2), y,
            line_width, row_height, style.markdown_live_table_separator
          )
          if header then
            renderer.draw_rect(
              x, y, first and layout.total_width or layout.separator_width, line_width,
              style.markdown_live_table_separator
            )
          end
          if not header then
            renderer.draw_rect(
              x, y + row_height - line_width, layout.separator_width, line_width,
              style.markdown_live_table_separator
            )
          end
        end,
      },
    }
  end
  for column, cell in ipairs(row.cells) do
    local presentation = row_presentations[column]
    local cell_font = presentation.font
    local alignment = layout.alignments[column]
    local text_lines = {}
    for _, wrapped in ipairs(row_wrapped[column]) do
      local wrapped_text = wrapped.text or ""
      local text_width = cell_font:get_width(wrapped_text)
      local offset = alignment == "right"
        and math.max(layout.padding, layout.widths[column] - text_width - layout.padding)
        or alignment == "center"
        and math.max(layout.padding, (layout.widths[column] - text_width) / 2)
        or layout.padding
      text_lines[#text_lines + 1] = {
        text = wrapped_text,
        x_offset = offset,
        source_col1 = presentation.source_col1 + (wrapped.col1 or 1) - 1,
        source_col2 = presentation.source_col1 + (wrapped.col2 or 1) - 1,
      }
    end
    local separator = row.separators[column]
    fragments[#fragments + 1] = border_fragment(
      separator, table_node.id .. ":pipe:" .. line .. ":" .. column, column == 1
    )
    fragments[#fragments + 1] = {
      source_col1 = cell.col1, source_col2 = cell.col2,
      text = presentation.text,
      width = layout.widths[column],
      text_x_offset = text_lines[1] and text_lines[1].x_offset or layout.padding,
      text_source_col1 = presentation.source_col1,
      text_source_col2 = presentation.source_col2,
      text_lines = text_lines,
      text_line_height = layout.text_line_height,
      text_y_padding = layout.vertical_padding,
      text_line_background = presentation.background,
      text_line_background_padding = presentation.background and math.max(1, SCALE * 2) or nil,
      table_alignment = alignment,
      font = cell_font,
      color = presentation.color,
      background = style.markdown_live_table_background,
      background_under_selection = true,
      background_full_height = true,
      background_border_top = header and style.markdown_live_table_separator or nil,
      background_border_bottom = not header and style.markdown_live_table_separator or nil,
      semantic_id = table_node.id .. ":cell:" .. line .. ":" .. column,
      table_cell = true, table_header = header, table_column = column,
    }
  end
  local separator = row.separators[#row.cells + 1]
  fragments[#fragments + 1] = border_fragment(
    separator, table_node.id .. ":pipe:" .. line .. ":end"
  )
  local position_rows = {}
  local fragment_x = 0
  local cell_x = {}
  for _, fragment in ipairs(fragments) do
    -- A table row is one shared grid. Source-position mappings describe caret
    -- placement inside cells, but must never reposition the border/cell
    -- fragments themselves; empty and differently wrapped rows would then
    -- draw each column at different x coordinates.
    fragment.layout_x = fragment_x
    if fragment.table_cell then
      cell_x[fragment.table_column] = {
        x1 = fragment_x,
        x2 = fragment_x + (fragment.width or 0),
      }
      for visual_index, text_line in ipairs(fragment.text_lines or {}) do
        position_rows[#position_rows + 1] = {
          source_col1 = text_line.source_col1,
          source_col2 = text_line.source_col2,
          end_inclusive = true,
          x_offset = fragment_x + (text_line.x_offset or 0),
          hit_x1 = fragment_x,
          hit_x2 = fragment_x + (fragment.width or 0),
          y_offset = (fragment.text_y_padding or 0)
            + (visual_index - 1) * (fragment.text_line_height or layout.text_line_height),
          height = fragment.text_line_height or layout.text_line_height,
          navigation_group = fragment.table_column,
          navigation_index = visual_index,
          table_cell = fragment.table_column,
          cell_source_col1 = fragment.text_source_col1,
          cell_source_col2 = fragment.text_source_col2,
          selection_full_cell = visual_index == 1,
          selection_empty_cell = visual_index == 1
            and fragment.text_source_col1 == fragment.text_source_col2,
          selection_x1 = fragment_x,
          selection_x2 = fragment_x + (fragment.width or 0),
          selection_y = 0,
          selection_height = row_height,
          selection_outline = style.caret,
        }
      end
    end
    fragment_x = fragment_x + (fragment.width or 0)
  end

  local control_size = math.max(
    math.floor(SCALE * 6),
    math.floor(layout.text_line_height * 0.72 + 0.5)
  )
  local control_hit_padding = math.max(
    math.floor(SCALE * 2), math.floor(control_size * 0.18 + 0.5)
  )
  local control_hit_size = control_size + control_hit_padding * 2
  local control_proximity_radius = math.max(
    layout.text_line_height * 1.6, control_size * 2
  )
  local function insertion_control(kind, after, source_col, x, y_offset, action)
    local icon_thickness = math.max(1, math.floor(control_size * 0.11 + 0.5))
    local icon_length = math.max(icon_thickness * 3, math.floor(control_size * 0.44))
    fragments[#fragments + 1] = {
      source_col1 = source_col,
      source_col2 = source_col,
      text = "",
      width = 0,
      hit_width = control_hit_size,
      layout_x = x - control_hit_padding,
      draw_y_offset = y_offset - control_hit_padding,
      control_size = control_size,
      semantic_id = table_node.id .. ":insert:" .. kind .. ":" .. tostring(after),
      table_insert_control = kind,
      table_insert_after = after,
      widget = {
        width = control_hit_size,
        height = control_hit_size,
        proximity_radius = control_proximity_radius,
        suppress_hover_overlay = true,
        cursor = "hand",
        draw = function(_, fragment, draw_x, draw_y)
          local visibility = fragment.hovered and 1 or fragment.proximity or 0
          if visibility <= 0.01 then return end
          visibility = visibility * visibility * (3 - 2 * visibility)
          local button_x = draw_x + control_hit_padding
          local button_y = draw_y + (fragment.draw_y_offset or 0)
            + control_hit_padding
          local accent = { table.unpack(style.accent) }
          accent[4] = (accent[4] or 255) * visibility * (0.35 + visibility * 0.4)
          renderer.draw_rounded_rect(
            button_x, button_y, control_size, control_size, control_size / 2,
            accent
          )
          local center_x = button_x + control_size / 2
          local center_y = button_y + control_size / 2
          local foreground = { table.unpack(style.background) }
          foreground[4] = (foreground[4] or 255) * visibility
          renderer.draw_rect(
            center_x - icon_length / 2, center_y - icon_thickness / 2,
            icon_length, icon_thickness, foreground
          )
          renderer.draw_rect(
            center_x - icon_thickness / 2, center_y - icon_length / 2,
            icon_thickness, icon_length, foreground
          )
        end,
        on_mouse_pressed = function(_, owner, _, button)
          if button ~= "left" then return false end
          core.log_quiet(
            "Markdown table Hover Insertion Control: insert %s after %s at %s:%d",
            kind, tostring(after), owner.doc:get_name(), line
          )
          return action(owner)
        end,
      },
    }
  end
  if header and layout.canonical then
    for column, bounds in ipairs(cell_x) do
      local target_column = column
      local cell = row.cells[column]
      insertion_control(
        "column", column, cell.col2,
        bounds.x2 - control_size / 2,
        math.max(0, (row_height - control_size) / 2),
        function(owner)
          owner.doc:set_selection(
            line, row_presentations[target_column].source_col1
          )
          return markdown_tables.insert_column(owner, "right")
        end
      )
    end
  end
  local first_bounds = cell_x[1]
  local first_presentation = row_presentations[1]
  if layout.canonical and first_bounds and first_presentation then
    insertion_control(
      "row", line, first_presentation.source_col1,
      (first_bounds.x1 + first_bounds.x2 - control_size) / 2,
      math.max(0, row_height - control_size - math.max(1, SCALE * 2)),
      function(owner)
        owner.doc:set_selection(line, first_presentation.source_col1)
        return markdown_tables.insert_row(owner, "below")
      end
    )
  end
  return fragments, layout, position_rows, row_height
end

local function table_geometry_signature(view)
  local font = markdown_live_body_font(view)
  return table.concat({
    tostring(table_available_width(view)),
    tostring(style.prose_font),
    tostring(font:get_size()),
    tostring(core.color_theme_generation or 0),
  }, ":")
end

local function frontmatter_for_line(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "frontmatter" then
      local line2 = node.source.line2
      if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
      if line >= node.source.line1 and line <= line2 then return node, line2 end
    end
  end
end

local function semantic_math_fragments(view, line_text, line, reveal_units)
  local fragments = {}
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "math" and line >= node.source.line1 and line <= node.source.line2 then
      local col1 = line == node.source.line1 and node.source.col1 or 1
      local col2 = line == node.source.line2 and node.source.col2 or #line_text + 1
      if col2 > col1 and not reveal_unit_matches(reveal_units, node.id, col1, col2) then
        fragments[#fragments + 1] = {
          source_col1 = col1, source_col2 = col2,
          text = line_text:sub(col1, col2 - 1),
          font = inline_style_font(view, "code"),
          color = style.markdown_live_math,
          background = style.markdown_live_math_background,
          semantic_id = node.id, math_source = true,
        }
      end
    end
  end
  return fragments
end

local function semantic_break_fragments(view, line_text, line, reveal_units)
  local fragments = {}
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "hard_break" and node.source.line1 == line
      and not reveal_unit_matches(reveal_units, node.id, node.source.col1, #line_text + 1)
    then
      fragments[#fragments + 1] = {
        source_col1 = node.source.col1, source_col2 = #line_text + 1,
        text = " ↵", color = style.markdown_live_hidden_syntax,
        semantic_id = node.id, hard_break = true,
      }
    end
  end
  return fragments
end

local function semantic_footnote_fragments(view, line_text, line, reveal_units)
  local fragments = {}
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "link_reference" and node.source.line1 == line and node.source.line2 == line then
      local attributes = node.attributes or {}
      local label = semantic_range_text_from_doc(view, attributes.reference_label or attributes.link_text)
      local key = normalize_reference_label(label)
      if key:sub(1, 1) == "^" then
        local definition = line_text:sub(node.source.col2, node.source.col2) == ":"
          and line_text:sub(1, node.source.col1 - 1):match("^%s*$") ~= nil
        fragments[#fragments + 1] = {
          source_col1 = node.source.col1, source_col2 = node.source.col2,
          text = line_text:sub(node.source.col1, node.source.col2 - 1),
          color = style.markdown_live_footnote,
          semantic_id = node.id,
          footnote = not definition and key:sub(2) or nil,
          footnote_definition = definition and key:sub(2) or nil,
        }
      end
    end
  end
  return fragments
end

local function semantic_tag_fragments(view, line_text, line, reveal_units)
  local fragments = {}
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "tag" and node.source.line1 == line and node.source.line2 == line
      and not reveal_unit_matches(reveal_units, node.id, node.source.col1, node.source.col2)
    then
      local content = node.attributes and node.attributes.tag
      fragments[#fragments + 1] = {
        source_col1 = node.source.col1, source_col2 = node.source.col2,
        text = line_text:sub(node.source.col1, node.source.col2 - 1),
        color = style.markdown_live_tag,
        semantic_id = node.id,
        tag = content and line_text:sub(content.col1, content.col2 - 1)
          or line_text:sub(node.source.col1 + 1, node.source.col2 - 1),
      }
    end
  end
  return fragments
end

local function markdown_indent_width(prefix)
  local width = 0
  for char in (prefix or ""):gmatch(".") do
    width = char == "\t" and width + (4 - width % 4) or width + 1
  end
  return width
end

local function markdown_list_visual_indent_width(prefix)
  local source_width = markdown_indent_width(prefix)
  local visual_step = math.max(
    1, math.floor(tonumber(config.markdown_live_list_indent_spaces) or 4)
  )
  return math.floor(source_width / 4) * visual_step + source_width % 4
end

local function ordered_list_display_marker(view, line, ordered)
  local revision = view.doc.text_revision or view.doc:get_change_id()
  local cache = view.__markdown_live_ordered_marker_cache
  if not cache or cache.revision ~= revision then
    cache = { revision = revision, lines = {} }
    local states = {}
    local function clear_from(indent, inclusive)
      for state_indent in pairs(states) do
        if state_indent > indent or inclusive and state_indent == indent then
          states[state_indent] = nil
        end
      end
    end
    for source_line, source in ipairs(view.doc.lines) do
      local text = source:gsub("\n$", "")
      if not text:match("^%s*$") then
        local indent, number, delimiter = text:match("^([ \t]*)(%d+)([.)])%s+")
        local indent_width = markdown_indent_width(
          indent or text:match("^[ \t]*") or ""
        )
        if number then
          clear_from(indent_width, false)
          local state = states[indent_width]
          if not state or state.delimiter ~= delimiter then
            state = { delimiter = delimiter, number = tonumber(number) }
            states[indent_width] = state
          else
            state.number = state.number + 1
          end
          cache.lines[source_line] = tostring(state.number) .. delimiter
        else
          clear_from(indent_width, true)
        end
      end
    end
    view.__markdown_live_ordered_marker_cache = cache
  end
  return cache.lines[line] or ordered
end

local function list_item_content_col(line_text, marker, task)
  local col = task and task.col2 or marker and marker.col2 or 1
  while col <= #line_text and line_text:sub(col, col):match("[ \t]") do
    col = col + 1
  end
  return col
end

local function draw_task_checkmark(box_x, box_y, box_size, color, font)
  local glyph = "✓"
  renderer.draw_text(
    font, glyph,
    box_x + math.floor((box_size - font:get_width(glyph)) / 2),
    box_y + math.floor((box_size - font:get_height()) / 2),
    color
  )
end

local function task_checkbox_widget(
  width, height, box_size, checked, checkmark_font, box_area_x, box_area_width
)
  box_area_x = box_area_x or 0
  box_area_width = box_area_width or width
  return {
    wrapping = "inline", cursor = "hand", width = width, height = height,
    checked = checked,
    draw = function(_, fragment, x, y, visual_row_height)
      local is_checked = fragment.checked
      local checkbox_color = is_checked and style.markdown_live_task_checked
        or style.markdown_live_task_unchecked
      local border = math.max(1, math.floor(SCALE))
      local box_x = x + box_area_x + math.floor((box_area_width - box_size) / 2)
      local box_y = y + math.floor((visual_row_height - box_size) / 2)
      local radius = math.max(border, math.floor(box_size * 0.22))
      renderer.draw_rounded_rect(
        box_x, box_y, box_size, box_size, radius, checkbox_color
      )
      if is_checked then
        draw_task_checkmark(
          box_x, box_y, box_size, style.markdown_live_task_checkmark,
          checkmark_font
        )
      else
        local inner_size = math.max(1, box_size - border * 2)
        renderer.draw_rounded_rect(
          box_x + border, box_y + border,
          inner_size, inner_size, math.max(0, radius - border),
          style.markdown_live_task_background
        )
      end
    end,
  }
end

local function list_bullet_widget(width, height, indent_width, marker_control_width, marker_size)
  return {
    wrapping = "inline", width = width, height = height,
    draw = function(_, _, x, y, visual_row_height)
      local bullet_x = x + indent_width
        + math.floor((marker_control_width - marker_size) / 2)
      local bullet_y = y + math.floor((visual_row_height - marker_size) / 2)
      renderer.draw_rounded_rect(
        bullet_x, bullet_y, marker_size, marker_size,
        marker_size / 2, style.markdown_live_list_marker
      )
    end,
  }
end

local function semantic_block_fragments(view, line_text, line, reveal_units)
  for _, unit in ipairs(reveal_units or {}) do
    if unit.whole_line then return {} end
  end
  local fragments, seen = {}, {}
  local callout = callout_for_line(view, line)
  local frontmatter, frontmatter_line2 = frontmatter_for_line(view, line)
  local table_node = table_for_line(view, line)
  if table_node then
    if config.markdown_live_interactive_tables ~= true then return {} end
    return table_row_fragments(view, table_node, line) or {}
  end
  if frontmatter then
    if line == frontmatter.source.line1 or line == frontmatter_line2 then
      return {
        {
          source_col1 = 1, source_col2 = #line_text + 1, text = line_text,
          color = style.markdown_live_frontmatter_delimiter,
          semantic_id = frontmatter.id .. ":delimiter:" .. line,
        },
      }
    end
    local key, separator = line_text:match("^([%w_-]+)(:%s*)")
    if key then
      local separator_col2 = #key + #separator + 1
      return {
        {
          source_col1 = 1, source_col2 = #key + 1, text = key,
          color = style.markdown_live_frontmatter_key,
          semantic_id = frontmatter.id .. ":key:" .. line,
        },
        {
          source_col1 = #key + 1, source_col2 = separator_col2, text = separator,
          color = style.markdown_live_frontmatter_delimiter,
          semantic_id = frontmatter.id .. ":separator:" .. line,
        },
      }
    end
    return {
      {
        source_col1 = 1, source_col2 = #line_text + 1, text = line_text,
        color = style.text, semantic_id = frontmatter.id .. ":value:" .. line,
      },
    }
  end
  local semantic_nodes = semantic_line(view, line) or {}
  local current_list_marker = list_marker_for_line(view, line) ~= nil
  local continuation_parent
  for _, candidate in ipairs(semantic_nodes) do
    local candidate_marker = candidate.attributes and candidate.attributes.list
    if candidate.type == "list_item" and not candidate_marker then
      candidate_marker = list_marker_for_line(view, candidate.source.line1)
    end
    if candidate.type == "list_item"
      and candidate_marker and candidate_marker.line1 < line
      and candidate.source.line1 < line and candidate.source.line2 >= line
      and (not continuation_parent
        or candidate_marker.line1 > continuation_parent.marker.line1)
    then
      continuation_parent = { node = candidate, marker = candidate_marker }
    end
  end
  if not current_list_marker and continuation_parent then
    local parent_render = view:get_line_render(continuation_parent.marker.line1)
    local target_x
    for _, fragment in ipairs(parent_render and parent_render.fragments or {}) do
      if fragment.markdown_list_content_col then
        target_x = view:get_line_render_col_x_offset(
          parent_render, fragment.markdown_list_content_col
        )
        break
      end
    end
    if target_x then
      local body_font = markdown_live_body_font(view)
      local leading = line_text:match("^[\t ]*") or ""
      local source_leading_width = body_font:get_width(
        string.rep(" ", markdown_indent_width(leading))
      )
      local width = target_x - source_leading_width
      if width > 0.1 then
        fragments[#fragments + 1] = {
          source_col1 = 1, source_col2 = 1, text = "", width = width,
          font = body_font, markdown_list_continuation_indent = true,
        }
      end
    end
  end
  for _, node in ipairs(semantic_nodes) do
    local attributes = node.attributes or {}
    if node.type == "link_reference" and attributes.reference_label
      and attributes.reference_destination and node.source.line1 == line
    then
      local label = semantic_range_text_from_doc(view, attributes.reference_label) or ""
      local normalized_label = normalize_reference_label(label)
      local footnote = normalized_label:sub(1, 1) == "^"
      fragments[#fragments + 1] = {
        source_col1 = attributes.reference_label.col1,
        source_col2 = attributes.reference_label.col2,
        text = label,
        color = footnote and style.markdown_live_footnote
          or style.markdown_live_reference_definition,
        semantic_id = node.id .. ":definition-label",
        reference_definition = not footnote and normalized_label or nil,
        footnote_definition = footnote and normalized_label:sub(2) or nil,
      }
      if not footnote then
        fragments[#fragments + 1] = {
          source_col1 = attributes.reference_destination.col1,
          source_col2 = attributes.reference_destination.col2,
          text = semantic_range_text_from_doc(view, attributes.reference_destination),
          color = style.markdown_live_link,
          underline = true,
          semantic_id = node.id .. ":definition-destination",
        }
      end
    elseif node.type == "thematic_break" and node.source.line1 == line then
      fragments[#fragments + 1] = {
        source_col1 = node.source.col1, source_col2 = #line_text + 1,
        text = "────────────────", color = style.markdown_live_rule,
        semantic_id = node.id,
      }
    elseif node.type == "quote" and not seen.quote then
      local col1, col2 = line_text:find("^%s*>%s*")
      if col1 then
        seen.quote = true
        if callout and line == callout.line1 then
          local fold = callout.fold == "+" and "▾ " or callout.fold == "-" and "▸ " or ""
          fragments[#fragments + 1] = {
            source_col1 = callout.col1, source_col2 = callout.col2,
            text = "◆ " .. fold .. (callout.title == "" and callout.display_type or ""),
            color = style.markdown_live_callout_icon,
            semantic_id = node.id .. ":callout-header",
            callout_type = callout.type,
            callout_known_type = callout.known_type,
          }
        else
          fragments[#fragments + 1] = {
            source_col1 = col1, source_col2 = col2 + 1,
            text = "│ ", color = style.markdown_live_quote_bar,
            semantic_id = node.id,
          }
        end
      end
    elseif node.type == "list" or node.type == "list_item" then
      local task = attributes.task_checked or attributes.task_unchecked
      local marker = attributes.list
      local source_checked
      if not task then
        task, source_checked = source_task_marker(line_text, marker)
      end
      local body_font = markdown_live_body_font(view)
      local checkmark_font = markdown_live_scaled_font(
        view, style.prose_strong_font,
        math.max(1, math.floor(body_font:get_size() * 0.78))
      )
      local row_height = markdown_live_body_line_height(view)
      local checked = task and attributes.task_checked ~= nil
      if source_checked ~= nil then checked = source_checked end
      local task_semantic_id = task and (node.id .. ":task")
      local task_revealed = task and reveal_unit_matches(
        reveal_units, task_semantic_id, task.col1, task.col2
      )
      local task_raw = task and line_text:sub(task.col1, task.col2 - 1)
      local task_content_col = task and list_item_content_col(line_text, marker, task)
      local list_control_size = math.max(
        math.floor(SCALE * 10), math.floor(body_font:get_height() * 0.72)
      )
      local box_size = task and list_control_size
      local task_source_width = task and math.max(
        body_font:get_width("[ ]"), body_font:get_width("[x]"),
        body_font:get_width("[X]"), box_size + math.floor(SCALE * 2)
      )
      local function toggle_task(_, owner, _, button)
        if button ~= "left" then return false end
        local selection = owner:get_selection_state()
        local source = (owner.doc.lines[line] or ""):sub(task.col1, task.col2 - 1)
        local currently_checked = source:match("^%[[xX]%]$") ~= nil
        owner:with_selection_state(function()
          owner.doc:set_selection(line, task.col1, line, task.col2)
          owner.doc:text_input(currently_checked and "[ ]" or "[x]")
          owner:set_selection_state(selection)
        end)
        return true
      end

      local task_checkbox_in_marker = false
      local marker_key = marker and table.concat({ marker.line1, marker.col1, marker.col2 }, ":")
      if marker and marker.line1 == line and not seen[marker_key] then
        seen[marker_key] = true
        local captured_raw = line_text:sub(marker.col1, marker.col2 - 1)
        local token_start = captured_raw:find("%S") or 1
        local token_col = marker.col1 + token_start - 1
        local indent = line_text:sub(1, token_col - 1):match("([ \t]*)$") or ""
        local marker_source_col1 = token_col - #indent
        local raw = line_text:sub(marker_source_col1, marker.col2 - 1)
        local ordered = raw:match("^%s*(%d+[.)])")
        local indent_width = body_font:get_width(
          string.rep(" ", markdown_list_visual_indent_width(indent))
        )
        local raw_width = body_font:get_width(raw)
        local marker_gap_width = body_font:get_width(" ")
        local marker_control_width = math.max(
          body_font:get_width("-"), list_control_size
        )
        local marker_lane_width = marker_control_width + marker_gap_width
        local marker_width = indent_width + marker_lane_width
        local marker_revealed = reveal_unit_matches(
          reveal_units, node.id, marker.col1, marker.col2
        )
        if ordered then
          local display_marker = ordered_list_display_marker(view, line, ordered)
          marker_width = math.max(
            marker_width, indent_width + body_font:get_width(display_marker .. " ")
          )
          if marker_revealed then
            fragments[#fragments + 1] = {
              source_col1 = marker_source_col1, source_col2 = marker.col2,
              text = raw, width = marker_width,
              color = style.markdown_live_list_marker,
              semantic_id = node.id .. ":marker",
              ordered_list_source_marker = true,
              markdown_list_content_col = list_item_content_col(line_text, marker, nil),
            }
          else
            fragments[#fragments + 1] = {
              source_col1 = marker_source_col1, source_col2 = marker.col2,
              text = display_marker, width = marker_width,
              text_x_offset = indent_width,
              color = style.markdown_live_list_marker,
              semantic_id = node.id .. ":marker",
              ordered_list_marker = true,
              markdown_list_content_col = list_item_content_col(line_text, marker, nil),
            }
          end
        else
          local marker_size = math.max(2, math.floor(body_font:get_height() * 0.24))
          if marker_revealed then
            fragments[#fragments + 1] = {
              source_col1 = marker_source_col1, source_col2 = marker.col2,
              text = raw, width = marker_width,
              text_x_offset = math.max(0, (marker_width - raw_width) / 2),
              color = style.markdown_live_list_marker,
              semantic_id = node.id .. ":marker",
              unordered_list_source_marker = true,
            }
          elseif task and not task_revealed then
            task_checkbox_in_marker = true
            local checkbox_widget = task_checkbox_widget(
              marker_width, row_height, box_size, checked,
              checkmark_font, indent_width, marker_control_width
            )
            checkbox_widget.on_mouse_pressed = toggle_task
            fragments[#fragments + 1] = {
              source_col1 = marker_source_col1, source_col2 = task_content_col,
              text = "", width = marker_width,
              color = checked and style.markdown_live_task_checked
                or style.markdown_live_task_unchecked,
              semantic_id = task_semantic_id,
              markdown_task_checkbox = true, checked = checked,
              markdown_list_content_col = task_content_col,
              draw_x_offset = indent_width
                + math.floor((marker_control_width - box_size) / 2),
              hit_width = box_size,
              widget = checkbox_widget,
            }
          else
            fragments[#fragments + 1] = {
              source_col1 = marker_source_col1, source_col2 = marker.col2,
              text = "", width = marker_width,
              color = style.markdown_live_list_marker,
              semantic_id = node.id .. ":marker",
            }
          end
          if not task then
            local fragment = fragments[#fragments]
            fragment.markdown_list_content_col = list_item_content_col(
              line_text, marker, nil
            )
            if not marker_revealed then
              fragment.unordered_list_marker = true
              fragment.widget = list_bullet_widget(
                marker_width, row_height, indent_width,
                marker_control_width, marker_size
              )
            end
          end
        end
      end
      if task and task.line1 == line then
        if task_revealed then
          fragments[#fragments + 1] = {
            source_col1 = task.col1, source_col2 = task_content_col,
            text_source_col1 = task.col1, text_source_col2 = task.col2,
            text = task_raw, width = task_source_width,
            text_x_offset = math.max(
              0, (task_source_width - body_font:get_width(task_raw)) / 2
            ),
            color = style.markdown_live_list_marker,
            semantic_id = task_semantic_id,
            markdown_task_source_marker = true,
            markdown_list_content_col = task_content_col,
          }
        elseif not task_checkbox_in_marker then
          local checkbox_widget = task_checkbox_widget(
            task_source_width, row_height, box_size, checked, checkmark_font
          )
          checkbox_widget.on_mouse_pressed = toggle_task
          fragments[#fragments + 1] = {
            source_col1 = task.col1, source_col2 = task_content_col,
            text = "", width = task_source_width,
            color = checked and style.markdown_live_task_checked
              or style.markdown_live_task_unchecked,
            semantic_id = task_semantic_id,
            markdown_task_checkbox = true, checked = checked,
            markdown_list_content_col = task_content_col,
            draw_x_offset = math.floor((task_source_width - box_size) / 2),
            hit_width = box_size,
            widget = checkbox_widget,
          }
        else
          fragments[#fragments + 1] = {
            source_col1 = task.col1, source_col2 = task_content_col,
            text = "", width = 0, semantic_id = task_semantic_id,
            markdown_list_content_col = task_content_col,
          }
        end
      end
    end
  end
  return fragments
end

local function inline_fragments(line_text, line, view, reveal_units)
  local fragments, occupied = {}, {}
  for _, fragment in ipairs(semantic_block_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  for _, fragment in ipairs(semantic_link_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  for _, fragment in ipairs(semantic_math_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  for _, fragment in ipairs(semantic_break_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  for _, fragment in ipairs(semantic_footnote_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  for _, fragment in ipairs(semantic_tag_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  for _, fragment in ipairs(semantic_formatting_fragments(view, line_text, line, reveal_units)) do
    add_fragment(fragments, occupied, fragment)
  end
  table.sort(fragments, function(a, b) return (a.source_col1 or 1) < (b.source_col1 or 1) end)
  return fragments
end

local function prose_render_line(view, line_text, render_line)
  local font = markdown_live_body_font(view)
  render_line.text_row_height = render_line.text_row_height
    or markdown_live_body_line_height(view)
  render_line.caret_height = render_line.caret_height or render_line.text_row_height
  local fragments, cursor = {}, 1
  for _, fragment in ipairs(render_line.fragments or {}) do
    local col1 = math.max(1, fragment.source_col1 or cursor)
    local col2 = math.max(col1, fragment.source_col2 or col1)
    if col1 > cursor then
      fragments[#fragments + 1] = {
        source_col1 = cursor, source_col2 = col1,
        text = line_text:sub(cursor, col1 - 1), font = font,
      }
    end
    if not fragment.font then fragment.font = font end
    fragments[#fragments + 1] = fragment
    if fragment.markdown_list_content_col then
      render_line.continuation_indent_col = fragment.markdown_list_content_col
      render_line.continuation_indent_font = font
    end
    cursor = math.max(cursor, col2)
  end
  if cursor <= #line_text then
    fragments[#fragments + 1] = {
      source_col1 = cursor, source_col2 = #line_text + 1,
      text = line_text:sub(cursor), font = font,
    }
  elseif #fragments == 0 then
    fragments[1] = {
      source_col1 = 1, source_col2 = 1, text = "", font = font,
    }
  end
  render_line.source_text = line_text
  render_line.fragments = fragments
  return render_line
end

local function set_render_line_task_completion(render_line, checked, content_col)
  if not (render_line and content_col) then return render_line end
  render_line.markdown_task_checked = checked == true
  render_line.markdown_task_content_col = content_col
  for _, fragment in ipairs(render_line.fragments or {}) do
    local col2 = fragment.source_col2 or fragment.source_col1 or 1
    if col2 > content_col and not fragment.widget and fragment.text ~= nil then
      if not fragment.markdown_task_base_style_saved then
        fragment.markdown_task_base_style_saved = true
        fragment.markdown_task_base_color = fragment.color
        fragment.markdown_task_base_strikethrough = fragment.strikethrough
      end
      if checked then
        fragment.color = style.markdown_live_task_completed_text
        fragment.strikethrough = true
      else
        fragment.color = fragment.markdown_task_base_color
        fragment.strikethrough = fragment.markdown_task_base_strikethrough
      end
    end
  end
  return render_line
end

local function apply_task_completion_presentation(view, line_text, line, render_line)
  local task, node, source_checked = task_marker_for_line(view, line)
  if not (task and node) then return render_line end
  local attributes = node.attributes or {}
  local content_col = list_item_content_col(line_text, attributes.list, task)
  local checked = source_checked
  if checked == nil then checked = attributes.task_checked ~= nil end
  return set_render_line_task_completion(
    render_line, checked, content_col
  )
end

local function layout_inline_image_rows(view, line_text, render_line)
  local blocks = {}
  for _, fragment in ipairs(render_line.fragments or {}) do
    if fragment.image_block and fragment.widget then blocks[#blocks + 1] = fragment end
  end
  if #blocks == 0 then return render_line end
  table.sort(blocks, function(a, b)
    return (a.image_block_col1 or 1) < (b.image_block_col1 or 1)
  end)

  local body_height = markdown_live_body_line_height(view)
  local wrap_width = image_available_width(view)
  local wrap_mode = config.plugins.linewrapping.mode
  local rows, y, segment_start = {}, 0, 1
  local function rendered_x(col)
    return view:get_line_render_col_x_offset(render_line, col)
  end
  local function append_text_rows(col1, col2, highlight_full_layout)
    if col2 <= col1 then return end
    local row_start, col, last_space = col1, col1, nil
    local function append_row(row_end)
      if row_end <= row_start then return end
      rows[#rows + 1] = {
        source_col1 = row_start,
        source_col2 = row_end,
        y_offset = y,
        height = body_height,
        highlight_full_layout = highlight_full_layout or nil,
      }
      y = y + body_height
      row_start = row_end
    end
    for char in common.utf8_chars(line_text:sub(col1, col2 - 1)) do
      local next_col = col + #char
      if char == " " then last_space = col end
      local row_width = rendered_x(next_col) - rendered_x(row_start)
      if wrap_width ~= math.huge and row_width > wrap_width and col > row_start then
        local split = col
        if wrap_mode == "word" and last_space and last_space >= row_start then
          split = last_space + 1
        end
        append_row(split)
        if last_space and last_space < row_start then last_space = nil end
      end
      col = next_col
    end
    append_row(col2)
  end

  for block_index, block in ipairs(blocks) do
    local block_col1 = block.image_block_col1 or block.source_col1 or segment_start
    local block_col2 = block.image_block_col2 or block.source_col2 or block_col1
    local top_end = block.image_block_active and block_col2 or block_col1
    append_text_rows(segment_start, top_end, block_index == 1 and segment_start == 1)
    if block.image_block_active and rows[#rows]
    and rows[#rows].source_col2 == top_end then
      rows[#rows].end_inclusive = true
    end

    block.layout_x = 0
    block.draw_x_offset = 0
    block.draw_y_offset = y + (block.widget.padding or 0)
    y = y + block.widget.height
    segment_start = block_col2
  end

  if segment_start <= #line_text then
    append_text_rows(segment_start, #line_text + 1, false)
    if rows[#rows] and rows[#rows].source_col2 == #line_text + 1 then
      rows[#rows].end_inclusive = true
    end
  end

  render_line.position_rows = rows
  render_line.layout_height = math.max(body_height, y)
  for _, row in ipairs(rows) do
    row.highlight_y_offset = row.y_offset
    row.highlight_height = row.height
  end
  for _, row in ipairs(rows) do
    if row.highlight_full_layout then
      row.highlight_y_offset = 0
      row.highlight_height = render_line.layout_height
    end
  end
  -- Measuring the text segments above populates DocView's normalized-fragment
  -- cache before the image's final block offsets are assigned. Rebuild those
  -- copies so drawing and hit testing use the positioned image rather than
  -- vertically centering it across the whole multi-row layout.
  view:invalidate_line_render_fragment_normalization(render_line)
  render_line.disable_wrapping = true
  return render_line
end

local view_in_source_mode

local function clone_render_line(render_line)
  local clone = {}
  for key, value in pairs(render_line or {}) do clone[key] = value end
  clone.on_mouse_selection = nil
  clone.on_text_input = nil
  clone.on_ime_text_editing = nil
  clone.on_table_source_changed = nil
  clone.on_table_structure_changed = nil
  clone.fragments = {}
  for _, fragment in ipairs(render_line and render_line.fragments or {}) do
    local copy = {}
    for key, value in pairs(fragment) do copy[key] = value end
    copy.on_mouse_pressed = nil
    if copy.widget then
      local widget = {}
      for key, value in pairs(copy.widget) do widget[key] = value end
      widget.on_mouse_pressed = nil
      copy.widget = widget
    end
    clone.fragments[#clone.fragments + 1] = copy
  end
  clone.hit_test_fragments = nil
  return clone
end

local function line_in_semantic_math(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "math"
      and line >= node.source.line1 and line <= node.source.line2
    then
      return true
    end
  end
  return false
end

local function render_line_metric_height(view, render_line)
  local height = render_line and render_line.text_row_height
    or markdown_live_body_line_height(view)
  for _, fragment in ipairs(render_line and render_line.fragments or {}) do
    if not render_line.text_row_height and fragment.font then
      height = math.max(
        height, math.floor(fragment.font:get_height() * config.line_height)
      )
    end
    if fragment.widget and fragment.widget.height then
      height = math.max(height, fragment.widget.height)
    end
  end
  return height
end

local function apply_inline_edit_to_render(render_line, current_text, edit)
  local start_col, end_col = edit.col1, edit.col2
  local replacement = edit.text or ""
  if not start_col or not end_col or start_col > end_col then
    return nil
  end
  if current_text == "" and #(render_line.fragments or {}) == 0 then
    render_line.fragments = {
      { source_col1 = 1, source_col2 = 1, text = "" },
    }
  end

  local owner_index
  for i, fragment in ipairs(render_line.fragments or {}) do
    local col1 = fragment.source_col1 or 1
    local col2 = fragment.source_col2 or col1
    local contains
    if start_col == end_col then
      contains = col1 <= start_col and start_col < col2
      if not contains and start_col == #current_text + 1 and col2 == start_col then
        contains = i == #render_line.fragments
      end
    else
      contains = col1 <= start_col and end_col <= col2
    end
    if contains then owner_index = i break end
  end
  local owner = owner_index and render_line.fragments[owner_index]
  if owner and owner.markdown_task_checkbox
    and replacement:match("^%[[ xX]%]$")
  then
    local delta = #replacement - (end_col - start_col)
    local updated_text = current_text:sub(1, start_col - 1)
      .. replacement .. current_text:sub(end_col)
    owner.checked = replacement:match("^%[[xX]%]$") ~= nil
    owner.color = owner.checked and style.markdown_live_task_checked
      or style.markdown_live_task_unchecked
    if owner.widget then
      local widget = {}
      for key, value in pairs(owner.widget) do widget[key] = value end
      widget.checked = owner.checked
      owner.widget = widget
    end
    owner.source_col2 = (owner.source_col2 or owner.source_col1 or 1) + delta
    for i = owner_index + 1, #render_line.fragments do
      local fragment = render_line.fragments[i]
      fragment.source_col1 = (fragment.source_col1 or 1) + delta
      fragment.source_col2 = (fragment.source_col2 or fragment.source_col1) + delta
    end
    render_line.source_text = updated_text
    render_line.markdown_pending_provenance = "active-source-reveal"
    set_render_line_task_completion(
      render_line, owner.checked, render_line.markdown_task_content_col
    )
    return updated_text
  end
  if not owner or owner.hidden or owner.widget or owner.width or owner.text_x_offset then return nil end
  local owner_col1 = owner.source_col1 or 1
  local owner_col2 = owner.source_col2 or owner_col1
  local old_span = current_text:sub(owner_col1, owner_col2 - 1)
  if owner.text ~= old_span then return nil end

  local delta = #replacement - (end_col - start_col)
  owner.text = old_span:sub(1, start_col - owner_col1)
    .. replacement .. old_span:sub(end_col - owner_col1 + 1)
  owner.source_col2 = owner_col2 + delta
  for i = owner_index + 1, #render_line.fragments do
    local fragment = render_line.fragments[i]
    local col1 = fragment.source_col1 or 1
    local col2 = fragment.source_col2 or col1
    fragment.source_col1 = col1 + delta
    fragment.source_col2 = col2 + delta
  end
  current_text = current_text:sub(1, start_col - 1)
    .. replacement .. current_text:sub(end_col)
  render_line.source_text = current_text
  render_line.markdown_pending_provenance = "active-source-reveal"
  return current_text
end

local function pending_list_marker_render(view, previous, current_text)
  if not current_text then return nil end
  local previous_marker
  if previous then
    for _, fragment in ipairs(previous.fragments or {}) do
      if fragment.markdown_task_checkbox
        or fragment.markdown_task_source_marker
        or fragment.unordered_list_marker
        or fragment.unordered_list_source_marker
        or fragment.ordered_list_marker
        or fragment.ordered_list_source_marker
      then
        previous_marker = fragment
        break
      end
    end
  end

  local kind, indent, content_col, checked, marker_text, body_text
  local task_indent, bullet, before_task, state, after_task, task_body = current_text:match(
    "^([\t ]*)([-%*%+])([\t ]+)%[([ xX])%]([\t ]*)(.*)$"
  )
  if task_indent then
    kind = "task"
    indent = task_indent
    content_col = #indent + #bullet + #before_task + 3 + #after_task + 1
    checked = state == "x" or state == "X"
    body_text = task_body
  else
    local ordered_indent, number, delimiter, spaces, ordered_body = current_text:match(
      "^([\t ]*)(%d+)([.)])([\t ]+)(.*)$"
    )
    if ordered_indent then
      kind = "ordered"
      indent = ordered_indent
      content_col = #indent + #number + 1 + #spaces + 1
      marker_text = number .. delimiter
      body_text = ordered_body
    else
      local bullet_indent, unordered_bullet, unordered_spaces, unordered_body = current_text:match(
        "^([\t ]*)([-%*%+])([\t ]+)(.*)$"
      )
      if not bullet_indent then return nil end
      kind = "unordered"
      indent = bullet_indent
      content_col = #indent + #unordered_bullet + #unordered_spaces + 1
      body_text = unordered_body
    end
  end

  if not previous_marker then
    local body_font = markdown_live_body_font(view)
    local indent_width = body_font:get_width(
      string.rep(" ", markdown_list_visual_indent_width(indent))
    )
    local marker_control_width = math.max(
      body_font:get_width("-"), math.max(
        math.floor(SCALE * 10), math.floor(body_font:get_height() * 0.72)
      )
    )
    local marker_text_width = kind == "ordered"
      and body_font:get_width(marker_text .. " ")
      or marker_control_width + body_font:get_width(" ")
    previous_marker = {
      width = indent_width + marker_text_width,
    }
  end

  local render = clone_render_line(previous or {})
  render.source_text = current_text
  render.markdown_pending_provenance = "active-source-reveal"
  render.fragments = {}
  local marker = {}
  for key, value in pairs(previous_marker) do marker[key] = value end
  marker.source_col1 = 1
  marker.source_col2 = content_col
  marker.text_source_col1 = nil
  marker.text_source_col2 = nil
  marker.text_x_offset = nil
  marker.draw_x_offset = nil
  marker.hit_width = nil
  marker.markdown_list_content_col = content_col
  marker.markdown_task_content_col = nil
  marker.markdown_task_source_marker = nil
  marker.unordered_list_source_marker = nil
  marker.ordered_list_source_marker = nil
  local body_font = markdown_live_body_font(view)
  local indent_width = body_font:get_width(
    string.rep(" ", markdown_list_visual_indent_width(indent))
  )
  local marker_control_width = math.max(
    body_font:get_width("-"), math.max(
      math.floor(SCALE * 10), math.floor(body_font:get_height() * 0.72)
    )
  )
  marker.width = kind == "ordered"
    and indent_width + body_font:get_width(marker_text .. " ")
    or indent_width + marker_control_width + body_font:get_width(" ")

  if kind == "task" then
    marker.text = ""
    marker.checked = checked
    marker.markdown_task_checkbox = true
    marker.unordered_list_marker = nil
    marker.ordered_list_marker = nil
    marker.markdown_task_content_col = content_col
    marker.color = checked and style.markdown_live_task_checked
      or style.markdown_live_task_unchecked
    local box_size = math.max(
      math.floor(SCALE * 10), math.floor(body_font:get_height() * 0.72)
    )
    marker_control_width = math.max(body_font:get_width("-"), box_size)
    local checkmark_font = markdown_live_scaled_font(
      view, style.prose_strong_font,
      math.max(1, math.floor(body_font:get_size() * 0.78))
    )
    local widget = task_checkbox_widget(
      marker.width, markdown_live_body_line_height(view), box_size,
      checked, checkmark_font, body_font:get_width(
        string.rep(" ", markdown_list_visual_indent_width(indent))
      ), marker_control_width
    )
    widget.on_mouse_pressed = nil
    marker.widget = widget
  elseif kind == "ordered" then
    marker.text = marker_text
    marker.markdown_task_checkbox = nil
    marker.checked = nil
    marker.unordered_list_marker = nil
    marker.ordered_list_marker = true
    marker.color = style.markdown_live_list_marker
    marker.widget = nil
    marker.text_x_offset = indent_width
  else
    marker.text = ""
    marker.markdown_task_checkbox = nil
    marker.checked = nil
    marker.ordered_list_marker = nil
    marker.unordered_list_marker = true
    marker.color = style.markdown_live_list_marker
    local marker_size = math.max(2, math.floor(body_font:get_height() * 0.24))
    marker.widget = list_bullet_widget(
      marker.width, markdown_live_body_line_height(view),
      indent_width, marker_control_width, marker_size
    )
  end
  render.fragments[1] = marker
  local preserved_body = false
  local previous_content_col = previous_marker.markdown_list_content_col
  if not previous_content_col and previous and previous.source_text then
    local old_indent, old_bullet, old_spaces = previous.source_text:match(
      "^([\t ]*)([-%*%+])([\t ]+)"
    )
    if old_indent then
      previous_content_col = #old_indent + #old_bullet + #old_spaces + 1
      local old_task = previous.source_text:sub(previous_content_col):match(
        "^%[[ xX]%]([\t ]*)"
      )
      if old_task then previous_content_col = previous_content_col + 3 + #old_task end
    else
      local old_number, old_delimiter
      old_indent, old_number, old_delimiter, old_spaces = previous.source_text:match(
        "^([\t ]*)(%d+)([.)])([\t ]+)"
      )
      if old_indent then
        previous_content_col = #old_indent + #old_number + #old_delimiter
          + #old_spaces + 1
      end
    end
  end
  if previous and previous.source_text and previous_content_col
    and previous.source_text:sub(previous_content_col) == (body_text or "")
  then
    local delta = content_col - previous_content_col
    for _, fragment in ipairs(previous.fragments or {}) do
      local col1 = fragment.source_col1 or 1
      if fragment ~= previous_marker and col1 >= previous_content_col
        and not fragment.widget
      then
        local copy = {}
        for key, value in pairs(fragment) do copy[key] = value end
        copy.source_col1 = (copy.source_col1 or previous_content_col) + delta
        copy.source_col2 = (copy.source_col2 or copy.source_col1) + delta
        if copy.text_source_col1 then copy.text_source_col1 = copy.text_source_col1 + delta end
        if copy.text_source_col2 then copy.text_source_col2 = copy.text_source_col2 + delta end
        if copy.image_block_col1 then copy.image_block_col1 = copy.image_block_col1 + delta end
        if copy.image_block_col2 then copy.image_block_col2 = copy.image_block_col2 + delta end
        copy.semantic_id = nil
        copy.link = nil
        copy.link_resolution = nil
        copy.on_mouse_pressed = nil
        render.fragments[#render.fragments + 1] = copy
        preserved_body = true
      end
    end
  end
  if not preserved_body and body_text and body_text ~= "" then
    render.fragments[2] = {
      source_col1 = content_col,
      source_col2 = #current_text + 1,
      text = body_text,
      font = markdown_live_body_font(view),
      color = style.text,
    }
  end
  return render
end

local function raw_pending_source_render(view, render_line, current_text, code)
  local font
  for _, fragment in ipairs(render_line and render_line.fragments or {}) do
    if fragment.font and fragment.text and fragment.text ~= "" then
      font = fragment.font
      break
    end
  end
  if code then
    font = style.syntax_fonts.normal or font
  else
    font = font or markdown_live_body_font(view)
  end
  local replacement = clone_render_line(render_line or {})
  replacement.source_text = current_text
  local source_needs_semantics = not code
    and current_text:find("[\\`*_~%[%]!<>#|$]", 1) ~= nil
  replacement.markdown_pending_provenance = source_needs_semantics
    and "unavailable" or "active-source-reveal"
  replacement.position_rows = nil
  replacement.layout_height = nil
  replacement.disable_wrapping = nil
  replacement.table_row = nil
  replacement.table_row_height = nil
  replacement.fragments = {
    {
      source_col1 = 1,
      source_col2 = #current_text + 1,
      text = current_text,
      font = font,
      color = code and style.syntax.normal or nil,
    },
  }
  return replacement
end

local pending_fenced_code_render

local function pending_source_render(view, line, render_line, current_text, code)
  if not code then
    local list_render = pending_list_marker_render(view, render_line, current_text)
    if list_render then return list_render end
  end
  local reveal_code_delimiter = false
  if code then
    local state = current_selection_state(view)
    for index = 1, #(state and state.selections or {}), 4 do
      local line1 = state.selections[index]
      local line2 = state.selections[index + 2] or line1
      if line1 and line >= math.min(line1, line2)
        and line <= math.max(line1, line2)
      then
        reveal_code_delimiter = true
        break
      end
    end
  end
  local render = pending_renderer.current_source(
    view, line, render_line, current_text, code,
    raw_pending_source_render, prose_render_line, markdown_live_scaled_font,
    heading_for_line, heading_font, reveal_code_delimiter,
    pending_fenced_code_render
  )
  local heading = not code and heading_for_line(current_text, line)
  if render and heading then
    local text_row_height = math.max(
      markdown_live_body_line_height(view),
      heading_text_row_height(view, heading.level)
    )
    local gap = markdown_block_gap(view)
    render.text_row_height = text_row_height
    render.first_row_content_y_offset = gap
    render.highlight_height = text_row_height
    render.caret_height = text_row_height
    render.markdown_pending_metric_height = text_row_height + gap
  end
  return render
end

local function current_source_render(view, line, previous, current_text, code)
  return pending_source_render(view, line, previous, current_text, code)
end

local interactive_table_render_line

local function publish_pending_table_row(view, line, render_line)
  local state = view.__markdown_live_owner
  if not (state and render_line) then return false end
  local current = (view.doc.lines[line] or ""):gsub("\n$", "")
  state.pending_lines = state.pending_lines or {}
  state.pending_lines[line] = {
    revision = view.doc.text_revision,
    source_text = current,
    render_line = render_line,
    height = render_line.layout_height
      or view:get_position_visual_row_height(line, 1),
    table_geometry = table_geometry_signature(view),
  }
  return true
end

interactive_table_render_line = function(view, table_node, line, allow_pending)
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local fragments, layout, position_rows, interactive_row_height =
    table_row_fragments(view, table_node, line, allow_pending)
  if not (fragments and layout) then return nil end
  local metric_height = interactive_row_height or layout.row_heights[line]
  if line == layout.delimiter_line then metric_height = math.max(1, math.floor(SCALE)) end

  local on_mouse_selection = function(owner, anchor_line, anchor_col, current_line, current_col)
    return markdown_tables.select_rectangle(
      owner, anchor_line, anchor_col, current_line, current_col
    )
  end
  local rebuild_pending = function(owner)
    local rebuilt = interactive_table_render_line(owner, table_node, line, true)
    return publish_pending_table_row(owner, line, rebuilt)
  end
  local on_structure_changed = function(owner, line1, line2)
    local adjusted = {}
    for key, value in pairs(table_node) do adjusted[key] = value end
    adjusted.source = {}
    for key, value in pairs(table_node.source or {}) do adjusted.source[key] = value end
    adjusted.id = "interactive-table:pending:" .. tostring(line1)
      .. ":" .. tostring(owner.doc.text_revision) .. ":" .. tostring(line2)
    adjusted.source.line1 = line1
    adjusted.source.line2 = line2
    adjusted.source.col2 = #(owner.doc.lines[line2] or "")
    local published = false
    for row_line = line1, line2 do
      local rebuilt = interactive_table_render_line(owner, adjusted, row_line, true)
      published = publish_pending_table_row(owner, row_line, rebuilt) or published
    end
    return published
  end
  local on_text_input = function(owner, input)
    if not markdown_tables.text_input(owner, input) then return false end
    return true
  end
  local on_ime_text_editing = function(owner, input, start, length)
    return markdown_tables.ime_text_editing(owner, input, start, length)
  end

  return prose_render_line(view, text, {
    fragments = fragments,
    disable_wrapping = true,
    table_row = true,
    table_row_height = metric_height,
    position_rows = position_rows,
    position_rows_draw_full_line = true,
    under_selection_backgrounds = true,
    selection_preserves_metrics = layout.selection_stable_layout,
    layout_height = metric_height,
    markdown_table_node = table_node,
    on_mouse_selection = on_mouse_selection,
    on_text_input = on_text_input,
    on_ime_text_editing = on_ime_text_editing,
    on_table_source_changed = rebuild_pending,
    on_table_structure_changed = on_structure_changed,
  })
end

local function split_pending_render(render_line, text)
  local lines, line_start = {}, 1
  while true do
    local newline = text:find("\n", line_start, true)
    local line_end = newline or (#text + 1)
    local source = text:sub(line_start, line_end - 1)
    local line_render = clone_render_line(render_line)
    line_render.source_text = source
    line_render.fragments = {}
    for _, fragment in ipairs(render_line.fragments or {}) do
      local col1 = fragment.source_col1 or 1
      local col2 = fragment.source_col2 or col1
      local from, to = math.max(col1, line_start), math.min(col2, line_end)
      if from < to or (from == to and col1 == col2 and from == line_start) then
        if fragment.widget and (from ~= col1 or to ~= col2) then return nil end
        local copy = {}
        for key, value in pairs(fragment) do copy[key] = value end
        copy.source_col1 = from - line_start + 1
        copy.source_col2 = to - line_start + 1
        if copy.text and not copy.widget then
          copy.text = copy.text:sub(from - col1 + 1, to - col1)
        end
        line_render.fragments[#line_render.fragments + 1] = copy
      end
    end
    lines[#lines + 1] = line_render
    if not newline then break end
    line_start = newline + 1
  end
  return lines
end

local function cached_render_line(view, line)
  local owner = view.__markdown_live_owner
  local pre_edit = owner and owner.pre_edit_lines and owner.pre_edit_lines[line]
  if pre_edit then return pre_edit.render_line end
  local cache = view.__line_render_cache
  local cached = cache and cache.lines and cache.lines[line]
  return cached and cached.render_line ~= false and cached.render_line or nil
end

local function pending_capture_visible_range(view, owner)
  local metric_cache = view.__visual_metric_cache
  if metric_cache
    and metric_cache.signature == view:get_visual_metric_signature()
    and not metric_cache.dirty_rows
  then
    return view:get_visible_line_range()
  end
  if owner.pending_visible_line1 and owner.pending_visible_line2 then
    return owner.pending_visible_line1, owner.pending_visible_line2
  end
  local line = select(1, view.doc:get_selection()) or 1
  local row_height = math.max(1, view:get_line_height())
  local rows = math.max(8, math.ceil((view.size.y or row_height) / row_height) + 8)
  local line1 = math.max(1, line - rows)
  local line2 = math.min(#view.doc.lines, line + rows)
  core.log_quiet(
    "Markdown Live Preview approximated pre-edit viewport at lines %d-%d",
    line1, line2
  )
  return line1, line2
end

local function capture_pre_edit_renders(view, change)
  local capture_started = system.get_time()
  local owner = view.__markdown_live_owner
  if not owner or view_in_source_mode and view_in_source_mode(view) then return end
  local lines = {}
  local transaction = change and change.transaction
  owner.pre_edit_transaction = transaction
  owner.pre_edit_revision = view.doc.text_revision + 1
  if view.get_visible_line_range then
    owner.pending_visible_line1, owner.pending_visible_line2 =
      pending_capture_visible_range(view, owner)
    for line = owner.pending_visible_line1, owner.pending_visible_line2 do
      lines[line] = true
    end
  end
  local structural = false
  for _, edit in ipairs(transaction and transaction.edits or {}) do
    for line = edit.line1 or 1, edit.line2 or edit.line1 or 1 do lines[line] = true end
    if edit.line1 ~= edit.line2
      or (edit.text or ""):find("\n", 1, true)
      or pending_projection.edit_changes_list_structure(edit)
    then
      structural = true
    end
  end
  local service = owner.fence_service
  local edit_touches_fence = false
  for _, edit in ipairs(transaction and transaction.edits or {}) do
    if service and (service:contains_line(edit.line1 or -1)
      or service:contains_line(edit.line2 or edit.line1 or -1))
    then
      edit_touches_fence = true
      break
    end
  end
  if edit_touches_fence then
    for cached_line in pairs(
      view.__line_render_cache and view.__line_render_cache.lines or {}
    ) do
      if service:contains_line(cached_line) then lines[cached_line] = true end
    end
  end
  if change and change.kind == "raw_insert" and change.line then lines[change.line] = true end
  if change and change.kind == "raw_remove" then
    for line = change.line1 or 1, change.line2 or change.line1 or 1 do lines[line] = true end
  end
  local visible_line1, visible_line2
  if structural and owner.pending_visible_line1 then
    visible_line1, visible_line2 =
      owner.pending_visible_line1, owner.pending_visible_line2
    local structural_shift = 0
    for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
      structural_shift = structural_shift + math.abs(range.line_delta or 0)
    end
    if structural_shift == 0 then
      for _, edit in ipairs(transaction and transaction.edits or {}) do
        local inserted = 0
        for _ in (edit.text or ""):gmatch("\n") do inserted = inserted + 1 end
        local removed = math.max(0, (edit.line2 or edit.line1) - edit.line1)
        structural_shift = structural_shift + math.abs(inserted - removed)
      end
    end
    -- A structural edit can expose one or more previously off-screen lines
    -- at either edge of the viewport. Capture a bounded context around the
    -- old visible range so those shifted rows can keep their presentation
    -- while the semantic parser catches up.
    local visible_span = math.max(1, visible_line2 - visible_line1 + 1)
    local context = math.min(structural_shift, visible_span)
    local capture_line1 = math.max(1, visible_line1 - context)
    local capture_line2 = math.min(#view.doc.lines, visible_line2 + context)
    for line = capture_line1, capture_line2 do lines[line] = true end
    visible_line1, visible_line2 = capture_line1, capture_line2
  end
  owner.pre_edit_lines = {}
  local metric_cache = view.__visual_metric_cache
  local metrics_current = metric_cache
    and metric_cache.signature == view:get_visual_metric_signature()
    and not metric_cache.dirty_rows
  local captured = 0
  for line in pairs(lines) do
    local render = cached_render_line(view, line)
    if not render then
      local pending = owner.pending_lines and owner.pending_lines[line]
      if pending and pending.source_text == (view.doc.lines[line] or ""):gsub("\n$", "") then
        render = pending.render_line
      end
    end
    local source_text = (view.doc.lines[line] or ""):gsub("\n$", "")
    local row_heights
    if view.wrapped_settings and metrics_current then
      local first, _, count = linewrapping.get_line_idx_col_count(view, line)
      row_heights = {}
      for row = 1, count do
        row_heights[row] = view:get_visual_row_height(first + row - 1)
      end
    end
    local captured_height = owner.pending_metric_state
      and owner.pending_metric_state.heights
      and owner.pending_metric_state.heights[line]
      or owner.published_line_heights and owner.published_line_heights[line]
      or render and render_line_metric_height(view, render)
      or view:get_line_height()
    owner.pre_edit_lines[line] = {
      source_text = source_text,
      render_line = render and clone_render_line(render) or nil,
      height = captured_height,
      row_heights = row_heights,
      fenced = service and service:contains_line(line) or false,
    }
    captured = captured + 1
  end
  owner.pre_edit_capture = structural and {
    line1 = visible_line1,
    line2 = visible_line2,
    captured = captured,
  } or nil
  owner.last_pre_edit_capture_ms = (system.get_time() - capture_started) * 1000
end

local function retained_metric_height(state, line)
  return state and state.heights and state.heights[line] or nil
end

local function pending_entry(view, render_line, source_text, height, row_heights, provenance)
  if not render_line or render_line.source_text ~= source_text then return nil end
  local rendered_height = render_line_metric_height(view, render_line)
  local metric_height = height or render_line.markdown_pending_metric_height
    or rendered_height
  local leading_spacing = tonumber(render_line.first_row_content_y_offset) or 0
  if leading_spacing > 0 then
    metric_height = math.max(
      metric_height or 0,
      rendered_height + leading_spacing
    )
  end
  return {
    revision = view.doc.text_revision,
    source_text = source_text,
    render_line = render_line,
    height = metric_height,
    row_heights = row_heights,
    provenance = provenance,
  }
end

local function build_pending_projection(view, transaction, pre_edit_lines)
  local owner = view.__markdown_live_owner
  if not owner or not transaction or transaction.type == "load" then return {}, { heights = {} } end
  pre_edit_lines = pre_edit_lines or {}
  local ranges = pending_projection.ordered_changed_ranges(transaction)
  local previous_metrics = owner.pending_metric_state
    or { heights = owner.published_line_heights or {} }
  local next_lines, next_metrics = {}, { heights = {} }
  local context_changed, global_context =
    pending_projection.transaction_changes_block_context(
    view.doc, transaction, pre_edit_lines
  )
  local context_line1, context_line2
  if context_changed then
    if global_context then
      context_line1, context_line2 = 1, #view.doc.lines
    else
      for _, range in ipairs(ranges) do
        local line1 = math.min(
          range.old_line1 or range.new_line1 or 1,
          range.new_line1 or range.old_line1 or 1
        )
        local line2 = math.max(
          range.old_line2 or range.new_line2 or line1,
          range.new_line2 or range.old_line2 or line1
        )
        context_line1 = math.min(context_line1 or line1, math.max(1, line1 - 1))
        context_line2 = math.max(
          context_line2 or line2, math.min(#view.doc.lines, line2 + 1)
        )
      end
    end
  end

  local function retain(old_line, render_line, height, row_heights)
    local new_line = pending_projection.map_unchanged_line(ranges, old_line)
    if not new_line or next_lines[new_line] then return end
    if context_changed
      and new_line >= (context_line1 or new_line)
      and new_line <= (context_line2 or new_line)
    then
      return
    end
    local source = (view.doc.lines[new_line] or ""):gsub("\n$", "")
    if render_line and render_line.source_text == source then
      local retained_height = height or retained_metric_height(previous_metrics, old_line)
      next_lines[new_line] = pending_entry(
        view, clone_render_line(render_line), source,
        retained_height, row_heights, "retained"
      )
      if retained_height then next_metrics.heights[new_line] = retained_height end
    end
  end

  for old_line, captured in pairs(pre_edit_lines) do
    retain(old_line, captured.render_line, captured.height, captured.row_heights)
  end
  for old_line, height in pairs(previous_metrics.heights or {}) do
    local new_line = pending_projection.map_unchanged_line(ranges, old_line)
    if new_line and not next_metrics.heights[new_line] then
      next_metrics.heights[new_line] = height
    end
  end

  local function publish(line, render, captured, provenance)
    if not render then return false end
    local source = (view.doc.lines[line] or ""):gsub("\n$", "")
    if render.position_rows then
      render.position_rows = nil
      render.layout_height = nil
      render = layout_inline_image_rows(view, source, render)
    end
    local entry = pending_entry(
      view, render, source,
      captured and captured.height,
      captured and captured.row_heights,
      provenance or render.markdown_pending_provenance
    )
    if not entry then return false end
    next_lines[line] = entry
    next_metrics.heights[line] = entry.height
    return true
  end

  if #ranges == 1 and #(transaction.edits or {}) == 1 then
    local range, edit = ranges[1], transaction.edits[1]
    local captured = pre_edit_lines[edit.line1]
    local old_render = captured and captured.render_line or cached_render_line(view, edit.line1)
    local transformed = old_render and clone_render_line(old_render)
    local new_source = (view.doc.lines[range.new_line1 or edit.line1] or "")
      :gsub("\n$", "")
    if transformed and pending_projection.block_signature(transformed.source_text or "")
      ~= pending_projection.block_signature(new_source)
    then
      transformed = nil
    end
    local combined = transformed and apply_inline_edit_to_render(
      transformed, transformed.source_text, edit
    )
    local split = combined and split_pending_render(transformed, combined)
    local new_line1 = range.new_line1 or edit.line1
    local new_line2 = range.new_line2 or new_line1
    if split and #split == new_line2 - new_line1 + 1 then
      for index, render in ipairs(split) do
        local line = new_line1 + index - 1
        local source = (view.doc.lines[line] or ""):gsub("\n$", "")
        local list = pending_list_marker_render(view, transformed, source)
        publish(line, list or render, captured, "active-source-reveal")
      end
    end
  end

  for _, range in ipairs(ranges) do
    local old_line1 = range.old_line1 or range.new_line1 or 1
    local old_line2 = range.old_line2 or old_line1
    local new_line1 = range.new_line1 or old_line1
    local new_line2 = range.new_line2 or new_line1
    local fallback = pre_edit_lines[old_line1] or pre_edit_lines[old_line2]
    for new_line = new_line1, new_line2 do
      if not next_lines[new_line] then
        local source = (view.doc.lines[new_line] or ""):gsub("\n$", "")
        local exact
        for old_line = old_line1, old_line2 do
          local captured = pre_edit_lines[old_line]
          if captured and captured.render_line and captured.source_text == source then
            exact = captured
            break
          end
        end
        if exact and not context_changed then
          publish(new_line, clone_render_line(exact.render_line), exact, "retained")
        else
          local previous = fallback and fallback.render_line or nil
          local list = pending_list_marker_render(view, previous, source)
          local render = list or current_source_render(
            view, new_line, previous, source,
            owner.fence_service and owner.fence_service:contains_line(new_line)
          )
          publish(
            new_line, render, context_changed and nil or fallback,
            render.markdown_pending_provenance
          )
        end
      end
    end
  end

  return next_lines, next_metrics, context_changed, context_line1, context_line2
end

local function capture_pending_renders(view, transaction)
  local projection_started = system.get_time()
  local owner = view.__markdown_live_owner
  if not owner or not transaction or transaction.type == "load" then return end
  local pre_edit_lines = owner.pre_edit_lines or {}
  local context_changed, context_line1, context_line2
  owner.pending_lines, owner.pending_metric_state, context_changed,
    context_line1, context_line2 = build_pending_projection(
    view, transaction, pre_edit_lines
  )
  owner.pending_context_revision = context_changed and view.doc.text_revision or nil
  owner.pending_context_line1 = context_line1
  owner.pending_context_line2 = context_line2
  owner.last_pending_projection_ms = (system.get_time() - projection_started) * 1000
  owner.pre_edit_lines = nil
  owner.pre_edit_transaction = nil
  owner.pre_edit_revision = nil
  local retained = 0
  for _ in pairs(owner.pending_lines) do retained = retained + 1 end
  local capture = owner.pre_edit_capture
  core.log_quiet(
    "Markdown Live Preview projection revision=%d visible=%s-%s captured=%d retained=%d capture_ms=%.2f projection_ms=%.2f",
    view.doc.text_revision,
    tostring(capture and capture.line1), tostring(capture and capture.line2),
    capture and capture.captured or 0, retained,
    owner.last_pre_edit_capture_ms or 0, owner.last_pending_projection_ms or 0
  )
  owner.pre_edit_capture = nil
end

local current_provisional_topology

local function pending_render(view, line)
  local owner = view.__markdown_live_owner
  local entry = owner and owner.pending_lines and owner.pending_lines[line]
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  if entry and entry.revision == view.doc.text_revision and entry.source_text == text then
    if entry.render_line and entry.render_line.table_row
    and entry.table_geometry ~= table_geometry_signature(view)
    then
      local table_node = entry.render_line.markdown_table_node
      local rebuilt = table_node and interactive_table_render_line(
        view, table_node, line, true
      )
      if rebuilt then
        publish_pending_table_row(view, line, rebuilt)
        entry = owner.pending_lines[line]
      end
    end
    return entry
  end
  local function current_entry()
    local topology = current_provisional_topology
      and current_provisional_topology(view, line)
      or owner and owner.provisional_topology
    local code
    if topology and topology.revision == view.doc.text_revision
      and line <= (topology.line_limit or 0)
    then
      code = topology.fenced[line] == true
    elseif owner and owner.fence_service then
      code = owner.fence_service:contains_line(line)
    end
    local render = current_source_render(view, line, nil, text, code == true)
    return pending_entry(
      view, render, text, nil, nil, render.markdown_pending_provenance
    )
  end
  if owner and owner.pending_context_revision == view.doc.text_revision
    and line >= (owner.pending_context_line1 or line)
    and line <= (owner.pending_context_line2 or line)
  then
    return current_entry()
  end
  if owner and owner.pre_edit_transaction
    and owner.pre_edit_revision == view.doc.text_revision
  then
    return current_entry()
  end
end

local provider = {}
local poi_provider = {}
local decoration_provider = {}
local file_drop_provider = attachments.drop_provider()
local clipboard_paste_provider = attachments.paste_provider()

function poi_provider:points_of_interest(view)
  local instance = current_semantic_model(view)
  if not instance then return {} end
  local nodes, reason = instance:inline_nodes_for_lines(1, #view.doc.lines, { limit = 32768 })
  if reason == "limit" then
    core.log_quiet("Markdown link POIs exceeded the 32768-capture bound for %s", view.doc:get_name())
    return {}
  end
  local points, seen = {}, {}
  for _, node in ipairs(nodes or {}) do
    if (node.type == "link" or node.type == "image" or node.type == "link_reference"
      or node.type == "wiki_link" or node.type == "embed")
      and node.source.line1 == node.source.line2 and not seen[node.id]
    then
      local line = node.source.line1
      local text = (view.doc.lines[line] or ""):gsub("\n$", "")
      local link = node.type == "link_reference"
        and reference_link_from_node(view, text, line, node)
        or markdown_links.from_semantic_node(text, line, node)
      if link then
        seen[node.id] = true
        points[#points + 1] = {
          line = line,
          col = node.source.col1,
          line2 = line,
          col2 = node.source.col2,
          text_bounds = true,
          kind = "markdown-link",
          label = link.display,
          semantic_id = node.id,
          link = link,
          activate = function(owner, point)
            return live.open_link(owner, {
              link = point.link,
              resolution = resolve_live_link(owner, point.link),
            })
          end,
        }
      end
    end
  end
  return points
end

view_in_source_mode = function(view)
  local owner = view.__markdown_live_owner
  return owner and owner.source_mode == true
end

local function fenced_code_for_line(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "code_fenced" then
      local line2 = node.source.line2
      if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
      if line >= node.source.line1 and line <= line2 then
        node.effective_line2 = line2
        return node
      end
    end
  end
end

local function indented_code_for_line(view, line)
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "code_indented" then
      local line2 = node.source.line2
      if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
      if line >= node.source.line1 and line <= line2 then return node end
    end
  end
end

current_provisional_topology = function(view, line)
  local owner = view.__markdown_live_owner
  local topology = owner and owner.provisional_topology
  if not topology or topology.revision ~= view.doc.text_revision then return nil end
  if line and line > (topology.line_limit or 0) then
    local old_limit = topology.line_limit or 0
    local line_limit = math.min(
      #view.doc.lines,
      math.max(line, old_limit + 256)
    )
    local fenced, comments, math, frontmatter, html, fence_delimiters =
      pending_projection.source_topology(view.doc.lines, line_limit)
    topology = {
      revision = view.doc.text_revision,
      line_limit = line_limit,
      fenced = fenced,
      comments = comments,
      math = math,
      frontmatter = frontmatter,
      html = html,
      fence_delimiters = fence_delimiters,
    }
    owner.provisional_topology = topology
    core.log_quiet(
      "Markdown Live Preview extended provisional topology from line %d to %d",
      old_limit, line_limit
    )
  end
  return topology
end

local function fenced_code_delimiter_kind(view, fenced, line)
  if line == fenced.source.line1 then return "open" end
  if line ~= fenced.effective_line2 then return nil end
  local opening = (view.doc.lines[fenced.source.line1] or ""):gsub("\n$", "")
  local closing = (view.doc.lines[line] or ""):gsub("\n$", "")
  local marker, count = fence_marker(opening)
  return marker and closes_fence(closing, marker, count) and "close" or nil
end

local function fenced_code_is_active(view, fenced, state)
  state = state or current_selection_state(view)
  for i = 1, #(state and state.selections or {}), 4 do
    local line1 = state.selections[i]
    local line2 = state.selections[i + 2] or line1
    if line1 and math.max(line1, line2) >= fenced.source.line1
      and math.min(line1, line2) <= fenced.effective_line2
    then
      return true
    end
  end
  return false
end

local function fenced_code_line_height(view)
  local base_font = style.syntax_fonts.normal or view:get_font()
  local height = base_font:get_height()
  -- Keep every code row stable while lazy tokenization publishes new token
  -- categories with potentially different font metrics.
  for _, font in pairs(style.syntax_fonts) do
    if font and font.get_height then height = math.max(height, font:get_height()) end
  end
  return math.max(math.floor(height * config.line_height), height)
end

local function fenced_code_fragments(text, entry)
  local fragments = {}
  local col = 1
  if entry then
    for _, syntax_type, token_text in tokenizer.each_token(entry.tokens) do
      if col > #text then break end
      token_text = token_text:sub(1, #text - col + 1)
      if token_text ~= "" then
        fragments[#fragments + 1] = {
          source_col1 = col,
          source_col2 = col + #token_text,
          text = token_text,
          font = style.syntax_fonts[syntax_type],
          color = style.syntax[syntax_type] or style.syntax.normal,
        }
        col = col + #token_text
      end
    end
  end
  if col <= #text then
    fragments[#fragments + 1] = {
      source_col1 = col,
      source_col2 = #text + 1,
      text = text:sub(col),
      font = style.syntax_fonts.normal,
      color = style.syntax.normal,
    }
  end
  return fragments
end

pending_fenced_code_render = function(view, line, text)
  local owner = view.__markdown_live_owner
  local service = owner and owner.fence_service
  local entry = service and service.peek_line_tokens_at_line
    and service:peek_line_tokens_at_line(line)
  return {
    source_text = text,
    x_offset = view:get_font():get_width(" "),
    text_row_height = fenced_code_line_height(view),
    fragments = fenced_code_fragments(text, entry),
  }
end

local function fenced_code_content_render_line(view, line, text, fenced)
  local owner = view.__markdown_live_owner
  local service = owner and owner.fence_service
  local entry = service and service:line_tokens(fenced, line, 100)
  return {
    source_text = text,
    x_offset = view:get_font():get_width(" "),
    text_row_height = fenced_code_line_height(view),
    fragments = fenced_code_fragments(text, entry),
  }
end

function decoration_provider:line_background(view, line)
  if view_in_source_mode(view) then return nil end
  local owner = view.__markdown_live_owner
  local model = owner and owner.semantic_model
  local semantics_pending = model and (
    model.status == "pending" or model.published_revision ~= view.doc.text_revision
  )
  if semantics_pending then
    local provisional = current_provisional_topology(view, line)
    if provisional and provisional.revision == view.doc.text_revision then
      if provisional.comments[line] then return nil end
      if provisional.fenced[line] then return style.markdown_live_code_background end
    elseif owner.fence_service and owner.fence_service:contains_line(line) then
      return style.markdown_live_code_background
    end
  end
  local topology = current_provisional_topology(view, line)
  if not (topology and topology.revision == view.doc.text_revision)
    and line_in_semantic_comment(view, line)
  then
    return nil
  end
  local fenced = fenced_code_for_line(view, line)
  if fenced then
    return style.markdown_live_code_background
  end
  if not current_semantic_model(view) and owner then
    local provisional = current_provisional_topology(view, line)
    if provisional and provisional.revision == view.doc.text_revision then
      if provisional.fenced[line] then return style.markdown_live_code_background end
    elseif owner.fence_service and owner.fence_service:contains_line(line) then
      -- The fence service transaction-maps unchanged block ownership before
      -- the semantic worker publishes. Unlike a retained render fragment,
      -- this membership belongs to the current Document revision.
      return style.markdown_live_code_background
    end
  end
  if indented_code_for_line(view, line) then
    return style.markdown_live_code_background
  end
  if callout_for_line(view, line) then return style.markdown_live_callout_background end
  if frontmatter_for_line(view, line) then return style.markdown_live_frontmatter_background end
  return nil
end

function decoration_provider:line_number_visible(view)
  if view_in_source_mode(view) then return nil end
  return false
end

function decoration_provider:line_number_gutter_visible(view)
  if view_in_source_mode(view) then return nil end
  return false
end

local function provider_generation_state(view)
  -- Wrapped-row topology is tracked by DocView's metric signature. It is not
  -- a Markdown presentation change: coupling it to this generation made a
  -- local wrap splice look like a document-wide metric invalidation.
  local presentation_generation = view:get_presentation_layout_generation()
  local theme_generation = core.color_theme_generation or 0
  local body_font = style.prose_font
  local body_font_size = view:get_font():get_size()
  local scrollbar_width = view.v_scrollbar.expanded_size or style.expanded_scrollbar_size
  local padding_x = style.padding.x
  local cache = view.__markdown_live_provider_generation_state
  local prose_typography_unchanged = cache and cache.prose_fonts ~= nil
  if prose_typography_unchanged then
    for _, name in ipairs(PROSE_FONT_ROLE_NAMES) do
      local font = style[name]
      local cached = cache.prose_fonts[name]
      if not cached or cached.font ~= font or cached.size ~= font:get_size() then
        prose_typography_unchanged = false
        break
      end
    end
  end
  if cache
    and cache.presentation_generation == presentation_generation
    and cache.theme_generation == theme_generation
    and cache.body_font == body_font
    and prose_typography_unchanged
    and cache.body_font_size == body_font_size
    and cache.scrollbar_width == scrollbar_width
    and cache.padding_x == padding_x
    and cache.interactive_tables == (config.markdown_live_interactive_tables == true)
    and cache.scale == SCALE
  then
    return cache
  end
  local prose_fonts = {}
  local prose_typography = {}
  for _, name in ipairs(PROSE_FONT_ROLE_NAMES) do
    local font = style[name]
    local size = font:get_size()
    prose_fonts[name] = { font = font, size = size }
    prose_typography[#prose_typography + 1] = tostring(font)
    prose_typography[#prose_typography + 1] = tostring(size)
  end
  cache = {
    presentation_generation = presentation_generation,
    theme_generation = theme_generation,
    body_font = body_font,
    prose_fonts = prose_fonts,
    prose_typography_signature = table.concat(prose_typography, ":"),
    body_font_size = body_font_size,
    scrollbar_width = scrollbar_width,
    padding_x = padding_x,
    interactive_tables = config.markdown_live_interactive_tables == true,
    scale = SCALE,
  }
  view.__markdown_live_provider_generation_state = cache
  return cache
end

function provider:generation_seed(view)
  return provider_generation_state(view)
end

function provider:generation(view)
  perf_frame_add("markdown_live_provider_generation_requests", 1)
  local state = provider_generation_state(view)
  if state.generation then
    perf_frame_add("markdown_live_provider_generation_cache_hits", 1)
    return state.generation
  end
  local font = markdown_live_body_font(view)
  local table_width = table_available_width(view)
  local image_width = image_available_width(view)
  local geometry_context = view.__centered_editor_in_geometry and "centered" or "host"
  perf_frame_add("markdown_live_provider_generation_calls", 1)
  perf_frame_add(
    geometry_context == "centered"
      and "markdown_live_provider_generation_centered_calls"
      or "markdown_live_provider_generation_host_calls",
    1
  )
  perf_detail(string.format(
    "markdown_live_provider_geometry:%s:view_width=%d:table_width=%d:image_width=%d",
    geometry_context,
    math.floor(tonumber(view.size and view.size.x) or 0),
    math.floor(tonumber(table_width) or 0),
    math.floor(tonumber(image_width) or 0)
  ), 1)
  -- `markdown_live_body_font()` may return a fresh size-adjusted copy. Keying
  -- by that temporary object's identity makes an unchanged layout look new
  -- whenever wrapping is locally refreshed.
  state.generation = state.prose_typography_signature .. ":" .. tostring(font:get_size())
    .. ":width:" .. tostring(table_width)
    .. ":image-width:" .. tostring(image_width)
    .. ":interactive-tables:" .. tostring(state.interactive_tables)
  return state.generation
end

function provider:horizontal_extent(view)
  if view_in_source_mode(view)
  or config.markdown_live_interactive_tables ~= true
  then
    return 0
  end
  local instance = current_semantic_model(view)
  if not instance then return cached_table_horizontal_extent(view) end
  local owner = view.__markdown_live_owner
  local key = table.concat({
    tostring(instance.generation), tostring(view.doc.text_revision),
    tostring(self:generation(view)),
  }, ":")
  local cached = owner and owner.table_horizontal_extent
  if cached and cached.key == key then
    if not cached.complete then
      cached.width = math.max(cached.width, cached_table_horizontal_extent(view))
    end
    return cached.width
  end

  local width = 0
  local nodes, reason = instance:nodes_for_lines(1, #view.doc.lines, {
    limit = 100000,
  })
  local seen = {}
  for _, node in ipairs(nodes or {}) do
    if node.type == "table" and not seen[node.id] then
      seen[node.id] = true
      local table_node = markdown_tables.extend_semantic_table(
        view, node.source.line1, node
      )
      local layout = table_layout(view, table_node, false)
      if layout then width = math.max(width, layout.total_width or 0) end
    end
  end
  if reason == "limit" then
    width = math.max(width, cached_table_horizontal_extent(view))
    core.log_quiet(
      "Markdown table horizontal extent used partial semantic results for %s",
      view.doc:get_name()
    )
  end
  if owner then
    owner.table_horizontal_extent = {
      key = key, width = width, complete = reason ~= "limit",
    }
  end
  return width
end

function provider:line_generation(view, line)
  if view_in_source_mode(view) then return "source" end
  local pending = pending_render(view, line)
  local owner = view.__markdown_live_owner
  local fence_generation = ""
  local fenced = fenced_code_for_line(view, line)
  if fenced and owner and owner.fence_service then
    fence_generation = ":fence:" .. tostring(owner.fence_service:line_generation(fenced, line))
  end
  local semantic_state = ""
  if owner and not pending and owner.semantic_pending_line
    and line >= owner.semantic_pending_line
  then
    semantic_state = ":semantic-pending:" .. tostring(view.doc.text_revision)
  elseif owner and owner.semantic_adoption_line
    and line >= owner.semantic_adoption_line
  then
    semantic_state = ":semantic-adopt:" .. tostring(owner.semantic_adoption_generation or 0)
  end
  local context = view.__markdown_live_line_generation_context or {}
  view.__markdown_live_line_generation_context = context
  context.line = line
  context.pending = pending or false
  context.owner = owner or false
  context.fenced = fenced or false
  return "font:" .. self:generation(view)
    .. fence_generation
    .. semantic_state
    .. (pending and ":pending:" .. tostring(pending.revision) or "")
end

function provider:on_text_transaction(view, transaction, line1, line2)
  if not line1 then return nil end
  local table_line1, table_line2
  local table_cache = view.__markdown_live_table_layout_cache
  for id, layout in pairs(table_cache and table_cache.layouts or {}) do
    if layout then
      for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
        local old_line1 = range.old_line1 or range.new_line1 or line1
        local old_line2 = range.old_line2 or old_line1
        if old_line2 >= layout.line1 and old_line1 <= layout.line2 then
          table_line1 = math.min(table_line1 or layout.line1, layout.line1)
          table_line2 = math.max(table_line2 or layout.line2, layout.line2)
          table_cache.layouts[id] = nil
          break
        end
      end
    end
  end
  local owner = view.__markdown_live_owner
  local pre_edit_lines = owner and owner.pre_edit_lines
  if owner then
    owner.link_targets_changed_revision =
      pending_projection.transaction_changes_link_targets(
        view.doc, transaction, pre_edit_lines
      ) and view.doc.text_revision or nil
  end
  local raw_context_changed = pending_projection.transaction_changes_raw_context(
    view.doc, transaction, pre_edit_lines
  )
  local block_context_changed, global_context_changed =
    pending_projection.transaction_changes_block_context(
    view.doc, transaction, pre_edit_lines
  )
  local frontmatter_changed = pending_projection.transaction_changes_frontmatter(
    view.doc, transaction, pre_edit_lines
  )
  local html_changed = pending_projection.transaction_changes_html(
    view.doc, transaction, pre_edit_lines
  )
  local line_structure_changed = false
  for _, edit in ipairs(transaction and transaction.edits or {}) do
    if edit.line1 ~= edit.line2 or (edit.text or ""):find("\n", 1, true) then
      line_structure_changed = true
      break
    end
  end
  if not line_structure_changed then
    for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
      if (range.line_delta or 0) ~= 0 then
        line_structure_changed = true
        break
      end
    end
  end
  local topology_changed = raw_context_changed or frontmatter_changed
    or html_changed or line_structure_changed
  if topology_changed and owner then
    local topology_started = system.get_time()
    local topology_limit = math.max(
      line1 or 1,
      owner.pending_visible_line2 or 1
    )
    for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
      topology_limit = math.max(
        topology_limit,
        range.new_line2 or range.new_line1 or 1
      )
    end
    topology_limit = math.min(#view.doc.lines, topology_limit)
    local fenced, comments, math, frontmatter, html, fence_delimiters =
      pending_projection.source_topology(view.doc.lines, topology_limit)
    owner.provisional_topology = {
      revision = view.doc.text_revision,
      line_limit = topology_limit,
      fenced = fenced,
      comments = comments,
      math = math,
      frontmatter = frontmatter,
      html = html,
      fence_delimiters = fence_delimiters,
    }
    owner.last_topology_ms = (system.get_time() - topology_started) * 1000
  elseif owner then
    owner.provisional_topology = nil
    owner.last_topology_ms = 0
  end
  capture_pending_renders(view, transaction)
  owner = view.__markdown_live_owner
  local fence_line1, fence_line2
  if owner and owner.fence_service then
    local cached_fence_lines = {}
    local opening_changed = false
    for _, edit in ipairs(transaction and transaction.edits or {}) do
      if owner.fence_service:is_opening_line(edit.line1 or -1) then
        opening_changed = true
        break
      end
    end
    if not opening_changed then
      for cached_line, captured in pairs(pre_edit_lines or {}) do
        local source = (view.doc.lines[cached_line] or ""):gsub("\n$", "")
        if captured.fenced and captured.render_line and captured.source_text == source then
          cached_fence_lines[cached_line] = {
            revision = view.doc.text_revision,
            source_text = source,
            render_line = clone_render_line(captured.render_line),
            height = captured.height,
            row_heights = captured.row_heights,
          }
        end
      end
      for cached_line, cached in pairs(
        view.__line_render_cache and view.__line_render_cache.lines or {}
      ) do
        if owner.fence_service:contains_line(cached_line) then
          local render = cached.render_line ~= false and cached.render_line or nil
          local source = (view.doc.lines[cached_line] or ""):gsub("\n$", "")
          if render and render.source_text == source then
            cached_fence_lines[cached_line] = {
              revision = view.doc.text_revision,
              source_text = source,
              render_line = clone_render_line(render),
              height = render_line_metric_height(view, render),
            }
          end
        end
      end
    end
    fence_line1, fence_line2 = owner.fence_service:on_text_transaction(transaction)
    if fence_line1 then
      owner.pending_lines = owner.pending_lines or {}
      for cached_line, cached in pairs(cached_fence_lines) do
        if cached_line >= fence_line1 and cached_line <= (fence_line2 or fence_line1)
          and not owner.pending_lines[cached_line]
        then
          owner.pending_lines[cached_line] = cached
        end
      end
    end
  end
  if table_line1 then
    local owner = view.__markdown_live_owner
    for line, entry in pairs(owner and owner.pending_lines or {}) do
      if entry.render_line and entry.render_line.table_row then
        owner.pending_lines[line] = nil
      end
    end
    local source_line1, source_line2 = markdown_tables.source_bounds(
      view, table_line1
    )
    if source_line1 then
      local pending_node = {
        id = "interactive-table:transaction:" .. tostring(source_line1)
          .. ":" .. tostring(view.doc.text_revision),
        source = {
          line1 = source_line1, col1 = 1,
          line2 = source_line2,
          col2 = #(view.doc.lines[source_line2] or ""),
        },
      }
      local published = 0
      for row_line = source_line1, source_line2 do
        local rebuilt = interactive_table_render_line(
          view, pending_node, row_line, true
        )
        if publish_pending_table_row(view, row_line, rebuilt) then
          published = published + 1
        end
      end
      core.log_quiet(
        "Markdown Interactive Table Editing retained %d rendered row(s) through revision %d",
        published, view.doc.text_revision
      )
    end
  end
  local structural_change = transaction and transaction.type == "load"
    or line_structure_changed
  -- A newline edit can replace one logical line with one logical line (for
  -- example, pressing Enter on an empty Markdown list item exits the list),
  -- so a zero net line delta does not prove that block structure is stable.
  local list_structure_changed = pending_projection.transaction_changes_list_structure(
    view.doc, transaction, pre_edit_lines
  )
  structural_change = structural_change or list_structure_changed
  if topology_changed and owner then
    local topology = owner.provisional_topology
    local fenced = topology.fenced
    for pending_line, pending in pairs(owner.pending_lines or {}) do
      local was_fenced = owner.fence_service
        and owner.fence_service:contains_line(pending_line) or false
      local is_fenced = fenced[pending_line] == true
      local was_comment = line_in_semantic_comment(view, pending_line)
      if not was_comment then
        local fragments = pending.render_line and pending.render_line.fragments or {}
        was_comment = #fragments > 0
        for _, fragment in ipairs(fragments) do
          if not fragment.hidden then was_comment = false break end
        end
      end
      local is_comment = topology.comments[pending_line] == true
      local was_math = line_in_semantic_math(view, pending_line)
      local is_math = topology.math[pending_line] == true
      local was_frontmatter = frontmatter_for_line(view, pending_line) ~= nil
      local is_frontmatter = topology.frontmatter[pending_line] == true
      local was_html = line_in_raw_block(view, pending_line) ~= nil
      local is_html = topology.html[pending_line] == true
      if was_fenced ~= is_fenced or was_comment ~= is_comment
        or was_math ~= is_math or was_frontmatter ~= is_frontmatter
        or was_html ~= is_html
      then
        pending.render_line = current_source_render(
          view, pending_line, pending.render_line,
          pending.source_text, is_fenced
        )
        pending.height = render_line_metric_height(view, pending.render_line)
        pending.row_heights = nil
      end
    end
  end
  local suffix_changed = structural_change or topology_changed or block_context_changed
  if not suffix_changed then
    local affected_line1 = math.min(table_line1 or math.huge, fence_line1 or math.huge)
    local affected_line2 = math.max(table_line2 or -math.huge, fence_line2 or -math.huge)
    core.log_quiet(
      "Markdown Live Preview transaction revision=%d type=%s structural=false raw_context=false changed=%s-%s provider=%s-%s pending=%d",
      view.doc.text_revision, tostring(transaction and transaction.type),
      tostring(line1), tostring(line2),
      tostring(affected_line1 ~= math.huge and affected_line1 or nil),
      tostring(affected_line2 ~= -math.huge and affected_line2 or nil),
      (function()
        local count = 0
        for _ in pairs(owner and owner.pending_lines or {}) do count = count + 1 end
        return count
      end)()
    )
    return affected_line1 ~= math.huge and affected_line1 or nil,
      affected_line2 ~= -math.huge and affected_line2 or nil,
      true
  end
  -- Setext markers own the previous line. Only reference definitions can
  -- change presentation before that; do not turn every local block edit into
  -- a whole-Document invalidation.
  local context_line1 = global_context_changed and 1
    or block_context_changed and math.max(1, line1 - 1)
    or line1
  if owner then
    owner.semantic_pending_line = math.min(
      owner.semantic_pending_line or context_line1, context_line1
    )
    if raw_context_changed then
      owner.semantic_pending_wrap_line = math.min(
        owner.semantic_pending_wrap_line or line1, line1
      )
    end
  end
  local affected_line1 = math.min(
    context_line1, table_line1 or context_line1, fence_line1 or context_line1
  )
  local affected_line2 = math.max(line1, table_line2 or line1, fence_line2 or line1)
  local pending_count = 0
  for _ in pairs(owner and owner.pending_lines or {}) do pending_count = pending_count + 1 end
  core.log_quiet(
    "Markdown Live Preview transaction revision=%d type=%s structural=%s raw_context=%s changed=%s-%s provider=%s-%s pending=%d pending_from=%s",
    view.doc.text_revision, tostring(transaction and transaction.type),
    tostring(structural_change), tostring(raw_context_changed),
    tostring(line1), tostring(line2),
    tostring(affected_line1), tostring(affected_line2), pending_count,
    tostring(owner and owner.semantic_pending_line)
  )
  return affected_line1,
    affected_line2,
    true
end

local function heading_content_fragments(view, text, heading, font, reveal_units)
  local fragments, occupied = {}, {}
  local italic_font = heading_italic_font(view, heading.level)
  for _, fragment in ipairs(semantic_link_fragments(view, text, heading.line, reveal_units, {
    base_font = font,
    base_bold = true,
    base_italic_font = italic_font,
  })) do
    if fragment.source_col1 >= heading.content_col1 and fragment.source_col2 <= heading.content_col2 then
      add_fragment(fragments, occupied, fragment)
    end
  end
  for _, fragment in ipairs(semantic_formatting_fragments(view, text, heading.line, reveal_units, {
    col1 = heading.content_col1,
    col2 = heading.content_col2,
    base_font = font,
    base_bold = true,
    base_italic_font = italic_font,
    color = style.text,
  })) do
    add_fragment(fragments, occupied, fragment)
  end
  table.sort(fragments, function(a, b) return a.source_col1 < b.source_col1 end)
  local normalized, cursor = {}, heading.content_col1
  for _, fragment in ipairs(fragments) do
    if cursor < fragment.source_col1 then
      normalized[#normalized + 1] = {
        source_col1 = cursor, source_col2 = fragment.source_col1,
        text = text:sub(cursor, fragment.source_col1 - 1), font = font, color = style.text,
      }
    end
    normalized[#normalized + 1] = fragment
    cursor = math.max(cursor, fragment.source_col2)
  end
  if cursor < heading.content_col2 then
    normalized[#normalized + 1] = {
      source_col1 = cursor, source_col2 = heading.content_col2,
      text = text:sub(cursor, heading.content_col2 - 1), font = font, color = style.text,
    }
  end
  return normalized
end

local function active_heading_fragments(view, text, heading, font, reveal_units)
  local fragments = {}
  if heading.content_col1 > 1 then
    fragments[#fragments + 1] = {
      source_col1 = 1, source_col2 = heading.content_col1,
      text = text:sub(1, heading.content_col1 - 1), font = font,
      color = style.markdown_live_heading_marker,
    }
  end
  for _, fragment in ipairs(heading_content_fragments(view, text, heading, font, reveal_units)) do fragments[#fragments + 1] = fragment end
  if heading.content_col2 < #text + 1 then
    fragments[#fragments + 1] = { source_col1 = heading.content_col2, source_col2 = #text + 1,
      text = text:sub(heading.content_col2), font = font, color = style.markdown_live_heading_marker }
  end
  return fragments
end

local function inactive_heading_fragments(view, text, heading, font, reveal_units)
  local fragments = {}
  if heading.content_col1 > 1 then
    fragments[#fragments + 1] = { source_col1 = 1, source_col2 = heading.content_col1, hidden = true }
  end
  for _, fragment in ipairs(heading_content_fragments(view, text, heading, font, reveal_units)) do fragments[#fragments + 1] = fragment end
  if heading.content_col2 < #text + 1 then
    fragments[#fragments + 1] = { source_col1 = heading.content_col2,
      source_col2 = #text + 1, hidden = true }
  end
  return fragments
end

local function heading_render_line(view, text, heading, reveal_units)
  local font = heading_font(view, heading.level)
  local text_row_height = math.max(
    markdown_live_body_line_height(view),
    heading_text_row_height(view, heading.level)
  )
  local heading_revealed = reveal_unit_matches(
    reveal_units, heading.semantic_id, heading.source_col1, heading.source_col2
  )
  return prose_render_line(view, text, {
    source_text = text,
    text_row_height = text_row_height,
    first_row_content_y_offset = markdown_block_gap(view),
    highlight_height = text_row_height,
    caret_height = text_row_height,
    semantic_id = heading.semantic_id,
    semantic_generation = heading.semantic_generation,
    fragments = heading_revealed
      and active_heading_fragments(view, text, heading, font, reveal_units)
      or inactive_heading_fragments(view, text, heading, font, reveal_units),
  })
end

local function block_spacing_after(view, line)
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local next_text = (view.doc.lines[line + 1] or ""):gsub("\n$", "")
  if text:match("^%s*$") or next_text == "" or next_text:match("^%s*$") then
    return 0
  end
  local table_node = table_for_line(view, line)
  if table_node then
    local next_table = table_for_line(view, line + 1)
    if not next_table or next_table.id ~= table_node.id then
      return markdown_block_gap(view)
    end
  end
  return 0
end

local function final_visual_row_for_line(view, line, entry)
  if not view.wrapped_settings then return true end
  return entry and entry.row_in_line == view:get_visual_row_count_for_line(line)
end

local function with_block_spacing(view, line, entry, height, leading_spacing)
  if not height then return height end
  if leading_spacing and leading_spacing > 0
    and (not entry or entry.row_in_line == 1)
  then
    height = height + leading_spacing
  end
  if final_visual_row_for_line(view, line, entry) then
    height = height + block_spacing_after(view, line)
  end
  return height
end

local function compute_line_height(view, line, entry)
  if view_in_source_mode(view) then return nil end
  local wrapped = line_is_wrapped(view, line)
  local semantic_model = current_semantic_model(view)
  local pending = pending_render(view, line)
  if pending and not semantic_model then
    local row = entry and entry.row_in_line
    if row and pending.row_heights and pending.row_heights[row] then
      return pending.row_heights[row]
    end
    if not wrapped then return pending.height end
  end
  local owner = view.__markdown_live_owner
  if not semantic_model and owner and owner.semantic_pending_line
    and line >= owner.semantic_pending_line
  then
    return view:get_line_height()
  end
  -- Resolve the presentation once through DocView's line cache. Metrics and
  -- drawing now consume the same fragment/widget/layout plan instead of
  -- independently rebuilding headings, images, tables, and inline spans.
  local render_line = view:get_line_render(line)
  if not render_line then return view:get_line_height() end
  if render_line.metric_height then return render_line.metric_height end
  local leading_spacing = tonumber(render_line.first_row_content_y_offset) or 0
  local body_height = render_line.text_row_height
    or markdown_live_body_line_height(view)
  if wrapped then
    local final_row = entry and entry.row_in_line
      and entry.row_in_line == view:get_visual_row_count_for_line(line)
    local height = body_height
    if final_row then
      height = math.max(height, render_line_metric_height(view, render_line))
    end
    return with_block_spacing(view, line, entry, height, leading_spacing)
  end
  if render_line.layout_height then
    return with_block_spacing(
      view, line, entry, render_line.layout_height, leading_spacing
    )
  end
  if render_line.table_row_height then
    return with_block_spacing(
      view, line, entry, render_line.table_row_height, leading_spacing
    )
  end
  local height = math.max(body_height, render_line_metric_height(view, render_line))
  return with_block_spacing(view, line, entry, height, leading_spacing)
end

function provider:line_height(view, line, entry)
  local owner = view.__markdown_live_owner
  local wrapped = line_is_wrapped(view, line)
  local semantic_model = current_semantic_model(view)
  if not wrapped and not semantic_model then
    local retained = owner and retained_metric_height(owner.pending_metric_state, line)
    if retained then return retained end
  end
  if not semantic_model and owner and owner.semantic_pending_line
    and line >= owner.semantic_pending_line
  then
    local pending = pending_render(view, line)
    if pending then
      local row = entry and entry.row_in_line
      if row and pending.row_heights and pending.row_heights[row] then
        return pending.row_heights[row]
      end
      if not wrapped and pending.height then return pending.height end
    end
    -- Do not ask the line-render provider for an unretained suffix row while
    -- the parser is pending. That turns a metric pass into a raw-source cache
    -- fill, which can flash Markdown syntax while the user is editing.
    return view:get_line_height()
  end
  local height = compute_line_height(view, line, entry)
  if semantic_model and owner then
    owner.published_line_heights = owner.published_line_heights or {}
    if not wrapped and height and height ~= view:get_line_height() then
      owner.published_line_heights[line] = height
    else
      owner.published_line_heights[line] = nil
    end
  end
  return height
end

---Resolve one logical line once for a visual-metric pass. Wrapped body rows
---share a height; only the final row can add widgets or block spacing.
function provider:line_metrics(view, line, row_count)
  row_count = math.max(1, row_count or 1)
  if not line_is_wrapped(view, line) then
    local height = self:line_height(view, line, { row_in_line = 1 })
    return { row_count = 1, height = height, final_height = height }
  end
  local pending = pending_render(view, line)
  if pending and pending.row_heights then
    local heights = {}
    for row = 1, row_count do
      heights[row] = compute_line_height(view, line, { row_in_line = row })
    end
    return { row_count = row_count, heights = heights }
  end
  local height = compute_line_height(view, line, { row_in_line = 1 })
  if row_count == 1 then
    return { row_count = 1, height = height, final_height = height }
  end
  return {
    row_count = row_count,
    height = height,
    final_height = compute_line_height(view, line, { row_in_line = row_count }),
  }
end

local sparse_metric_node_types = {
  heading = true,
  code_fenced = true,
  code_indented = true,
  html = true,
  link_reference = true,
  table = true,
  table_header = true,
  table_row = true,
  table_cell = true,
  thematic_break = true,
  image = true,
  embed = true,
  math = true,
}

---Describe the small set of unwrapped lines whose Markdown presentation can
---differ from the body-row height. DocView can initialize every ordinary
---prose row from the default and ask line_height only for these exceptions.
function provider:sparse_line_metrics(view)
  if view_in_source_mode(view) or view.wrapped_settings then return nil end
  local instance = current_semantic_model(view)
  if not instance then return nil end
  local nodes, reason = instance:nodes_for_lines(1, #view.doc.lines, {
    limit = 100000,
  })
  if not nodes or reason == "limit" then return nil end
  local lines = {}
  for _, node in ipairs(nodes) do
    if sparse_metric_node_types[node.type] then
      local line1 = math.max(1, node.source.line1 or 1)
      local line2 = math.min(#view.doc.lines, node.source.line2 or line1)
      for line = line1, line2 do lines[line] = true end
    end
  end
  local owner = view.__markdown_live_owner
  for line in pairs(owner and owner.published_line_heights or {}) do lines[line] = true end
  return {
    complete = true,
    default_height = markdown_live_body_line_height(view),
    lines = lines,
  }
end

local function record_raw_fallback(view, line, reason)
  local owner = view.__markdown_live_owner
  if not owner then return end
  local revision = view.doc.text_revision
  local record = owner.raw_fallback_record
  if not record or record.revision ~= revision then
    record = { revision = revision, lines = {}, count = 0, line1 = line, line2 = line }
    owner.raw_fallback_record = record
  end
  if record.lines[line] then return end
  record.lines[line] = reason or true
  record.count = record.count + 1
  record.line1 = math.min(record.line1, line)
  record.line2 = math.max(record.line2, line)
  if record.count == 1 or record.count == 10 or record.count % 50 == 0 then
    local instance = markdown_model.peek(view.doc)
    core.log_quiet(
      "Markdown Live Preview RAW FALLBACK revision=%d line=%d reason=%s count=%d range=%d-%d model=%s published_revision=%s pending_from=%s pending=%s",
      revision, line, tostring(reason), record.count, record.line1, record.line2,
      tostring(instance and instance.status),
      tostring(instance and instance.published_revision),
      tostring(owner.semantic_pending_line),
      tostring(pending_render(view, line) ~= nil)
    )
  end
end

local function build_render_line(view, line, _context)
  if view_in_source_mode(view) then
    return { raw_passthrough = true }
  end
  local generation_context = view.__markdown_live_line_generation_context
  if not generation_context or generation_context.line ~= line then generation_context = nil end
  local pending
  if generation_context then
    pending = generation_context.pending ~= false
      and generation_context.pending or nil
  else
    pending = pending_render(view, line)
  end
  local owner
  if generation_context then
    owner = generation_context.owner ~= false and generation_context.owner or nil
  else
    owner = view.__markdown_live_owner
  end
  if pending and not current_semantic_model(view) then return pending.render_line end
  if not render_semantic_model(view, line) then
    local semantic_model = owner and owner.semantic_model
    local semantic_pending = owner and (
      owner.semantic_pending_line ~= nil
      or semantic_model and (
        semantic_model.status == "pending"
        or semantic_model.published_revision ~= view.doc.text_revision
      )
    )
    if semantic_pending
      and (not owner.semantic_pending_line or line >= owner.semantic_pending_line)
    then
      local text = (view.doc.lines[line] or ""):gsub("\n$", "")
      local pending_list = pending_list_marker_render(view, nil, text)
      if pending_list then return pending_list end
      local provisional = current_provisional_topology(view, line)
      local code
      if provisional and provisional.revision == view.doc.text_revision then
        code = provisional.fenced[line] == true
      else
        code = owner.fence_service and owner.fence_service:contains_line(line)
      end
      return current_source_render(view, line, nil, text, code == true)
    end
    record_raw_fallback(view, line, "semantic-unavailable")
    return { raw_passthrough = true }
  end
  local in_comment = line_in_semantic_comment(view, line)
  local fenced
  if not in_comment then
    if generation_context then
      fenced = generation_context.fenced ~= false and generation_context.fenced or nil
    else
      fenced = fenced_code_for_line(view, line)
    end
  end
  if fenced then
    local text = (view.doc.lines[line] or ""):gsub("\n$", "")
    local delimiter_kind = fenced_code_delimiter_kind(view, fenced, line)
    if delimiter_kind then
      if not fenced_code_is_active(view, fenced) then
        return {
          source_text = text,
          metric_height = view:get_line_height(),
          semantic_generation = select(2, semantic_line(view, line)),
          fragments = {
            {
              source_col1 = 1, source_col2 = #text + 1,
              hidden = true,
              semantic_id = fenced.id .. ":" .. delimiter_kind,
            },
          },
        }
      end
      return { raw_passthrough = true }
    end
    return fenced_code_content_render_line(view, line, text, fenced)
  end
  local table_node = table_for_line(view, line)
  if not in_comment and not table_node and line_in_raw_block(view, line) then
    return { raw_passthrough = true }
  end

  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local reveal_units = reveal_units_for_line(view, line)
  local setext_marker = semantic_setext_marker_for_line(view, text, line)
  if setext_marker then
    if reveal_unit_matches(reveal_units, setext_marker.id, 1, #text + 1) then
      return prose_render_line(view, text, { fragments = {} })
    end
    return prose_render_line(view, text, {
      source_text = text,
      semantic_id = setext_marker.id .. ":setext-marker",
      fragments = { { source_col1 = 1, source_col2 = #text + 1, hidden = true } },
    })
  end
  local heading = semantic_heading_for_line(view, text, line)
  if heading then return heading_render_line(view, text, heading, reveal_units) end

  local interactive_table = config.markdown_live_interactive_tables == true
  if table_node and not interactive_table then return { raw_passthrough = true } end
  if table_node and interactive_table then
    local rendered = interactive_table_render_line(view, table_node, line, false)
    if rendered then return rendered end
  end

  local image_span = image_only_span(view, text, line)
  if image_span then
    local image_revealed = reveal_unit_matches(
      reveal_units, image_span.semantic_id, image_span.col1, image_span.col2
    )
    local render_line = image_only_render_line(view, text, line, image_span, image_revealed)
    if render_line then
      for _, fragment in ipairs(render_line.fragments or {}) do
        if fragment.image_anchor then
          decorate_link_fragment(view, line, image_span, fragment)
        end
      end
      return prose_render_line(view, text, render_line)
    end
  end

  local fragments = inline_fragments(text, line, view, reveal_units)
  if #fragments > 0 then
    local _, semantic_generation = semantic_line(view, line)
    local render_line = layout_inline_image_rows(view, text, prose_render_line(view, text, {
      source_text = text,
      semantic_generation = semantic_generation,
      fragments = fragments,
    }))
    return apply_task_completion_presentation(view, text, line, render_line)
  end
  return prose_render_line(view, text, { fragments = {} })
end

function provider:render_line(view, line, context)
  local render_line = build_render_line(view, line, context)
  if not render_line or render_line.raw_passthrough then return render_line end

  local revision = view.doc.text_revision or 0
  local semantic = render_semantic_model(view, line)
  local pending = pending_render(view, line)
  local provenance
  if current_semantic_model(view) then
    provenance = "current"
  elseif pending and pending.render_line == render_line then
    provenance = pending.provenance
      or render_line.markdown_pending_provenance
      or "retained"
  elseif semantic then
    provenance = "retained"
  elseif render_line.markdown_pending_provenance then
    provenance = render_line.markdown_pending_provenance
  else
    provenance = "unavailable"
  end
  render_line.markdown_provenance = provenance
  render_line.markdown_document_revision = revision
  local snapshot = semantic or markdown_model.peek(view.doc)
  render_line.markdown_semantic_revision = snapshot and snapshot.published_revision or nil

  if provenance == "unavailable" then
    local owner = view.__markdown_live_owner
    local diagnostic = owner and owner.unavailable_projection_record
    if owner and (not diagnostic or diagnostic.revision ~= revision) then
      owner.unavailable_projection_record = {
        revision = revision,
        first_line = line,
        count = 1,
      }
      core.log_quiet(
        "Markdown Live Preview unavailable projection revision=%d line=%d semantic_revision=%s",
        revision, line, tostring(render_line.markdown_semantic_revision)
      )
    elseif diagnostic then
      diagnostic.count = diagnostic.count + 1
    end
  end

  local source = (view.doc.lines[line] or ""):gsub("\n$", "")
  if render_line.source_text ~= source then
    core.log_quiet(
      "Markdown Live Preview rejected mismatched render provenance=%s line=%d document_revision=%d semantic_revision=%s",
      provenance, line, revision,
      tostring(render_line.markdown_semantic_revision)
    )
    local owner = view.__markdown_live_owner
    local topology = current_provisional_topology(view, line)
    local code
    if topology and topology.revision == revision then
      code = topology.fenced[line] == true
    elseif owner and owner.fence_service then
      code = owner.fence_service:contains_line(line)
    end
    local safe = current_source_render(view, line, nil, source, code == true)
    safe.markdown_provenance = "unavailable"
    safe.markdown_document_revision = revision
    safe.markdown_semantic_revision = render_line.markdown_semantic_revision
    return safe
  end
  return render_line
end

function live.image_at_position(view, x, y)
  if not (view and view.__markdown_live_attached and view.get_render_widget_at_position) then return nil end
  local hit = view:get_render_widget_at_position(x, y)
  if not (hit and hit.fragment and hit.fragment.image_path) then return nil end
  hit.path = hit.fragment.image_path
  return hit
end

local owner_serial = 0

local function apply_source_mode(view, enabled, reason)
  local owner = view and view.__markdown_live_owner
  if not owner then return false end
  enabled = enabled == true
  if owner.source_mode == enabled then return false end
  owner.source_mode = enabled
  view:invalidate_line_render(PROVIDER_ID)
  view:invalidate_visual_metrics(PROVIDER_ID)
  core.redraw = true
  core.log_quiet(
    "Markdown Live Preview switched %s for %s: %s",
    enabled and "to Source Mode" or "to Live Preview",
    view.doc:get_name(), tostring(reason or "request")
  )
  return true
end

local function prune_image_references(view, line1, line2)
  for key, record in pairs(view and view.__markdown_live_image_cache or {}) do
    for reference_id, line in pairs(record.consumers or {}) do
      if not line1 or (line >= line1 and line <= line2) then
        record.consumers[reference_id] = nil
        if view.__markdown_live_image_references then
          view.__markdown_live_image_references[reference_id] = nil
        end
      end
    end
    if not next(record.consumers or {}) then
      images.unsubscribe(record.entry, view)
      view.__markdown_live_image_cache[key] = nil
    end
  end
end

local function clear_image_cache(view)
  for _, record in pairs(view and view.__markdown_live_image_cache or {}) do
    if record.entry then images.unsubscribe(record.entry, view) end
  end
  if view then
    view.__markdown_live_image_cache = nil
    view.__markdown_live_image_references = nil
  end
end

local function invalidate_metadata_caches(view, event)
  if not view then return end
  if not event or event.filename_changed or event.syntax_changed then
    clear_image_cache(view)
  end
  if view.invalidate_line_render then view:invalidate_line_render(PROVIDER_ID) end
  if view.invalidate_visual_metrics then view:invalidate_visual_metrics(PROVIDER_ID) end
  core.redraw = true
end

local function ensure_owner(view)
  if not (view and view.extends and view:extends(DocView) and view.doc) then return false end
  local owner = view.__markdown_live_owner
  if owner and owner.doc == view.doc then return true end
  if owner then view:remove_owned_feature(PROVIDER_ID, "document-replaced") end
  owner_serial = owner_serial + 1
  owner = {
    doc = view.doc,
    listener_id = "markdown-live-render:" .. tostring(owner_serial),
    get_state = function(self)
      return self.source_mode and { source_mode = true } or nil
    end,
    set_state = function(_, owner_view, state)
      apply_source_mode(owner_view, state and state.source_mode == true, "workspace-restore")
    end,
    on_release = function(self, owner_view, reason)
      if self.doc and self.doc.remove_metadata_listener then
        self.doc:remove_metadata_listener(self.listener_id)
      end
      if self.doc and self.doc.remove_text_change_listener then
        self.doc:remove_text_change_listener(self.text_listener_id)
      end
      live.detach(owner_view)
      if owner_view.__markdown_live_owner == self then owner_view.__markdown_live_owner = nil end
      core.log_quiet(
        "Markdown Live Preview released lifecycle ownership: %s", reason or "release"
      )
    end,
  }
  view.__markdown_live_owner = owner
  owner.text_listener_id = owner.listener_id .. ":pre-edit"
  view:add_owned_feature(PROVIDER_ID, owner)
  if owner.doc.add_text_change_listener then
    owner.doc:add_text_change_listener(owner.text_listener_id, {
      before_change = function(_, change)
        if view.__markdown_live_owner == owner and view.__markdown_live_attached then
          capture_pre_edit_renders(view, change)
        end
      end,
    })
  end
  if owner.doc.add_metadata_listener then
    owner.doc:add_metadata_listener(owner.listener_id, function(_, event)
      if view.__markdown_live_owner ~= owner then return end
      if event and event.kind == "close" then
        live.release(view, "doc-close")
      else
        invalidate_metadata_caches(view, event)
        live.refresh_view(view)
      end
    end)
  end
  core.log_quiet("Markdown Live Preview now owns lifecycle for %s", owner.doc:get_name())
  return true
end

local function invalidate_semantic_publication(view, instance, reason)
  local perf = active_perf()
  local publication_started = system.get_time()
  local reset_started = system.get_time()
  local fence_reconcile_ms = 0
  perf_frame_add("markdown_live_semantic_publications", 1)
  local previous_table_cache = view.__markdown_live_table_layout_cache
  view.__markdown_live_semantic_line_cache = nil
  view.__markdown_live_reference_prepare_pending = nil
  local owner = view.__markdown_live_owner
  local pending_line = owner and owner.semantic_pending_line
  local pending_wrap_line = owner and owner.semantic_pending_wrap_line
  if owner then
    local raw = owner.raw_fallback_record
    if raw and raw.revision == view.doc.text_revision and raw.count > 0 then
      core.log_quiet(
        "Markdown Live Preview publication revision=%d generation=%d recovered_raw_lines=%d range=%d-%d pending_from=%s pending_wrap_from=%s",
        view.doc.text_revision, instance.generation, raw.count, raw.line1, raw.line2,
        tostring(pending_line), tostring(pending_wrap_line)
      )
    end
    owner.raw_fallback_record = nil
    owner.unavailable_projection_record = nil
    owner.provisional_topology = nil
    if owner.fence_service then
      local reconcile_started = system.get_time()
      owner.fence_service:reconcile(instance)
      fence_reconcile_ms = elapsed_ms(reconcile_started)
    end
    owner.pending_lines = nil
    owner.pending_metric_state = nil
    owner.pending_context_revision = nil
    owner.pending_context_line1 = nil
    owner.pending_context_line2 = nil
    owner.pending_visible_line1 = nil
    owner.pending_visible_line2 = nil
    owner.published_line_heights = {}
  end
  if owner and reason ~= "pending" then
    owner.semantic_pending_line = nil
    owner.semantic_pending_wrap_line = nil
    if pending_line then
      owner.semantic_adoption_line = pending_line
      owner.semantic_adoption_generation = instance.generation
    end
  end
  local reset_ms = math.max(0, elapsed_ms(reset_started) - fence_reconcile_ms)
  local range_expand_started = system.get_time()
  local ranges
  if reason == "published" and pending_wrap_line then
    ranges = { { line1 = pending_wrap_line, line2 = #view.doc.lines } }
  elseif reason == "published" then
    ranges = instance.changed_ranges
  end
  if ranges and #ranges > 0 then
    local expanded = {}
    for _, range in ipairs(ranges) do
      local line1 = range.line1 or 1
      local line2 = range.line2 or line1
      for _, layout in pairs(previous_table_cache and previous_table_cache.layouts or {}) do
        if layout and line2 >= layout.line1 and line1 <= layout.line2 then
          line1, line2 = math.min(line1, layout.line1), math.max(line2, layout.line2)
        end
      end
      local nodes = instance:nodes_for_lines(line1, line2, { limit = 4096 })
      for _, node in ipairs(nodes or {}) do
        if node.type == "table" then
          local table_line2 = node.source.line2
          if node.source.col2 == 1 and table_line2 > node.source.line1 then
            table_line2 = table_line2 - 1
          end
          line1 = math.min(line1, node.source.line1)
          line2 = math.max(line2, table_line2)
        end
      end
      expanded[#expanded + 1] = { line1 = line1, line2 = line2 }
    end
    ranges = expanded
  end
  local publication_lines = 0
  for _, range in ipairs(ranges or {}) do
    publication_lines = publication_lines
      + math.max(0, (range.line2 or range.line1 or 1) - (range.line1 or 1) + 1)
  end
  perf_frame_add("markdown_live_semantic_publication_ranges", #(ranges or {}))
  perf_frame_add("markdown_live_semantic_publication_lines", publication_lines)
  perf_detail(string.format(
    "markdown_live_semantic_publication:reason=%s:ranges=%d:lines=%d",
    tostring(reason), #(ranges or {}), publication_lines
  ), 1)
  local range_expand_ms = elapsed_ms(range_expand_started)
  view.__markdown_live_table_layout_cache = nil
  local prune_images_ms, line_invalidate_ms, metric_invalidate_ms = 0, 0, 0
  local global_invalidation = not (ranges and #ranges > 0)
  local deferred_wrapped_invalidation = ranges and #ranges > 0
    and view.wrapped_settings ~= nil
    and publication_lines > 128
  if ranges and #ranges > 0 and not deferred_wrapped_invalidation then
    for _, range in ipairs(ranges) do
      local line1 = common.clamp(range.line1 or 1, 1, #view.doc.lines)
      local line2 = common.clamp(range.line2 or line1, line1, #view.doc.lines)
      local phase_started = system.get_time()
      prune_image_references(view, line1, line2)
      prune_images_ms = prune_images_ms + elapsed_ms(phase_started)
      phase_started = system.get_time()
      view:invalidate_line_render(PROVIDER_ID, line1, line2)
      line_invalidate_ms = line_invalidate_ms + elapsed_ms(phase_started)
      phase_started = system.get_time()
      view:invalidate_visual_metrics(PROVIDER_ID, line1, line2)
      metric_invalidate_ms = metric_invalidate_ms + elapsed_ms(phase_started)
    end
  else
    if global_invalidation then
      perf_frame_add("markdown_live_semantic_global_invalidations", 1)
    else
      perf_frame_add("markdown_live_semantic_deferred_wrap_invalidations", 1)
      core.log_quiet(
        "Markdown Live Preview deferred wrapped publication layout: ranges=%d lines=%d",
        #ranges, publication_lines
      )
    end
    local phase_started = system.get_time()
    prune_image_references(view)
    prune_images_ms = elapsed_ms(phase_started)
    phase_started = system.get_time()
    view:invalidate_line_render(PROVIDER_ID, nil, nil, {
      defer_wrapped_reconstruction = true,
      on_wrapped_reconstructed = function()
        if view.__markdown_live_attached then
          view:invalidate_visual_metrics(PROVIDER_ID)
        end
      end,
    })
    line_invalidate_ms = elapsed_ms(phase_started)
    phase_started = system.get_time()
    view:invalidate_visual_metrics(PROVIDER_ID)
    metric_invalidate_ms = elapsed_ms(phase_started)
  end
  local total_ms = elapsed_ms(publication_started)
  if total_ms >= 8 then
    core.log_quiet(
      "Markdown Live Preview slow publication: total=%.1fms reset=%.1fms fence=%.1fms expand=%.1fms render_invalidate=%.1fms metric_invalidate=%.1fms ranges=%d lines=%d deferred_wrap=%s",
      total_ms, reset_ms, fence_reconcile_ms, range_expand_ms,
      line_invalidate_ms, metric_invalidate_ms, #(ranges or {}),
      publication_lines, tostring(deferred_wrapped_invalidation)
    )
  end
  if perf then
    perf.frame_add("markdown_live_publication_listener_ms", total_ms)
    perf.frame_add("markdown_live_publication_reset_ms", reset_ms)
    perf.frame_add("markdown_live_publication_fence_reconcile_ms", fence_reconcile_ms)
    perf.frame_add("markdown_live_publication_range_expand_ms", range_expand_ms)
    perf.frame_add("markdown_live_publication_prune_images_ms", prune_images_ms)
    perf.frame_add("markdown_live_publication_line_invalidate_ms", line_invalidate_ms)
    perf.frame_add("markdown_live_publication_metric_invalidate_ms", metric_invalidate_ms)
    local root = core.root_panel and core.root_panel.root_node
    local node = root and root.get_node_for_view and root:get_node_for_view(view)
    perf.record_markdown_view_publication({
      time = system.get_time(),
      elapsed_ms = total_ms,
      path = view.doc.abs_filename or view.doc.filename or view.doc:get_name(),
      bytes = instance.published_byte_len or 0,
      lines = instance.published_line_count or #view.doc.lines,
      reason = reason,
      generation = instance.generation,
      wrapped = view.wrapped_settings ~= nil,
      active = core.active_view == view,
      visible = not node or node.active_view == view,
      view_width = view.size and view.size.x or 0,
      range_count = #(ranges or {}),
      publication_lines = publication_lines,
      global_invalidation = global_invalidation,
      reset_ms = reset_ms,
      fence_reconcile_ms = fence_reconcile_ms,
      range_expand_ms = range_expand_ms,
      prune_images_ms = prune_images_ms,
      line_invalidate_ms = line_invalidate_ms,
      metric_invalidate_ms = metric_invalidate_ms,
    })
  end
  core.redraw = true
end

local function bind_fence_service(view, instance)
  local owner = view.__markdown_live_owner
  if not owner then return end
  local service = fence_highlight.get(view.doc)
  if owner.fence_service and owner.fence_service ~= service then
    owner.fence_service:remove_listener(owner.fence_listener_id)
  end
  owner.fence_service = service
  owner.fence_listener_id = owner.listener_id .. ":fences"
  service:reconcile(instance)
  service:add_listener(owner.fence_listener_id, function(_, line1, line2)
    if view.__markdown_live_owner ~= owner or not view.__markdown_live_attached then return end
    line1 = common.clamp(line1 or 1, 1, #view.doc.lines)
    line2 = common.clamp(line2 or line1, line1, #view.doc.lines)
    owner.fence_invalidation_line1 = math.min(
      owner.fence_invalidation_line1 or line1, line1
    )
    owner.fence_invalidation_line2 = math.max(
      owner.fence_invalidation_line2 or line2, line2
    )
    owner.fence_invalidation_count = (owner.fence_invalidation_count or 0) + 1
    owner.fence_invalidation_serial = (owner.fence_invalidation_serial or 0) + 1
    local serial = owner.fence_invalidation_serial
    core.add_thread(function()
      coroutine.yield(0.05)
      if view.__markdown_live_owner ~= owner or not view.__markdown_live_attached then return end
      if owner.fence_invalidation_serial ~= serial then return end
      local pending_line1 = owner.fence_invalidation_line1
      local pending_line2 = owner.fence_invalidation_line2
      local count = owner.fence_invalidation_count or 0
      owner.fence_invalidation_line1 = nil
      owner.fence_invalidation_line2 = nil
      owner.fence_invalidation_count = nil
      if not pending_line1 then return end
      view:invalidate_line_render(PROVIDER_ID, pending_line1, pending_line2)
      view:invalidate_visual_metrics(PROVIDER_ID, pending_line1, pending_line2)
      core.log_quiet(
        "Markdown Live Preview coalesced %d fence refresh(es) into lines %d-%d",
        count, pending_line1, pending_line2
      )
      core.redraw = true
    end)
  end)
end

local function unbind_fence_service(view)
  local owner = view.__markdown_live_owner
  if not (owner and owner.fence_service) then return end
  owner.fence_service:remove_listener(owner.fence_listener_id)
  owner.fence_service = nil
  owner.fence_listener_id = nil
  owner.fence_invalidation_line1 = nil
  owner.fence_invalidation_line2 = nil
  owner.fence_invalidation_count = nil
  owner.fence_invalidation_serial = (owner.fence_invalidation_serial or 0) + 1
end

local function bind_semantic_model(view)
  local owner = view.__markdown_live_owner
  if not owner then return end
  local instance = markdown_model.get(view.doc)
  if not instance then return end
  local listener_id = owner.listener_id .. ":semantic"
  if owner.semantic_model and owner.semantic_model ~= instance then
    owner.semantic_model:remove_listener(listener_id)
  end
  owner.semantic_model = instance
  owner.semantic_listener_id = listener_id
  bind_fence_service(view, instance)
  if instance.status == "pending" then
    -- This view did not necessarily observe the edit that made the shared model pending.
    owner.semantic_pending_line = 1
  end
  instance:add_listener(listener_id, function(published, reason)
    if view.__markdown_live_owner ~= owner or not view.__markdown_live_attached then return end
    if reason == "pending" then return end
    invalidate_semantic_publication(view, published, reason)
  end)
end

local function unbind_semantic_model(view)
  local owner = view.__markdown_live_owner
  if not (owner and owner.semantic_model) then return end
  owner.semantic_model:remove_listener(owner.semantic_listener_id)
  owner.semantic_model = nil
  owner.semantic_listener_id = nil
  view.__markdown_live_semantic_line_cache = nil
end

local function bind_link_index(view)
  local owner = view.__markdown_live_owner
  local path = view.doc.abs_filename or view.doc.filename
  if not (owner and path) then return end
  local index = vault_index.index_for_path(path)
  local listener_id = owner.listener_id .. ":links"
  if owner.link_index == index and owner.link_listener_id == listener_id then return end
  if owner.link_index and owner.link_index ~= index then
    owner.link_index:remove_listener(listener_id)
    owner.link_index:release(listener_id)
  end
  owner.link_resolution_pending = nil
  owner.link_index = index
  owner.link_listener_id = listener_id
  index:acquire(listener_id)
  index:add_listener(listener_id, function(_, reason, detail)
    if view.__markdown_live_owner ~= owner or not view.__markdown_live_attached then return end
    if reason == "indexing" then
      -- Starting a rebuild does not change any resolved target. Invalidating
      -- here caused wrapped layout to restart once for every dependent range,
      -- only to repeat the work when the new snapshot was published.
      core.log_quiet("Markdown Live Preview deferred link refresh until vault publication")
      return
    end
    if reason == "document-updated" and detail == view.doc
      and owner.link_targets_changed_revision ~= view.doc.text_revision
    then
      core.log_quiet(
        "Markdown Live Preview skipped self-overlay link refresh for ordinary edit revision=%d",
        view.doc.text_revision
      )
      return
    end
    local had_pending_resolution = owner.link_resolution_pending == true
    if reason == "ready" then owner.link_resolution_pending = nil end
    if reason == "ready" and detail and (detail.notes_rebuilt or 0) == 0
      and not had_pending_resolution
    then
      core.log_quiet(
        "Markdown Live Preview skipped unchanged vault snapshot link refresh"
      )
      return
    end
    local refresh_started = system.get_time()
    perf_frame_add("markdown_live_link_index_invalidations", 1)
    perf_detail(
      "markdown_live_link_index_invalidation:" .. tostring(reason or "unknown"), 1
    )
    -- Vault changes can alter link resolution, embed previews, and image
    -- targets, but ordinary prose and code rows do not depend on the vault.
    -- Invalidating the entire Document here made every heading keystroke
    -- synchronously reconstruct wrapping for large notes.
    local ranges = {}
    local line1, line2
    local function flush()
      if line1 then ranges[#ranges + 1] = { line1 = line1, line2 = line2 } end
      line1, line2 = nil, nil
    end
    for line, source in ipairs(view.doc.lines or {}) do
      local dependent = source:find("[", 1, true) ~= nil
        or source:find("](", 1, true) ~= nil
        or source:find("<http", 1, true) ~= nil
      if dependent then
        if line2 and line == line2 + 1 then
          line2 = line
        else
          flush()
          line1, line2 = line, line
        end
      else
        flush()
      end
    end
    flush()
    for _, range in ipairs(ranges) do
      prune_image_references(view, range.line1, range.line2)
    end
    if #ranges > 0 then
      if view.wrapped_settings then
        -- Link ranges commonly span most of a note. Rebuilding all affected
        -- wrap rows synchronously blocked the worker-result callback for
        -- 40-65 ms in ordinary editing logs.
        view:invalidate_line_render(PROVIDER_ID, nil, nil, {
          defer_wrapped_reconstruction = true,
          on_wrapped_reconstructed = function()
            if view.__markdown_live_attached then
              view:invalidate_visual_metrics(PROVIDER_ID)
            end
          end,
        })
      else
        local refresh_line1 = ranges[1].line1
        local refresh_line2 = ranges[#ranges].line2
        view:invalidate_line_render(PROVIDER_ID, refresh_line1, refresh_line2)
        view:invalidate_visual_metrics(PROVIDER_ID, refresh_line1, refresh_line2)
      end
    end
    core.log_quiet(
      "Markdown Live Preview refreshed %d link-dependent range(s) after vault %s in %.1fms",
      #ranges, tostring(reason or "change"),
      (system.get_time() - refresh_started) * 1000
    )
    core.redraw = true
  end)
  index:track_doc(view.doc)
  index:ensure("live-preview")
end

local function unbind_link_index(view)
  local owner = view.__markdown_live_owner
  if not (owner and owner.link_index) then return end
  owner.link_index:remove_listener(owner.link_listener_id)
  owner.link_index:release(owner.link_listener_id)
  owner.link_index = nil
  owner.link_listener_id = nil
end

local function invalidate_selection_lines(view, new_state, old_state)
  local lines = {}
  local states = { old_state, new_state }
  local table_cells_by_state = { {}, {} }
  local touched_by_state = { {}, {} }
  local fenced_by_state = { {}, {} }
  local reveal_candidates = {}
  local reveal_units_by_state = { {}, {} }
  local reveal_units_known = { {}, {} }
  local function state_reveal_units(state_index, line)
    if not reveal_units_known[state_index][line] then
      reveal_units_by_state[state_index][line] = reveal_units_for_line(
        view, line, states[state_index]
      )
      reveal_units_known[state_index][line] = true
    end
    return reveal_units_by_state[state_index][line]
  end
  local function add_reveal_candidates(state_index, line)
    reveal_candidates[line] = true
    for _, unit in ipairs(state_reveal_units(state_index, line)) do
      if unit.line1 and unit.line2 then
        for unit_line = unit.line1, unit.line2 do
          reveal_candidates[unit_line] = true
        end
      end
    end
  end
  local function same_reveal_unit(left, right)
    return left.type == right.type
      and left.id == right.id
      and left.col1 == right.col1
      and left.col2 == right.col2
      and left.line1 == right.line1
      and left.line2 == right.line2
      and (left.whole_line == true) == (right.whole_line == true)
  end
  local function same_reveal_units(left, right)
    if #left ~= #right then return false end
    local matched = {}
    for _, left_unit in ipairs(left) do
      local found
      for index, right_unit in ipairs(right) do
        if not matched[index] and same_reveal_unit(left_unit, right_unit) then
          matched[index] = true
          found = true
          break
        end
      end
      if not found then return false end
    end
    return true
  end
  for state_index = 1, 2 do
    local state = states[state_index]
    local touched = touched_by_state[state_index]
    for i = 1, #(state and state.selections or {}), 4 do
      local line1 = state.selections[i]
      local col1 = state.selections[i + 1]
      local line2 = state.selections[i + 2] or line1
      local col2 = state.selections[i + 3] or col1
      if line1 then
        for _, endpoint in ipairs({ { line1, col1 }, { line2, col2 } }) do
          local endpoint_line, endpoint_col = endpoint[1], endpoint[2]
          local render = view:get_line_render(endpoint_line)
          if render and render.table_row then
            for _, fragment in ipairs(render.fragments or {}) do
              if fragment.table_cell
              and endpoint_col >= (fragment.source_col1 or 1)
              and endpoint_col <= (fragment.source_col2 or fragment.source_col1 or 1)
              then
                local node = render.markdown_table_node
                table_cells_by_state[state_index][table.concat({
                  node and node.source and node.source.line1 or endpoint_line,
                  endpoint_line, fragment.table_column,
                }, ":")] = endpoint_line
                break
              end
            end
          end
        end
        for line = math.min(line1, line2), math.max(line1, line2) do
          local line_length = source_line_length(view.doc.lines[line] or "")
          if not fenced_code_for_line(view, line)
            and selection_touches_line(line, line_length, line1, col1, line2, col2)
          then
            touched[line] = true
          end
        end
        for _, endpoint in ipairs({ line1, line2 }) do
          local fenced = fenced_code_for_line(view, endpoint)
          if fenced then
            fenced_by_state[state_index][fenced.id] = fenced
          else
            add_reveal_candidates(state_index, endpoint)
          end
        end
        local selection_line1, selection_line2 = math.min(line1, line2), math.max(line1, line2)
        local instance = render_semantic_model(view, selection_line1)
        local nodes = instance and instance:nodes_for_lines(
          selection_line1, selection_line2,
          { limit = 4096, allow_pending_result = instance.status == "pending" }
        ) or {}
        for _, node in ipairs(nodes or {}) do
          if node.type == "code_fenced" then
            local effective_line2 = node.source.line2
            if node.source.col2 == 1 and effective_line2 > node.source.line1 then
              effective_line2 = effective_line2 - 1
            end
            if selection_line1 <= effective_line2
              and selection_line2 >= node.source.line1
            then
              node.effective_line2 = effective_line2
              fenced_by_state[state_index][node.id or tostring(node)] = node
            end
          end
        end
      end
    end
  end
  local changed_touch_lines = {}
  for line in pairs(touched_by_state[1]) do
    if not touched_by_state[2][line] then changed_touch_lines[line] = true end
  end
  for line in pairs(touched_by_state[2]) do
    if not touched_by_state[1][line] then changed_touch_lines[line] = true end
  end
  for line in pairs(changed_touch_lines) do
    add_reveal_candidates(1, line)
    add_reveal_candidates(2, line)
  end
  for state_index = 1, 2 do
    local other = fenced_by_state[3 - state_index]
    for id, fenced in pairs(fenced_by_state[state_index]) do
      if not other[id] then
        for line = fenced.source.line1, fenced.effective_line2 do lines[line] = true end
      end
    end
  end
  for line in pairs(reveal_candidates) do
    if not same_reveal_units(
      state_reveal_units(1, line), state_reveal_units(2, line)
    ) then
      lines[line] = true
    end
  end
  for state_index = 1, 2 do
    local other = table_cells_by_state[3 - state_index]
    for key, line in pairs(table_cells_by_state[state_index]) do
      if not other[key] then lines[line] = true end
    end
  end
  local ordered = {}
  for line in pairs(lines) do ordered[#ordered + 1] = line end
  table.sort(ordered)
  local line1, line2
  local function invalidate_range()
    if not line1 then return end
    local preserves_metrics = true
    for line = line1, line2 do
      local render = view:get_line_render(line)
      if not (render and render.selection_preserves_metrics) then
        preserves_metrics = false
        break
      end
    end
    view:invalidate_line_render(PROVIDER_ID, line1, line2)
    if not preserves_metrics then
      view:invalidate_visual_metrics(PROVIDER_ID, line1, line2)
    end
  end
  for _, line in ipairs(ordered) do
    if not line1 then
      line1, line2 = line, line
    elseif line == line2 + 1 then
      line2 = line
    else
      invalidate_range()
      line1, line2 = line, line
    end
  end
  invalidate_range()
end

function provider:on_selection_interaction_end(view, new_state, old_state)
  invalidate_selection_lines(view, new_state, old_state)
  return true
end

function live.attach(view)
  if not (view and view.extends and view:extends(DocView)) then return false end
  if view.__markdown_live_attached then return false end
  view:add_visual_metric_provider(PROVIDER_ID, provider)
  view:add_decoration_provider(PROVIDER_ID, decoration_provider)
  -- Install gutter policy before the render provider reconstructs soft-wrap
  -- breaks so wrapping immediately uses the Live Preview content width.
  view:add_line_render_provider(PROVIDER_ID, provider)
  view:add_clipboard_paste_provider(PROVIDER_ID, clipboard_paste_provider)
  view:add_file_drop_provider(PROVIDER_ID, file_drop_provider)
  view:add_poi_provider(PROVIDER_ID, poi_provider)
  view:add_selection_listener(PROVIDER_ID, function(owner, new_state, old_state)
    -- During mouse drag and IME interactions the renderer deliberately uses
    -- the frozen selection captured at interaction start. Rebuilding rows for
    -- every transient selection is therefore both expensive and ineffective;
    -- the interaction-end hook invalidates the final old/new ranges once.
    if owner.__line_render_interaction_state then return end
    invalidate_selection_lines(owner, new_state, old_state)
  end)
  view.__markdown_live_attached = true
  bind_semantic_model(view)
  bind_link_index(view)
  link_completion.ensure_provider()
  core.log_quiet("Markdown Live Preview attached to %s", view.doc and view.doc:get_name() or tostring(view))
  return true
end

function live.detach(view)
  if not (view and view.__markdown_live_attached) then return false end
  unbind_link_index(view)
  unbind_fence_service(view)
  unbind_semantic_model(view)
  clear_image_cache(view)
  view:remove_visual_metric_provider(PROVIDER_ID)
  -- Restore ordinary gutter policy before removing rendered wrapping so the
  -- reconstruction returns directly to the Source/standard Editor width.
  view:remove_decoration_provider(PROVIDER_ID)
  view:remove_line_render_provider(PROVIDER_ID)
  view:remove_clipboard_paste_provider(PROVIDER_ID)
  view:remove_file_drop_provider(PROVIDER_ID)
  view:remove_poi_provider(PROVIDER_ID)
  view:remove_selection_listener(PROVIDER_ID)
  view.__markdown_live_attached = nil
  core.log_quiet("Markdown Live Preview detached from %s", view.doc and view.doc:get_name() or tostring(view))
  return true
end

function live.release(view, reason)
  if not (view and view.__markdown_live_owner) then return false end
  return view:remove_owned_feature(PROVIDER_ID, reason or "release")
end

function live.link_at_caret(view)
  if not (view and view.doc and current_semantic_model(view)) then return nil end
  local state = current_selection_state(view)
  local line = state and state.selections and state.selections[1]
  local col = state and state.selections and state.selections[2]
  if not (line and col) then return nil end
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local best, best_size
  for _, span in ipairs(semantic_link_spans(view, text, line)) do
    if col >= span.col1 and col < span.col2 then
      local size = span.col2 - span.col1
      if not best_size or size < best_size then best, best_size = span, size end
    end
  end
  if not best then return nil end
  return { line = line, col1 = best.col1, col2 = best.col2, link = best.link,
    resolution = resolve_live_link(view, best.link) }
end

local function record_navigation_origin()
  local ok, history = pcall(require, "plugins.navigation_history")
  if ok and history.record_current_place then history.record_current_place("markdown-live-link") end
end

local function open_link_resolution(resolution)
  if resolution.status == "external" then
    record_navigation_origin()
    return common.open_in_system(resolution.path)
  end
  if resolution.status ~= "resolved" then return false end
  local info = resolution.path and system.get_file_info(resolution.path)
  if (not info or info.type ~= "file") and not (resolution.entry and resolution.entry.doc) then
    core.log_quiet("Markdown link target disappeared before activation: %s", tostring(resolution.path))
    return false
  end
  record_navigation_origin()
  if resolution.kind == "attachment" then
    return common.open_in_system(resolution.path)
  end
  local target_view = core.open_file(resolution.path)
  if target_view and resolution.line and target_view.set_selection_state then
    target_view:set_selection_state({
      selections = { resolution.line, 1, resolution.line, 1 },
      last_selection = 1,
    })
    target_view:scroll_to_line(resolution.line, true, true)
  end
  return target_view ~= nil
end

local function open_ambiguous_picker(view, link, resolution)
  local index = view.__markdown_live_owner and view.__markdown_live_owner.link_index
  if not (index and core.command_view) then return false end
  local suggestions = {}
  for _, entry in ipairs(resolution.candidates or {}) do
    suggestions[#suggestions + 1] = { text = entry.rel_path, entry = entry }
  end
  table.sort(suggestions, function(a, b) return a.text < b.text end)
  local function exact_suggestion(text)
    for _, suggestion in ipairs(suggestions) do
      if suggestion.text == text then return suggestion end
    end
  end
  core.command_view:enter("Open Markdown Link", {
    text = "",
    suggest = function(text)
      local needle = tostring(text or ""):lower()
      if needle == "" then return suggestions end
      local filtered = {}
      for _, suggestion in ipairs(suggestions) do
        if suggestion.text:lower():find(needle, 1, true) then filtered[#filtered + 1] = suggestion end
      end
      return filtered
    end,
    validate = function(text, suggestion)
      return (suggestion and suggestion.entry ~= nil) or exact_suggestion(text) ~= nil
    end,
    submit = function(text, suggestion)
      suggestion = suggestion and suggestion.entry and suggestion or exact_suggestion(text)
      if not suggestion then return end
      local selected = index:resolve_entry_result(suggestion.entry, link, link.raw_target or link.path)
      open_link_resolution(selected)
    end,
  })
  return true
end

function live.open_link(view, opts)
  opts = opts or live.link_at_caret(view)
  if not opts then return false, "no link at caret" end
  local link = opts.link
  local resolution = opts.resolution or resolve_live_link(view, link)
  if resolution.status == "ambiguous" then
    return open_ambiguous_picker(view, link, resolution), resolution.status
  end
  if resolution.status ~= "resolved" and resolution.status ~= "external" then
    core.log_quiet("Markdown link not opened: status=%s target=%s", resolution.status, tostring(resolution.target))
    return false, resolution.status
  end
  return open_link_resolution(resolution), resolution.status
end

function live.allow_remote_image_once(view)
  local target = live.link_at_caret(view)
  local link = target and target.link
  if not (link and (link.kind == "image" or link.kind == "embed")
    and images.is_remote(link.path))
  then
    return false, "no remote image at caret"
  end
  local owner = view.__markdown_live_owner
  if not owner then return false, "Live Preview unavailable" end
  owner.one_shot_remote_images = owner.one_shot_remote_images or {}
  owner.one_shot_remote_images[link.path] = true
  clear_image_cache(view)
  view:invalidate_line_render(PROVIDER_ID, target.line, target.line)
  view:invalidate_visual_metrics(PROVIDER_ID, target.line, target.line)
  core.redraw = true
  core.log_quiet("Markdown remote image allowed once: %s", link.path)
  return true
end

function live.set_project_remote_image_trust(view, trusted)
  local project = view and view.doc and core.current_project(view.doc.abs_filename)
  if not project then return false, "Project unavailable" end
  local key = common.path_compare_key(common.normalize_path(project.path))
  config.markdown_live_trusted_remote_image_projects =
    config.markdown_live_trusted_remote_image_projects or {}
  config.markdown_live_trusted_remote_image_projects[key] = trusted and true or nil
  clear_image_cache(view)
  local owner = view.__markdown_live_owner
  local index = owner and owner.link_index
  if index then
    index.generation = index.generation + 1
    index:notify("remote-image-policy", trusted)
  else
    view:invalidate_line_render(PROVIDER_ID)
    view:invalidate_visual_metrics(PROVIDER_ID)
  end
  core.redraw = true
  core.log_quiet("Markdown remote image Project trust %s: %s", trusted and "enabled" or "disabled", project.path)
  return true
end

function live.remote_image_allowed(view, url)
  local project = view and view.doc and core.current_project(view.doc.abs_filename)
  return remote_image_allowed(view, url, project)
end

function live.create_link_target(view)
  local target = live.link_at_caret(view)
  if not target then return false, "no link at caret" end
  local resolution = target.resolution
  if resolution.status ~= "missing" then return false, resolution.status end
  local link_path = (target.link.path or ""):match("^[^#?]*") or ""
  if link_path == "" or common.is_absolute_path(link_path)
    or link_path:match("^[%a][%w+.-]*:")
  then
    return false, "unsupported target"
  end
  local owner = view.__markdown_live_owner
  local index = owner and owner.link_index
  if not index then return false, "index unavailable" end
  local source_relative = link_path:find("/", 1, true) ~= nil
    or link_path:find("\\", 1, true) ~= nil
    or link_path:sub(1, 1) == "."
  local path = link_path:gsub("[/\\]", PATHSEP)
  if not extension(path) then path = path .. ".md" end
  local base = source_relative and view.doc.abs_filename
    and common.dirname(view.doc.abs_filename) or index.root
  local normalized, abs = pcall(common.normalize_path, base .. PATHSEP .. path)
  if not normalized or not abs or not common.path_belongs_to(abs, index.root) then
    return false, "outside Project"
  end
  local parent = common.dirname(abs)
  local parent_info = system.get_file_info(parent)
  if not (parent_info and parent_info.type == "dir") then
    local ok, err = common.mkdirp(parent)
    if not ok then return false, err end
  end
  record_navigation_origin()
  core.open_file(abs)
  return true, abs
end

function live.is_source_mode(view)
  return view_in_source_mode(view)
end

function live.is_live_mode(view)
  return view and view.__markdown_live_attached == true
    and not view_in_source_mode(view)
end

function live.set_source_mode(view, enabled, reason)
  if not (view and view.doc and live.is_markdown_doc(view.doc)) then return false end
  ensure_owner(view)
  live.refresh_view(view)
  return apply_source_mode(view, enabled, reason or "command")
end

function live.toggle_source_mode(view, reason)
  return live.set_source_mode(view, not view_in_source_mode(view), reason or "toggle")
end

function live.refresh_view(view)
  if not (view and view.doc) then return false end
  ensure_owner(view)
  if config.markdown_live_editor and live.is_markdown_doc(view.doc) then
    if view.__markdown_live_attached then
      bind_link_index(view)
      return false
    end
    return live.attach(view)
  else
    return live.detach(view)
  end
end

local function refresh_open_views()
  local root = core.root_panel and core.root_panel.root_node
  if not (root and root.get_children) then return end
  for _, view in ipairs(root:get_children()) do
    live.refresh_view(view)
  end
end

function live.install()
  if live.__installed then return end
  live.__installed = true
  local file_context = require "core.file_context"
  local old_mark_editor_view = file_context.mark_editor_view
  file_context.mark_editor_view = function(view)
    view = old_mark_editor_view(view)
    live.refresh_view(view)
    return view
  end

  local old_set_active_view = core.set_active_view
  core.set_active_view = function(view)
    local result = old_set_active_view(view)
    live.refresh_view(view)
    return result
  end


  refresh_open_views()
end

return live
