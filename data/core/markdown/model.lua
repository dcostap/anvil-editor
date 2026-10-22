local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local queries = require "core.markdown.queries"
local native = require "treesitter"
local worker_pool = require "core.worker_pool"

local model = {}
local Model = {}
Model.__index = Model

local native_ok, native_pool = pcall(require, "worker_pool_native")

local models_by_buffer = setmetatable({}, { __mode = "k" })
local MARKDOWN_EXTENSIONS = { md = true, markdown = true, mdown = true }
local METADATA_LISTENER_ID = "markdown-semantic-model"
-- Input-thread time each frame may spend finishing pending parses before
-- it draws. A slower parse falls back to its worker job.
local SETTLE_BUDGET_MS = 8
-- An opened Buffer's first parse may take longer, once, so its first frame
-- draws rendered Markdown instead of its raw source.
local FIRST_PARSE_BUDGET_MS = 20
-- That first frame lays out every rendered line of the Buffer at once. A
-- longer Buffer leaves its first parse to the worker and shows its source
-- until the background layout of its rendered lines is ready.
local FIRST_PARSE_MAX_LINES = 400
local settle_queue = setmetatable({}, { __mode = "k" })

local function active_perf()
  local perf = package.loaded["core.perf"]
  return perf and (core.perf_frame_stats or (perf.is_recording and perf.is_recording()))
    and perf or nil
end

local function elapsed_ms(started)
  return started and (system.get_time() - started) * 1000 or 0
end

local function extension(path)
  local value = (path or ""):match("%.([^.\\/]+)$")
  return value and value:lower() or nil
end

function model.is_markdown_buffer(buffer)
  if not buffer then return false end
  if MARKDOWN_EXTENSIONS[extension(buffer.abs_filename or buffer.filename or "") or ""] then return true end
  local syntax_name = buffer.syntax and buffer.syntax.name
  return type(syntax_name) == "string" and syntax_name:lower():find("markdown", 1, true) ~= nil
end

local function weak_buffer(buffer)
  return setmetatable({ buffer }, { __mode = "v" })
end

local function metadata_signature(buffer)
  local syntax_name = buffer and buffer.syntax and buffer.syntax.name or ""
  return table.concat({
    tostring(buffer and buffer.filename or ""),
    tostring(buffer and buffer.abs_filename or ""),
    tostring(syntax_name),
  }, "\0")
end

local function source_text(buffer)
  return table.concat(buffer and buffer.lines or {})
end

local function parse_payload(text, previous_result)
  return {
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
    previous_result = previous_result,
  }
end

function Model:new(buffer)
  return setmetatable({
    buffer_ref = weak_buffer(buffer),
    status = "cold",
    reason = "not parsed",
    generation = 0,
    parse_generation = 0,
    published_revision = nil,
    published_metadata = nil,
    result = nil,
    request = nil,
    pending_changed_range = nil,
    pending_structural_change = false,
    active_changed_range = nil,
    active_structural_change = false,
    changed_ranges = {},
    semantic_id_by_source = {},
    semantic_id_by_native = {},
    previous_semantic_id_by_native = {},
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
      last_incremental_ms = 0,
      settled = 0,
      settle_misses = 0,
      settle_skipped = 0,
    },
  }, self)
end

function Model:buffer()
  return self.buffer_ref[1]
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
  local perf = active_perf()
  local listener_count, total_ms = 0, 0
  local slowest_listener_ms, slowest_listener_id = 0, ""
  for id, fn in pairs(self.listeners) do
    local started = system.get_time()
    local ok, err = pcall(fn, self, reason)
    local listener_ms = elapsed_ms(started)
    if listener_ms >= 16 then
      local buffer = self:buffer()
      core.log_quiet(
        "Markdown model slow listener: id=%s reason=%s elapsed=%.1fms generation=%d revision=%s lines=%d path=%s",
        id, reason, listener_ms, self.generation, tostring(self.published_revision),
        self.published_line_count or 0, buffer and buffer:get_name() or "<closed>"
      )
    end
    if perf then
      listener_count = listener_count + 1
      total_ms = total_ms + listener_ms
      if listener_ms > slowest_listener_ms then
        slowest_listener_ms = listener_ms
        slowest_listener_id = id
      end
    end
    if not ok then core.log_quiet("Markdown model listener %s failed: %s", tostring(id), tostring(err)) end
  end
  if perf then
    return {
      count = listener_count,
      total_ms = total_ms,
      slowest_ms = slowest_listener_ms,
      slowest_id = slowest_listener_id,
    }
  end
