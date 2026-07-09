local core = require "core"
local command = require "core.command"
local language_intelligence = require "core.language_intelligence"
local navigation_feedback = require "core.navigation_feedback"
local registry = require "core.treesitter.registry"
local ts_highlight = require "core.treesitter.highlight"
local ts_outline = require "core.treesitter.outline"
local ts_selection = require "core.treesitter.selection"
local ts_folding = require "core.treesitter.folding"
local ts_navigation = require "core.treesitter.navigation"
local ts_locals = require "core.treesitter.locals"
local ts_symbol_index = require "core.treesitter.symbol_index"
local Doc = require "core.doc"

local native_ok, native = nil, nil

local treesitter = {}
treesitter.registry = registry
treesitter.outline = ts_outline
treesitter.selection = ts_selection
treesitter.folding = ts_folding
treesitter.navigation = ts_navigation
treesitter.locals = ts_locals
treesitter.symbol_index = ts_symbol_index
treesitter.language_intelligence = language_intelligence
treesitter.enabled = true

local attached_docs = setmetatable({}, { __mode = "k" })
local compiled_query_cache = {}
local patched = false

local DEFAULT_PARSE_TIMEOUT_MS = 750

local complete_event_registered = false

local function ensure_native()
  if native_ok == nil then
    native_ok, native = pcall(require, "treesitter")
  end
  if not native_ok or not native then
    treesitter.enabled = false
    return nil
  end
  if not complete_event_registered and native.register_complete_event then
    local ok, err = native.register_complete_event()
    if not ok then error(err or "failed to register treesitter_complete event") end
    complete_event_registered = true
  end
  return native
end

local function log_quiet(...)
  if core and core.log_quiet then core.log_quiet(...) end
end

local function doc_name(doc)
  if doc and doc.get_name then return doc:get_name() end
  return tostring(doc)
end

