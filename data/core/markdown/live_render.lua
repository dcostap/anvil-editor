local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local images = require "core.markdown.images"
local linewrapping = require "core.linewrapping"
local parser = require "core.markdown.parser"
local style = require "core.style"

local live = {}

local PROVIDER_ID = "markdown-live"
local MARKDOWN_EXTENSIONS = { md = true, markdown = true, mdown = true }
local IMAGE_EXTENSIONS = { avif = true, bmp = true, gif = true, jpeg = true, jpg = true, png = true, svg = true, webp = true }

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

local function line_in_raw_block(view, line)
  local doc = view.doc
  local signature = tostring(doc.text_revision or 0) .. ":" .. tostring(#doc.lines)
  local cache = view.__markdown_live_raw_block_cache
  if not (cache and cache.signature == signature) then
    local suppressed = {}
    local marker, count
    for i, raw in ipairs(doc.lines) do
      local text = (raw or ""):gsub("\n$", "")
      if marker then
        suppressed[i] = true
        if closes_fence(text, marker, count) then marker, count = nil, nil end
      else
        local m, c = fence_marker(text)
        if m then
          suppressed[i] = true
          marker, count = m, c
        elseif text:match("^    %S") or text:match("^\t%S") then
          suppressed[i] = true
        end
      end
    end
    cache = { signature = signature, suppressed = suppressed }
    view.__markdown_live_raw_block_cache = cache
  end
  return cache.suppressed[line] == true
end

local function current_selection_state(view)
  if view.get_line_render_selection_state then return view:get_line_render_selection_state() end
  return view.selection_state or { selections = view.doc.selections }
end

local function view_active_line(view, line)
  local state = current_selection_state(view)
  local selections = state and state.selections or view.doc.selections or {}
  for i = 1, #selections, 4 do
    local l1, _, l2 = selections[i], selections[i + 1], selections[i + 2]
    if l1 and l2 and line >= math.min(l1, l2) and line <= math.max(l1, l2) then return true end
  end
  return false
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

local function heading_font(view, level)
  view.__markdown_live_heading_fonts = view.__markdown_live_heading_fonts or {}
  local cache = view.__markdown_live_heading_fonts
  local font = view:get_font()
  local size = font:get_size()
  local scale = ({ 1.65, 1.45, 1.30, 1.18, 1.08, 1.0 })[level] or 1
  local key = tostring(font) .. ":" .. tostring(size) .. ":" .. tostring(level)
  if not cache[key] then
    cache[key] = font:copy(math.max(1, math.floor(size * scale)), { bold = true })
  end
  return cache[key]
end

local function inline_style_font(view, span_type, base_font)
  view.__markdown_live_inline_fonts = view.__markdown_live_inline_fonts or {}
  local cache = view.__markdown_live_inline_fonts
  local font = base_font or view:get_font()
  local size = font:get_size()
  local key = tostring(font) .. ":" .. tostring(size) .. ":" .. tostring(span_type)
  if not cache[key] then
    local attrs = {}
    if span_type == "strong" or span_type == "strong_emphasis" then attrs.bold = true end
    if span_type == "emphasis" or span_type == "strong_emphasis" then attrs.italic = true end
    if span_type == "strikethrough" then attrs.strikethrough = true end
    cache[key] = font:copy(size, attrs)
  end
  return cache[key]
end

local function normal_text_color()
  return style.text or style.syntax.normal
end

local function strong_overdraw(span_type)
  return span_type == "strong" or span_type == "strong_emphasis" or nil
end

local function is_image_target(path)
  local ext = ((path or ""):match("^[^#?]+") or (path or "")):match("%.([^%.?#/\\]+)$")
  return ext and IMAGE_EXTENSIONS[ext:lower()] == true
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

local function image_fragment(view, span, opts)
  opts = opts or {}
  if config.markdown_live_render_images ~= true then return nil end
  local link = span.link
  if not (link and (link.kind == "image" or link.kind == "embed") and is_image_target(link.path)) then return nil end
  view.__markdown_live_image_cache = view.__markdown_live_image_cache or {}
  local key = link.raw_target or link.path
  local entry = view.__markdown_live_image_cache[key]
  if not entry then
    local project = core.current_project(view.doc.abs_filename)
    entry = images.ensure_entry(link.path, {
      alt = link.alias or link.alt,
      source_path = view.doc.abs_filename,
      project_root = project and project.path,
      download_remote = config.markdown_live_download_remote_images == true,
      on_done = function(ok, err, filename)
        if ok and filename then
          local loaded = images.load_from_path(filename)
          for key, value in pairs(loaded) do entry[key] = value end
        else
          entry.status = "error"
          entry.errmsg = err or "image download failed"
        end
        view:invalidate_line_render(PROVIDER_ID)
        view:invalidate_visual_metrics(PROVIDER_ID)
        core.redraw = true
      end,
    })
    view.__markdown_live_image_cache[key] = entry
  end

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

  return {
    source_col1 = span.col1,
    source_col2 = span.col2,
    text = "[image: " .. (link.path or link.raw_target or "") .. "]",
    color = style.markdown_live_unresolved_link,
  }
end

local function image_only_span(line_text, line)
  local trimmed_start = line_text:find("%S")
  if not trimmed_start then return nil end
  local trimmed_end = line_text:match("^.*%S()")
  for _, span in ipairs(parser.parse_inline(line_text, line)) do
    local link = span.link
    if link and (link.kind == "image" or link.kind == "embed") and is_image_target(link.path)
    and span.col1 == trimmed_start and span.col2 == trimmed_end then
      return span
    end
  end
end

local function image_only_render_line(view, text, line, span, active)
  local image = image_fragment(view, span, active and { width = 0 } or nil)
  if not image then return nil end
  if active and image.widget then
    local leading_width = span.col1 > 1 and view:get_font():get_width(text:sub(1, span.col1 - 1)) or 0
    image.source_col1 = #text + 1
    image.source_col2 = #text + 1
    image.draw_x_offset = leading_width - view:get_font():get_width(text)
    image.draw_y_offset = view:get_line_height() + image_vertical_padding()
    image.widget.height = image.widget.height + view:get_line_height()
    return {
      source_text = text,
      fragments = { image },
    }
  end
  if image.widget and span.col1 > 1 then
    image.draw_x_offset = view:get_font():get_width(text:sub(1, span.col1 - 1))
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

local function emphasis_fragment(view, line_text, span, active, opts)
  opts = opts or {}
  local content = span.content_ranges and span.content_ranges[1]
  if not content then
    return {
      source_col1 = span.col1,
      source_col2 = span.col2,
      text = span.text,
      font = inline_style_font(view, span.type, opts.base_font),
      color = opts.color or normal_text_color(),
      overdraw = strong_overdraw(span.type),
    }
  end
  if active then
    return {
      {
        source_col1 = span.col1,
        source_col2 = content.col1,
        text = line_text:sub(span.col1, content.col1 - 1),
        color = style.markdown_live_hidden_syntax,
      },
      {
        source_col1 = content.col1,
        source_col2 = content.col2,
        text = span.text,
        font = inline_style_font(view, span.type, opts.base_font),
        color = opts.color or normal_text_color(),
        overdraw = strong_overdraw(span.type),
      },
      {
        source_col1 = content.col2,
        source_col2 = span.col2,
        text = line_text:sub(content.col2, span.col2 - 1),
        color = style.markdown_live_hidden_syntax,
      },
    }
  end
  return {
    {
      source_col1 = span.col1,
      source_col2 = content.col1,
      hidden = true,
    },
    {
      source_col1 = content.col1,
      source_col2 = content.col2,
      text = span.text,
      font = inline_style_font(view, span.type, opts.base_font),
      color = opts.color or normal_text_color(),
      overdraw = strong_overdraw(span.type),
    },
    {
      source_col1 = content.col2,
      source_col2 = span.col2,
      hidden = true,
    },
  }
end

local function add_fragment_or_fragments(fragments, occupied, fragment)
  if fragment[1] then
    local ok = true
    for _, item in ipairs(fragment) do
      ok = add_fragment(fragments, occupied, item) and ok
    end
    return ok
  end
  return add_fragment(fragments, occupied, fragment)
end

local function inline_fragments(line_text, line, view, active)
  local fragments, occupied = {}, {}
  for _, span in ipairs(parser.parse_inline(line_text, line)) do
    if span.link then
      if not active then
        local image = image_fragment(view, span)
        if image then
          add_fragment(fragments, occupied, image)
        else
          local link = span.link
          add_fragment(fragments, occupied, {
            source_col1 = span.col1,
            source_col2 = span.col2,
            text = link.display ~= "" and link.display or link.raw_target,
            color = style.markdown_live_link,
          })
        end
      end
    elseif span.type == "strong" or span.type == "emphasis" or span.type == "strong_emphasis" or span.type == "strikethrough" then
      add_fragment_or_fragments(fragments, occupied, emphasis_fragment(view, line_text, span, active))
    end
  end
  table.sort(fragments, function(a, b) return (a.source_col1 or 1) < (b.source_col1 or 1) end)
  return fragments
end

local provider = {}

function provider:generation(view)
  local state = current_selection_state(view)
  return table.concat(state and state.selections or {}, ",")
end

local function heading_content_fragments(view, text, heading, font, active)
  local fragments = {}
  local cursor = heading.content_col1
  for _, span in ipairs(parser.parse_inline(text, heading.line)) do
    local emphasis = span.type == "strong" or span.type == "emphasis" or span.type == "strong_emphasis" or span.type == "strikethrough"
    if emphasis and span.col1 >= heading.content_col1 and span.col2 <= heading.content_col2 and span.col1 >= cursor then
      if cursor < span.col1 then
        fragments[#fragments + 1] = {
          source_col1 = cursor,
          source_col2 = span.col1,
          text = text:sub(cursor, span.col1 - 1),
          font = font,
          color = style.text,
        }
      end
      local item = emphasis_fragment(view, text, span, active, { base_font = font, color = style.text })
      if item[1] then
        for _, fragment in ipairs(item) do fragments[#fragments + 1] = fragment end
      else
        fragments[#fragments + 1] = item
      end
      cursor = span.col2
    end
  end
  if cursor < heading.content_col2 then
    fragments[#fragments + 1] = {
      source_col1 = cursor,
      source_col2 = heading.content_col2,
      text = text:sub(cursor, heading.content_col2 - 1),
      font = font,
      color = style.text,
    }
  end
  return fragments
end

local function active_heading_fragments(view, text, heading, font)
  local fragments = {
    { source_col1 = 1, source_col2 = heading.content_col1, text = text:sub(1, heading.content_col1 - 1), font = font, color = style.markdown_live_heading_marker },
  }
  for _, fragment in ipairs(heading_content_fragments(view, text, heading, font, true)) do fragments[#fragments + 1] = fragment end
  fragments[#fragments + 1] = { source_col1 = heading.content_col2, source_col2 = #text + 1, text = text:sub(heading.content_col2), font = font, color = style.markdown_live_heading_marker }
  return fragments
end

local function inactive_heading_fragments(view, text, heading, font)
  local fragments = {
    { source_col1 = 1, source_col2 = heading.content_col1, hidden = true },
  }
  for _, fragment in ipairs(heading_content_fragments(view, text, heading, font, false)) do fragments[#fragments + 1] = fragment end
  fragments[#fragments + 1] = { source_col1 = heading.content_col2, source_col2 = #text + 1, hidden = true }
  return fragments
end

local function heading_render_line(view, text, heading, active)
  local font = heading_font(view, heading.level)
  local active_fragments = active_heading_fragments(view, text, heading, font)
  return {
    source_text = text,
    fragments = active and active_fragments or inactive_heading_fragments(view, text, heading, font),
  }
end

function provider:line_height(view, line)
  if line_is_wrapped(view, line) or line_in_raw_block(view, line) then return nil end
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local heading = heading_for_line(text, line)
  if heading then
    return math.max(view:get_line_height(), math.floor(heading_font(view, heading.level):get_height() * config.line_height))
  end
  local active = view_active_line(view, line)
  local image_span = image_only_span(text, line)
  if image_span then
    local render_line = image_only_render_line(view, text, line, image_span, active)
    local max_height
    if render_line then
      for _, fragment in ipairs(render_line.fragments or {}) do
        if fragment.widget and fragment.widget.height then
          max_height = math.max(max_height or 0, fragment.widget.height)
        end
      end
    end
    if max_height then return math.max(view:get_line_height(), max_height) end
  end
  if active then return nil end
  local max_height
  for _, fragment in ipairs(inline_fragments(text, line, view, false)) do
    if fragment.widget and fragment.widget.height then
      max_height = math.max(max_height or 0, fragment.widget.height)
    end
  end
  if max_height then return math.max(view:get_line_height(), max_height) end
end

function provider:render_line(view, line)
  if line_is_wrapped(view, line) or line_in_raw_block(view, line) then return { raw_passthrough = true } end

  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local heading = heading_for_line(text, line)
  local active = view_active_line(view, line)
  if heading then return heading_render_line(view, text, heading, active) end

  local image_span = image_only_span(text, line)
  if image_span then
    local render_line = image_only_render_line(view, text, line, image_span, active)
    if render_line then return render_line end
  end

  local fragments = inline_fragments(text, line, view, active)
  if #fragments > 0 then return { source_text = text, fragments = fragments } end
  if active then return { raw_passthrough = true } end
end

function live.image_at_position(view, x, y)
  if not (view and view.__markdown_live_attached and view.get_line_render) then return nil end
  local line = view:resolve_screen_position(x, y)
  local render_line = view:get_line_render(line)
  if not render_line then return nil end
  local line_x, line_y = view:get_line_screen_position(line)
  local xrel, yrel = x - line_x, y - line_y
  local row = view:get_visual_row(line, 1)
  local row_height = view:get_visual_row_height(row)
  local tx = 0
  local _, indent_size = view.doc:get_indent_info()
  for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
    if not fragment.hidden then
      local font = fragment.font or view:get_font()
      font:set_tab_size(indent_size)
      local widget = fragment.widget
      local text = fragment.text or ""
      local width = fragment.width or (widget and widget.width) or font:get_width(text, { tab_offset = tx })
      if widget and fragment.image_path then
        local padding = widget.padding or 0
        local image_height = widget.image_height or widget.height or row_height
        local left = tx + (fragment.draw_x_offset or 0)
        local top
        if fragment.draw_y_offset then
          top = fragment.draw_y_offset - padding
        else
          top = math.max(0, (row_height - image_height) / 2) - padding
        end
        local hit_height = image_height + padding * 2
        if xrel >= left and xrel <= left + (widget.width or width or 0)
        and yrel >= top and yrel <= top + hit_height then
          return { line = line, path = fragment.image_path, fragment = fragment }
        end
      end
      tx = tx + width
    end
  end
end

function live.attach(view)
  if not (view and view.extends and view:extends(DocView)) then return false end
  if view.__markdown_live_attached then return false end
  view:add_visual_metric_provider(PROVIDER_ID, provider)
  view:add_line_render_provider(PROVIDER_ID, provider)
  view.__markdown_live_attached = true
  core.log_quiet("Markdown live editor attached to %s", view.doc and view.doc:get_name() or tostring(view))
  return true
end

function live.detach(view)
  if not (view and view.__markdown_live_attached) then return false end
  view:remove_visual_metric_provider(PROVIDER_ID)
  view:remove_line_render_provider(PROVIDER_ID)
  view.__markdown_live_attached = nil
  core.log_quiet("Markdown live editor detached from %s", view.doc and view.doc:get_name() or tostring(view))
  return true
end

function live.refresh_view(view)
  if not (view and view.doc) then return false end
  if config.markdown_live_editor and live.is_markdown_doc(view.doc) then
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

  local old_docview_mouse_pressed = DocView.on_mouse_pressed
  DocView.on_mouse_pressed = function(view, button, x, y, clicks, ...)
    if button == "left" and view.__markdown_live_attached then
      local hit = live.image_at_position(view, x, y)
      if hit and hit.path then
        view.doc:set_selection(hit.line, 1)
        local image_overlay = require "core.markdown.image_overlay"
        image_overlay.open(hit.path)
        return true
      end
    end
    return old_docview_mouse_pressed(view, button, x, y, clicks, ...)
  end

  refresh_open_views()
end

return live
