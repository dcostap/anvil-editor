local common = require "core.common"
local core = require "core"
local Doc = require "core.doc"
local queries = require "core.markdown.queries"
local worker_pool = require "core.worker_pool"

local model = {}
local Model = {}
Model.__index = Model

local models_by_doc = setmetatable({}, { __mode = "k" })
local MARKDOWN_EXTENSIONS = { md = true, markdown = true, mdown = true }
local DEBOUNCE_SECONDS = 0.015
local METADATA_LISTENER_ID = "markdown-semantic-model"

local function extension(path)
  local value = (path or ""):match("%.([^.\\/]+)$")
  return value and value:lower() or nil
end

function model.is_markdown_doc(doc)
  if not doc then return false end
  if MARKDOWN_EXTENSIONS[extension(doc.abs_filename or doc.filename or "") or ""] then return true end
  local syntax_name = doc.syntax and doc.syntax.name
  return type(syntax_name) == "string" and syntax_name:lower():find("markdown", 1, true) ~= nil
end

local function weak_doc(doc)
  return setmetatable({ doc }, { __mode = "v" })
end

local function metadata_signature(doc)
  local syntax_name = doc and doc.syntax and doc.syntax.name or ""
  return table.concat({
    tostring(doc and doc.filename or ""),
    tostring(doc and doc.abs_filename or ""),
    tostring(syntax_name),
  }, "\0")
end

local function source_text(doc)
  return table.concat(doc and doc.lines or {})
end

local function capture_range(capture)
  return {
    line1 = capture.start_line,
    col1 = capture.start_col,
    line2 = capture.end_line,
    col2 = capture.end_col,
    start_byte = capture.start_byte,
    end_byte = capture.end_byte,
  }
end

local function contains(outer, inner)
  return outer.start_byte <= inner.start_byte and outer.end_byte >= inner.end_byte
end

local function parent_capture_name(name)
  return name:match("^block%.") or name:match("^span%.")
end

local function canonical_type(name)
  return name:gsub("^block%.", ""):gsub("^span%.", ""):gsub("%.", "_")
end

