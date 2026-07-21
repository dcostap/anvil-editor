local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local attachments = require "core.markdown.attachments"
local images = require "core.markdown.images"
local link_completion = require "core.markdown.completion"
local keymap = require "core.keymap"
local linewrapping = require "core.linewrapping"
local markdown_links = require "core.markdown.links"
local markdown_model = require "core.markdown.model"
local vault_index = require "core.markdown.vault_index"
local style = require "core.style"

local live = {}

local PROVIDER_ID = "markdown-live"
local MARKDOWN_EXTENSIONS = { md = true, markdown = true, mdown = true }
local IMAGE_EXTENSIONS = { avif = true, bmp = true, gif = true, jpeg = true, jpg = true, png = true, svg = true, webp = true }
local AUDIO_EXTENSIONS = { flac = true, mp3 = true, ogg = true, wav = true }
local VIDEO_EXTENSIONS = { mov = true, mp4 = true, webm = true }

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

semantic_line = function(view, line)
  local instance = current_semantic_model(view)
  if not instance then return nil end
  local cache = view.__markdown_live_semantic_line_cache
  if not cache or cache.generation ~= instance.generation then
    cache = { generation = instance.generation, lines = {} }
    view.__markdown_live_semantic_line_cache = cache
  end
  if cache.lines[line] == nil then
    local nodes, reason = instance:nodes_for_lines(line, line, { limit = 512 })
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
        local token = raw:match("^%S+") or raw
        return marker, node, marker.col1 + #token
      end
    end
  end
end

local function node_line_range(node, line, line_text)
  if line < node.source.line1 or line > node.source.line2 then return nil end
  return line == node.source.line1 and node.source.col1 or 1,
    line == node.source.line2 and node.source.col2 or #line_text + 1
end

