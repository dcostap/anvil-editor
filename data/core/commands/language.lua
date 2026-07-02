local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local intelligence = require "core.language_intelligence"
local lsp_position = require "core.lsp.position"

local language = {}

local DEFAULT_NAVIGATION_TIMEOUT = 10.0
local NAVIGATION_POLL_SECONDS = 0.03

local function navigation_timeout(opts)
  opts = opts or {}
  if opts.timeout then return opts.timeout end
  local lsp_cfg = type(config.lsp) == "table" and config.lsp or nil
  return tonumber(lsp_cfg and lsp_cfg.navigation_timeout) or DEFAULT_NAVIGATION_TIMEOUT
end

local function is_doc_view(value)
  return type(value) == "table" and value.doc ~= nil
end

local function doc_view_predicate(value)
  local view = is_doc_view(value) and value or core.active_view
  return is_doc_view(view), view
end

local function quiet_log(...)
  if core.log_quiet then core.log_quiet(...) end
end

local function visible_log(...)
  if core.log then core.log(...) end
end

local function symbol_text_at_doc_selection(doc)
  if not doc then return "symbol" end
  local line1, col1, line2, col2 = doc:get_selection(true)
  local selected = doc:get_text(line1, col1, line2, col2)
  if selected and selected:match("^" .. doc:get_symbol_pattern() .. "$") then return selected end
  local line, col = doc:get_selection()
  local text = doc.lines[line] or ""
  local pattern = doc:get_symbol_pattern()
  local best
  for s, value in text:gmatch("()(" .. pattern .. ")") do
    local e = s + #value
    if col >= s and col <= e then
      best = value
      break
    end
  end
  return best
end

local function normalize_path(path)
  return path and common.normalize_path(path) or nil
end

local function result_path(result)
  return normalize_path(result and (result.path or (result.uri and require("core.lsp.uri").uri_to_path(result.uri))))
end

local function result_doc_range(view, result)
  local doc = view and view.doc
  local range = result.selection_range or result.range
  if range then return range end
  local lsp_range = result.lsp_selection_range or result.lsp_range
  if doc and lsp_range then
    return lsp_position.range_lsp_to_doc(doc, lsp_range, result.position_encoding or "utf-16")
  end
end

local function navigation_history()
  return core.navigation_history or package.loaded["plugins.navigation_history"]
end

local function open_location(result, opts)
  opts = opts or {}
  if not result then return false, "no result" end
  local history = navigation_history()
  local navigation_anchor = opts.navigation_anchor or (history and history.capture_current_place())

  if result.start_line then
    local view = opts.view or core.active_view
    local doc = view and view.doc
    if doc then
      if view.expand_folds_covering_range then
        view:expand_folds_covering_range(result.start_line, result.start_col, result.end_line, result.end_col, "language-location")
      end
      doc:set_selection(result.start_line, result.start_col, result.end_line, result.end_col)
      if history then history.record_place(navigation_anchor, { reason = "language-location" }) end
      return true
    end
  end

  local path = result_path(result)
  if not path then return false, "location has no path" end
  local target_side = opts.side == true
  local view
  if target_side then
    local sidepanel = require "core.sidepanel"
    view = sidepanel.open_path_in_side(path, { focus = true, restore_focus = opts.view })
  else
    view = core.open_file(path)
  end
  if not view or not view.doc then return false, "failed to open target" end
  local range = result_doc_range(view, result)
  if range then
    if view.expand_folds_covering_range then view:expand_folds_covering_range(range.line1, range.col1, range.line2, range.col2, "language-location") end
    view.doc:set_selection(range.line1, range.col1, range.line2, range.col2)
  elseif result.line and result.col then
    local line2, col2 = result.line2 or result.line, result.col2 or result.col
    if view.expand_folds_covering_range then
      view:expand_folds_covering_range(result.line, result.col, line2, col2, "language-location")
    elseif view.expand_folds_at_line then
      view:expand_folds_at_line(result.line, "language-location")
    end
    view.doc:set_selection(result.line, result.col, line2, col2)
  end
  if history then history.record_place(navigation_anchor, { reason = "language-location" }) end
  return true
end

