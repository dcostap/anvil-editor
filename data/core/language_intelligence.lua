local core = require "core"

-- First-party language-intelligence provider registry.
--
-- This module is intentionally provider-oriented so editor commands can ask for
-- capabilities instead of hard-coding Tree-sitter or a future LSP client.
-- Precedence rules:
--   * Providers with higher `priority` are tried first.
--   * Tree-sitter registers as a syntactic/current-document fallback provider.
--   * Future LSP providers should use a higher priority for semantic outline,
--     definition/reference, navigation, diagnostics, and similar features.
--   * Tree-sitter highlighting remains the base syntax token provider; future
--     semantic tokens can overlay/replace it without removing the regex/native
--     tokenizer fallback in Highlighter.
--   * If no provider can answer, callers get nil/false/{} and should keep their
--     existing no-op or tokenizer fallback behavior.

local intelligence = {}

local providers = {}
local provider_order = {}

local function sort_providers()
  table.sort(provider_order, function(a, b)
    local pa, pb = providers[a], providers[b]
    local aprio = pa and pa.priority or 0
    local bprio = pb and pb.priority or 0
    if aprio ~= bprio then return aprio > bprio end
    return tostring(a) < tostring(b)
  end)
end

local function has_feature(provider, feature)
  if not provider then return false end
  if provider.features and provider.features[feature] == false then return false end
  return type(provider[feature]) == "function"
end

function intelligence.register_provider(provider)
  assert(type(provider) == "table", "language intelligence provider must be a table")
  assert(type(provider.id) == "string" and provider.id ~= "", "language intelligence provider needs an id")
  local exists = providers[provider.id] ~= nil
  providers[provider.id] = provider
  if not exists then provider_order[#provider_order + 1] = provider.id end
  sort_providers()
  if core and core.log_quiet then
    core.log_quiet("Language intelligence: registered provider %s priority=%s", provider.id, tostring(provider.priority or 0))
  end
  return provider
end

function intelligence.unregister_provider(id)
  providers[id] = nil
  for i = #provider_order, 1, -1 do
    if provider_order[i] == id then table.remove(provider_order, i) end
  end
end

function intelligence.get_provider(id)
  return providers[id]
end

function intelligence.providers_for(feature, doc)
  local result = {}
  for _, id in ipairs(provider_order) do
    local provider = providers[id]
    if has_feature(provider, feature) and (not provider.is_available or provider.is_available(doc, feature)) then
      result[#result + 1] = provider
    end
  end
  return result
end

function intelligence.without_provider(id, fn, ...)
  local provider = providers[id]
  if not provider then return fn(...) end
  intelligence.unregister_provider(id)
  local args = { n = select("#", ...), ... }
  local result = { pcall(function()
    return fn(table.unpack(args, 1, args.n))
  end) }
  intelligence.register_provider(provider)
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2)
end

local function first_value(feature, empty_value, doc, ...)
  local saw_provider = false
  local last_reason = "no-provider"
  for _, provider in ipairs(intelligence.providers_for(feature, doc)) do
    saw_provider = true
    local value, reason = provider[feature](doc, ...)
    if value and (type(value) ~= "table" or #value > 0 or next(value) ~= nil) then
      return value, reason, provider.id
    end
    last_reason = reason or last_reason
  end
  return empty_value, saw_provider and last_reason or "no-provider"
end

local function first_bool(feature, doc, ...)
  local saw_provider = false
  local last_reason = "no-provider"
  for _, provider in ipairs(intelligence.providers_for(feature, doc)) do
    saw_provider = true
    local ok, reason = provider[feature](doc, ...)
    if ok then return true, nil, provider.id end
    last_reason = reason or last_reason
  end
  return false, saw_provider and last_reason or "no-provider"
end

function intelligence.render_tokens(doc, line_idx, opts)
  return first_value("render_tokens", nil, doc, line_idx, opts)
end

function intelligence.invalidate_render_cache(doc, first_line, last_line)
  for _, provider in ipairs(intelligence.providers_for("invalidate_render_cache", doc)) do
    provider.invalidate_render_cache(doc, first_line, last_line)
  end
end

function intelligence.document_outline(doc, opts)
  return first_value("document_outline", {}, doc, opts)
end

function intelligence.current_document_outline(opts)
  local view = core.active_view
  return intelligence.document_outline(view and view.doc, opts)
end

function intelligence.node_ranges(doc, line1, col1, line2, col2, opts)
  return first_value("node_ranges", {}, doc, line1, col1, line2, col2, opts)
end

function intelligence.current_node_ranges(opts)
  local view = core.active_view
  return intelligence.node_ranges(view and view.doc, nil, nil, nil, nil, opts)
end

function intelligence.expand_selection(doc)
  return first_bool("expand_selection", doc)
end

function intelligence.shrink_selection(doc)
  return first_bool("shrink_selection", doc)
end

function intelligence.enclosing_symbol(doc, line1, col1, line2, col2, opts)
  return first_value("enclosing_symbol", nil, doc, line1, col1, line2, col2, opts)
end

function intelligence.next_symbol(doc, line, col, opts)
  return first_value("next_symbol", nil, doc, line, col, opts)
end

function intelligence.previous_symbol(doc, line, col, opts)
  return first_value("previous_symbol", nil, doc, line, col, opts)
end

function intelligence.goto_enclosing_symbol(doc)
  return first_bool("goto_enclosing_symbol", doc)
end

function intelligence.goto_next_symbol(doc)
  return first_bool("goto_next_symbol", doc)
end

function intelligence.goto_previous_symbol(doc)
  return first_bool("goto_previous_symbol", doc)
end

function intelligence.local_definition(doc, line1, col1, line2, col2, opts)
  return first_value("local_definition", nil, doc, line1, col1, line2, col2, opts)
end

function intelligence.local_declaration(doc, line1, col1, line2, col2, opts)
  return first_value("local_declaration", nil, doc, line1, col1, line2, col2, opts)
end

function intelligence.local_references(doc, line1, col1, line2, col2, opts)
  return first_value("local_references", {}, doc, line1, col1, line2, col2, opts)
end

function intelligence.goto_local_definition(doc)
  return first_bool("goto_local_definition", doc)
end

function intelligence.goto_local_declaration(doc)
  return first_bool("goto_local_declaration", doc)
end

function intelligence.select_local_references(doc)
  return first_bool("select_local_references", doc)
end

return intelligence
