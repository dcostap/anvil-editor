local core = require "core"
local Doc = require "core.doc"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"

local fence_highlight = {}
local Service = {}
Service.__index = Service

local services_by_doc = setmetatable({}, { __mode = "k" })
local METADATA_LISTENER_ID = "markdown-fence-highlight"
local BATCH_LINES = 24

local function weak_value(value)
  return setmetatable({ value }, { __mode = "v" })
end

local function without_newline(text)
  return (text or ""):gsub("\n$", "")
end

local function fence_marker(text)
  local indent, ticks = text:match("^(%s*)(`+)")
  if ticks and #indent <= 3 and #ticks >= 3 then return "`", #ticks end
  local tildes
  indent, tildes = text:match("^(%s*)(~+)")
  if tildes and #indent <= 3 and #tildes >= 3 then return "~", #tildes end
end

local function closes_fence(text, marker, count)
  if not marker then return false end
  local pattern = marker == "`" and "`+" or "~+"
  local indent, run, rest = text:match("^(%s*)(" .. pattern .. ")(%s*)$")
  return run ~= nil and #indent <= 3 and #run >= count and rest ~= nil
end

local function range_text(doc, range)
  if not (doc and range and range.line1 == range.line2) then return "" end
  local line = without_newline(doc.lines[range.line1])
  return line:sub(range.col1, range.col2 - 1)
end

local function effective_line2(node)
  local line2 = node.source.line2
  if node.source.col2 == 1 and line2 > node.source.line1 then line2 = line2 - 1 end
  return line2
end

