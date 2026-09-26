local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local intelligence = require "core.language_intelligence"
local language_mode = require "core.language_mode"
local navigation_history = require "core.navigation_history"

local language = {}

local DEFAULT_NAVIGATION_TIMEOUT = 10.0
local NAVIGATION_POLL_SECONDS = 0.03

local function navigation_timeout(opts)
  opts = opts or {}
  if opts.timeout then return opts.timeout end
  local lsp_cfg = type(config.lsp) == "table" and config.lsp or nil
  return tonumber(lsp_cfg and lsp_cfg.navigation_timeout) or DEFAULT_NAVIGATION_TIMEOUT
end

local function is_buffer_view(value)
  return type(value) == "table" and value.buffer ~= nil
end

local function buffer_view_predicate(value)
  local view = is_buffer_view(value) and value or core.active_view
  return is_buffer_view(view), view
end

local function language_mode_suggestions(text)
  local choices = language_mode.choices()
  if text == "" then return choices end
  local by_name = {}
  local names = {}
  for _, item in ipairs(choices) do
    names[#names + 1] = item.text
    by_name[item.text] = item
  end
  local results = {}
  for _, name in ipairs(common.fuzzy_match(names, text)) do results[#results + 1] = by_name[name] end
  return results
end

local function persist_language_mode(buffer)
  if buffer.intellij_untitled then
    local ok, recovery = pcall(require, "plugins.untitled_recovery")
    if ok and recovery.update_buffer_metadata then recovery.update_buffer_metadata(buffer, "Language Mode change") end
  end
  if core.save_workspace then core.save_workspace() end
end

local function set_language_mode_command(view)
  local buffer = view.buffer
  core.global_prompt_bar:enter("Language Mode", {
    text = buffer.language_mode_override or "Automatic",
    select_text = true,
    suggest = language_mode_suggestions,
    validate = function(text, item)
      return item ~= nil or language_mode.find_choice(text) ~= nil
    end,
    submit = function(text, item)
      item = item or language_mode.find_choice(text)
      local changed, err = buffer:set_language_mode(item and item.mode, { reason = "language-mode-command" })
      if err then
        core.warn("%s", err)
        return
      end
      if changed then persist_language_mode(buffer) end
    end,
  })
end

local function quiet_log(...)
  if core.log_quiet then core.log_quiet(...) end
end

local function visible_log(...)
  if core.log then core.log(...) end
end

local function symbol_text_at_buffer_selection(buffer)
  if not buffer then return "symbol" end
  local line1, col1, line2, col2 = buffer:get_selection(true)
  local selected = buffer:get_text(line1, col1, line2, col2)
  if selected and selected:match("^" .. buffer:get_symbol_pattern() .. "$") then return selected end
  local line, col = buffer:get_selection()
  local text = buffer.lines[line] or ""
  local pattern = buffer:get_symbol_pattern()
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

local function tree_sitter_refs_to_picker_item(buffer, item, symbol)
  local path = item and item.path or buffer and buffer.abs_filename or buffer and buffer.filename
  if not path or not item then return nil end
  local text = item.line_text or ((buffer and buffer.lines and buffer.lines[item.start_line] or "") or "")
  local root = core.root_project and core.root_project()
  local rel = item.relpath or path
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

local function set_reference_picker_results(picker, symbol, items, status)
  if picker and picker.set_static_results then
    picker:set_static_results(items, status)
  else
    show_locations_picker("References: " .. symbol, status, items)
  end
end

local function local_reference_items(buffer, line, col, symbol)
  local items = {}
  local refs = intelligence.local_references(buffer, line, col)
  for _, ref in ipairs(refs or {}) do
    local item = tree_sitter_refs_to_picker_item(buffer, ref, symbol)
    if item then items[#items + 1] = item end
  end
  return items
end

local function show_local_reference_fallback(picker, buffer, line, col, symbol, reason)
  local items = local_reference_items(buffer, line, col, symbol)
  local status = #items > 0 and (#items == 1 and "1 local reference" or string.format("%d local references", #items))
    or "No references found"
  set_reference_picker_results(picker, symbol, items, status)
  if reason then quiet_log("Language references unavailable for %s: %s", symbol, tostring(reason)) end
end

local tree_sitter_reference_request_generation = 0

local function tree_sitter_reference_items(results, symbol)
  local items = {}
  for _, ref in ipairs(results or {}) do
    local item = tree_sitter_refs_to_picker_item(nil, ref, symbol)
    if item then items[#items + 1] = item end
  end
  return items
end

local function reference_picker_alive(picker)
  if not picker then return true end
  if picker.is_visible and not picker:is_visible() then return false end
  return true
end

local function show_tree_sitter_workspace_reference_fallback(picker, buffer, line, col, symbol, reason)
  local ok, symbol_index = pcall(require, "core.treesitter.symbol_index")
  local workspace_usages = ok and symbol_index and (symbol_index.workspace_usages or symbol_index.workspace_references)
  if not workspace_usages then
    show_local_reference_fallback(picker, buffer, line, col, symbol, reason)
    return
  end

  tree_sitter_reference_request_generation = tree_sitter_reference_request_generation + 1
  local request_generation = tree_sitter_reference_request_generation

  core.add_thread(function()
    local results, workspace_reason, status, meta
    local async_request
    if symbol_index.workspace_usages_async then
      async_request, workspace_reason, status, meta = symbol_index.workspace_usages_async(symbol, {
        include_declaration = false,
        allow_stale = true,
        limit = 1000,
      })
      if async_request then
        while not async_request.done and request_generation == tree_sitter_reference_request_generation and reference_picker_alive(picker) do
          coroutine.yield(0.03)
        end
        if request_generation ~= tree_sitter_reference_request_generation or not reference_picker_alive(picker) then
          async_request:cancel()
          return
        end
        if async_request.done and (async_request.status == "fresh" or async_request.status == "stale") then
          results = async_request.results
          workspace_reason = async_request.reason
          status = async_request.status
          meta = async_request.meta or meta
        else
          if async_request.cancel then async_request:cancel() end
          workspace_reason = async_request.reason or workspace_reason
          status = async_request.status or status
        end
      end
    end

    if status ~= "fresh" and status ~= "stale" then
      results, workspace_reason, status, meta = workspace_usages(symbol, {
        include_declaration = false,
        allow_stale = true,
        limit = 1000,
      })
    end
    while status ~= "fresh" and request_generation == tree_sitter_reference_request_generation and reference_picker_alive(picker) do
      if status == "stale" then
        local items = tree_sitter_reference_items(results, symbol)
        if #items > 0 then
          local text = #items == 1 and "1 Project usage" or string.format("%d Project usages", #items)
          set_reference_picker_results(picker, symbol, items, "Tree-sitter: " .. text .. " (indexing)")
        end
      elseif meta and meta.index and picker and picker.set_static_results then
        local index = meta.index
        picker:set_static_results({}, string.format(
          "Tree-sitter: indexing Project usages… %d/%d files scanned",
          tonumber(index.files_scanned) or 0,
          tonumber(index.files_total) or 0
        ))
      elseif status == "unavailable" then
        show_local_reference_fallback(picker, buffer, line, col, symbol, workspace_reason or reason or "workspace-usages-unavailable")
        return
      end
      coroutine.yield(0.05)
      results, workspace_reason, status, meta = workspace_usages(symbol, {
        include_declaration = false,
        allow_stale = true,
        limit = 1000,
      })
    end

    if request_generation ~= tree_sitter_reference_request_generation or not reference_picker_alive(picker) then return end

    local items = tree_sitter_reference_items(results, symbol)
    local truncated = meta and meta.usage_truncated
    if #items > 0 then
      local text = #items == 1 and "1 Project usage" or string.format("%d Project usages", #items)
      local suffix = truncated and " (index truncated)" or ""
      set_reference_picker_results(picker, symbol, items, "Tree-sitter: " .. text .. suffix)
      return
    end
    if truncated then
      set_reference_picker_results(picker, symbol, {}, "Tree-sitter: no Project usages in indexed subset (index truncated)")
      return
    end
    show_local_reference_fallback(picker, buffer, line, col, symbol, reason or workspace_reason or "no-workspace-usages")
  end)
end

function language.show_references(view)
  view = view or core.active_view
  local buffer = view and view.buffer
  if not buffer then return false, "no active buffer" end
  local symbol = symbol_text_at_buffer_selection(buffer)
  if not symbol then return false, "no symbol at caret" end
  local picker = show_locations_picker("References: " .. symbol, "Loading references…", {})
  local line, col = buffer:get_selection()
  request_until_ready(function()
    return intelligence.references(buffer, line, col, nil, nil, { include_declaration = false })
  end, function(results)
    local items = {}
    for _, result in ipairs(results or {}) do
      local item = lsp_result_to_picker_item(result, symbol)
      if item then items[#items + 1] = item end
    end
    if #items == 0 then
      show_tree_sitter_workspace_reference_fallback(picker, buffer, line, col, symbol, "no-lsp-reference-results")
      return
    end
    local status = #items == 1 and "1 reference" or string.format("%d references", #items)
    set_reference_picker_results(picker, symbol, items, status)
  end, function(reason)
    show_tree_sitter_workspace_reference_fallback(picker, buffer, line, col, symbol, reason)
  end)
  return true
end

local function symbol_buffer_view_predicate(value)
  local ok, view = buffer_view_predicate(value)
  if not ok or view.command_output_view then return false end
  return symbol_text_at_buffer_selection(view.buffer) ~= nil, view
end

function language.symbol_at_view(view)
  if not view or view.context == "application" or view.command_output_view or not view.buffer
      or view.buffer.git_view_pane_read_only then return nil end
  return symbol_text_at_buffer_selection(view.buffer)
end

local function unique_local_definition(buffer, symbol, line, col)
  local definition = intelligence.local_definition(buffer, line, col)
  if not definition or definition.name ~= symbol or not definition.start_line or not definition.start_col
      or not definition.end_line or not definition.end_col then return nil end
  if definition.kind == "function" or definition.kind == "method" then
    local outline = intelligence.buffer_outline(buffer)
    local count, matches = 0, false
    for _, item in ipairs(outline) do
      if item.name == symbol and (item.kind == "function" or item.kind == "method") then
        count = count + 1
        local name = item.name_range and item.name_range.start
        if name and name.line == definition.start_line and name.col == definition.start_col then
          matches = true
        end
      end
    end
    if count ~= 1 or not matches then return nil end
  end
  return definition
end

function language.activate_symbol(view, opts)
  opts = opts or {}
  local symbol = language.symbol_at_view(view)
  if not symbol then return false end
  local buffer = view.buffer
  local line, col = buffer:get_selection()
  if not opts.placement then
    local definition = unique_local_definition(buffer, symbol, line, col)
    if definition and (definition.start_line ~= line or col < definition.start_col or col >= definition.end_col) then
      navigation_history.perform_jump_with_options(view, { departure = { prefer_incoming_state = true } }, function()
        buffer:set_selection(definition.start_line, definition.start_col, definition.end_line, definition.end_col)
        view:scroll_to_make_visible(definition.start_line, definition.start_col)
      end)
      quiet_log("Symbol activation: local definition %s at %d:%d", symbol, definition.start_line, definition.start_col)
      return true
    end
  end
  quiet_log("Symbol activation: Project Symbol Search for %s (no unique local definition)", symbol)
  return require("plugins.fuzzy_searcher").open_project_symbols(symbol, {
    source_view = view,
    case_sensitive = true,
  })
end

command.add(symbol_buffer_view_predicate, {
  ["editor:show_references"] = command.palette(function(view)
    return language.show_references(view)
  end),
})

command.add(buffer_view_predicate, {
  ["editor:set_language_mode"] = command.palette(set_language_mode_command),
})


return language