local function lsp_result_to_picker_item(result, symbol)
  local path = result_path(result)
  if not path then return nil end
  local line, col, line2, col2 = 1, 1, nil, nil
  local range = result.selection_range or result.range
  if range then
    line, col = range.line1, range.col1
    line2, col2 = range.line2, range.col2
  elseif result.lsp_selection_range or result.lsp_range then
    local lsp_range = result.lsp_selection_range or result.lsp_range
    line = (lsp_range.start and lsp_range.start.line or 0) + 1
    col = (lsp_range.start and lsp_range.start.character or 0) + 1
    line2 = (lsp_range["end"] and lsp_range["end"].line or (line - 1)) + 1
    col2 = (lsp_range["end"] and lsp_range["end"].character or (col - 1)) + 1
  elseif result.line and result.col then
    line, col = result.line, result.col
    line2, col2 = result.line2, result.col2
  end
  local text = ""
  local fh = io.open(path, "rb")
  if fh then
    for i = 1, line do
      text = fh:read("*l") or ""
      if i == line then break end
    end
    fh:close()
  end
  local rel = path
  local root = core.root_project and core.root_project()
  if root and root.path and common.path_belongs_to(path, root.path) then
    rel = common.relative_path(root.path, path):gsub("\\", "/")
  end
  return {
    kind = "grep",
    file = path,
    line = line,
    col = col,
    text = text,
    exact = true,
    grep_query = symbol or "",
    content_selection_span = col2 and { col, math.max(col, col2 - 1) } or nil,
    content_match_start = col,
    label = string.format("%s:%d:%d", rel, line, col),
    language_location = result,
  }
end

local function tree_sitter_refs_to_picker_item(doc, item, symbol)
  local path = doc and doc.abs_filename or doc and doc.filename
  if not path then return nil end
  local text = (doc.lines and doc.lines[item.start_line] or "") or ""
  local root = core.root_project and core.root_project()
  local rel = path
  if root and root.path and common.path_belongs_to(path, root.path) then
    rel = common.relative_path(root.path, path):gsub("\\", "/")
  end
  return {
    kind = "grep",
    file = path,
    line = item.start_line,
    col = item.start_col,
    text = text:gsub("\n$", ""),
    exact = true,
    grep_query = symbol or "",
    content_selection_span = { item.start_col, math.max(item.start_col, item.end_col - 1) },
    content_match_start = item.start_col,
    label = string.format("%s:%d:%d", rel, item.start_line, item.start_col),
    language_location = item,
  }
end

