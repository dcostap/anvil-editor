local test = require "core.test"
local common = require "core.common"
local native_pool = require "worker_pool_native"

local function drain_until(pool, predicate, limit)
  limit = limit or 1000
  for _ = 1, limit do
    for _, message in ipairs(pool:drain({ max_messages = 64 })) do
      if predicate(message) then return true end
    end
    coroutine.yield(0.001)
  end
  for _, message in ipairs(pool:drain({ max_messages = 64 })) do
    if predicate(message) then return true end
  end
  return false
end

test.describe("worker_pool_native", function()
  local pools = {}

  local function new_pool(name, workers)
    local pool = native_pool.new({ name = name, worker_count = workers or 1 })
    pools[#pools + 1] = pool
    return pool
  end

  local function submit_result(pool, spec)
    local handle = test.not_nil(pool:submit(spec))
    local result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then result = message.result end
      return message.type == "final"
    end))
    return test.not_nil(result), handle
  end

  test.after_each(function()
    for i = #pools, 1, -1 do
      pools[i]:shutdown({ cancel_running = true })
      pools[i] = nil
    end
  end)

  test.test("delivers results and terminal status", function()
    local pool = new_pool("lua-native-submit", 1)
    local handle = pool:submit({ kind = "test_echo", value = "hello" })
    test.not_nil(handle)
    local value
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then value = message.value end
      return message.type == "final"
    end))
    test.equal(value, "hello")
    test.equal(pool:status(handle).status, "complete")
  end)

  test.test("running cancellation reaches native job", function()
    local pool = new_pool("lua-native-cancel", 1)
    local handle = pool:submit({ kind = "test_count", count = 1000, sleep_ms = 1 })
    test.ok(drain_until(pool, function(message) return message.type == "progress" and message.index >= 2 end))
    test.ok(pool:cancel(handle))
    test.ok(drain_until(pool, function(message) return message.type == "cancelled" end))
    test.equal(pool:status(handle).status, "cancelled")
  end)

  test.test("Markdown jobs honor shared cancel tokens without semantic queries", function()
    local pool = new_pool("lua-native-markdown-cancel", 1)
    local token = native_pool.new_cancel_token()
    local handle = pool:submit({
      kind = "markdown_parse",
      text = string.rep("# Heading with **bold** text\n", 30000),
      cancel_token = token:name(),
      parse_timeout_ms = 5000,
    })
    test.not_nil(handle)
    token:cancel()
    test.ok(drain_until(pool, function(message) return message.type == "cancelled" end, 5000))
    test.equal(pool:status(handle).status, "cancelled")
  end)

  test.test("cancel tokens can be opened by name across Lua states", function()
    local token = native_pool.new_cancel_token()
    local name = token:name()
    test.ok(name ~= "")
    local opened = native_pool.open_cancel_token(name)
    test.equal(opened:cancelled(), false)
    token:cancel()
    test.equal(opened:cancelled(), true)
  end)

  test.test("drain respects message count budget", function()
    local pool = new_pool("lua-native-drain-budget", 1)
    pool:submit({ kind = "test_count", count = 10, sleep_ms = 0 })
    test.ok(drain_until(pool, function(message) return message.type == "progress" end))
    local messages = pool:drain({ max_messages = 2 })
    test.ok(#messages <= 2)
  end)

  test.test("Tree-sitter index job returns bounded result handle", function()
    local pool = new_pool("lua-native-treesitter-index", 1)
    local handle = pool:submit({
      kind = "treesitter_index_text",
      language = "c",
      text = "int add(int a, int b) { return a + b; }\n",
      outline_query = "(function_definition) @definition.function",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    })
    test.not_nil(handle)
    local result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then result = message.result end
      return message.type == "final"
    end))
    test.not_nil(result)
    local summary = result:summary()
    test.equal(summary.language, "c")
    test.ok(summary.line_count > 0)
    test.ok(summary.metrics.total_ms >= summary.metrics.parse_ms)
    test.equal(summary.outline.status, "ready")
    test.equal(summary.outline.line_indexed, true)
    test.ok(summary.outline.capture_count >= 1)
    local captures = result:captures("outline", { offset = 1, limit = 1 })
    test.equal(#captures, 1)
    test.equal(captures[1].capture, "definition.function")
    test.equal(captures.total, summary.outline.capture_count)
    test.ok(captures.next_offset >= 2)
  end)

  test.test("Tree-sitter Project capabilities skip line indexes and normalize length-aware input", function()
    local pool = new_pool("lua-native-treesitter-project-capabilities", 1)
    local source = "int first(void) { return 1; }\r\nint second(void) { return first(); }\r\n"
    local result = submit_result(pool, {
      kind = "treesitter_index_text",
      language = "c",
      text = source,
      outline_query = "(function_definition) @definition.function",
      capture_paging = true,
      line_range_lookup = false,
      compact_project_records = false,
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    })
    local summary = result:summary()
    test.equal(summary.byte_len, #(source:gsub("\r\n", "\n")))
    test.equal(summary.capabilities.capture_paging, true)
    test.equal(summary.capabilities.line_range_lookup, false)
    test.equal(summary.outline.line_indexed, false)
    test.equal(summary.metrics.line_indexes_skipped, 1)
    test.equal(#result:captures_for_lines("outline", 2, 2), 1)
  end)

  test.test("Tree-sitter native jobs can own and normalize file input directly", function()
    local path = USERDIR .. PATHSEP .. "native-worker-owned-input.c"
    local fp = test.not_nil(io.open(path, "wb"))
    local source = "int from_path(void) { return 1; }\r\n"
    fp:write(source)
    fp:close()
    local pool = new_pool("lua-native-treesitter-owned-path", 1)
    local result = submit_result(pool, {
      kind = "treesitter_index_text",
      language = "c",
      path = path,
      outline_query = "(function_definition) @definition.function",
      capture_paging = true,
      line_range_lookup = false,
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    })
    os.remove(path)
    local summary = result:summary()
    test.equal(summary.byte_len, #(source:gsub("\r\n", "\n")))
    test.equal(summary.outline.capture_count, 1)
    test.equal(summary.outline.line_indexed, false)
  end)

  test.test("Tree-sitter workers reuse parsers and compiled query fingerprints", function()
    local pool = new_pool("lua-native-treesitter-cache-reuse", 1)
    local spec = {
      kind = "treesitter_index_text",
      language = "c",
      text = "int cache_target(void) { return 1; }\n",
      outline_query = "(identifier) @milestone_two_cache_target",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    }
    local first = submit_result(pool, spec):summary()
    local second = submit_result(pool, spec):summary()
    test.equal(first.outline.query_cache_miss, true)
    test.equal(second.outline.query_cache_hit, true)
    test.equal(first.metrics.parser_reused, false)
    test.equal(second.metrics.parser_reused, true)
  end)

  test.test("Tree-sitter query cache retains failed compilation metadata", function()
    local pool = new_pool("lua-native-treesitter-failed-query-cache", 1)
    local spec = {
      kind = "treesitter_index_text",
      language = "c",
      text = "int failed_cache_target(void) { return 1; }\n",
      outline_query = "((identifier) @milestone_two_bad_cache",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    }
    local first = submit_result(pool, spec):summary()
    local second = submit_result(pool, spec):summary()
    test.equal(first.outline.status, "failed")
    test.equal(first.outline.query_cache_miss, true)
    test.equal(second.outline.status, "failed")
    test.equal(second.outline.query_cache_hit, true)
    test.equal(second.outline.error, first.outline.error)
  end)

  test.test("Markdown native jobs reject embedded NUL queries without truncation", function()
    local pool = new_pool("lua-native-markdown-query-nul", 1)
    local handle, err = pool:submit({
      kind = "markdown_parse",
      text = "# Heading\n",
      outline_query = "(atx_heading) @heading\0(paragraph) @paragraph",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    })
    test.is_nil(handle)
    test.equal(err, "Tree-sitter query contains embedded NUL")
  end)

  test.test("Tree-sitter native jobs reject embedded NUL input without truncation", function()
    local pool = new_pool("lua-native-treesitter-nul", 1)
    local error_message
    local handle = test.not_nil(pool:submit({
      kind = "treesitter_index_text",
      language = "c",
      text = "int before(void) { return 1; }\0int after(void) { return 2; }\n",
      outline_query = "(function_definition) @definition.function",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    }))
    test.ok(drain_until(pool, function(message)
      if message.type == "error" then error_message = message.error end
      return message.type == "error"
    end))
    test.equal(error_message, "Tree-sitter input contains embedded NUL")
    test.equal(pool:status(handle).status, "failed")
  end)

  test.test("native Project records bound previews and prefer duplicate declarations", function()
    local pool = new_pool("lua-native-project-record-edges", 1)
    local long_name = string.rep("n", 1200)
    local result = submit_result(pool, {
      kind = "treesitter_index_text",
      language = "c",
      path = "long.c",
      relpath = "long.c",
      text = "int " .. long_name .. "(void) { return 0; }\n",
      outline_query = [[
        (function_definition
          declarator: (function_declarator
            declarator: (identifier) @name
            parameters: (parameter_list) @signature.params)) @outline.function
      ]],
      usage_query = [[
        (function_declarator
          declarator: (identifier) @reference @definition.function)
      ]],
      capture_paging = false,
      line_range_lookup = false,
      compact_project_records = true,
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      usage_query_timeout_ms = 100,
      max_captures = 100,
      usage_max_captures = 100,
    })
    test.error(function() result:symbols({ limit = 4097 }) end)
    test.error(function() result:usages({ limit = 4097 }) end)
    local symbols = result:symbols({ limit = 10 })
    local usages = result:usages({ limit = 10 })
    test.equal(#symbols, 1)
    test.ok(#symbols[1].declaration <= 1024)
    test.equal(#usages, 1)
    test.equal(usages[1].capture, "definition.function")
    test.equal(usages[1].is_declaration, true)
    test.ok(#usages[1].line_text <= 512)
  end)

  test.test("native Project builders publish immutable deterministic snapshots", function()
    local pool = new_pool("lua-native-project-builder", 2)
    local builder = native_pool.new_project_builder({ usage_cap = 2 })
    local function extract(path, source)
      return submit_result(pool, {
        kind = "treesitter_index_text",
        language = "c",
        path = path,
        relpath = path,
        text = source,
        outline_query = [[
          (function_definition
            declarator: (function_declarator
              declarator: (identifier) @name
              parameters: (parameter_list) @signature.params)) @outline.function
        ]],
        usage_query = [[
          (function_declarator declarator: (identifier) @definition.function)
          (identifier) @reference
        ]],
        capture_paging = false,
        line_range_lookup = false,
        compact_project_records = true,
        parse_timeout_ms = 1000,
        query_timeout_ms = 100,
        usage_query_timeout_ms = 100,
        max_captures = 100,
        usage_max_captures = 100,
      })
    end

    local later = extract("z.c", "int zed(void) { return zed(); }\n")
    local earlier = extract("a.c", "int alpha(void) { return alpha(); }\n")
    test.ok(later:adopt_project(builder:id(), { fingerprint = "z-1", usage_complete = true }))
    test.ok(earlier:adopt_project(builder:id(), { fingerprint = "a-1", usage_complete = true }))

    local partial = builder:snapshot({ status = "partial" })
    local partial_summary = partial:summary()
    test.equal(partial_summary.status, "partial")
    test.equal(partial_summary.files, 2)
    test.equal(partial_summary.symbols, 2)
    test.equal(partial_summary.usages, 2)
    test.equal(partial_summary.usage_names, 1)
    test.equal(partial_summary.usage_truncated, true)
    local symbols = partial:symbols({ offset = 1, limit = 10 })
    test.equal(symbols[1].relpath, "a.c")
    test.equal(symbols[2].relpath, "z.c")
    local usages = partial:usages({ offset = 1, limit = 10 })
    test.equal(#usages, 2)
    test.equal(usages.total, 2)
    test.equal(usages[1].relpath, "a.c")
    test.equal(usages[2].relpath, "a.c")

    local first_page = partial:query_symbols("", { offset = 0, limit = 1 })
    test.equal(#first_page, 1)
    test.equal(first_page[1].name, "alpha")
    test.equal(first_page.total, 2)
    test.equal(first_page.has_more, true)
    local second_page = partial:query_symbols("", { offset = first_page.next_offset, limit = 1 })
    test.equal(#second_page, 1)
    test.equal(second_page[1].name, "zed")
    test.equal(second_page.has_more, false)
    local selective = partial:query_symbols("zd", { limit = 10, kinds = { "function" } })
    test.equal(#selective, 1)
    test.equal(selective[1].name, "zed")
    local excluded = partial:query_symbols("", { limit = 10, excluded_paths = { "a.c" } })
    test.equal(#excluded, 1)
    test.equal(excluded[1].name, "zed")
    local usage_page = partial:query_usages("alpha", { offset = 0, limit = 1 })
    test.equal(#usage_page, 1)
    test.equal(usage_page.total, 2)
    test.equal(usage_page.has_more, true)
    local usage_page2 = partial:query_usages("alpha", { offset = usage_page.next_offset, limit = 1 })
    test.equal(#usage_page2, 1)
    test.equal(usage_page2.has_more, false)
    local references_only = partial:query_usages("alpha", { limit = 10, include_declaration = false })
    test.equal(references_only.total, 1)
    test.equal(references_only[1].is_declaration, false)
    test.equal(partial:query_usages("alpha", { limit = 10, excluded_paths = { "a.c" } }).total, 0)
    test.error(function() partial:query_symbols("", { limit = 4097 }) end)
    test.error(function() partial:query_usages("alpha", { limit = 4097 }) end)

    local replacement = extract("a.c", "int beta(void) { return beta(); }\n")
    test.ok(replacement:adopt_project(builder:id(), { fingerprint = "a-2", usage_complete = true }))
    local removed = extract("q.c", "int removed(void) { return removed(); }\n")
    test.ok(removed:adopt_project(builder:id(), { fingerprint = "q-1", usage_complete = true }))
    test.equal(builder:remove("q.c"), true)
    test.equal(builder:remove("q.c"), false)
    local ready = builder:freeze()
    test.equal(ready:summary().status, "ready")
    local ready_symbols = ready:symbols({ offset = 1, limit = 10 })
    test.equal(#ready_symbols, 2)
    test.equal(ready_symbols[1].name, "beta")
    test.equal(ready_symbols[2].name, "zed")
    local files = ready:files({ offset = 1, limit = 10 })
    test.equal(files[1].relpath, "a.c")
    test.equal(files[1].fingerprint, "a-2")
    test.error(function() extract("q.c", "int q(void) { return 0; }\n"):adopt_project(builder:id()) end)
    builder:close()
    test.equal(ready:symbols({ limit = 10 })[1].name, "beta")
    pool:shutdown({ cancel_running = true })
  end)

  test.test("native Project batch jobs transfer bounded file sets without record messages", function()
    local path1 = USERDIR .. PATHSEP .. "native-project-batch-a.c"
    local path2 = USERDIR .. PATHSEP .. "native-project-batch-b.c"
    local path3 = USERDIR .. PATHSEP .. "native-project-batch-usage-failed.c"
    local path4 = USERDIR .. PATHSEP .. "native-project-batch-outline-failed.c"
    for path, source in pairs({
      [path1] = "int batch_a(void) { return batch_a(); }\n",
      [path2] = "int batch_b(void) { return batch_b(); }\n",
      [path3] = "int batch_usage_failed(void) { return 0; }\n",
      [path4] = "int batch_outline_failed(void) { return 0; }\n",
    }) do
      local fp = test.not_nil(io.open(path, "wb"))
      fp:write(source)
      fp:close()
    end
    local pool = new_pool("lua-native-project-batch", 2)
    local builder = native_pool.new_project_builder({ usage_cap = 100 })
    local outline_query = [[
      (function_definition
        declarator: (function_declarator
          declarator: (identifier) @name
          parameters: (parameter_list) @signature.params)) @outline.function
    ]]
    local usage_query = [[(identifier) @reference]]
    local handle = test.not_nil(pool:submit({
      kind = "treesitter_project_batch",
      project_builder_id = builder:id(),
      files = {
        { path = path2, relpath = "b.c", fingerprint = "b-1", language = "c",
          outline_query = outline_query, usage_query = usage_query, parse_timeout_ms = 1000,
          query_timeout_ms = 100, usage_query_timeout_ms = 100, max_captures = 100, usage_max_captures = 100 },
        { path = path1, relpath = "a.c", fingerprint = "a-1", language = "c",
          outline_query = outline_query, usage_query = usage_query, parse_timeout_ms = 1000,
          query_timeout_ms = 100, usage_query_timeout_ms = 100, max_captures = 100 },
        { path = path3, relpath = "usage-failed.c", fingerprint = "failed-1", language = "c",
          outline_query = outline_query, usage_query = "(not_a_c_node) @reference", parse_timeout_ms = 1000,
          query_timeout_ms = 100, usage_query_timeout_ms = 100, max_captures = 100, usage_max_captures = 100 },
        { path = path4, relpath = "outline-failed.c", fingerprint = "outline-failed-1", language = "c",
          outline_query = "(not_a_c_node) @outline.function", usage_query = usage_query, parse_timeout_ms = 1000,
          query_timeout_ms = 100, usage_query_timeout_ms = 100, max_captures = 100, usage_max_captures = 100 },
        { path = path1 .. ".gone", relpath = "gone.c", fingerprint = "gone", language = "c",
          outline_query = outline_query, usage_query = usage_query, parse_timeout_ms = 1000,
          query_timeout_ms = 100, usage_query_timeout_ms = 100, max_captures = 100, usage_max_captures = 100 },
      },
    }))
    local batch_payload, saw_record_handle
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then
        batch_payload = message.payload
        saw_record_handle = message.result ~= nil
      end
      return message.type == "final" and message.job_id == handle:status().id
    end))
    test.equal(saw_record_handle, false)
    test.equal(batch_payload.files_completed, 3)
    test.equal(batch_payload.files_skipped, 2)
    local snapshot = builder:freeze()
    test.same({ "a.c", "b.c", "usage-failed.c" }, (function()
      local out = {}
      for _, file in ipairs(snapshot:files({ limit = 10 })) do out[#out + 1] = file.relpath end
      return out
    end)())
    test.equal(snapshot:summary().symbols, 3)
    test.equal(snapshot:summary().usages, 4)
    test.equal(snapshot:summary().usage_complete, false)
    os.remove(path1)
    os.remove(path2)
    os.remove(path3)
    os.remove(path4)
  end)

  test.test("native Project runs enumerate, filter, parse, and publish through one job", function()
    local root = USERDIR .. PATHSEP .. "native-project-run"
    common.rm(root, true)
    common.mkdirp(root .. PATHSEP .. "ignored")
    common.mkdirp(root .. PATHSEP .. "excluded")
    local function write(path, text)
      local fp = test.not_nil(io.open(path, "wb")); fp:write(text); fp:close()
    end
    write(root .. PATHSEP .. "a.c", "int alpha(void) { return alpha(); }\n")
    write(root .. PATHSEP .. "b.c", "int beta(void) { return beta(); }\n")
    write(root .. PATHSEP .. "ignored" .. PATHSEP .. "skip.c", "int skipped(void) { return 0; }\n")
    write(root .. PATHSEP .. "excluded" .. PATHSEP .. "skip.c", "int excluded(void) { return 0; }\n")
    write(root .. PATHSEP .. "note.txt", "not source\n")
    local outline_query = [[
      (function_definition declarator: (function_declarator
        declarator: (identifier) @name
        parameters: (parameter_list) @signature.params)) @outline.function
    ]]
    local pool = new_pool("lua-native-project-run", 2)
    local builder = native_pool.new_project_builder({ usage_cap = 100 })
    local handle = test.not_nil(pool:submit({
      kind = "treesitter_project_run",
      project_builder_id = builder:id(),
      project_root = root,
      excluded_paths = { root .. PATHSEP .. "excluded" },
      ignore_patterns = "^ignored/",
      project_usage_cap = 100,
      max_file_bytes = 1024 * 1024,
      languages = {
        {
          id = "c", grammar = "c", files = { "native%-project%-run.*%.c$" }, outline_query = outline_query,
          usage_query = "(identifier) @reference", parse_timeout_ms = 1000,
          query_timeout_ms = 100, usage_query_timeout_ms = 100,
          match_limit = 100, max_captures = 100, usage_match_limit = 100, usage_max_captures = 100,
        },
      },
    }))
    local final_payload, progress_count = nil, 0
    test.ok(drain_until(pool, function(message)
      if message.type == "progress" then progress_count = progress_count + 1 end
      if message.type == "result" then final_payload = message.payload end
      return message.type == "final" and message.job_id == handle:status().id
    end, 10000))
    test.ok(progress_count > 0)
    test.equal(final_payload.files_completed, 2)
    local snapshot = builder:freeze()
    test.equal(snapshot:summary().files, 2)
    test.same({ "a.c", "b.c" }, (function()
      local out = {}
      for _, file in ipairs(snapshot:files({ limit = 10 })) do out[#out + 1] = file.relpath:gsub("\\", "/") end
      return out
    end)())
    common.rm(root, true)
  end)

  test.test("cancelling a native Project batch publishes no partial ownership", function()
    local path = USERDIR .. PATHSEP .. "native-project-batch-cancel.c"
    local fp = test.not_nil(io.open(path, "wb"))
    fp:write(string.rep("int cancellable_value = 1;\n", 50000))
    fp:close()
    local files = {}
    for i = 1, 20 do
      files[i] = {
        path = path, relpath = string.format("cancel-%02d.c", i), fingerprint = tostring(i), language = "c",
        outline_query = "(declaration) @outline.variable", usage_query = "(identifier) @reference",
        parse_timeout_ms = 5000, query_timeout_ms = 1000, usage_query_timeout_ms = 1000,
        max_captures = 100000, usage_max_captures = 100000,
      }
    end
    local pool = new_pool("lua-native-project-batch-cancel", 1)
    local builder = native_pool.new_project_builder({ usage_cap = 100 })
    local handle = test.not_nil(pool:submit({
      kind = "treesitter_project_batch",
      project_builder_id = builder:id(),
      files = files,
    }))
    for _ = 1, 100 do
      if pool:status(handle).status == "running" then break end
      coroutine.yield(0.001)
    end
    test.ok(pool:cancel(handle))
    test.ok(drain_until(pool, function(message) return message.type == "cancelled" end, 5000))
    local partial = builder:snapshot({ status = "cancelled" })
    test.equal(partial:summary().files, 0)
    builder:close()
    os.remove(path)
  end)

  test.test("Markdown block reuse requires an identical complete structural query", function()
    local pool = new_pool("lua-native-markdown-query-reuse", 1)
    local spec = {
      kind = "markdown_parse",
      text = "# A\n\nText.\n\n# B\n",
      outline_query = "(atx_heading) @heading",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 1,
    }
    local limited = submit_result(pool, spec)
    test.equal(limited:summary().outline.status, "limit")

    spec.text = "# C\n\nText.\n\n# B\n"
    spec.previous_result = limited
    local limited_again = submit_result(pool, spec)
    local limited_summary = limited_again:summary()
    test.equal(limited_summary.outline.status, "limit")
    test.equal(limited_summary.metrics.reused_block_captures, 0)

    spec.max_captures = 100
    spec.previous_result = nil
    local complete = submit_result(pool, spec)
    test.equal(complete:summary().outline.status, "ready")

    spec.max_captures = 1
    spec.text = "# D\n\nText.\n\n# B\n"
    spec.previous_result = complete
    local lowered_limit = submit_result(pool, spec)
    test.equal(lowered_limit:summary().outline.status, "limit")
    test.equal(lowered_limit:captures("outline")[1].start_byte, 0)

    spec.max_captures = 100
    spec.text = "# Earlier\n\n# C\n\nText.\n\n# B\n"
    spec.previous_result = complete
    local inserted = submit_result(pool, spec)
    local ordered = inserted:captures("outline")
    test.equal(#ordered, 3)
    test.equal(ordered[1].start_byte, 0)
    for i = 2, #ordered do test.ok(ordered[i - 1].start_byte <= ordered[i].start_byte) end

    spec.outline_query = "(paragraph) @paragraph"
    spec.previous_result = inserted
    local changed_query = submit_result(pool, spec)
    local changed_summary = changed_query:summary()
    test.equal(changed_summary.metrics.reused_block_captures, 0)
    test.equal(changed_summary.outline.capture_count, 1)
    test.equal(changed_query:captures("outline")[1].capture, "paragraph")

    spec.text = "# A\n"
    spec.outline_query = "((atx_heading) @heading (#match? @heading \"A\"))"
    spec.previous_result = nil
    local predicate_before = submit_result(pool, spec)
    test.equal(predicate_before:summary().outline.capture_count, 1)
    spec.text = "# B\n"
    spec.previous_result = predicate_before
    local predicate_after = submit_result(pool, spec)
    test.equal(predicate_after:summary().metrics.reused_block_captures, 0)
    test.equal(predicate_after:summary().outline.capture_count, 0)
  end)

  test.test("Markdown block reuse replaces containers extended at a changed boundary", function()
    local pool = new_pool("lua-native-markdown-container-reuse", 1)
    local spec = {
      kind = "markdown_parse",
      text = "- one\n",
      outline_query = "(list) @list\n(list_item) @item",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      max_captures = 100,
    }
    local before = submit_result(pool, spec)
    spec.text = "- one\n- two\n"
    spec.previous_result = before
    local after = submit_result(pool, spec)
    local captures = after:captures("outline")
    local lists, items = 0, 0
    local match_ids = {}
    for _, capture in ipairs(captures) do
      test.equal(match_ids[capture.match_id], nil)
      match_ids[capture.match_id] = true
      if capture.capture == "list" then
        lists = lists + 1
        test.equal(capture.start_byte, 0)
        test.equal(capture.end_byte, #spec.text)
      elseif capture.capture == "item" then
        items = items + 1
      end
    end
    test.equal(lists, 1)
    test.equal(items, 2)
  end)

  test.test("Markdown job publishes block and inline captures from one composite parse", function()
    local pool = new_pool("lua-native-markdown-parse", 1)
    local spec = {
      kind = "markdown_parse",
      text = "# Heading\n\nFirst *span*.\nSecond **span**.\n",
      outline_query = "(atx_heading) @heading",
      usage_query = "(emphasis) @span\n(emphasis) @span\n(strong_emphasis) @span",
      parse_timeout_ms = 1000,
      query_timeout_ms = 100,
      usage_query_timeout_ms = 100,
      max_captures = 100,
      usage_max_captures = 100,
    }
    local handle = pool:submit(spec)
    test.not_nil(handle)
    local result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then result = message.result end
      return message.type == "final"
    end))
    test.not_nil(result)
    local summary = result:summary()
    test.equal(summary.language, "markdown")
    test.equal(summary.outline.status, "ready")
    test.equal(summary.usage.status, "ready")
    test.equal(summary.outline.line_indexed, true)
    test.equal(summary.usage.line_indexed, true)
    test.equal(summary.outline.capture_count, 1)
    test.equal(summary.usage.capture_count, 3)
    local heading = result:captures_for_lines("outline", 1, 1)[1]
    test.not_nil(heading.node_id)
    local following_line = result:captures_for_lines("outline", 2, 2)
    test.equal(#following_line, 0)
    local first_line = result:captures_for_lines("usage", 3, 3)
    test.equal(#first_line, 2)
    test.equal(first_line[1].capture, "span")
    test.ok(first_line[1].node_id ~= first_line[2].node_id)
    test.equal(first_line.truncated, false)

    spec.text = spec.text .. "Another paragraph.\n"
    spec.previous_result = result
    local incremental_handle = pool:submit(spec)
    test.not_nil(incremental_handle)
    local incremental_result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then incremental_result = message.result end
      return message.type == "final"
    end))
    local incremental_summary = incremental_result:summary()
    test.equal(incremental_summary.metrics.incremental, true)
    test.ok(incremental_summary.metrics.reused_block_captures > 0)
    test.ok(incremental_summary.metrics.reused_inline_regions > 0)
    local incremental_heading = incremental_result:captures_for_lines("outline", 1, 1)[1]
    test.equal(incremental_heading.node_id, heading.node_id)

    spec.text = "Preface paragraph.\n" .. spec.text
    spec.previous_result = incremental_result
    local shifted_handle = pool:submit(spec)
    test.not_nil(shifted_handle)
    local shifted_result
    test.ok(drain_until(pool, function(message)
      if message.type == "result" then shifted_result = message.result end
      return message.type == "final"
    end))
    local shifted_summary = shifted_result:summary()
    test.equal(shifted_summary.metrics.incremental, true)
    test.ok(shifted_summary.metrics.reused_inline_regions > 0)
    local shifted_heading = shifted_result:captures_for_lines("outline", 2, 2)[1]
    test.equal(shifted_heading.node_id, heading.node_id)
    test.equal(result:close(), true)
    test.equal(result:close(), false)
    test.equal(incremental_result:close(), true)
    test.equal(shifted_result:close(), true)
  end)
end)