end

function Model:is_current(revision, signature, generation)
  local buffer = self:buffer()
  return buffer ~= nil
    and self.status ~= "closed"
    and self.status ~= "detached"
    and models_by_buffer[buffer] == self
    and model.is_markdown_buffer(buffer)
    and buffer.text_revision == revision
    and metadata_signature(buffer) == signature
    and self.parse_generation == generation
end

function Model:on_metadata(event)
  local buffer = self:buffer()
  if not buffer then return end
  if event and event.kind == "close" then
    self:close("buffer-close")
    models_by_buffer[buffer] = nil
    return
  end
  if not model.is_markdown_buffer(buffer) then
    self:cancel_request("metadata-detach")
    if self.result then self.result:close() end
    self.result = nil
    self.status = "detached"
    self.reason = "Buffer is not Markdown"
    self.published_metadata = nil
    self:notify("detached")
    core.log_quiet("Markdown model detached after Buffer metadata change")
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
    if result then result:close() end
    self.diagnostics.stale = self.diagnostics.stale + 1
    core.log_quiet("Markdown model discarded stale generation %d", generation)
    return false
  end
  local perf = active_perf()
  local publication_started = perf and system.get_time()
  local summary_started = perf and system.get_time()
  local summary = result:summary()
  local summary_ms = elapsed_ms(summary_started)
  local block_status = summary.outline and summary.outline.status
  local inline_status = summary.usage and summary.usage.status
  if (block_status ~= "ready" and block_status ~= "limit")
    or (inline_status ~= "ready" and inline_status ~= "limit")
  then
    self.request = nil
    self.status = "error"
    self.reason = (summary.outline and summary.outline.error)
      or (summary.usage and summary.usage.error)
      or "Markdown semantic query failed"
    self.diagnostics.failed = self.diagnostics.failed + 1
    result:close()
    self:notify("error")
    return false
  end

  local state_started = perf and system.get_time()
  local previous_result = self.result
  self.previous_semantic_id_by_native = self.semantic_id_by_native
  self.semantic_id_by_source = {}
  self.semantic_id_by_native = {}
  self.result = result
  local state_ms = elapsed_ms(state_started)
  local previous_close_started = perf and system.get_time()
  if previous_result and previous_result ~= result then previous_result:close() end
  local previous_close_ms = elapsed_ms(previous_close_started)
  state_started = perf and system.get_time()
  self.request = nil
  self.status = "ready"
  self.reason = nil
  self.generation = self.generation + 1
  self.published_revision = revision
  self.published_metadata = signature
  self.published_byte_len = summary.byte_len or 0
  self.published_line_count = summary.line_count or 0
  self.published_footnote_definition_lines = summary.footnote_definition_lines or {}
  self.published_footnote_lines = summary.footnote_lines or {}
  self.footnote_definitions_cache = nil
  self.diagnostics.published = self.diagnostics.published + 1
  self.diagnostics.last_parse_ms = summary.metrics and summary.metrics.parse_ms or 0
  self.diagnostics.last_total_ms = summary.metrics and summary.metrics.total_ms or 0
  if summary.metrics and summary.metrics.incremental then
    self.diagnostics.last_incremental_ms = self.diagnostics.last_total_ms
    self.diagnostics.incremental_publications = self.diagnostics.incremental_publications + 1
    self.diagnostics.reused_block_captures = self.diagnostics.reused_block_captures
      + (summary.metrics.reused_block_captures or 0)
    self.diagnostics.reused_inline_regions = self.diagnostics.reused_inline_regions
      + (summary.metrics.reused_inline_regions or 0)
  else
    self.diagnostics.full_publications = self.diagnostics.full_publications + 1
  end
  if summary.changed_line1 then
    changed_range = changed_range or {}
    changed_range.line1 = math.min(
      changed_range.line1 or math.huge, summary.changed_line1
    )
    changed_range.line2 = math.max(
      changed_range.line2 or -math.huge,
      summary.changed_line2 or summary.changed_line1
    )
  end
  self.changed_ranges = changed_range and { common.merge({}, changed_range) } or {}
  self.active_changed_range = nil
  self.active_structural_change = false
  state_ms = state_ms + elapsed_ms(state_started)
  core.log_quiet(
    "Markdown model published generation=%d revision=%d bytes=%d lines=%d parse_ms=%.3f total_ms=%.3f",
    self.generation,
    revision,
    summary.byte_len or 0,
    summary.line_count or 0,
    self.diagnostics.last_parse_ms,
    self.diagnostics.last_total_ms
  )
  local notify_started = perf and system.get_time()
  local notify_stats = self:notify("published")
  local notify_ms = elapsed_ms(notify_started)
  if perf then
    local total_ms = elapsed_ms(publication_started)
    perf.frame_add("markdown_model_publication_ms", total_ms)
    perf.frame_add("markdown_model_publication_summary_ms", summary_ms)
    perf.frame_add("markdown_model_publication_previous_close_ms", previous_close_ms)
    perf.frame_add("markdown_model_publication_state_ms", state_ms)
    perf.frame_add("markdown_model_publication_notify_ms", notify_ms)
    perf.frame_add("markdown_model_publication_listener_calls", notify_stats.count)
    local buffer = self:buffer()
    perf.record_markdown_model_publication({
      time = system.get_time(),
      elapsed_ms = total_ms,
      path = buffer and (buffer.abs_filename or buffer.filename or buffer:get_name()) or "",
      bytes = summary.byte_len or 0,
      lines = summary.line_count or 0,
      generation = generation,
      revision = revision,
      incremental = summary.metrics and summary.metrics.incremental == true,
      changed_line1 = changed_range and changed_range.line1,
      changed_line2 = changed_range and changed_range.line2,
      native_parse_ms = summary.metrics and summary.metrics.parse_ms or 0,
      native_total_ms = summary.metrics and summary.metrics.total_ms or 0,
      summary_ms = summary_ms,
      previous_close_ms = previous_close_ms,
      state_ms = state_ms,
      notify_ms = notify_ms,
      listener_count = notify_stats.count,
      slowest_listener_ms = notify_stats.slowest_ms,
      slowest_listener_id = notify_stats.slowest_id,
    })
  end
  core.redraw = true
  return true