local function build_nodes(captures)
  local nodes = {}
  local decorations = {}
  for _, capture in ipairs(captures) do
    local name = capture.capture or ""
    if parent_capture_name(name) then
      local range = capture_range(capture)
      nodes[#nodes + 1] = {
        id = table.concat({ name, capture.node_id or range.start_byte .. ":" .. range.end_byte }, ":"),
        type = canonical_type(name),
        source = range,
        marker_ranges = {},
        content_ranges = {},
        attributes = {},
        confidence = "complete",
      }
    elseif name:match("^marker%.") or name:match("^content%.") then
      decorations[#decorations + 1] = capture
    end
  end

  table.sort(nodes, function(a, b)
    if a.source.start_byte == b.source.start_byte then return a.source.end_byte < b.source.end_byte end
    return a.source.start_byte < b.source.start_byte
  end)
  for _, capture in ipairs(decorations) do
    local range = capture_range(capture)
    local family = capture.capture:match("^[^.]+%.(wiki)_")
      or capture.capture:match("^[^.]+%.(embed)_")
      or capture.capture:match("^[^.]+%.(highlight)")
      or capture.capture:match("^[^.]+%.(comment)")
    if family == "wiki" then family = "wiki_link" end
    local extension_link_content = capture.capture == "content.target"
      or capture.capture == "content.alias"
    local best
    for _, node in ipairs(nodes) do
      local family_match = not family or node.type == family
      local link_match = not extension_link_content
        or node.type == "wiki_link" or node.type == "embed"
      if contains(node.source, range) and family_match and link_match and (not best or
        node.source.end_byte - node.source.start_byte < best.source.end_byte - best.source.start_byte)
      then
        best = node
      end
    end
    if best then
      local destination = capture.capture:match("^marker%.") and best.marker_ranges or best.content_ranges
      destination[#destination + 1] = range
      local attribute = capture.capture:match("^[^.]+%.(.+)$")
      if attribute then best.attributes[attribute:gsub("%.", "_")] = range end
    end
  end
  return nodes
end

function Model:new(doc)
  return setmetatable({
    doc_ref = weak_doc(doc),
    status = "cold",
    reason = "not parsed",
    generation = 0,
    parse_generation = 0,
    published_revision = nil,
    published_metadata = nil,
    result = nil,
    request = nil,
    debounce_serial = 0,
    pending_changed_range = nil,
    changed_ranges = {},
    listeners = {},
    diagnostics = {
      requests = 0,
      coalesced = 0,
      cancelled = 0,
      published = 0,
      stale = 0,
      failed = 0,
      bytes_submitted = 0,
      lines_submitted = 0,
      last_parse_ms = 0,
      last_total_ms = 0,
      full_publications = 0,
      incremental_publications = 0,
      reused_block_captures = 0,
      reused_inline_regions = 0,
    },
  }, self)
end

function Model:doc()
  return self.doc_ref[1]
end

function Model:add_listener(id, fn)
  assert(type(id) == "string" and id ~= "", "Markdown model listener id is required")
  assert(type(fn) == "function", "Markdown model listener must be a function")
  self.listeners[id] = fn
end

function Model:remove_listener(id)
  if not self.listeners[id] then return false end
  self.listeners[id] = nil
  return true
end

function Model:notify(reason)
  for id, fn in pairs(self.listeners) do
    local ok, err = pcall(fn, self, reason)
    if not ok then core.log_quiet("Markdown model listener %s failed: %s", tostring(id), tostring(err)) end
  end
end

function Model:is_current(revision, signature, generation)
  local doc = self:doc()
  return doc ~= nil
    and self.status ~= "closed"
    and self.status ~= "detached"
    and models_by_doc[doc] == self
    and model.is_markdown_doc(doc)
    and doc.text_revision == revision
    and metadata_signature(doc) == signature
    and self.parse_generation == generation
end

function Model:on_metadata(event)
  local doc = self:doc()
  if not doc then return end
  if event and event.kind == "close" then
    self:close("doc-close")
    models_by_doc[doc] = nil
    return
  end
  self.debounce_serial = self.debounce_serial + 1
  if not model.is_markdown_doc(doc) then
    self:cancel_request("metadata-detach")
    if self.result then self.result:close() end
    self.result = nil
    self.status = "detached"
    self.reason = "Document is not Markdown"
    self.published_metadata = nil
    self:notify("detached")
    core.log_quiet("Markdown model detached after Document metadata change")
    return
  end
  if self.status == "detached" then
    self.status = "cold"
    self.reason = "Markdown eligibility restored"
  end
  self:submit("metadata-change")
end

function Model:cancel_request(reason)
  if not self.request then return false end
  local pool = worker_pool.current_system()
  if pool then pool:cancel(self.request) end
  self.request = nil
  self.diagnostics.cancelled = self.diagnostics.cancelled + 1
  core.log_quiet("Markdown model cancelled generation %d: %s", self.parse_generation, reason or "superseded")
  return true
end

function Model:publish(result, revision, signature, generation, changed_range)
  if not self:is_current(revision, signature, generation) then
    self.diagnostics.stale = self.diagnostics.stale + 1
    core.log_quiet("Markdown model discarded stale generation %d", generation)
    return false
  end
  local summary = result:summary()
  local block_status = summary.outline and summary.outline.status
  local inline_status = summary.usage and summary.usage.status
  if (block_status ~= "ready" and block_status ~= "limit")
    or (inline_status ~= "ready" and inline_status ~= "limit")
  then
    self.status = "error"
    self.reason = (summary.outline and summary.outline.error)
      or (summary.usage and summary.usage.error)
      or "Markdown semantic query failed"
    self.diagnostics.failed = self.diagnostics.failed + 1
    self:notify("error")
    return false
  end

  local previous_result = self.result
  self.result = result
  if previous_result and previous_result ~= result then previous_result:close() end
  self.request = nil
  self.status = "ready"
  self.reason = nil
  self.generation = self.generation + 1
  self.published_revision = revision
  self.published_metadata = signature
  self.diagnostics.published = self.diagnostics.published + 1
  self.diagnostics.last_parse_ms = summary.metrics and summary.metrics.parse_ms or 0
  self.diagnostics.last_total_ms = summary.metrics and summary.metrics.total_ms or 0
  if summary.metrics and summary.metrics.incremental then
    self.diagnostics.incremental_publications = self.diagnostics.incremental_publications + 1
    self.diagnostics.reused_block_captures = self.diagnostics.reused_block_captures
      + (summary.metrics.reused_block_captures or 0)
    self.diagnostics.reused_inline_regions = self.diagnostics.reused_inline_regions
      + (summary.metrics.reused_inline_regions or 0)
  else
    self.diagnostics.full_publications = self.diagnostics.full_publications + 1
  end
  self.changed_ranges = changed_range and { common.merge({}, changed_range) } or {}
  core.log_quiet(
    "Markdown model published generation=%d revision=%d bytes=%d lines=%d parse_ms=%.3f total_ms=%.3f",
    self.generation,
    revision,
    summary.byte_len or 0,
    summary.line_count or 0,
    self.diagnostics.last_parse_ms,
    self.diagnostics.last_total_ms
  )
  self:notify("published")
  core.redraw = true
  return true
end

function Model:submit(reason)
  if self.status == "closed" then return false, "closed" end
  local doc = self:doc()
  if not doc or not model.is_markdown_doc(doc) then
    self:cancel_request("not-markdown")
    if self.result then self.result:close() end
    self.result = nil
    self.status = "detached"
    self.reason = "Document is not Markdown"
    self:notify("detached")
    return false
  end

  self:cancel_request("superseded")
  self.parse_generation = self.parse_generation + 1
  local generation = self.parse_generation
  local revision = doc.text_revision
  local signature = metadata_signature(doc)
  local text = source_text(doc)
  local changed_range = self.pending_changed_range
  self.pending_changed_range = nil
  self.status = "pending"
  self.reason = reason or "parse requested"
  self.diagnostics.requests = self.diagnostics.requests + 1
  self.diagnostics.bytes_submitted = self.diagnostics.bytes_submitted + #text
  self.diagnostics.lines_submitted = self.diagnostics.lines_submitted + #doc.lines

  local pool = worker_pool.system()
  local handle, err = pool:submit({
    kind = "markdown-parse",
    native = true,
    native_kind = "markdown_parse",
    generation = generation,
    native_payload = {
      text = text,
      outline_query = queries.block,
      usage_query = queries.inline,
      parse_timeout_ms = 5000,
      query_timeout_ms = 1000,
      usage_query_timeout_ms = 5000,
      match_limit = 200000,
      max_captures = 200000,
      usage_match_limit = 200000,
      usage_max_captures = 200000,
      previous_result = self.result,
    },
    is_stale = function()
      return not self:is_current(revision, signature, generation)
    end,
    on_result = function(message)
      if message.result then
        self:publish(message.result, revision, signature, generation, changed_range)
      end
    end,
    on_error = function(message)
      if not self:is_current(revision, signature, generation) then return end
      self.request = nil
      self.status = "error"
      self.reason = message.error or "Markdown parse failed"
      self.diagnostics.failed = self.diagnostics.failed + 1
      core.log_quiet("Markdown model generation %d failed: %s", generation, tostring(self.reason))
      self:notify("error")
    end,
    on_cancelled = function()
      if self.parse_generation == generation then self.request = nil end
    end,
    on_stale = function()
      self.diagnostics.stale = self.diagnostics.stale + 1
    end,
  })
  if not handle then
    self.status = "error"
    self.reason = err or "Markdown worker submission failed"
    self.diagnostics.failed = self.diagnostics.failed + 1
    self:notify("error")
    return false, err
  end
  self.request = handle
  core.log_quiet(
    "Markdown model scheduled generation=%d revision=%d bytes=%d reason=%s",
    generation, revision, #text, tostring(reason or "initial")
  )
  self:notify("pending")
  return true
end

function Model:schedule(reason, transaction)
  if self.status == "closed" or self.status == "detached" then return false end
  for _, range in ipairs(transaction and transaction.changed_ranges or {}) do
    local line1 = math.min(range.old_line1 or range.new_line1, range.new_line1 or range.old_line1)
    local line2 = math.max(range.old_line2 or range.new_line2, range.new_line2 or range.old_line2)
    if not self.pending_changed_range then
      self.pending_changed_range = { line1 = line1, line2 = line2 }
    else
      self.pending_changed_range.line1 = math.min(self.pending_changed_range.line1, line1)
      self.pending_changed_range.line2 = math.max(self.pending_changed_range.line2, line2)
    end
  end
  self.debounce_serial = self.debounce_serial + 1
  local serial = self.debounce_serial
  if serial > 1 then self.diagnostics.coalesced = self.diagnostics.coalesced + 1 end
  self.status = "pending"
  self.reason = reason or "change"
  core.add_thread(function()
    coroutine.yield(DEBOUNCE_SECONDS)
    if self.debounce_serial ~= serial then return end
    self:submit(reason)
  end)
  return true
end

function Model:ensure()
  local doc = self:doc()
  if not doc then return false end
  local signature = metadata_signature(doc)
  if self.status == "ready"
    and self.published_revision == doc.text_revision
    and self.published_metadata == signature
  then
    return true
  end
  if self.status == "pending" and self.request then return false end
  self:submit("first-use")
  return false
end

function Model:status_snapshot()
  return {
    status = self.status,
    reason = self.reason,
    generation = self.generation,
    parse_generation = self.parse_generation,
    published_revision = self.published_revision,
    changed_ranges = self.changed_ranges,
    diagnostics = common.merge({}, self.diagnostics),
  }
end

local function extension_parent_kind(name)
  return name == "span.wiki_link" or name == "span.embed" or name == "span.comment"
end

local function extension_capture(name)
  return name == "span.wiki_link" or name == "span.embed" or name == "span.highlight"
    or name == "span.comment" or name:match("^marker%.wiki_")
    or name:match("^marker%.embed_") or name:match("^marker%.highlight_")
    or name:match("^marker%.comment_") or name == "content.target"
    or name == "content.alias" or name == "content.highlight" or name == "content.comment"
end

function Model:captures_for_lines(kind, line1, line2, opts)
  if self.status ~= "ready" or not self.result then return nil, self.status end
  local result_kind = kind == "inline" and "usage" or "outline"
  local captures = self.result:captures_for_lines(result_kind, line1, line2, opts or {})
  if kind == "inline" then
    local parents = {}
    for _, capture in ipairs(captures) do
      if extension_parent_kind(capture.capture) then parents[#parents + 1] = capture end
    end
    local filtered = {}
    for _, capture in ipairs(captures) do
      local suppress = false
      if not extension_capture(capture.capture) then
        for _, parent in ipairs(parents) do
          if capture.start_byte >= parent.start_byte and capture.end_byte <= parent.end_byte then
            if parent.capture == "span.comment"
              or capture.capture == "span.link_reference"
              or capture.capture:match("^content%.link")
            then
              suppress = true
              break
            end
          end
        end
      end
      if not suppress then filtered[#filtered + 1] = capture end
    end
    filtered.total = captures.total
    filtered.truncated = captures.truncated
    captures = filtered
  end
  return captures, captures.truncated and "limit" or nil
end

function Model:nodes_for_lines(line1, line2, opts)
  local blocks, block_reason = self:captures_for_lines("block", line1, line2, opts)
  if not blocks then return nil, block_reason end
  local inlines, inline_reason = self:captures_for_lines("inline", line1, line2, opts)
  if not inlines then return nil, inline_reason end
  local captures = {}
  for _, capture in ipairs(blocks) do captures[#captures + 1] = capture end
  for _, capture in ipairs(inlines) do captures[#captures + 1] = capture end
  return build_nodes(captures), block_reason or inline_reason
end

function Model:close(reason)
  local doc = self:doc()
  if doc and doc.remove_metadata_listener then doc:remove_metadata_listener(METADATA_LISTENER_ID) end
  self:cancel_request(reason or "close")
  self.debounce_serial = self.debounce_serial + 1
  self.parse_generation = self.parse_generation + 1
  if self.result then self.result:close() end
  self.result = nil
  self.listeners = {}
  self.status = "closed"
  self.reason = reason or "closed"
end

function model.get(doc, opts)
  opts = opts or {}
  if not doc or not model.is_markdown_doc(doc) then return nil end
  local current = models_by_doc[doc]
  if not current then
    current = Model:new(doc)
    models_by_doc[doc] = current
    if doc.add_metadata_listener then
      doc:add_metadata_listener(METADATA_LISTENER_ID, function(_, event)
        if models_by_doc[doc] == current then current:on_metadata(event) end
      end)
    end
  end
  if opts.ensure ~= false then current:ensure() end
  return current
end

function model.peek(doc)
  return models_by_doc[doc]
end

function model.close(doc, reason)
  local current = models_by_doc[doc]
  if not current then return false end
  current:close(reason)
  models_by_doc[doc] = nil
  return true
end

Doc.register_text_transaction_handler("markdown-semantic-model", function(doc, transaction)
  local current = models_by_doc[doc]
  if current and transaction and transaction.changed then
    current:schedule("text-change", transaction)
  end
end)

model.Model = Model
model.queries = queries

return model
