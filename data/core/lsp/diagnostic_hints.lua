local core = require "core"
local style = require "core.style"
local DocView = require "core.docview"
local diagnostic_markers = require "core.lsp.diagnostic_markers"

local diagnostic_hints = {}

local cache = setmetatable({}, { __mode = "k" })

local function doc_change_id(doc)
  if doc and doc.get_change_id then return doc:get_change_id() end
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

local function build_line_hints(doc)
  local by_line = {}
  for _, item in ipairs(diagnostic_markers.visual_document_items(doc)) do
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

local function cached_line_hints(doc)
  if not doc then return {} end
  local generation = diagnostic_markers.generation and diagnostic_markers.generation() or 0
  local change_id = doc_change_id(doc)
  local entry = cache[doc]
  if not entry or entry.generation ~= generation or entry.change_id ~= change_id then
    entry = {
      generation = generation,
      change_id = change_id,
      by_line = build_line_hints(doc),
    }
    cache[doc] = entry
  end
  return entry.by_line
end

function diagnostic_hints.get_line_hint(doc, line)
  local entry = cached_line_hints(doc)[line]
  if not entry or not entry.hint then return nil end
  return {
    text = entry.hint.text,
    color = severity_color(entry.hint.severity),
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
  return segments
end

function diagnostic_hints.install()
  DocView.__lsp_diagnostic_hints_module = diagnostic_hints
  if DocView.__lsp_diagnostic_hints_installed then return false end
  local base_get_line_hint = DocView.get_line_hint
  DocView.__lsp_diagnostic_hints_installed = true
  DocView.__lsp_diagnostic_hints_base_get_line_hint = base_get_line_hint

  function DocView:get_line_hint(line)
    local base_hint = base_get_line_hint(self, line)
    local module = DocView.__lsp_diagnostic_hints_module or diagnostic_hints
    local diagnostic_hint = module.get_line_hint(self.doc, line)
    return append_hint(self, base_hint, diagnostic_hint)
  end

  if core and core.log_quiet then
    core.log_quiet("LSP diagnostic Line Hints installed")
  end
  return true
end

diagnostic_hints.install()

return diagnostic_hints