local function show_locations_picker(title, status, items)
  local ok, fuzzy = pcall(require, "plugins.fuzzy_searcher")
  if not ok or not fuzzy or not fuzzy.open_static_results then
    visible_log("%s: %d results", title, #(items or {}))
    return nil
  end
  return fuzzy.open_static_results(title, items or {}, { status = status or title })
end

local function doc_language_id(doc)
  return doc and doc.treesitter and doc.treesitter.language_id
end

local function tree_sitter_symbol_location(symbol)
  if type(symbol) ~= "table" then return nil end
  local name_start = symbol.name_range and symbol.name_range.start
  local name_end = symbol.name_range and symbol.name_range["end"]
  local line = name_start and name_start.line or symbol.start_line
  local col = name_start and name_start.col or symbol.start_col
  if not line or not col then return nil end
  local line2 = name_end and name_end.line or symbol.end_line or line
  local col2 = name_end and name_end.col or symbol.end_col or col
  return {
    path = symbol.path or symbol.abs_filename,
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    selection_range = { line1 = line, col1 = col, line2 = line2, col2 = col2 },
    name = symbol.name,
    kind = symbol.kind,
    language_id = symbol.language_id,
  }
end

local function exact_workspace_symbol_locations(symbol_index, symbol, doc)
  local results, reason, status = symbol_index.workspace_symbols(symbol, {
    limit = 200,
    allow_stale = true,
  })
  if status ~= "fresh" and status ~= "stale" then return nil, reason, nil, status end

  local exact = {}
  local current_language = doc_language_id(doc)
  for _, candidate in ipairs(results or {}) do
    if candidate.name == symbol then
      local location = tree_sitter_symbol_location(candidate)
      if location then exact[#exact + 1] = location end
    end
  end

  if current_language then
    local same_language = {}
    for _, location in ipairs(exact) do
      if location.language_id == current_language then same_language[#same_language + 1] = location end
    end
    if #same_language > 0 then exact = same_language end
  end

  if status == "stale" and reason == "indexing" then
    return nil, reason, nil, "pending"
  end
  return exact, reason, nil, status
end

local function request_until_ready(request_fn, on_ready, on_unavailable, opts)
  opts = opts or {}
  local deadline = system.get_time() + navigation_timeout(opts)
  local function step()
    local results, reason, _provider, status = request_fn()
    if status == "fresh" or status == "stale" then
      on_ready(results or {}, status)
      return true
    end
    if status == "unavailable" then
      if on_unavailable then on_unavailable(reason) end
      return true
    end
    if system.get_time() >= deadline then
      if on_unavailable then on_unavailable(reason or "timeout") end
      return true
    end
    return false
  end
  if step() then return end
  core.add_thread(function()
    while not step() do coroutine.yield(NAVIGATION_POLL_SECONDS) end
  end)
end

function language.goto_declaration(view)
  view = view or core.active_view
  local doc = view and view.doc
  if not doc then return false, "no active document" end
  local symbol = symbol_text_at_doc_selection(doc)
  if not symbol then return false, "no symbol at caret" end
  local history = navigation_history()
  local navigation_anchor = history and history.capture_current_place()
  local line, col = doc:get_selection()

  local function show_no_declaration(reason)
    visible_log("No declaration found for %s", symbol)
    quiet_log("Language declaration unavailable for %s: %s", symbol, tostring(reason))
  end

  local function open_declaration_results(results)
    if #results == 1 then
      open_location(results[1], { view = view, navigation_anchor = navigation_anchor })
    elseif #results > 1 then
      local items = {}
      for _, result in ipairs(results) do
        local item = lsp_result_to_picker_item(result, symbol)
        if item then items[#items + 1] = item end
      end
      show_locations_picker("Declarations: " .. symbol, string.format("%d declarations", #items), items)
    end
  end

  local function try_workspace_declaration(reason)
    local ok, symbol_index = pcall(require, "core.treesitter.symbol_index")
    if not ok or not symbol_index or not symbol_index.workspace_symbols then
      show_no_declaration(reason)
      return
    end
    request_until_ready(function()
      return exact_workspace_symbol_locations(symbol_index, symbol, doc)
    end, function(results)
      if #results > 0 then
        open_declaration_results(results)
      else
        show_no_declaration(reason)
      end
    end, function(workspace_reason)
      show_no_declaration(workspace_reason or reason)
    end)
  end

  local function try_local_declaration(reason)
    local fallback, fallback_reason = intelligence.local_declaration(doc, line, col)
    if fallback then
      open_location(fallback, { view = view, navigation_anchor = navigation_anchor })
    else
      try_workspace_declaration(fallback_reason or reason)
    end
  end

  request_until_ready(function()
    return intelligence.declarations(doc, line, col)
  end, function(results)
    if #results > 0 then
      open_declaration_results(results)
    else
      try_local_declaration("no-declaration-results")
    end
  end, function(reason)
    try_local_declaration(reason)
  end)
  return true
end

function language.show_references(view)
  view = view or core.active_view
  local doc = view and view.doc
  if not doc then return false, "no active document" end
  local symbol = symbol_text_at_doc_selection(doc)
  if not symbol then return false, "no symbol at caret" end
  local picker = show_locations_picker("References: " .. symbol, "Loading references…", {})
  local line, col = doc:get_selection()
  request_until_ready(function()
    return intelligence.references(doc, line, col, nil, nil, { include_declaration = false })
  end, function(results)
    local items = {}
    for _, result in ipairs(results or {}) do
      local item = lsp_result_to_picker_item(result, symbol)
      if item then items[#items + 1] = item end
    end
    if #items == 0 then
      local refs = intelligence.local_references(doc, line, col)
      for _, ref in ipairs(refs or {}) do
        local item = tree_sitter_refs_to_picker_item(doc, ref, symbol)
        if item then items[#items + 1] = item end
      end
    end
    local status = #items == 1 and "1 reference" or string.format("%d references", #items)
    if picker and picker.set_static_results then
      picker:set_static_results(items, status)
    else
      show_locations_picker("References: " .. symbol, status, items)
    end
  end, function(reason)
    local items = {}
    local refs = intelligence.local_references(doc, line, col)
    for _, ref in ipairs(refs or {}) do
      local item = tree_sitter_refs_to_picker_item(doc, ref, symbol)
      if item then items[#items + 1] = item end
    end
    local status = #items > 0 and (#items == 1 and "1 local reference" or string.format("%d local references", #items))
      or "No references found"
    if picker and picker.set_static_results then picker:set_static_results(items, status) end
    quiet_log("Language references unavailable for %s: %s", symbol, tostring(reason))
  end)
  return true
end

local function symbol_doc_view_predicate(value)
  local ok, view = doc_view_predicate(value)
  if not ok or view.command_output_view then return false end
  return symbol_text_at_doc_selection(view.doc) ~= nil, view
end

command.add(symbol_doc_view_predicate, {
  ["language:go-to-declaration"] = function(view)
    return language.goto_declaration(view)
  end,
  ["language:show-references"] = function(view)
    return language.show_references(view)
  end,
})

keymap.add({
  ["alt+r"] = "language:go-to-declaration",
  ["alt+shift+r"] = "language:show-references",
}, true)

return language
