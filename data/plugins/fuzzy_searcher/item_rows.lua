-- Rows that providers add to File Search, such as the objects of a Project's databases. A provider's
-- `project_file_groups(query, opts)` gives groups: `label` and `items`. An item has `name`, `icon` (a glyph of
-- the icon font), `dim_length` (the bytes of the name that draw dim), `info`, `activate(source_view, placement)`
-- and `preview()`. A preview gives `text`, `language`, and optionally `line`, `col` and `col2` to mark, or nil and
-- an error while it is not there. Symbol Search rows can have a preview too.
local style = require "core.style"
local common = require "core.common"
local Buffer = require "core.buffer"
local fuzzy = require "fuzzy"
local preview_text_view = require "plugins.fuzzy_searcher.preview_text_view"

local item_rows = {}

-- Adds each provider's groups after `out`: a divider, a header with the group's label, then its rows.
function item_rows.add_groups(view, out, query, limit)
  local buffer = view.source_buffer or (view.source_view and view.source_view.buffer)
  local providers = require("core.language_intelligence").providers_for("project_file_groups", buffer)
  for _, provider in ipairs(providers) do
    local groups = provider.project_file_groups(query, { limit = limit, case_sensitive = view.case_sensitive })
    for _, group in ipairs(groups or {}) do
      if #group.items > 0 then
        if #out > 0 then out[#out + 1] = { header = true, separator = true, label = "" } end
        out[#out + 1] = { header = true, label = group.label }
        for _, item in ipairs(group.items) do
          local match = fuzzy.match(item.name, query, { mode = "path", spans = true, case_sensitive = view.case_sensitive })
          out[#out + 1] = { kind = "item", label = item.name, icon = item.icon, dim_length = item.dim_length,
            info = item.info, activate = item.activate, preview = item.preview, match_spans = match and match.spans or {} }
        end
      end
    end
  end
  return out
end

local function spans_between(spans, first, last, shift)
  local out = {}
  for _, span in ipairs(spans) do
    local a, b = math.max(span[1], first), math.min(span[2], last)
    if a <= b then out[#out + 1] = { a - shift, b - shift } end
  end
  return out
end

-- Draws an item row: its icon in the file icon column, its name, and its info at the right.
-- `draw_text(font, text, x, y, width, color, spans)` draws highlighted text and returns its end.
function item_rows.draw(font, r, x, y, width, icon_column_width, draw_text)
  local height = font:get_height()
  if r.icon then
    local icon_font = require("core.ui").small_icon_font()
    renderer.draw_text(icon_font, r.icon, x + math.floor((icon_column_width - icon_font:get_width(r.icon)) / 2),
      y + math.floor((height - icon_font:get_height()) / 2), style.accent)
  end
  local small = style.get_small_font(font)
  local info = r.info or ""
  local info_width = info ~= "" and small:get_width(info) + style.padding.x or 0
  local name_x = x + icon_column_width
  local available = math.max(0, x + width - info_width - name_x)
  if not r.name_text then
    local dim = math.min(r.dim_length or 0, #r.label)
    r.dim_text, r.dim_spans = r.label:sub(1, dim), spans_between(r.match_spans, 1, dim, 0)
    r.name_text, r.name_spans = r.label:sub(dim + 1), spans_between(r.match_spans, dim + 1, #r.label, dim)
  end
  local cx = name_x
  if r.dim_text ~= "" then cx = draw_text(font, r.dim_text, cx, y, available, style.dim, r.dim_spans) end
  local name_end = draw_text(font, r.name_text, cx, y, math.max(0, available - (cx - name_x)), style.text,
    r.name_spans)
  if info_width > 0 and x + width - info_width >= name_end then
    renderer.draw_text(small, info, x + width - small:get_width(info),
      y + math.floor((height - small:get_height()) / 2), style.dim)
  end
  return name_x, name_end
end

-- Shows a row's preview in the picker. Returns the preview View, or nil while the preview is not there.
function item_rows.update_preview(picker, r)
  local shown, err = r.preview()
  if not shown then
    local key = "item-wait:" .. tostring(r.preview) .. ":" .. tostring(err)
    if picker.preview_key ~= key then
      picker:clear_preview_view()
      picker.preview_key = key
      if err then picker.preview_blocked = { reason = err, path = r.label } end
    end
    return nil
  end
  local key = "item:" .. tostring(shown)
  if picker.preview_key ~= key then
    picker:clear_preview_view()
    picker.preview_key = key
    local buffer = Buffer()
    buffer.disable_language_services = true
    buffer.disable_gitdiff_highlight = true
    buffer:replace_snapshot(shown.text)
    if shown.language then buffer:set_language_mode(shown.language, { reason = "Fuzzy Searcher preview" }) end
    buffer.read_only = true
    buffer.read_only_reason = "Fuzzy Searcher previews are read-only"
    picker.preview_view = preview_text_view.new(buffer)
  end
  local view = picker.preview_view
  local px, py, pw, ph = picker:preview_bounds()
  view.position.x, view.position.y = px, py
  view.size.x, view.size.y = math.max(0, pw), math.max(0, ph)
  if shown.line and picker.preview_target_line ~= shown.line then
    local line = common.clamp(shown.line, 1, #view.buffer.lines)
    local col1, col2 = shown.col or 1, shown.col2 or shown.col or 1
    view:with_selection_state(function()
      view.buffer:clear_search_selections()
      view.buffer:add_search_selection(line, col1, line, col2)
      view.preview_search_ranges = { { line, col1, line, col2 } }
      view.buffer:set_selection(line, col1, line, col2)
    end)
    view:scroll_to_line(line, false, false)
    picker.preview_target_line = shown.line
  end
  if view.restore_preview_search_ranges then view:restore_preview_search_ranges() end
  view:update()
  return view
end

return item_rows