local function first_bytes(doc, max_bytes)
  if not doc or not doc.lines then return "" end
  local out, total = {}, 0
  for i = 1, #doc.lines do
    local line = doc.lines[i]
    if total + #line > max_bytes then
      out[#out + 1] = line:sub(1, max_bytes - total)
      break
    end
    out[#out + 1] = line
    total = total + #line
    if total >= max_bytes then break end
  end
  return table.concat(out)
end

local function doc_path(doc)
  local path = doc and doc.abs_filename or doc and doc.filename
  if path and common and common.normalize_path then return common.normalize_path(path) end
  return path
end

local function doc_fingerprint(doc)
  if not doc or not doc.lines then return "0:0::" end
  local byte_len = 0
  for _, line in ipairs(doc.lines) do byte_len = byte_len + #line end
  return table.concat({ tostring(#doc.lines), tostring(byte_len), doc.lines[1] or "", doc.lines[#doc.lines] or "" }, "\0")
end

-- Avoid requiring core.common before core has finished bootstrap in unusual test loaders.
local common = require "core.common"

doc_path = function(doc)
  local path = doc and (doc.abs_filename or doc.filename)
  return path and common.normalize_path(path) or path
end

local function close_native(ts)
  if ts and ts.native then
    pcall(ts.native.close, ts.native)
  end
end

local function compile_queries(language)
  local queries = {}
  native = ensure_native()
  if not native then return queries end
  for kind, source in pairs(language.query_sources or {}) do
    local key = table.concat({ tostring(language.grammar), tostring(kind), tostring(source) }, "\0")
    local cached = compiled_query_cache[key]
    local query, err
    if cached ~= nil then
      query = cached or nil
      err = cached == false and "compile-failed" or nil
    else
      query, err = native.compile_query(language.grammar, kind, source)
      compiled_query_cache[key] = query or false
    end
    if query then
      queries[kind] = query
    else
      log_quiet(
        "Tree-sitter: disabled %s query for %s: %s",
        tostring(kind), tostring(language.id), tostring(err)
      )
    end
  end
  return queries
end

function treesitter.close_doc(doc)
  local ts = doc and doc.treesitter
  if not ts then return end
  ts_symbol_index.clear_open_document(doc, "close")
  close_native(ts)
  attached_docs[doc] = nil
  doc.treesitter = nil
end

local function disable_doc(doc, reason)
  treesitter.close_doc(doc)
  doc.treesitter = {
    status = "disabled",
    reason = reason,
    generation = 0,
    parse_generation = 0,
    tree_generation = 0,
    native = nil,
    queries = {},
    stale_renderable = false,
    stale_unrenderable = false,
  }
end

local function count_newlines(text)
  local count = 0
  for _ in tostring(text or ""):gmatch("\n") do count = count + 1 end
  return count
end

local function remap_stale_highlight_cache(ts, edit, line_count)
  if not edit or not ts.highlight_cache then return false end
  local old_count = math.max(1, (edit.line2 or edit.line1) - (edit.line1 or 1) + 1)
  local new_count = math.max(1, count_newlines(edit.text) + 1)
  local blanks = {}
  for i = 1, new_count do blanks[i] = false end
  common.splice(ts.highlight_cache, edit.line1 or 1, old_count, blanks)
  for i = line_count + 1, #ts.highlight_cache do ts.highlight_cache[i] = nil end
  return true
end

function treesitter.schedule_parse(doc, edit)
  local ts = doc and doc.treesitter
  if not ts or not ts.native or not doc.lines then return false end
  ts.snapshots_constructed = (ts.snapshots_constructed or 0) + 1
  ts.generation = (ts.generation or 0) + 1
  ts.parse_generation = ts.generation
  ts.status = "snapshotting"
  ts.reason = nil
  ts.last_poll_changed = false
  ts.scheduled_fingerprint = doc_fingerprint(doc)
  local remapped_stale_cache = edit and ts.stale_renderable and remap_stale_highlight_cache(ts, edit, #doc.lines)
  if not remapped_stale_cache then ts.highlight_cache = {} end
  ts.selection_history = {}
  ts.line_starts = nil
  ts.outline_line_starts = nil
  ts.selection_line_starts = nil
  ts.navigation_line_starts = nil
  ts.locals_line_starts = nil
  if doc.highlighter and doc.highlighter.invalidate_render_cache then
    if remapped_stale_cache then
      local changed_lines = math.max(1, count_newlines(edit.text) + 1)
      local last_line = math.min(#doc.lines, (edit.line1 or 1) + changed_lines)
      doc.highlighter:invalidate_render_cache(edit.line1 or 1, last_line)
    else
      doc.highlighter:invalidate_render_cache()
    end
  end
  local snapshot_bytes = 0
  for _, line in ipairs(doc.lines) do snapshot_bytes = snapshot_bytes + #line end
  local snapshot_started = system.get_time()
  local ok, err = ts.native:schedule_parse(doc.lines, ts.generation, edit)
  local snapshot_ms = (system.get_time() - snapshot_started) * 1000
  ts.snapshot_bytes = (ts.snapshot_bytes or 0) + snapshot_bytes
  ts.snapshot_ms = (ts.snapshot_ms or 0) + snapshot_ms
  ts.snapshot_max_ms = math.max(ts.snapshot_max_ms or 0, snapshot_ms)
  if not ok then
    ts.status = "failed"
    ts.reason = err or "schedule failed"
    log_quiet("Tree-sitter: failed to schedule %s generation=%d: %s", doc_name(doc), ts.generation, tostring(ts.reason))
    return false, err
  end
  local status = ts.native:status()
  ts.status = status or "queued"
  log_quiet("Tree-sitter: scheduled %s language=%s generation=%d edit=%s snapshot_bytes=%d snapshot_ms=%.3f constructed=%d coalesced=%d",
    doc_name(doc), tostring(ts.language_id), ts.generation, edit and "single" or "full", snapshot_bytes, snapshot_ms,
    ts.snapshots_constructed or 0, ts.snapshot_requests_coalesced or 0)
  return true
end

local function schedule_coalesced_parse(doc)
  local ts = doc and doc.treesitter
  if not ts or not ts.native then return false end
  ts.pending_parse_serial = (ts.pending_parse_serial or 0) + 1
  if ts.pending_parse_thread then
    ts.snapshot_requests_coalesced = (ts.snapshot_requests_coalesced or 0) + 1
    return true
  end
  ts.pending_parse_thread = true
  core.add_thread(function()
    coroutine.yield(0.015)
    local current = doc.treesitter
    if current ~= ts or not ts.native then return end
    ts.pending_parse_thread = false
    treesitter.schedule_parse(doc, nil)
  end)
  return true
end

function treesitter.attach_or_update_doc(doc, reason)
  if not doc then return nil end
  if doc.disable_treesitter or doc.disable_language_services then
    treesitter.close_doc(doc)
    return nil
  end
  if doc.binary then
    disable_doc(doc, "binary")
    log_quiet("Tree-sitter: disabled binary document %s", doc_name(doc))
    return doc.treesitter
  end

  local language = registry.get(doc_path(doc), first_bytes(doc, 512))
  if not language then
    treesitter.close_doc(doc)
    return nil
  end

  native = ensure_native()
  if not native or not native.has_language or not native.has_language(language.grammar) then
    treesitter.close_doc(doc)
    if native then
      log_quiet("Tree-sitter: disabling %s because grammar %s is unavailable", tostring(language.id), tostring(language.grammar))
    end
    return nil
  end

  local ts = doc.treesitter
  if ts and ts.native and ts.language_id == language.id and ts.grammar == language.grammar then
    if ts.scheduled_fingerprint ~= doc_fingerprint(doc) then
      treesitter.schedule_parse(doc, nil)
    end
    return ts
  end

  treesitter.close_doc(doc)
  local state, err = native.new_document_state(language.grammar, {
    parse_timeout_ms = language.parse_timeout_ms or DEFAULT_PARSE_TIMEOUT_MS,
  })
  if not state then
    log_quiet("Tree-sitter: failed to attach %s: %s", doc_name(doc), tostring(err))
    return nil
  end

  ts = {
    language_id = language.id,
    grammar = language.grammar,
    language = language,
    generation = 0,
    parse_generation = 0,
    tree_generation = 0,
    status = "idle",
    reason = nil,
    native = state,
    queries = compile_queries(language),
    highlight_cache = {},
    stale_renderable = false,
    stale_unrenderable = false,
    last_poll_changed = false,
    attached_reason = reason,
  }
  doc.treesitter = ts
  attached_docs[doc] = true
  if ts_symbol_index.remember_open_document then ts_symbol_index.remember_open_document(doc) end
  treesitter.schedule_parse(doc, nil)
  return ts
end

local function edit_for_transaction(doc, ts, transaction)
  if not transaction or not transaction.edits or #transaction.edits ~= 1 then return nil end
  if not ts or not ts.native or not ts.native:has_tree() or ts.status ~= "ready" then return nil end
  local edit = transaction.edits[1]
  return {
    line1 = edit.line1,
    col1 = edit.col1,
    line2 = edit.line2,
    col2 = edit.col2,
    start_offset = edit.start_offset,
    end_offset = edit.end_offset,
    text = edit.text or "",
  }
end

function treesitter.on_text_transaction(doc, transaction)
  local ts = doc and doc.treesitter
  if not ts or not ts.native or not transaction or not transaction.changed then return end

  ts.snapshot_requests = (ts.snapshot_requests or 0) + 1
  local edit = edit_for_transaction(doc, ts, transaction)
  if edit then
    ts.stale_renderable = true
    ts.stale_unrenderable = false
    ts.status = "stale"
    treesitter.schedule_parse(doc, edit)
  else
    ts.stale_renderable = false
    ts.stale_unrenderable = true
    ts.status = "stale"
    if ts.native.cancel then ts.native:cancel() end
    schedule_coalesced_parse(doc)
  end
end

function treesitter.poll_doc(doc)
  local ts = doc and doc.treesitter
  if not ts or not ts.native then return nil end
  local status, changed, discarded_stale, changed_ranges = ts.native:poll(ts.generation or 0)
  ts.status = status or ts.status
  ts.last_poll_changed = changed or false
  ts.last_discarded_stale = discarded_stale or false
  ts.tree_generation = ts.native:tree_generation()
  if ts.status == "ready" then
    ts.reason = nil
    ts.stale_renderable = false
    ts.stale_unrenderable = false
    if changed then ts_symbol_index.update_open_document(doc, "parse-ready") end
  else
    local native_status, reason = ts.native:status()
    ts.status = native_status or ts.status
    ts.reason = reason
  end
  if changed then
    local partial = ts.status == "ready" and type(changed_ranges) == "table"
    if partial then
      ts.highlight_cache = ts.highlight_cache or {}
      for _, range in ipairs(changed_ranges) do
        local first_line = math.max(1, (range.start_line or 1) - 1)
        local last_line = math.min(#doc.lines, math.max(first_line, (range.end_line or first_line) + 1))
        for line = first_line, last_line do ts.highlight_cache[line] = nil end
        if doc.highlighter and doc.highlighter.invalidate_render_cache then
          doc.highlighter:invalidate_render_cache(first_line, last_line)
        end
      end
    else
      ts.highlight_cache = {}
      if doc.highlighter and doc.highlighter.invalidate_render_cache then
        doc.highlighter:invalidate_render_cache()
      end
    end
    ts.selection_history = {}
    ts.line_starts = nil
    ts.outline_line_starts = nil
    ts.selection_line_starts = nil
    ts.navigation_line_starts = nil
    ts.locals_line_starts = nil
    ts.last_changed_ranges = changed_ranges
    core.redraw = true
    log_quiet("Tree-sitter: polled %s status=%s changed=%s stale=%s ranges=%d generation=%d tree_generation=%d",
      doc_name(doc), tostring(ts.status), tostring(changed), tostring(discarded_stale),
      type(changed_ranges) == "table" and #changed_ranges or 0, ts.generation or 0, ts.tree_generation or 0)
  elseif discarded_stale then
    log_quiet("Tree-sitter: discarded stale parse for %s generation=%d", doc_name(doc), ts.generation or 0)
  end
  return ts.status, changed, discarded_stale
end

function treesitter.poll_all()
  local any_changed = false
  for doc in pairs(attached_docs) do
    if doc.treesitter and doc.treesitter.native then
      local _, changed, discarded = treesitter.poll_doc(doc)
      any_changed = any_changed or changed or discarded
    else
      attached_docs[doc] = nil
    end
  end
  if any_changed then core.redraw = true end
  return any_changed
end

function treesitter.get_document_outline(doc, opts)
  return language_intelligence.document_outline(doc, opts)
end

function treesitter.get_current_document_outline(opts)
  return language_intelligence.current_document_outline(opts)
end

function treesitter.get_node_ranges(doc, line1, col1, line2, col2, opts)
  return language_intelligence.node_ranges(doc, line1, col1, line2, col2, opts)
end

function treesitter.get_current_node_ranges(opts)
  return language_intelligence.current_node_ranges(opts)
end

function treesitter.get_fold_target(doc, line1, col1, line2, col2, opts)
  return language_intelligence.fold_target(doc, line1, col1, line2, col2, opts)
end

function treesitter.expand_selection(doc)
  return language_intelligence.expand_selection(doc)
end

function treesitter.shrink_selection(doc)
  return language_intelligence.shrink_selection(doc)
end

function treesitter.get_enclosing_symbol(doc, line1, col1, line2, col2, opts)
  return language_intelligence.enclosing_symbol(doc, line1, col1, line2, col2, opts)
end

function treesitter.get_next_symbol(doc, line, col, opts)
  return language_intelligence.next_symbol(doc, line, col, opts)
end

function treesitter.get_previous_symbol(doc, line, col, opts)
  return language_intelligence.previous_symbol(doc, line, col, opts)
end

function treesitter.goto_enclosing_symbol(doc)
  return language_intelligence.goto_enclosing_symbol(doc)
end

function treesitter.goto_next_symbol(doc)
  return language_intelligence.goto_next_symbol(doc)
end

function treesitter.goto_previous_symbol(doc)
  return language_intelligence.goto_previous_symbol(doc)
end

function treesitter.get_local_definition(doc, line1, col1, line2, col2, opts)
  return language_intelligence.local_definition(doc, line1, col1, line2, col2, opts)
end

function treesitter.get_local_declaration(doc, line1, col1, line2, col2, opts)
  return language_intelligence.local_declaration(doc, line1, col1, line2, col2, opts)
end

function treesitter.get_local_references(doc, line1, col1, line2, col2, opts)
  return language_intelligence.local_references(doc, line1, col1, line2, col2, opts)
end

function treesitter.goto_local_definition(doc)
  return language_intelligence.goto_local_definition(doc)
end

function treesitter.goto_local_declaration(doc)
  return language_intelligence.goto_local_declaration(doc)
end

function treesitter.select_local_references(doc)
  return language_intelligence.select_local_references(doc)
end

function treesitter.log_document_status(doc)
  doc = doc or (core.active_view and core.active_view.doc)
  if not doc then
    core.log("Tree-sitter: no active document")
    return
  end
  local ts = doc.treesitter
  if not ts then
    core.log("Tree-sitter: %s unsupported/not attached", doc_name(doc))
    return
  end
  core.log(
    "Tree-sitter: %s status=%s reason=%s language=%s generation=%s tree_generation=%s stale_renderable=%s stale_unrenderable=%s",
    doc_name(doc), tostring(ts.status), tostring(ts.reason), tostring(ts.language_id),
    tostring(ts.generation), tostring(ts.tree_generation), tostring(ts.stale_renderable), tostring(ts.stale_unrenderable)
  )
end

local function patch_doc()
  if patched then return end
  patched = true

  local old_set_filename = Doc.set_filename
  function Doc:set_filename(...)
    ts_symbol_index.clear_open_document(self, "filename")
    local result = old_set_filename(self, ...)
    treesitter.attach_or_update_doc(self, "filename")
    return result
  end

  local old_load = Doc.load
  function Doc:load(...)
    ts_symbol_index.clear_open_document(self, "load")
    local result = old_load(self, ...)
    treesitter.attach_or_update_doc(self, "load")
    return result
  end

  local old_reset_syntax = Doc.reset_syntax
  function Doc:reset_syntax(...)
    local result = old_reset_syntax(self, ...)
    if self.lines then treesitter.attach_or_update_doc(self, "syntax") end
    return result
  end

  local old_save = Doc.save
  function Doc:save(...)
    local result = old_save(self, ...)
    treesitter.attach_or_update_doc(self, "save")
    local path = doc_path(self)
    if path and ts_symbol_index.reindex_file then
      ts_symbol_index.reindex_file(path, { force = true, reason = "save" })
    end
    return result
  end

  local old_on_text_transaction = Doc.on_text_transaction
  function Doc:on_text_transaction(transaction)
    old_on_text_transaction(self, transaction)
    treesitter.on_text_transaction(self, transaction)
  end

  local old_on_close = Doc.on_close
  function Doc:on_close(...)
    treesitter.close_doc(self)
    return old_on_close(self, ...)
  end
end

patch_doc()

local function install_project_index_hooks()
  if core.__treesitter_project_index_hooks_wrapped then return end
  core.__treesitter_project_index_hooks_wrapped = true

  local old_add_project = core.add_project
  function core.add_project(project, ...)
    local result = old_add_project(project, ...)
    if result and result.path and ts_symbol_index.start_project_indexing then
      ts_symbol_index.start_project_indexing({ root = result.path, reason = "project-added" })
    end
    return result
  end

  local old_set_project = core.set_project
  function core.set_project(project, ...)
    local result = old_set_project(project, ...)
    if result and result.path and ts_symbol_index.start_project_indexing then
      ts_symbol_index.start_project_indexing({ root = result.path, reason = "project-set" })
    end
    return result
  end
end

install_project_index_hooks()

local previous_on_event = core.on_event
if type(previous_on_event) == "function" and not core.__treesitter_on_event_wrapped then
  core.__treesitter_on_event_wrapped = true
  function core.on_event(type, ...)
    if type == "treesitter_complete" then
      if native and native.ack_complete_event then native.ack_complete_event() end
      treesitter.poll_all()
    end
    return previous_on_event(type, ...)
  end
end

language_intelligence.register_provider({
  id = "treesitter",
  name = "Tree-sitter",
  priority = 10,
  kind = "syntactic-local-fallback",
  features = {
    render_tokens = true,
    document_outline = true,
    node_ranges = true,
    fold_target = true,
    expand_selection = true,
    shrink_selection = true,
    enclosing_symbol = true,
    next_symbol = true,
    previous_symbol = true,
    local_definition = true,
    local_declaration = true,
    local_references = true,
  },

  render_tokens = function(doc, line_idx, opts)
    return ts_highlight.line_tokens(doc, line_idx, opts)
  end,

  invalidate_render_cache = function(doc, first_line, last_line)
    return ts_highlight.invalidate_doc(doc, first_line, last_line)
  end,

  document_outline = function(doc, opts)
    return ts_outline.get_document_outline(doc, opts)
  end,

  node_ranges = function(doc, line1, col1, line2, col2, opts)
    return ts_selection.get_node_ranges(doc, line1, col1, line2, col2, opts)
  end,

  fold_target = function(doc, line1, col1, line2, col2, opts)
    return ts_folding.get_fold_target(doc, line1, col1, line2, col2, opts)
  end,

  expand_selection = function(doc)
    return ts_selection.expand_selection(doc)
  end,

  shrink_selection = function(doc)
    return ts_selection.shrink_selection(doc)
  end,

  enclosing_symbol = function(doc, line1, col1, line2, col2, opts)
    return ts_navigation.get_enclosing_symbol(doc, line1, col1, line2, col2, opts)
  end,

  next_symbol = function(doc, line, col, opts)
    return ts_navigation.get_next_symbol(doc, line, col, opts)
  end,

  previous_symbol = function(doc, line, col, opts)
    return ts_navigation.get_previous_symbol(doc, line, col, opts)
  end,

  goto_enclosing_symbol = function(doc)
    return ts_navigation.goto_enclosing_symbol(doc)
  end,

  goto_next_symbol = function(doc)
    return ts_navigation.goto_next_symbol(doc)
  end,

  goto_previous_symbol = function(doc)
    return ts_navigation.goto_previous_symbol(doc)
  end,

  local_definition = function(doc, line1, col1, line2, col2, opts)
    return ts_locals.get_local_definition(doc, line1, col1, line2, col2, opts)
  end,

  local_declaration = function(doc, line1, col1, line2, col2, opts)
    return ts_locals.get_local_definition(doc, line1, col1, line2, col2, opts)
  end,

  local_references = function(doc, line1, col1, line2, col2, opts)
    return ts_locals.get_local_references(doc, line1, col1, line2, col2, opts)
  end,

  goto_local_definition = function(doc)
    return ts_locals.goto_local_definition(doc)
  end,

  goto_local_declaration = function(doc)
    return ts_locals.goto_local_declaration(doc)
  end,

  select_local_references = function(doc)
    return ts_locals.select_local_references(doc)
  end,
})

local function doc_command_predicate()
  local view = core.active_view
  local doc = view and view.doc
  return doc and type(doc.get_selection) == "function", doc
end

command.add(doc_command_predicate, {
  ["tree-sitter:expand-selection"] = function(doc)
    treesitter.expand_selection(doc)
  end,

  ["tree-sitter:shrink-selection"] = function(doc)
    treesitter.shrink_selection(doc)
  end,

  ["tree-sitter:go-to-enclosing-symbol"] = function(doc)
    treesitter.goto_enclosing_symbol(doc)
  end,

  ["tree-sitter:go-to-next-symbol"] = function(doc)
    local ok, reason = treesitter.goto_next_symbol(doc)
    if not ok then
      if reason == "no-symbols" or reason == "no-navigable-symbols" then
        navigation_feedback.none("symbols")
      else
        navigation_feedback.no_more(1, "symbol")
      end
    end
  end,

  ["tree-sitter:go-to-previous-symbol"] = function(doc)
    local ok, reason = treesitter.goto_previous_symbol(doc)
    if not ok then
      if reason == "no-symbols" or reason == "no-navigable-symbols" then
        navigation_feedback.none("symbols")
      else
        navigation_feedback.no_more(-1, "symbol")
      end
    end
  end,

  ["tree-sitter:go-to-local-definition"] = function(doc)
    treesitter.goto_local_definition(doc)
  end,

  ["tree-sitter:go-to-local-declaration"] = function(doc)
    treesitter.goto_local_declaration(doc)
  end,

  ["tree-sitter:select-local-references"] = function(doc)
    treesitter.select_local_references(doc)
  end,
})

command.add(nil, {
  ["tree-sitter:log-document-status"] = function()
    treesitter.log_document_status()
  end,
})

return treesitter