local function reveal_units_for_line(view, line, state)
  state = state or current_selection_state(view)
  local selections = state and state.selections or view.doc.selections or {}
  local line_text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local units = {}
  for i = 1, #selections, 4 do
    local line1, col1 = selections[i], selections[i + 1]
    local line2, col2 = selections[i + 2], selections[i + 3]
    if line1 and line2 then
      local collapsed = line1 == line2 and col1 == col2
      if not collapsed then
        if line >= math.min(line1, line2) and line <= math.max(line1, line2) then
          units[#units + 1] = { type = "line", col1 = 1, col2 = #line_text + 1, whole_line = true }
        end
      elseif config.markdown_live_reveal_mode == "line" then
        if line == line1 then
          units[#units + 1] = { type = "line", col1 = 1, col2 = #line_text + 1, whole_line = true }
        end
      else
        local cursor_text = (view.doc.lines[line1] or ""):gsub("\n$", "")
        local best, best_size, has_localized_reveal
        for _, node in ipairs(semantic_line(view, line1) or {}) do
          if REVEAL_TYPES[node.type] then
            if node.type ~= "heading" then has_localized_reveal = true end
            local node_col1, node_col2 = node_line_range(node, line1, cursor_text)
            if node_col1 and col1 >= node_col1 and col1 < node_col2 then
              local size = (node.source.end_byte or 0) - (node.source.start_byte or 0)
              if not best_size or size < best_size then best, best_size = node, size end
            end
          end
        end
        local list_marker, list_node, list_marker_token_col2 = list_marker_for_line(view, line1)
        if list_marker and col1 >= list_marker.col1 and col1 <= list_marker_token_col2 then
          units[#units + 1] = {
            type = "list_marker", id = list_node.id,
            col1 = list_marker.col1, col2 = list_marker.col2,
            line1 = line1, line2 = line1,
          }
        elseif best and line >= best.source.line1 and line <= best.source.line2 then
          local unit_col1, unit_col2 = node_line_range(best, line, line_text)
          units[#units + 1] = {
            type = best.type, id = best.id, col1 = unit_col1, col2 = unit_col2,
            line1 = best.source.line1, line2 = best.source.line2,
          }
        elseif not best and not list_marker and not has_localized_reveal and line == line1 then
          units[#units + 1] = { type = "line", col1 = 1, col2 = #line_text + 1, whole_line = true }
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
  return markdown_live_scaled_font(view, style.markdown_live_font)
end

local function markdown_live_body_line_height(view)
  return math.floor(markdown_live_body_font(view):get_height() * config.line_height)
end

local function heading_font(view, level)
  view.__markdown_live_heading_fonts = view.__markdown_live_heading_fonts or {}
  local cache = view.__markdown_live_heading_fonts
  local font = markdown_live_scaled_font(view, style.markdown_live_bold_font)
  local size = font:get_size()
  local scale = ({ 1.65, 1.45, 1.30, 1.18, 1.08, 1.0 })[level] or 1
  local key = tostring(font) .. ":" .. tostring(size) .. ":" .. tostring(level)
  if not cache[key] then
    cache[key] = font:copy(math.max(1, math.floor(size * scale)))
  end
  return cache[key]
end

local function inline_style_font(view, span_type, base_font, base_bold)
  view.__markdown_live_inline_fonts = view.__markdown_live_inline_fonts or {}
  local cache = view.__markdown_live_inline_fonts
  local font
  if span_type == "code" then
    font = style.code_font
  elseif span_type == "strong_emphasis" or base_bold and span_type == "emphasis" then
    font = style.markdown_live_bold_italic_font
  elseif span_type == "strong" then
    font = style.markdown_live_bold_font
  elseif span_type == "emphasis" then
    font = style.markdown_live_italic_font
  else
    font = base_font or style.markdown_live_font
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
            marker_revealed = marker_revealed
              or reveal_unit_matches(reveal_units, span.semantic_id, span.col1, span.col2)
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
          font = code and inline_style_font(view, "code", opts.base_font, opts.base_bold)
            or font_type ~= "normal"
              and inline_style_font(view, font_type, opts.base_font, opts.base_bold)
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
  opts = opts or {}
  if config.markdown_live_render_images ~= true then return nil end
  local link = span.link
  if not (link and (link.kind == "image" or link.kind == "embed") and is_image_target(link.path)) then return nil end
  view.__markdown_live_image_cache = view.__markdown_live_image_cache or {}
  view.__markdown_live_image_references = view.__markdown_live_image_references or {}
  local project = core.current_project(view.doc.abs_filename)
  local owner = view.__markdown_live_owner
  local asset_opts = {
    alt = link.alias or link.alt,
    source_path = view.doc.abs_filename,
    project_root = project and project.path,
    download_remote = remote_image_allowed(view, link.path, project),
    retry_generation = owner and owner.link_index and owner.link_index.generation or 0,
  }
  local key = images.asset_key(link.path, asset_opts)
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

  local entry = images.get_asset(link.path, asset_opts)
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
    local width, height = images.scale_size(natural_w, natural_h, 320 * SCALE, link.resize, false)
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
          local image_overlay = require "core.markdown.image_overlay"
          image_overlay.open(hit.fragment.image_path)
          return true
        end,
        draw = function(_, fragment, x, y, row_height)
          local image = entry.image
          if width ~= natural_w or height ~= natural_h then
            if not entry.scaled_image or entry.scaled_width ~= width or entry.scaled_height ~= height then
              entry.scaled_image = image:scaled(width, height, "nearest")
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
  if entry.status == "loading" then
    status_text, color = "loading image", style.markdown_live_image_loading
  elseif entry.status == "remote-disabled" then
    status_text, color = "remote image blocked", style.markdown_live_image_blocked
  end
  return {
    source_col1 = span.col1,
    source_col2 = span.col2,
    text = "[" .. status_text .. ": " .. label .. "]",
    color = color,
    image_status = entry.status,
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

local function image_only_render_line(view, text, line, span, active)
  local image = image_fragment(view, span, active and { width = 0 } or nil)
  if not image then return nil end
  image.semantic_id = span.semantic_id
  if active and image.widget then
    local body_font = markdown_live_body_font(view)
    local leading_width = span.col1 > 1
      and body_font:get_width(text:sub(1, span.col1 - 1)) or 0
    image.source_col1 = #text + 1
    image.source_col2 = #text + 1
    image.draw_x_offset = leading_width - body_font:get_width(text)
    image.draw_y_offset = markdown_live_body_line_height(view) + image_vertical_padding()
    image.widget.height = image.widget.height + markdown_live_body_line_height(view)
    return {
      source_text = text,
      fragments = { image },
    }
  end
  if image.widget and span.col1 > 1 then
    image.draw_x_offset = markdown_live_body_font(view):get_width(text:sub(1, span.col1 - 1))
  end
  return {
    source_text = text,
    fragments = {
      { source_col1 = 1, source_col2 = span.col1, hidden = true },
      image,
      { source_col1 = span.col2, source_col2 = #text + 1, hidden = true },
    },
  }
end

local function resolve_live_link(view, link)
  local owner = view.__markdown_live_owner
  local index = owner and owner.link_index
  local target = link.raw_target or link.path or ""
  if not common.is_absolute_path(target) and target:match("^[%a][%w+.-]*:") then
    return { status = "external", target = target, path = target }
  elseif index and index.status == "ready" then
    return index:resolve(link, view.doc.abs_filename)
  end
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
    local modifier = PLATFORM == "Mac OS X" and "cmd" or "ctrl"
    if button ~= "left" or not keymap.modkeys[modifier] then return false end
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
  fragment.font = code and inline_style_font(view, "code", opts.base_font, opts.base_bold)
    or font_type ~= "normal"
      and inline_style_font(view, font_type, opts.base_font, opts.base_bold)
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

local function revealed_link_fragments(view, line_text, line, span, opts)
  if span.link and (span.link.kind == "image" or span.link.kind == "embed")
    and is_image_target(span.link.path)
  then
    return {}
  end
  local linked_col1, linked_col2
  if span.type == "wiki_link" or span.type == "embed" then
    local marker_width = line_text:sub(span.col1, span.col1) == "!" and 3 or 2
    linked_col1, linked_col2 = span.col1 + marker_width, span.col2 - 2
  else
    local attributes = span.attributes or {}
    local range = attributes.link_text or attributes.reference_label
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
  if not (resolution and resolution.status == "resolved" and resolution.kind == "note") then return nil end
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

local function semantic_link_fragments(view, line_text, line, reveal_units, opts)
  local fragments = {}
  for _, span in ipairs(semantic_link_spans(view, line_text, line)) do
    local revealed = reveal_unit_matches(reveal_units, span.semantic_id, span.col1, span.col2)
    if span.link and revealed then
      for _, fragment in ipairs(revealed_link_fragments(view, line_text, line, span, opts)) do
        fragments[#fragments + 1] = fragment
      end
    elseif span.link then
      local fragment = image_fragment(view, span)
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
      end
      fragment = decorate_link_fragment(view, line, span, fragment, opts)
      if fragment then
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
  for _, node in ipairs(semantic_line(view, line) or {}) do
    if node.type == "table" then
      local line2 = node.source.line2
      if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
      if line >= node.source.line1 and line <= line2 then return node end
    end
  end
end

local TABLE_MAX_PRESENTATION_ROWS = 256
local TABLE_MAX_PRESENTATION_COLUMNS = 64

local function table_pipe_positions(text)
  local positions = {}
  local escaped, ticks = false, 0
  local i = 1
  while i <= #text do
    local char = text:sub(i, i)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == "`" then
      local finish = i
      while text:sub(finish + 1, finish + 1) == "`" do finish = finish + 1 end
      local count = finish - i + 1
      if ticks == 0 then ticks = count elseif ticks == count then ticks = 0 end
      i = finish
    elseif char == "|" and ticks == 0 then
      positions[#positions + 1] = i
    end
    i = i + 1
  end
  return positions
end

local function table_source_row(text)
  local pipes = table_pipe_positions(text)
  if #pipes == 0 then return nil end
  local first = text:find("%S")
  local last = text:match("^.*()%S")
  local outer_left = first and pipes[1] == first
  local outer_right = last and pipes[#pipes] == last
  local first_inner = outer_left and 2 or 1
  local last_inner = outer_right and #pipes - 1 or #pipes
  local cells, separators = {}, {}
  local start_col = outer_left and pipes[1] + 1 or 1
  if outer_left then
    separators[#separators + 1] = { col1 = 1, col2 = pipes[1] + 1 }
  else
    separators[#separators + 1] = { col1 = 1, col2 = 1 }
  end
  for i = first_inner, last_inner do
    local pipe = pipes[i]
    cells[#cells + 1] = { col1 = start_col, col2 = pipe }
    separators[#separators + 1] = { col1 = pipe, col2 = pipe + 1 }
    start_col = pipe + 1
  end
  local end_col = outer_right and pipes[#pipes] or #text + 1
  if end_col >= start_col then cells[#cells + 1] = { col1 = start_col, col2 = end_col } end
  if not outer_right then
    separators[#separators + 1] = { col1 = #text + 1, col2 = #text + 1 }
  elseif separators[#separators].col1 ~= pipes[#pipes] then
    separators[#separators + 1] = {
      col1 = pipes[#pipes], col2 = #text + 1,
    }
  end
  return { cells = cells, separators = separators }
end

local function table_cell_text(text, cell)
  return (text:sub(cell.col1, cell.col2 - 1):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function table_layout(view, table_node)
  local instance = current_semantic_model(view)
  if not instance then return nil end
  local font = markdown_live_body_font(view)
  local line2 = table_node.source.line2
  if table_node.source.col2 == 1 and line2 > table_node.source.line1 then line2 = line2 - 1 end
  local line1 = table_node.source.line1
  if line2 - line1 + 1 > TABLE_MAX_PRESENTATION_ROWS then
    core.log_quiet("Markdown table presentation kept raw beyond %d rows at %s:%d",
      TABLE_MAX_PRESENTATION_ROWS, view.doc:get_name(), line1)
    return nil
  end
  local cache = view.__markdown_live_table_layout_cache
  if not cache or cache.generation ~= instance.generation
    or cache.font ~= font or cache.font_size ~= font:get_size()
  then
    cache = {
      generation = instance.generation, font = font,
      font_size = font:get_size(), layouts = {},
    }
    view.__markdown_live_table_layout_cache = cache
  end
  if cache.layouts[table_node.id] ~= nil then
    return cache.layouts[table_node.id] or nil
  end

  local rows, columns = {}, nil
  for line = line1, line2 do
    local text = (view.doc.lines[line] or ""):gsub("\n$", "")
    local row = table_source_row(text)
    if not row or #row.cells == 0 or #row.cells > TABLE_MAX_PRESENTATION_COLUMNS then
      cache.layouts[table_node.id] = false
      core.log_quiet("Markdown table presentation fell back to source at %s:%d",
        view.doc:get_name(), line)
      return nil
    end
    columns = columns or #row.cells
    if #row.cells ~= columns then
      cache.layouts[table_node.id] = false
      core.log_quiet("Markdown table presentation found inconsistent columns at %s:%d",
        view.doc:get_name(), line)
      return nil
    end
    row.line, row.text = line, text
    rows[line] = row
  end

  local pad = math.max(font:get_width(" "), SCALE)
  local widths = {}
  for column = 1, columns do widths[column] = pad * 4 end
  for line = line1, line2 do
    if line ~= line1 + 1 then
      local row = rows[line]
      for column, cell in ipairs(row.cells) do
        local cell_font = line == line1 and inline_style_font(view, "strong") or font
        widths[column] = math.max(
          widths[column], cell_font:get_width(table_cell_text(row.text, cell)) + pad * 2
        )
      end
    end
  end
  local alignments = {}
  for column, cell in ipairs(rows[line1 + 1].cells) do
    local marker = table_cell_text(rows[line1 + 1].text, cell)
    local left, right = marker:sub(1, 1) == ":", marker:sub(-1) == ":"
    alignments[column] = left and right and "center" or right and "right" or "left"
  end
  local separator_width = math.max(font:get_width(" "), math.max(1, SCALE * 3))
  local total_width = separator_width * (columns + 1)
  for _, width in ipairs(widths) do total_width = total_width + width end
  local layout = {
    id = table_node.id, line1 = line1, line2 = line2,
    delimiter_line = line1 + 1, rows = rows, columns = columns,
    widths = widths, alignments = alignments, padding = pad,
    separator_width = separator_width, total_width = total_width,
  }
  cache.layouts[table_node.id] = layout
  return layout
end

local function table_row_fragments(view, table_node, line)
  local layout = table_layout(view, table_node)
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
  local cell_font = header and inline_style_font(view, "strong")
    or markdown_live_body_font(view)
  local function border_fragment(separator, id)
    local line_width = math.max(1, math.floor(SCALE))
    return {
      source_col1 = separator.col1, source_col2 = separator.col2,
      text = "", width = layout.separator_width,
      semantic_id = id,
      table_border = true,
      widget = {
        width = layout.separator_width,
        height = markdown_live_body_line_height(view),
        draw = function(_, _, x, y, row_height)
          renderer.draw_rect(x, y, layout.separator_width, row_height,
            style.markdown_live_table_background)
          renderer.draw_rect(
            x + math.floor((layout.separator_width - line_width) / 2), y,
            line_width, row_height, style.markdown_live_table_separator
          )
        end,
      },
    }
  end
  for column, cell in ipairs(row.cells) do
    local cell_text = table_cell_text(row.text, cell)
    local text_width = cell_font:get_width(cell_text)
    local alignment = layout.alignments[column]
    local text_x_offset = alignment == "right"
      and math.max(layout.padding, layout.widths[column] - text_width - layout.padding)
      or alignment == "center"
      and math.max(layout.padding, (layout.widths[column] - text_width) / 2)
      or layout.padding
    local separator = row.separators[column]
    fragments[#fragments + 1] = border_fragment(
      separator, table_node.id .. ":pipe:" .. line .. ":" .. column
    )
    fragments[#fragments + 1] = {
      source_col1 = cell.col1, source_col2 = cell.col2,
      text = cell_text,
      width = layout.widths[column],
      text_x_offset = text_x_offset,
      table_alignment = alignment,
      font = header and cell_font or nil,
      color = header and style.markdown_live_table_header
        or style.markdown_live_table_cell,
      background = style.markdown_live_table_background,
      background_full_height = true,
      semantic_id = table_node.id .. ":cell:" .. line .. ":" .. column,
      table_cell = true, table_header = header, table_column = column,
    }
  end
  local separator = row.separators[#row.cells + 1]
  fragments[#fragments + 1] = border_fragment(
    separator, table_node.id .. ":pipe:" .. line .. ":end"
  )
  return fragments, layout
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

local function semantic_block_fragments(view, line_text, line, reveal_units)
  for _, unit in ipairs(reveal_units or {}) do
    if unit.whole_line then return {} end
  end
  local fragments, seen = {}, {}
  local callout = callout_for_line(view, line)
  local frontmatter, frontmatter_line2 = frontmatter_for_line(view, line)
  local table_node = table_for_line(view, line)
  if table_node then
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
  for _, node in ipairs(semantic_line(view, line) or {}) do
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
        source_col1 = node.source.col1, source_col2 = node.source.col2,
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
      local marker = attributes.list
      local marker_key = marker and table.concat({ marker.line1, marker.col1, marker.col2 }, ":")
      if marker and marker.line1 == line and not seen[marker_key] then
        seen[marker_key] = true
        local raw = line_text:sub(marker.col1, marker.col2 - 1)
        local ordered = raw:match("^(%d+[.)])")
        if ordered then
          fragments[#fragments + 1] = {
            source_col1 = marker.col1, source_col2 = marker.col2,
            text = ordered, color = style.markdown_live_list_marker,
            semantic_id = node.id .. ":marker",
          }
        else
          local body_font = markdown_live_body_font(view)
          local raw_width = body_font:get_width(raw)
          local marker_width = math.max(
            body_font:get_width(" "), raw_width, math.floor(SCALE * 4)
          )
          local marker_size = math.max(2, math.floor(body_font:get_height() * 0.24))
          local marker_revealed = reveal_unit_matches(
            reveal_units, node.id, marker.col1, marker.col2
          )
          if marker_revealed then
            fragments[#fragments + 1] = {
              source_col1 = marker.col1, source_col2 = marker.col2,
              text = raw, width = marker_width,
              text_x_offset = math.max(0, (marker_width - raw_width) / 2),
              color = style.markdown_live_list_marker,
              semantic_id = node.id .. ":marker",
              unordered_list_source_marker = true,
            }
          else
            fragments[#fragments + 1] = {
              source_col1 = marker.col1, source_col2 = marker.col2,
              text = "", width = marker_width,
              color = style.markdown_live_list_marker,
              semantic_id = node.id .. ":marker",
              unordered_list_marker = true,
              widget = {
                width = marker_width, height = markdown_live_body_line_height(view),
                draw = function(_, _, x, y, row_height)
                  renderer.draw_rect(
                    x + math.floor((marker_width - marker_size) / 2),
                    y + math.floor((row_height - marker_size) / 2),
                    marker_size, marker_size, style.markdown_live_list_marker
                  )
                end,
              },
            }
          end
        end
      end
      local task = attributes.task_checked or attributes.task_unchecked
      if task and task.line1 == line then
        local checked = attributes.task_checked ~= nil
        fragments[#fragments + 1] = {
          source_col1 = task.col1, source_col2 = task.col2,
          text = checked and "☑" or "☐",
          color = checked and style.markdown_live_task_checked or style.markdown_live_task_unchecked,
          cursor = "hand",
          semantic_id = node.id .. ":task",
          on_mouse_pressed = function(_, owner, _, button)
            if button ~= "left" then return false end
            owner:set_selection_state({
              selections = { line, task.col1, line, task.col2 }, last_selection = 1,
            })
            owner:with_selection_state(function()
              owner.doc:text_input(checked and "[ ]" or "[x]")
            end)
            return true
          end,
        }
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

local view_in_source_mode

local function clone_render_line(render_line)
  local clone = {}
  for key, value in pairs(render_line or {}) do clone[key] = value end
  clone.fragments = {}
  for _, fragment in ipairs(render_line and render_line.fragments or {}) do
    local copy = {}
    for key, value in pairs(fragment) do copy[key] = value end
    clone.fragments[#clone.fragments + 1] = copy
  end
  clone.hit_test_fragments = nil
  return clone
end

local function apply_inline_edit_to_render(render_line, current_text, edit)
  local start_col, end_col = edit.col1, edit.col2
  local replacement = edit.text or ""
  if not start_col or not end_col or start_col > end_col then
    return nil
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
  return current_text
end

local function split_optimistic_render(render_line, text)
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

local function capture_pre_edit_renders(view, change)
  local owner = view.__markdown_live_owner
  if not owner or view_in_source_mode and view_in_source_mode(view) then return end
  local lines = {}
  local transaction = change and change.transaction
  for _, edit in ipairs(transaction and transaction.edits or {}) do
    for line = edit.line1 or 1, edit.line2 or edit.line1 or 1 do lines[line] = true end
  end
  if change and change.kind == "raw_insert" and change.line then lines[change.line] = true end
  if change and change.kind == "raw_remove" then
    for line = change.line1 or 1, change.line2 or change.line1 or 1 do lines[line] = true end
  end
  owner.pre_edit_lines = {}
  for line in pairs(lines) do
    local render = view:get_line_render(line)
    owner.pre_edit_lines[line] = {
      source_text = (view.doc.lines[line] or ""):gsub("\n$", ""),
      render_line = render and clone_render_line(render) or nil,
      height = view:get_visual_row_height(line),
    }
  end
end

local function capture_optimistic_renders(view, transaction)
  local owner = view.__markdown_live_owner
  if not owner or not transaction or transaction.type == "load" then return end
  local pre_edit_lines = owner.pre_edit_lines or {}
  owner.optimistic_lines = owner.optimistic_lines or {}
  for _, entry in pairs(owner.optimistic_lines) do entry.revision = view.doc.text_revision end

  local structural = false
  for _, edit in ipairs(transaction.edits or {}) do
    if edit.line1 ~= edit.line2 or (edit.text or ""):find("\n", 1, true) then
      structural = true
      break
    end
  end
  if structural then
    local ranges = transaction.changed_ranges or {}
    local edit = transaction.edits and transaction.edits[1]
    local range = ranges[1]
    local cache = view.__line_render_cache
    local next_lines = {}
    if #ranges == 1 and range and cache and cache.lines then
      local old_line1 = range.old_line1 or 1
      local old_line2 = range.old_line2 or old_line1
      local delta = range.line_delta or 0
      for old_line, cached in pairs(cache.lines) do
        local render = cached.render_line ~= false and cached.render_line or nil
        local new_line
        if old_line < old_line1 then new_line = old_line
        elseif old_line > old_line2 then new_line = old_line + delta end
        local current = new_line and (view.doc.lines[new_line] or ""):gsub("\n$", "")
        if render and current == render.source_text then
          next_lines[new_line] = {
            revision = view.doc.text_revision, source_text = current,
            render_line = clone_render_line(render), height = view:get_visual_row_height(old_line),
          }
        end
      end

      if edit and #transaction.edits == 1 and edit.line1 == edit.line2 then
        local old_render = cached_render_line(view, edit.line1)
        local combined = old_render and old_render.source_text
        local transformed = old_render and clone_render_line(old_render)
        combined = transformed and apply_inline_edit_to_render(transformed, combined, edit)
        local new_line1 = range.new_line1 or edit.line1
        local new_line2 = range.new_line2 or new_line1
        local current_parts = {}
        for line = new_line1, new_line2 do
          current_parts[#current_parts + 1] = (view.doc.lines[line] or ""):gsub("\n$", "")
        end
        local current = table.concat(current_parts, "\n")
        local split = combined == current and split_optimistic_render(transformed, combined) or nil
        if split and #split == new_line2 - new_line1 + 1 then
          local height = pre_edit_lines[edit.line1] and pre_edit_lines[edit.line1].height
            or view:get_visual_row_height(edit.line1)
          for i, render in ipairs(split) do
            next_lines[new_line1 + i - 1] = {
              revision = view.doc.text_revision, source_text = render.source_text,
              render_line = render, height = height,
            }
          end
        end
      end
    end
    owner.optimistic_lines = next_lines
    owner.pre_edit_lines = nil
    local retained = 0
    for _ in pairs(next_lines) do retained = retained + 1 end
    core.log_quiet(
      "Markdown Live Preview retained %d resident rendered lines across a structural edit",
      retained
    )
    return
  end

  local edits_by_line = {}
  for _, edit in ipairs(transaction.edits or {}) do
    local edits = edits_by_line[edit.line1]
    if not edits then edits = {}; edits_by_line[edit.line1] = edits end
    edits[#edits + 1] = edit
  end

  for line, edits in pairs(edits_by_line) do
    local old_render = cached_render_line(view, line)
    local render = old_render and clone_render_line(old_render)
    local text = render and render.source_text
    table.sort(edits, function(a, b) return a.col1 > b.col1 end)
    for _, edit in ipairs(edits) do
      text = render and apply_inline_edit_to_render(render, text, edit)
      if not text then render = nil break end
    end
    local current_text = (view.doc.lines[line] or ""):gsub("\n$", "")
    if render and text == current_text then
      owner.optimistic_lines[line] = {
        revision = view.doc.text_revision,
        source_text = current_text,
        render_line = render,
        height = pre_edit_lines[line] and pre_edit_lines[line].height
          or view:get_visual_row_height(line),
      }
      core.log_quiet("Markdown Live Preview retained rendered line %d while semantics are pending", line)
    else
      owner.optimistic_lines[line] = nil
      core.log_quiet("Markdown Live Preview could not retain rendered line %d for this edit", line)
    end
  end
  owner.pre_edit_lines = nil
end

local function optimistic_render(view, line)
  local owner = view.__markdown_live_owner
  local entry = owner and owner.optimistic_lines and owner.optimistic_lines[line]
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  if entry and entry.revision == view.doc.text_revision and entry.source_text == text then
    return entry
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

function decoration_provider:line_background(view, line)
  if view_in_source_mode(view) or line_in_semantic_comment(view, line) then return nil end
  local fenced = fenced_code_for_line(view, line)
  if fenced then
    return style.markdown_live_code_background
  end
  if indented_code_for_line(view, line) then
    return style.markdown_live_code_background
  end
  if callout_for_line(view, line) then return style.markdown_live_callout_background end
  if frontmatter_for_line(view, line) then return style.markdown_live_frontmatter_background end
  return nil
end

function provider:generation(view)
  local font = markdown_live_body_font(view)
  return tostring(font) .. ":" .. tostring(font:get_size())
end

function provider:line_generation(view, line)
  if view_in_source_mode(view) then return "source" end
  local optimistic = optimistic_render(view, line)
  return "font:" .. self:generation(view)
    .. (optimistic and ":optimistic:" .. tostring(optimistic.revision) or "")
end

function provider:on_text_transaction(view, transaction, line1)
  if not line1 then return nil end
  capture_optimistic_renders(view, transaction)
  local suffix_changed = transaction and transaction.type == "load"
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    if (range.line_delta or 0) ~= 0 then suffix_changed = true break end
  end
  if not suffix_changed then
    for _, edit in ipairs(transaction and transaction.edits or {}) do
      if (edit.text or ""):find("[`~%%]") or (edit.old_text or ""):find("[`~%%]") then
        suffix_changed = true
        break
      end
    end
  end
  if not suffix_changed then
    for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
      for line = range.new_line1 or line1, range.new_line2 or range.new_line1 or line1 do
        local changed_line = view.doc.lines[line] or ""
        if changed_line:match("^%s*[`~]") or changed_line:find("%", 1, true) then
          suffix_changed = true
          break
        end
      end
      if suffix_changed then break end
    end
  end
  if not suffix_changed then return nil end
  local owner = view.__markdown_live_owner
  if owner then
    owner.semantic_pending_line = math.min(owner.semantic_pending_line or line1, line1)
  end
  return line1, #view.doc.lines
end

local function heading_content_fragments(view, text, heading, font, reveal_units)
  local fragments, occupied = {}, {}
  for _, fragment in ipairs(semantic_link_fragments(view, text, heading.line, reveal_units, {
    base_font = font,
    base_bold = true,
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
  local heading_revealed = reveal_unit_matches(
    reveal_units, heading.semantic_id, heading.source_col1, heading.source_col2
  )
  return prose_render_line(view, text, {
    source_text = text,
    semantic_id = heading.semantic_id,
    semantic_generation = heading.semantic_generation,
    fragments = heading_revealed
      and active_heading_fragments(view, text, heading, font, reveal_units)
      or inactive_heading_fragments(view, text, heading, font, reveal_units),
  })
end

function provider:line_height(view, line)
  if view_in_source_mode(view) then return nil end
  if line_is_wrapped(view, line) then return nil end
  local optimistic = optimistic_render(view, line)
  if optimistic and not current_semantic_model(view) then return optimistic.height end
  if not current_semantic_model(view) then return nil end
  local in_comment = line_in_semantic_comment(view, line)
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local body_height = markdown_live_body_line_height(view)
  if not in_comment then
    local table_node = table_for_line(view, line)
    if table_node then
      local layout = table_layout(view, table_node)
      if layout and line == layout.delimiter_line
        and #reveal_units_for_line(view, line) == 0
      then
        return math.max(1, math.floor(SCALE))
      end
    end
  end
  local heading = semantic_heading_for_line(view, text, line)
  if heading then
    local height = math.max(
      body_height,
      math.floor(heading_font(view, heading.level):get_height() * config.line_height)
    )
    local render_line = heading_render_line(view, text, heading, reveal_units_for_line(view, line))
    for _, fragment in ipairs(render_line.fragments or {}) do
      if fragment.widget and fragment.widget.height then height = math.max(height, fragment.widget.height) end
    end
    return height
  end
  if not in_comment and line_in_raw_block(view, line) then return nil end
  local reveal_units = reveal_units_for_line(view, line)
  local image_span = image_only_span(view, text, line)
  if image_span then
    local image_revealed = reveal_unit_matches(
      reveal_units, image_span.semantic_id, image_span.col1, image_span.col2
    )
    local render_line = image_only_render_line(view, text, line, image_span, image_revealed)
    local max_height
    if render_line then
      for _, fragment in ipairs(render_line.fragments or {}) do
        if fragment.widget and fragment.widget.height then
          max_height = math.max(max_height or 0, fragment.widget.height)
        end
      end
    end
    if max_height then return math.max(body_height, max_height) end
  end
  local max_height
  for _, fragment in ipairs(inline_fragments(text, line, view, reveal_units)) do
    if fragment.widget and fragment.widget.height then
      max_height = math.max(max_height or 0, fragment.widget.height)
    end
  end
  if max_height then return math.max(body_height, max_height) end
  return body_height
end

function provider:render_line(view, line)
  if view_in_source_mode(view) then
    return { raw_passthrough = true }
  end
  local optimistic = optimistic_render(view, line)
  if optimistic and not current_semantic_model(view) then return optimistic.render_line end
  if not current_semantic_model(view) then return { raw_passthrough = true } end
  local in_comment = line_in_semantic_comment(view, line)
  local fenced = not in_comment and fenced_code_for_line(view, line)
  if fenced then
    local text = (view.doc.lines[line] or ""):gsub("\n$", "")
    local delimiter_kind = fenced_code_delimiter_kind(view, fenced, line)
    if delimiter_kind and not fenced_code_is_active(view, fenced) then
      return {
        source_text = text,
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
  if not in_comment and line_in_raw_block(view, line) then return { raw_passthrough = true } end

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

  local image_span = image_only_span(view, text, line)
  if image_span then
    if line_is_wrapped(view, line) then return { raw_passthrough = true } end
    local image_revealed = reveal_unit_matches(
      reveal_units, image_span.semantic_id, image_span.col1, image_span.col2
    )
    local render_line = image_only_render_line(view, text, line, image_span, image_revealed)
    if render_line then
      for _, fragment in ipairs(render_line.fragments or {}) do
        if fragment.semantic_id then decorate_link_fragment(view, line, image_span, fragment) end
      end
      return prose_render_line(view, text, render_line)
    end
  end

  local fragments = inline_fragments(text, line, view, reveal_units)
  if #fragments > 0 then
    local _, semantic_generation = semantic_line(view, line)
    return prose_render_line(view, text, {
      source_text = text,
      semantic_generation = semantic_generation,
      fragments = fragments,
    })
  end
  return prose_render_line(view, text, { fragments = {} })
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
        "Markdown live editor released lifecycle ownership: %s", reason or "release"
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
  core.log_quiet("Markdown live editor now owns lifecycle for %s", owner.doc:get_name())
  return true
end

local function invalidate_semantic_publication(view, instance, reason)
  local previous_table_cache = view.__markdown_live_table_layout_cache
  view.__markdown_live_semantic_line_cache = nil
  view.__markdown_live_reference_prepare_pending = nil
  local owner = view.__markdown_live_owner
  if owner then owner.optimistic_lines = nil end
  local pending_line = owner and owner.semantic_pending_line
  if owner and reason ~= "pending" then owner.semantic_pending_line = nil end
  local ranges
  if reason == "published" and pending_line then
    ranges = { { line1 = pending_line, line2 = #view.doc.lines } }
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
  view.__markdown_live_table_layout_cache = nil
  if ranges and #ranges > 0 then
    for _, range in ipairs(ranges) do
      local line1 = common.clamp(range.line1 or 1, 1, #view.doc.lines)
      local line2 = common.clamp(range.line2 or line1, line1, #view.doc.lines)
      prune_image_references(view, line1, line2)
      view:invalidate_line_render(PROVIDER_ID, line1, line2)
      view:invalidate_visual_metrics(PROVIDER_ID, line1, line2)
    end
  else
    prune_image_references(view)
    view:invalidate_line_render(PROVIDER_ID)
    view:invalidate_visual_metrics(PROVIDER_ID)
  end
  core.redraw = true
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
  owner.link_index = index
  owner.link_listener_id = listener_id
  index:acquire(listener_id)
  index:add_listener(listener_id, function()
    if view.__markdown_live_owner ~= owner or not view.__markdown_live_attached then return end
    view:invalidate_line_render(PROVIDER_ID)
    view:invalidate_visual_metrics(PROVIDER_ID)
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
  for _, state in ipairs({ old_state, new_state }) do
    for i = 1, #(state and state.selections or {}), 4 do
      local line1 = state.selections[i]
      local line2 = state.selections[i + 2] or line1
      if line1 then
        for line = math.min(line1, line2), math.max(line1, line2) do lines[line] = true end
        for _, endpoint in ipairs({ line1, line2 }) do
          local fenced = fenced_code_for_line(view, endpoint)
          if fenced then
            for line = fenced.source.line1, fenced.effective_line2 do lines[line] = true end
          end
        end
        if line1 == line2 and state.selections[i + 1] == state.selections[i + 3] then
          for _, unit in ipairs(reveal_units_for_line(view, line1, state)) do
            if unit.line1 and unit.line2 then
              for line = unit.line1, unit.line2 do lines[line] = true end
            end
          end
        end
      end
    end
  end
  for line in pairs(lines) do
    view:invalidate_line_render(PROVIDER_ID, line, line)
    view:invalidate_visual_metrics(PROVIDER_ID, line, line)
  end
end

function live.attach(view)
  if not (view and view.extends and view:extends(DocView)) then return false end
  if view.__markdown_live_attached then return false end
  view:add_visual_metric_provider(PROVIDER_ID, provider)
  view:add_line_render_provider(PROVIDER_ID, provider)
  view:add_decoration_provider(PROVIDER_ID, decoration_provider)
  view:add_clipboard_paste_provider(PROVIDER_ID, clipboard_paste_provider)
  view:add_file_drop_provider(PROVIDER_ID, file_drop_provider)
  view:add_poi_provider(PROVIDER_ID, poi_provider)
  view:add_selection_listener(PROVIDER_ID, function(owner, new_state, old_state)
    invalidate_selection_lines(owner, new_state, old_state)
  end)
  view.__markdown_live_attached = true
  bind_semantic_model(view)
  bind_link_index(view)
  link_completion.ensure_provider()
  core.log_quiet("Markdown live editor attached to %s", view.doc and view.doc:get_name() or tostring(view))
  return true
end

function live.detach(view)
  if not (view and view.__markdown_live_attached) then return false end
  unbind_link_index(view)
  unbind_semantic_model(view)
  clear_image_cache(view)
  view:remove_visual_metric_provider(PROVIDER_ID)
  view:remove_line_render_provider(PROVIDER_ID)
  view:remove_decoration_provider(PROVIDER_ID)
  view:remove_clipboard_paste_provider(PROVIDER_ID)
  view:remove_file_drop_provider(PROVIDER_ID)
  view:remove_poi_provider(PROVIDER_ID)
  view:remove_selection_listener(PROVIDER_ID)
  view.__markdown_live_attached = nil
  core.log_quiet("Markdown live editor detached from %s", view.doc and view.doc:get_name() or tostring(view))
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