local function token_text(tokens)
  local parts = {}
  for _, _, text in tokenizer.each_token(tokens or {}) do parts[#parts + 1] = text end
  return table.concat(parts)
end

function Service:new(doc)
  local instance = setmetatable({
    doc_ref = weak_value(doc),
    closed = false,
    generation = 1,
    model = nil,
    model_generation = nil,
    tokenizer_generation = tokenizer.get_backend_generation(),
    blocks = {},
    listeners = {},
    queue = {},
    queued = {},
    worker_running = false,
    diagnostics = {
      requests = 0,
      cache_hits = 0,
      cache_misses = 0,
      lines_tokenized = 0,
      bytes_tokenized = 0,
      resumed_lines = 0,
      cancellations = 0,
      stale_publications = 0,
      token_mismatches = 0,
      lines_reused = 0,
      convergence_stops = 0,
      blocks = 0,
      cached_lines = 0,
      queued_blocks = 0,
    },
  }, self)

  syntax.add_registry_listener(instance, function(_, reason)
    if not instance.closed then instance:on_syntax_registry_changed(reason) end
  end)
  tokenizer.add_backend_listener(instance, function(generation, _, reason)
    if not instance.closed then instance:on_tokenizer_backend_changed(generation, reason) end
  end)
  if doc.add_metadata_listener then
    doc:add_metadata_listener(METADATA_LISTENER_ID, function(_, event)
      if event and event.kind == "close" then instance:close("doc-close") end
    end)
  end
  core.log_quiet("Markdown fence highlight service created for %s", doc:get_name())
  return instance
end

function Service:doc()
  return self.doc_ref[1]
end

function Service:add_listener(id, callback)
  assert(id ~= nil, "fence highlight listener id is required")
  assert(type(callback) == "function", "fence highlight listener callback is required")
  self.listeners[id] = callback
end

function Service:remove_listener(id)
  if not self.listeners[id] then return false end
  self.listeners[id] = nil
  if not next(self.listeners) then self:release_heavy_caches("last-listener-detached") end
  return true
end

function Service:notify(line1, line2, reason)
  for id, callback in pairs(self.listeners) do
    local ok, err = pcall(callback, self, line1, line2, reason)
    if not ok then
      core.log_quiet("Markdown fence listener %s failed: %s", tostring(id), tostring(err))
    end
  end
end

function Service:queue_ready_notification(line1, line2)
  self.ready_line1 = math.min(self.ready_line1 or line1, line1)
  self.ready_line2 = math.max(self.ready_line2 or line2 or line1, line2 or line1)
end

function Service:flush_ready_notifications()
  if not self.ready_line1 then return end
  local line1, line2 = self.ready_line1, self.ready_line2
  self.ready_line1, self.ready_line2 = nil, nil
  self:notify(line1, line2, "ready")
end

function Service:release_heavy_caches(reason)
  if next(self.blocks) or #self.queue > 0 then
    self.generation = self.generation + 1
    self.diagnostics.cancellations = self.diagnostics.cancellations + #self.queue
  end
  self.blocks = {}
  self.queue = {}
  self.queued = {}
  self.ready_line1, self.ready_line2 = nil, nil
  self.diagnostics.blocks = 0
  self.diagnostics.cached_lines = 0
  self.diagnostics.queued_blocks = 0
  core.log_quiet("Markdown fence caches released: %s", reason or "release")
end

function Service:close(reason)
  if self.closed then return false end
  self.closed = true
  self.generation = self.generation + 1
  local doc = self:doc()
  if doc and doc.remove_metadata_listener then doc:remove_metadata_listener(METADATA_LISTENER_ID) end
  syntax.remove_registry_listener(self)
  tokenizer.remove_backend_listener(self)
  self:release_heavy_caches(reason or "close")
  self.listeners = {}
  self.model = nil
  if doc and services_by_doc[doc] == self then services_by_doc[doc] = nil end
  core.log_quiet("Markdown fence highlight service closed: %s", reason or "close")
  return true
end

function Service:reconcile(model)
  if self.closed then return false end
  self.model = model
  self.model_generation = model and model.generation or nil
  return true
end

function Service:on_syntax_registry_changed(reason)
  local ranges = {}
  for _, block in pairs(self.blocks) do
    ranges[#ranges + 1] = { block.body_line1, block.body_line2 }
  end
  self:release_heavy_caches("syntax-registry-" .. tostring(reason))
  for _, range in ipairs(ranges) do self:notify(range[1], range[2], "syntax-registry") end
end

function Service:on_tokenizer_backend_changed(generation, reason)
  local ranges = {}
  for _, block in pairs(self.blocks) do
    ranges[#ranges + 1] = { block.body_line1, block.body_line2 }
  end
  self.tokenizer_generation = generation
  self:release_heavy_caches("tokenizer-" .. tostring(reason))
  for _, range in ipairs(ranges) do self:notify(range[1], range[2], "tokenizer-backend") end
end

local function cached_line_count(block)
  local count = 0
  for _, entry in pairs(block.lines or {}) do
    if entry and entry.complete then count = count + 1 end
  end
  return count
end

function Service:cancel_queued_work(reason)
  self.generation = self.generation + 1
  self.queue = {}
  self.queued = {}
  self.ready_line1, self.ready_line2 = nil, nil
  self.diagnostics.queued_blocks = 0
  self.diagnostics.cancellations = self.diagnostics.cancellations + 1
  for _, block in pairs(self.blocks) do
    block.service_generation = self.generation
    block.in_progress = nil
  end
  core.log_quiet("Markdown fence work cancelled: %s", reason or "cancelled")
end

function Service:invalidate_block_suffix(block, relative)
  relative = math.max(1, math.min(relative, block.unsafe_from or relative))
  local old_suffix = block.old_suffix or {}
  local unsafe_until = math.max(relative, block.unsafe_until or relative)
  for index, entry in pairs(block.lines) do
    if index >= relative then
      old_suffix[index] = entry
      block.lines[index] = nil
      unsafe_until = math.max(unsafe_until, index)
      self.diagnostics.cached_lines = math.max(0, self.diagnostics.cached_lines - 1)
    end
  end
  block.old_suffix = next(old_suffix) and old_suffix or nil
  block.unsafe_from = relative
  block.unsafe_until = unsafe_until
  block.next_relative = math.min(block.next_relative, relative)
  block.failed_reason = nil
  block.token_generation = block.token_generation + 1
end

---Invalidates tokenizer-state-dependent cached suffixes immediately after a
---Document transaction. Repeated calls for the same transaction are harmless.
function Service:on_text_transaction(transaction)
  if self.closed or not (transaction and transaction.changed) then return nil end
  if self.last_transaction == transaction then
    return self.last_transaction_line1, self.last_transaction_line2
  end
  self.last_transaction = transaction
  local doc = self:doc()
  if not doc then return nil end
  local invalid_line1, invalid_line2
  local affected = false
  local ranges = transaction.changed_ranges or {}

  local function map_old_line(line, affinity)
    local delta = 0
    for _, range in ipairs(ranges) do
      local old_line1 = range.old_line1 or range.new_line1 or 1
      local old_line2 = range.old_line2 or old_line1
      if line < old_line1 then break end
      if line <= old_line2 then
        return affinity == "end"
          and (range.new_line2 or range.new_line1 or old_line2)
          or (range.new_line1 or old_line1)
      end
      delta = delta + (range.line_delta or 0)
    end
    return line + delta
  end

  for _, block in pairs(self.blocks) do
    local body_relative
    local structural = transaction.full_snapshot == true
    local retain_after_structure = not transaction.full_snapshot
    local intersects = structural
    local old_opening = block.opening_line
    local old_body_line1 = block.body_line1
    local old_body_line2 = block.body_line2
    local old_closing = block.closing_line
    local old_last = block.closing_line or block.body_line2

    for _, range in ipairs(ranges) do
      local old_line1 = range.old_line1 or range.new_line1 or 1
      local old_line2 = range.old_line2 or old_line1
      local delta = range.line_delta or 0
      if old_line1 <= old_last and old_line2 >= old_opening then
        intersects = true
        local touches_boundary = old_line1 <= old_opening
          or (old_closing and old_line2 >= old_closing)
        if delta ~= 0 or touches_boundary then
          structural = true
          retain_after_structure = retain_after_structure
            and delta == 0
            and old_line1 == old_opening
            and old_line2 == old_opening
        else
          body_relative = math.min(body_relative or math.huge, old_line1 - old_body_line1 + 1)
        end
      end
    end

    if transaction.full_snapshot then
      block.opening_line = 1
      block.body_line1 = 1
      block.body_line2 = #doc.lines
      block.closing_line = nil
    else
      block.opening_line = map_old_line(old_opening, "start")
      block.body_line1 = map_old_line(old_body_line1, "start")
      block.body_line2 = map_old_line(old_body_line2, "end")
      block.closing_line = old_closing and map_old_line(old_closing, "end") or nil
    end

    if intersects then
      affected = true
      block.source_revision = doc.text_revision
      if structural then
        block.structurally_unsafe = true
        block.retain_after_structure = retain_after_structure
        block.invalidated_model_generation = self.model_generation or 0
        block.unsafe_from = 1
        block.token_generation = block.token_generation + 1
        if not retain_after_structure then
          self.diagnostics.cached_lines = math.max(
            0, self.diagnostics.cached_lines - cached_line_count(block)
          )
          block.lines = {}
          block.old_suffix = nil
          block.next_relative = 1
        end
        invalid_line1 = math.min(invalid_line1 or block.opening_line, block.opening_line)
        local new_last = block.closing_line or block.body_line2
        invalid_line2 = math.max(invalid_line2 or new_last, new_last)
      elseif body_relative then
        self:invalidate_block_suffix(block, body_relative)
        local line1 = block.body_line1 + body_relative - 1
        invalid_line1 = math.min(invalid_line1 or line1, line1)
        invalid_line2 = math.max(invalid_line2 or block.body_line2, block.body_line2)
      end
    else
      block.source_revision = doc.text_revision
    end
  end

  if affected then self:cancel_queued_work("text-transaction") end
  self.last_transaction_line1 = invalid_line1
  self.last_transaction_line2 = invalid_line2
  if invalid_line1 then self:notify(invalid_line1, invalid_line2, "transaction") end
  return invalid_line1, invalid_line2
end

function Service:complete_node(node, line)
  if node and node.attributes and node.attributes.code_info then return node end
  if not (self.model and self.model.fenced_node_for_line) then return node end
  local complete, reason = self.model:fenced_node_for_line(line, { limit = 512 })
  if reason == "limit" or reason == "incomplete" then return nil, reason end
  return complete or node, reason
end

function Service:describe_block(node, line)
  local doc = self:doc()
  if not (doc and node and node.type == "code_fenced") then return nil, "missing" end
  node = self:complete_node(node, line)
  if not node then return nil, "incomplete" end

  local opening_line = node.source.line1
  local last_line = effective_line2(node)
  local opening = without_newline(doc.lines[opening_line])
  local marker, marker_count = fence_marker(opening)
  if not marker then return nil, "incomplete" end
  local has_closing = last_line > opening_line
    and closes_fence(without_newline(doc.lines[last_line]), marker, marker_count)
  local body_line1 = opening_line + 1
  local body_line2 = has_closing and last_line - 1 or last_line
  if body_line2 < body_line1 then body_line2 = body_line1 - 1 end

  local info = range_text(doc, node.attributes and node.attributes.code_info)
  local resolved, metadata = syntax.resolve_language(info, { source = "markdown-fence" })
  local selected = resolved or syntax.plain_text_syntax
  local fingerprint = table.concat({
    metadata.normalized or "", tostring(selected), tostring(body_line1 - opening_line),
    tostring(body_line2 - opening_line), marker, tostring(marker_count),
  }, "\0")
  return {
    id = node.id,
    node = node,
    fingerprint = fingerprint,
    info = info,
    metadata = metadata,
    selected_syntax = selected,
    syntax_identity = resolved,
    source_revision = doc.text_revision,
    opening_line = opening_line,
    closing_line = has_closing and last_line or nil,
    body_line1 = body_line1,
    body_line2 = body_line2,
    lines = {},
    next_relative = 1,
    wanted_relative = 0,
    token_generation = 0,
    service_generation = self.generation,
    tokenizer_generation = self.tokenizer_generation,
  }
end

function Service:block_for(node, line)
  local described, reason = self:describe_block(node, line)
  if not described then return nil, reason end
  local block = self.blocks[described.id]
  if not block then
    for previous_id, candidate in pairs(self.blocks) do
      if candidate.fingerprint == described.fingerprint
        and candidate.source_revision == described.source_revision
        and candidate.opening_line == described.opening_line
        and candidate.body_line1 == described.body_line1
        and candidate.body_line2 == described.body_line2
      then
        self.blocks[previous_id] = nil
        candidate.id = described.id
        self.blocks[described.id] = candidate
        block = candidate
        break
      end
    end
  end
  if block and block.structurally_unsafe and block.retain_after_structure
    and block.fingerprint == described.fingerprint
    and block.source_revision == described.source_revision
    and block.tokenizer_generation == self.tokenizer_generation
    and (self.model_generation or 0) > (block.invalidated_model_generation or 0)
  then
    block.structurally_unsafe = nil
    block.retain_after_structure = nil
    block.unsafe_from = nil
    block.unsafe_until = nil
    block.node = described.node
    block.opening_line = described.opening_line
    block.closing_line = described.closing_line
    block.body_line1 = described.body_line1
    block.body_line2 = described.body_line2
    return block
  end
  if block and block.fingerprint == described.fingerprint
    and block.source_revision == described.source_revision
    and block.tokenizer_generation == self.tokenizer_generation
    and not block.structurally_unsafe
  then
    block.node = described.node
    block.opening_line = described.opening_line
    block.closing_line = described.closing_line
    block.body_line1 = described.body_line1
    block.body_line2 = described.body_line2
    return block
  end
  if block then
    self.diagnostics.cancellations = self.diagnostics.cancellations + 1
    self.diagnostics.cached_lines = math.max(
      0, self.diagnostics.cached_lines - cached_line_count(block)
    )
    self.queued[block.id] = nil
  else
    self.diagnostics.blocks = self.diagnostics.blocks + 1
  end
  self.blocks[described.id] = described
  core.log_quiet(
    "Markdown fence language requested=%s normalized=%s reason=%s",
    tostring(described.metadata.requested), tostring(described.metadata.normalized),
    tostring(described.metadata.reason)
  )
  return described
end

function Service:queue_block(block, priority)
  block.priority = math.max(block.priority or 0, priority or 0)
  if not self.queued[block.id] then
    self.queued[block.id] = true
    self.queue[#self.queue + 1] = block
    self.diagnostics.queued_blocks = self.diagnostics.queued_blocks + 1
  end
  self:start_worker()
end

function Service:request(node, line, priority)
  self.diagnostics.requests = self.diagnostics.requests + 1
  if self.closed then return nil, "closed" end
  local block, reason = self:block_for(node, line)
  if not block then return nil, reason end
  if line < block.body_line1 or line > block.body_line2 then return nil, "delimiter" end
  local relative = line - block.body_line1 + 1
  local entry = block.lines[relative]
  local doc = self:doc()
  local source = doc and doc:get_utf8_line(line)
  if entry and entry.complete and entry.text == source
    and block.source_revision == (doc and doc.text_revision)
    and block.tokenizer_generation == self.tokenizer_generation
    and not block.structurally_unsafe
    and not (block.unsafe_from and relative >= block.unsafe_from)
  then
    self.diagnostics.cache_hits = self.diagnostics.cache_hits + 1
    return entry, "ready"
  end
  if block.failed_reason then return nil, block.failed_reason end
  self.diagnostics.cache_misses = self.diagnostics.cache_misses + 1
  block.wanted_relative = math.max(block.wanted_relative, relative)
  self:queue_block(block, priority)
  return nil, "pending"
end

function Service:line_tokens(node, line, priority)
  return self:request(node, line, priority)
end

function Service:peek_line_tokens(node, line)
  if self.closed or not node then return nil end
  local block = self.blocks[node.id]
  if not block or line < block.body_line1 or line > block.body_line2 then return nil end
  if block.source_revision ~= (self:doc() and self:doc().text_revision)
    or block.tokenizer_generation ~= self.tokenizer_generation
    or block.structurally_unsafe
  then
    return nil
  end
  local relative = line - block.body_line1 + 1
  if block.unsafe_from and relative >= block.unsafe_from then return nil end
  local entry = block.lines[relative]
  local doc = self:doc()
  if entry and entry.complete and doc and entry.text == doc:get_utf8_line(line) then return entry end
end

function Service:line_generation(node, line)
  local entry = self:peek_line_tokens(node, line)
  if entry then return entry.generation end
  local block = node and self.blocks[node.id]
  return block and ("pending:" .. tostring(block.token_generation)) or "cold"
end

function Service:is_line_unsafe(line)
  for _, block in pairs(self.blocks) do
    if line >= block.body_line1 and line <= block.body_line2 then
      local relative = line - block.body_line1 + 1
      return block.structurally_unsafe == true
        or (block.unsafe_from ~= nil and relative >= block.unsafe_from)
    end
  end
  return false
end

function Service:next_queued_block()
  local best_index, best
  for index, block in ipairs(self.queue) do
    if self.queued[block.id] and self.blocks[block.id] == block then
      if not best or (block.priority or 0) > (best.priority or 0) then
        best_index, best = index, block
      end
    end
  end
  if not best then
    self.queue = {}
    return nil
  end
  table.remove(self.queue, best_index)
  self.queued[best.id] = nil
  self.diagnostics.queued_blocks = math.max(0, self.diagnostics.queued_blocks - 1)
  best.priority = 0
  return best
end

function Service:tokenize_one(block)
  local doc = self:doc()
  if not doc or self.closed or self.blocks[block.id] ~= block
    or block.service_generation ~= self.generation
    or block.tokenizer_generation ~= self.tokenizer_generation
    or block.source_revision ~= doc.text_revision
  then
    self.diagnostics.stale_publications = self.diagnostics.stale_publications + 1
    return false, "stale"
  end
  local relative = block.next_relative
  if relative > block.wanted_relative then return false, "complete" end
  local line = block.body_line1 + relative - 1
  if line > block.body_line2 then return false, "complete" end
  local previous = relative > 1 and block.lines[relative - 1] or nil
  if relative > 1 and not (previous and previous.complete) then return false, "blocked" end
  local text = doc:get_utf8_line(line)
  if not text then return false, "stale" end
  local init_state = previous and previous.state or nil
  local current = block.in_progress
  if current and (current.relative ~= relative or current.text ~= text
    or current.init_state ~= init_state)
  then
    current = nil
    block.in_progress = nil
  end
  local tokens, state, resume = tokenizer.tokenize(
    block.selected_syntax, text, init_state, current and current.resume
  )
  self.diagnostics.bytes_tokenized = self.diagnostics.bytes_tokenized + #text
  if resume then
    block.in_progress = {
      relative = relative, text = text, init_state = init_state,
      tokens = tokens, state = state, resume = resume,
    }
    self.diagnostics.resumed_lines = self.diagnostics.resumed_lines + 1
    return true, "resume"
  end
  block.in_progress = nil
  if token_text(tokens) ~= text then
    self.diagnostics.token_mismatches = self.diagnostics.token_mismatches + 1
    block.failed_reason = "mismatch"
    core.log_quiet("Markdown fence token/source mismatch on line %d", line)
    return false, "mismatch"
  end
  block.token_generation = block.token_generation + 1
  block.lines[relative] = {
    text = text,
    init_state = init_state,
    tokens = tokens,
    state = state,
    complete = true,
    generation = block.token_generation,
  }
  block.next_relative = relative + 1
  self.diagnostics.lines_tokenized = self.diagnostics.lines_tokenized + 1
  self.diagnostics.cached_lines = self.diagnostics.cached_lines + 1
  local old = block.old_suffix and block.old_suffix[relative]
  if old and old.text == text and old.init_state == init_state and old.state == state then
    local reused_from = relative + 1
    local reused_to = relative
    local previous_state = state
    while block.old_suffix[reused_to + 1] do
      local candidate = block.old_suffix[reused_to + 1]
      local candidate_line = block.body_line1 + reused_to
      if candidate.text ~= doc:get_utf8_line(candidate_line)
        or candidate.init_state ~= previous_state
      then
        break
      end
      reused_to = reused_to + 1
      block.token_generation = block.token_generation + 1
      candidate.generation = block.token_generation
      block.lines[reused_to] = candidate
      previous_state = candidate.state
      self.diagnostics.lines_reused = self.diagnostics.lines_reused + 1
      self.diagnostics.cached_lines = self.diagnostics.cached_lines + 1
    end
    if reused_to >= reused_from then
      block.next_relative = reused_to + 1
      self:queue_ready_notification(
        block.body_line1 + reused_from - 1,
        block.body_line1 + reused_to - 1
      )
    end
    block.old_suffix = nil
    block.unsafe_from = nil
    block.unsafe_until = nil
    self.diagnostics.convergence_stops = self.diagnostics.convergence_stops + 1
  elseif block.unsafe_until and relative >= block.unsafe_until then
    block.old_suffix = nil
    block.unsafe_from = nil
    block.unsafe_until = nil
  end
  self:queue_ready_notification(line, line)
  return true, "ready"
end

function Service:start_worker()
  if self.worker_running or self.closed then return end
  self.worker_running = true
  local worker_generation = self.generation
  core.add_thread(function()
    local processed = 0
    while not self.closed and self.generation == worker_generation do
      local block = self:next_queued_block()
      if not block then break end
      while block.next_relative <= block.wanted_relative do
        local progressed, reason = self:tokenize_one(block)
        if not progressed then break end
        processed = processed + 1
        if reason == "resume" or processed >= BATCH_LINES then
          processed = 0
          self:flush_ready_notifications()
          core.redraw = true
          coroutine.yield(0)
          if self.closed or self.generation ~= worker_generation then break end
        end
      end
    end
    self:flush_ready_notifications()
    self.worker_running = false
    core.redraw = true
    if not self.closed and #self.queue > 0 then self:start_worker() end
  end, self)
end

function Service:get_diagnostics()
  local copy = {}
  for key, value in pairs(self.diagnostics) do copy[key] = value end
  copy.closed = self.closed
  copy.generation = self.generation
  return copy
end

function fence_highlight.get(doc)
  if not doc then return nil end
  local service = services_by_doc[doc]
  if not service or service.closed then
    service = Service:new(doc)
    services_by_doc[doc] = service
  end
  return service
end

function fence_highlight.peek(doc)
  return services_by_doc[doc]
end

function fence_highlight.close(doc, reason)
  local service = services_by_doc[doc]
  return service and service:close(reason) or false
end

Doc.register_text_transaction_handler("markdown-fence-highlight", function(doc, transaction)
  local service = services_by_doc[doc]
  if service then service:on_text_transaction(transaction) end
end)

return fence_highlight
