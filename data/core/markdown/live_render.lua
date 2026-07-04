local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local parser = require "core.markdown.parser"
local style = require "core.style"

local live = {}

local PROVIDER_ID = "markdown-live"
local MARKDOWN_EXTENSIONS = { md = true, markdown = true, mdown = true }

local function extension(path)
  return (path or ""):match("%.([^.\\/]+)$") and (path or ""):match("%.([^.\\/]+)$"):lower() or nil
end

function live.is_markdown_doc(doc)
  if not doc then return false end
  if MARKDOWN_EXTENSIONS[extension(doc.abs_filename or doc.filename or "") or ""] then return true end
  local syntax_name = doc.syntax and doc.syntax.name
  return type(syntax_name) == "string" and syntax_name:lower():find("markdown", 1, true) ~= nil
end

local function view_active_line(view, line)
  local selections = view.selection_state and view.selection_state.selections or view.doc.selections or {}
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

local function inline_fragments(line_text, line)
  local fragments, occupied = {}, {}
  for _, span in ipairs(parser.parse_inline(line_text, line)) do
    if span.link then
      local link = span.link
      add_fragment(fragments, occupied, {
        source_col1 = span.col1,
        source_col2 = span.col2,
        text = link.display ~= "" and link.display or link.raw_target,
        color = style.markdown_live_link,
      })
    elseif span.type == "strong" or span.type == "emphasis" or span.type == "strong_emphasis" or span.type == "strikethrough" then
      add_fragment(fragments, occupied, {
        source_col1 = span.col1,
        source_col2 = span.col2,
        text = span.text,
        color = style.text,
      })
    elseif span.type == "code" then
      add_fragment(fragments, occupied, {
        source_col1 = span.col1,
        source_col2 = span.col2,
        text = span.text,
        color = style.text,
      })
    end
  end
  table.sort(fragments, function(a, b) return (a.source_col1 or 1) < (b.source_col1 or 1) end)
  return fragments
end

local provider = {}

function provider:line_height(view, line)
  if view.wrapped_settings then return nil end
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local heading = heading_for_line(text, line)
  if heading then
    return math.max(view:get_line_height(), math.floor(heading_font(view, heading.level):get_height() * config.line_height))
  end
end

function provider:render_line(view, line)
  if view_active_line(view, line) then return { raw_passthrough = true } end
  if view.wrapped_settings then return { raw_passthrough = true } end

  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local heading = heading_for_line(text, line)
  if heading then
    return {
      source_text = text,
      fragments = {
        { source_col1 = 1, source_col2 = heading.content_col1, hidden = true },
        { source_col1 = heading.content_col1, source_col2 = heading.content_col2, text = heading.text, font = heading_font(view, heading.level), color = style.text },
        { source_col1 = heading.content_col2, source_col2 = #text + 1, hidden = true },
      },
    }
  end

  local fragments = inline_fragments(text, line)
  if #fragments > 0 then return { source_text = text, fragments = fragments } end
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
end

return live