end

function Model:submit(reason)
  if self.status == "closed" then return false, "closed" end
  local buffer = self:buffer()
  if not buffer or not model.is_markdown_buffer(buffer) then
    self:cancel_request("not-markdown")
    if self.result then self.result:close() end
    self.result = nil
    self.status = "detached"
    self.reason = "Buffer is not Markdown"
    self:notify("detached")
    return false
  end

  self:cancel_request("superseded")
  self.parse_generation = self.parse_generation + 1
  local generation = self.parse_generation
  local revision = buffer.text_revision
  local signature = metadata_signature(buffer)
  local text = source_text(buffer)
  local changed_range = self.pending_changed_range
  if self.active_changed_range then
    changed_range = changed_range or {}
    changed_range.line1 = math.min(
      changed_range.line1 or math.huge, self.active_changed_range.line1
    )
    changed_range.line2 = math.max(
      changed_range.line2 or -math.huge, self.active_changed_range.line2
    )
  end
  local structural_change = self.pending_structural_change
    or self.active_structural_change
  self.pending_changed_range = nil
  self.active_changed_range = changed_range and common.merge({}, changed_range) or nil
  self.active_structural_change = structural_change
  self.pending_structural_change = false
  self.status = "pending"
  self.reason = reason or "parse requested"
  self.diagnostics.requests = self.diagnostics.requests + 1
  self.diagnostics.bytes_submitted = self.diagnostics.bytes_submitted + #text
  self.diagnostics.lines_submitted = self.diagnostics.lines_submitted + #buffer.lines

  local pool = worker_pool.system()
  local handle, err = pool:submit({
    kind = "markdown-parse",
    native = true,
    native_kind = "markdown_parse",
    generation = generation,
    native_payload = parse_payload(text, self.result),
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
    on_stale = function(message)
      if message and message.result then message.result:close() end
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
  self.pending_submission = {
    text = text, revision = revision, signature = signature,
    generation = generation, changed_range = changed_range,
  }
  settle_queue[self] = true
  core.log_quiet(
    "Markdown model scheduled generation=%d revision=%d bytes=%d reason=%s",
    generation, revision, #text, tostring(reason or "initial")
  )
  self:notify("pending")
  return true
end

-- Finish the pending parse on the input thread when it fits the budget, so
-- the next frame draws from real semantics instead of an edit projection.
-- Returns the elapsed milliseconds when it tried to parse.
function Model:settle(budget_ms)
  local submission = self.pending_submission
  self.pending_submission = nil
  settle_queue[self] = nil
  if not (submission and native_ok and native_pool.markdown_parse_now) then return nil end
  if self.status ~= "pending"
    or not self:is_current(submission.revision, submission.signature, submission.generation)
  then
    return nil
  end
  -- Without a listener nothing draws this Buffer.
  if not next(self.listeners) then return nil end
  local first = not self.result
  if first and #self:buffer().lines > FIRST_PARSE_MAX_LINES then
    core.log_quiet(
      "Markdown model left first parse of %d lines to its worker",
      #self:buffer().lines
    )
    return nil
  end
  -- The last incremental parse predicts this one. Leave a slow Buffer to
  -- its worker instead of spending the budget on a likely miss.
  if not first and self.diagnostics.last_incremental_ms >= budget_ms then
    self.diagnostics.settle_skipped = self.diagnostics.settle_skipped + 1
    return nil
  end
  local started = system.get_time()
  local result, err, over_budget = native_pool.markdown_parse_now(
    parse_payload(submission.text, self.result), math.max(1, math.floor(budget_ms))
  )
  local elapsed = elapsed_ms(started)
  if not result then
    self.diagnostics.settle_misses = self.diagnostics.settle_misses + 1
    if over_budget and not first then
      -- Skip later attempts until a worker publication reports a fast parse.
      self.diagnostics.last_incremental_ms = math.max(
        self.diagnostics.last_incremental_ms, budget_ms
      )
    end
    core.log_quiet(
      "Markdown model left revision %d to its worker after %.2fms: %s",
      submission.revision, elapsed, tostring(err)
    )
    return elapsed
  end
  -- The worker job parses the same text. Retire its generation so a late
  -- result cannot publish this revision a second time.
  self:cancel_request("settled on input thread")
  self.parse_generation = self.parse_generation + 1
  self.diagnostics.settled = self.diagnostics.settled + 1
  core.log_quiet(
    "Markdown model settled %s %d on the input thread in %.2fms",
    first and "first parse of revision" or "revision", submission.revision, elapsed
  )
  self:publish(
    result, submission.revision, submission.signature,
    self.parse_generation, submission.changed_range
  )
  return elapsed
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
    if (range.line_delta or 0) ~= 0 then self.pending_structural_change = true end
  end
  self.status = "pending"
  self.reason = reason or "change"
  return self:submit(reason)
end

function Model:can_render_published_line(line)
  local buffer = self:buffer()
  if not (buffer and self.result and self.published_metadata == metadata_signature(buffer)) then return false end
  if self.status == "ready" then return self.published_revision == buffer.text_revision end
  if self.status ~= "pending" then return false end
  local pending, active = self.pending_changed_range, self.active_changed_range
  if not (pending or active) then return false end
  local range = {
    line1 = math.min(
      pending and pending.line1 or math.huge,
      active and active.line1 or math.huge
    ),
    line2 = math.max(
      pending and pending.line2 or -math.huge,
      active and active.line2 or -math.huge
    ),
  }
  if self.pending_structural_change or self.active_structural_change then
    return line < range.line1
  end
  return line < range.line1 or line > range.line2
end

function Model:ensure()
  local buffer = self:buffer()
  if not buffer then return false end
  local signature = metadata_signature(buffer)
  if self.status == "ready"
    and self.published_revision == buffer.text_revision
    and self.published_metadata == signature
  then
    return true
  end
  if self.status == "pending" and self.request then return false end
  self:submit("first-use")
  return false
end

-- Check list ownership before projecting a changed prefix. Use the block
-- grammar, not an indentation heuristic. Bound work on the input thread;
-- callers retain the last presentation when this probe cannot finish.
function Model:probe_list_markers()
  local buffer = self:buffer()
  if not buffer then return nil end
  if self.list_probe_revision == buffer.text_revision then return self.list_probe end
  self.list_probe_revision, self.list_probe = buffer.text_revision, nil
  local bytes = 0
  for _, line in ipairs(buffer.lines) do
    bytes = bytes + #line
    if bytes > 65536 then
      core.log_quiet("Markdown list probe deferred: source exceeds input-thread bound")
      return nil
    end
  end
  local result, err = native.index_text {
    language = "markdown", lines = buffer.lines,
    outline_query = queries.list_markers,
    parse_timeout_ms = 4, query_timeout_ms = 2,
    match_limit = 4096, max_captures = 4096,
  }
  if not result or result.outline.status ~= "ready" then
    core.log_quiet("Markdown list probe deferred: %s",
      err or result and result.outline.status or "unavailable")
    return nil
  end
  local markers = {}
  for _, capture in ipairs(result.outline.captures) do
    markers[capture.start_line] = true
  end
  self.list_probe = markers
  return markers
end

---Footnote definition lines by label, from the published parse. A line that
---an edit has since changed is left out until the next parse.
---@return table<string, integer>
function Model:footnote_definitions()
  local cache = self.footnote_definitions_cache
  local buffer = self:buffer()
  local revision = buffer and buffer.text_revision
  if cache and cache.generation == self.generation and cache.revision == revision then
    return cache.lines
  end
  local lines = {}
  for _, line in ipairs(self.published_footnote_definition_lines or {}) do
    local label = buffer and (buffer.lines[line] or ""):match("^ ? ? ?%[%^([^%s%[%]]+)%]:")
    if label and not lines[label] then lines[label] = line end
  end
  self.footnote_definitions_cache = { generation = self.generation, revision = revision, lines = lines }
  return lines
end

---Lines with a footnote reference or an inline footnote, in source order,
---from the published parse.
---@return integer[]
function Model:footnote_lines()
  return self.published_footnote_lines or {}
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
    or name == "span.tag" or name == "span.footnote_reference"
    or name == "span.footnote_inline" or name == "marker.footnote_definition_open"
end

local function extension_capture(name)
  return name == "span.wiki_link" or name == "span.embed" or name == "span.highlight"
    or name == "span.comment" or name == "span.tag" or name:match("^marker%.wiki_")
    or name:match("^marker%.embed_") or name:match("^marker%.highlight_")
    or name:match("^marker%.comment_") or name == "content.target"
    or name == "content.alias" or name == "content.highlight" or name == "content.comment"
    or name == "content.tag" or name:match("^span%.footnote_")
    or name:match("^marker%.footnote_") or name:match("^content%.footnote_")
end

function Model:captures_for_lines(kind, line1, line2, opts)
  opts = opts or {}
  if not self.result or (self.status ~= "ready"
    and not (self.status == "pending" and opts.allow_pending_result))
  then
    return nil, self.status
  end
  local result_kind = kind == "inline" and "usage" or "outline"
  local captures = self.result:captures_for_lines(result_kind, line1, line2, opts)
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

function Model:stabilize_node_ids(nodes)
  for _, node in ipairs(nodes or {}) do
    local native_id = node.id
    local source_key = table.concat({
      node.type, node.source.start_byte or 0, node.source.end_byte or 0,
    }, ":")
    local stable_id = self.semantic_id_by_source[source_key]
      or self.semantic_id_by_native[native_id]
      -- Old source positions can now belong to different nodes after an edit.
      -- Only native identities can link nodes across publications.
      or self.previous_semantic_id_by_native[native_id]
      or native_id
    node.id = stable_id
    self.semantic_id_by_source[source_key] = stable_id
    self.semantic_id_by_native[native_id] = stable_id
  end
  return nodes
end

function Model:inline_nodes_for_lines(line1, line2, opts)
  opts = opts or {}
  if not self.result or (self.status ~= "ready"
    and not (self.status == "pending" and opts.allow_pending_result))
  then
    return nil, self.status
  end
  local nodes = self.result:semantic_nodes_for_lines(
    "inline", line1, line2, opts
  )
  return self:stabilize_node_ids(nodes), nodes.truncated and "limit" or nil
end

function Model:nodes_for_lines(line1, line2, opts)
  opts = opts or {}
  if not self.result or (self.status ~= "ready"
    and not (self.status == "pending" and opts.allow_pending_result))
  then
    return nil, self.status
  end
  local nodes = self.result:semantic_nodes_for_lines("both", line1, line2, opts)
  return self:stabilize_node_ids(nodes), nodes.truncated and "limit" or nil
end

---Return table identities and source ranges without inline metadata.
function Model:table_nodes_for_lines(line1, line2, opts)
  opts = opts or {}
  if not self.result or (self.status ~= "ready"
    and not (self.status == "pending" and opts.allow_pending_result))
  then
    return nil, self.status
  end
  local nodes = self.result:semantic_nodes_for_lines("table", line1, line2, opts)
  return self:stabilize_node_ids(nodes), nodes.truncated and "limit" or nil
end

---Return block quote identities and source ranges without other nodes.
function Model:quote_nodes_for_lines(line1, line2, opts)
  opts = opts or {}
  if not self.result or (self.status ~= "ready"
    and not (self.status == "pending" and opts.allow_pending_result))
  then
    return nil, self.status
  end
  local nodes = self.result:semantic_nodes_for_lines("quote", line1, line2, opts)
  return self:stabilize_node_ids(nodes), nodes.truncated and "limit" or nil
end

---Returns the fenced-code block containing a line, completing opening-line
---metadata through a second bounded semantic query when necessary.
---@param line integer
---@param opts? table
---@return table? node
---@return string? reason
function Model:fenced_node_for_line(line, opts)
  opts = common.merge({ limit = 512 }, opts or {})
  local nodes, reason = self:nodes_for_lines(line, line, opts)
  if not nodes or reason == "limit" then return nil, reason end

  local fenced
  for _, node in ipairs(nodes) do
    if node.type == "code_fenced"
      and line >= node.source.line1 and line <= node.source.line2
    then
      fenced = node
      break
    end
  end
  if not fenced or (fenced.attributes and fenced.attributes.code_info) then
    return fenced, reason
  end

  local opening_nodes, opening_reason = self:nodes_for_lines(
    fenced.source.line1, fenced.source.line1, opts
  )
  if not opening_nodes or opening_reason == "limit" then
    return nil, opening_reason
  end
  for _, candidate in ipairs(opening_nodes) do
    if candidate.type == "code_fenced"
      and (candidate.id == fenced.id or (
        candidate.source.start_byte == fenced.source.start_byte
        and candidate.source.end_byte == fenced.source.end_byte
      ))
    then
      return candidate, opening_reason
    end
  end
  return nil, "incomplete"
end

function Model:close(reason)
  local buffer = self:buffer()
  if buffer and buffer.remove_metadata_listener then buffer:remove_metadata_listener(METADATA_LISTENER_ID) end
  self:cancel_request(reason or "close")
  self.parse_generation = self.parse_generation + 1
  self.pending_submission = nil
  settle_queue[self] = nil
  if self.result then self.result:close() end
  self.result = nil
  self.listeners = {}
  self.status = "closed"
  self.reason = reason or "closed"
end

function model.get(buffer, opts)
  opts = opts or {}
  if not buffer or not model.is_markdown_buffer(buffer) then return nil end
  local current = models_by_buffer[buffer]
  if not current then
    current = Model:new(buffer)
    models_by_buffer[buffer] = current
    if buffer.add_metadata_listener then
      buffer:add_metadata_listener(METADATA_LISTENER_ID, function(_, event)
        if models_by_buffer[buffer] == current then current:on_metadata(event) end
      end)
    end
  end
  if opts.ensure ~= false then current:ensure() end
  return current
end

-- Called once per frame after input and before layout and drawing.
function model.settle_pending()
  if not next(settle_queue) then return end
  local spent = 0
  local pending = {}
  for instance in pairs(settle_queue) do pending[#pending + 1] = instance end
  -- The Buffer the user looks at settles before the others.
  local active = core.active_view and core.active_view.buffer
  table.sort(pending, function(a, b)
    return active ~= nil and a:buffer() == active and b:buffer() ~= active
  end)
  for _, instance in ipairs(pending) do
    local budget = instance.result and SETTLE_BUDGET_MS or FIRST_PARSE_BUDGET_MS
    local remaining = budget - spent
    if remaining < 1 then
      -- The frame budget is spent. Leave the rest to their workers.
      instance.pending_submission = nil
      settle_queue[instance] = nil
    else
      spent = spent + (instance:settle(remaining) or 0)
    end
  end
end

function model.peek(buffer)
  return models_by_buffer[buffer]
end

function model.close(buffer, reason)
  local current = models_by_buffer[buffer]
  if not current then return false end
  current:close(reason)
  models_by_buffer[buffer] = nil
  return true
end

Buffer.register_text_transaction_handler("markdown-semantic-model", function(buffer, transaction)
  local current = models_by_buffer[buffer]
  if current and transaction and transaction.changed then
    current:schedule("text-change", transaction)
  end
end)

model.Model = Model
model.queries = queries

return model
