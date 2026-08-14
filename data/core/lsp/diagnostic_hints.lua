local core = require "core"
local style = require "core.style"
local TextView = require "core.textview"
local diagnostic_markers = require "core.lsp.diagnostic_markers"

local diagnostic_hints = {}

local cache = setmetatable({}, { __mode = "k" })

local function buffer_change_id(buffer)
  if buffer and buffer.get_change_id then return buffer:get_change_id() end
  return nil
end

local function visible_severity(severity)
  severity = tonumber(severity)
  return severity == 1 or severity == 2
end

local function severity_color(severity)
  severity = tonumber(severity)
  if severity == 1 then return style.error or style.line_hint end
  if severity == 2 then return style.warn or style.error or style.line_hint end
  return style.line_hint
end

local function diagnostic_message(diagnostic)
  local message = diagnostic and diagnostic.message
  if message == nil or tostring(message) == "" then
    message = diagnostic and (diagnostic.code or diagnostic.source)
  end
  if message == nil or tostring(message) == "" then message = "LSP diagnostic" end
  return tostring(message):gsub("[\r\n]+", " ")
end

local function should_replace(existing, item, severity)
  if not existing then return true end
  if severity ~= existing.severity then return severity < existing.severity end
  if item.col1 ~= existing.col1 then return item.col1 < existing.col1 end
  return diagnostic_message(item.diagnostic) < diagnostic_message(existing.diagnostic)
end

local function build_line_hints(buffer)
  local by_line = {}
  for _, item in ipairs(diagnostic_markers.visual_buffer_items(buffer)) do
    local diagnostic = item.diagnostic or {}
    local severity = tonumber(diagnostic.severity)
    if visible_severity(severity) and item.line1 then
      local existing = by_line[item.line1]
      if should_replace(existing, item, severity) then
        by_line[item.line1] = {
          severity = severity,
          col1 = item.col1 or 1,
          diagnostic = diagnostic,
          hint = {
            text = diagnostic_message(diagnostic),
            severity = severity,
          },
        }
      end
    end
  end
  return by_line
end

local function cached_line_hints(buffer)
  if not buffer then return {} end
  local generation = diagnostic_markers.generation and diagnostic_markers.generation() or 0
  local change_id = buffer_change_id(buffer)
  local entry = cache[buffer]
  if not entry or entry.generation ~= generation or entry.change_id ~= change_id then
    entry = {
      generation = generation,
      change_id = change_id,
      by_line = build_line_hints(buffer),
    }
    cache[buffer] = entry
  end
  return entry.by_line
end

function diagnostic_hints.get_line_hint(buffer, line)
  local entry = cached_line_hints(buffer)[line]
  if not entry or not entry.hint then return nil end
  return {
    text = entry.hint.text,
    color = severity_color(entry.hint.severity),
    placement = "after_line_buffer_text",
    gap_spaces = 4,
    truncate = "right",
  }
end

local function append_hint(view, base_hint, diagnostic_hint)
  if not diagnostic_hint then return base_hint end
  if not base_hint then return diagnostic_hint end

  local segments = view:normalize_line_hint(base_hint) or {}
  if #segments == 0 then return diagnostic_hint end
  segments[#segments + 1] = {
    text = "   ",
    font = view:get_font(),
    color = style.line_hint,
  }
  segments[#segments + 1] = diagnostic_hint
  segments.placement = diagnostic_hint.placement
  segments.gap = diagnostic_hint.gap
  segments.gap_spaces = diagnostic_hint.gap_spaces
  segments.truncate = diagnostic_hint.truncate
  return segments
end

function diagnostic_hints.install()
  TextView.__lsp_diagnostic_hints_module = diagnostic_hints
  if TextView.__lsp_diagnostic_hints_installed then return false end
  local base_get_line_hint = TextView.get_line_hint
  TextView.__lsp_diagnostic_hints_installed = true
  TextView.__lsp_diagnostic_hints_base_get_line_hint = base_get_line_hint

  function TextView:get_line_hint(line)
    local base_hint = base_get_line_hint(self, line)
    local module = TextView.__lsp_diagnostic_hints_module or diagnostic_hints
    local diagnostic_hint = module.get_line_hint(self.buffer, line)
    return append_hint(self, base_hint, diagnostic_hint)
  end

  if core and core.log_quiet then
    core.log_quiet("LSP diagnostic Line Hints installed")
  end
  return true
end

diagnostic_hints.install()

return diagnostic_hints
