local common = require "core.common"
local Doc = require "core.doc"
local intelligence = require "core.language_intelligence"
local documents = require "core.lsp.documents"
local provider = require "core.lsp.provider"
local test = require "core.test"

local temp_root
local registered = {}

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_doc(path, text)
  local doc = Doc()
  set_text(doc, text or "")
  doc:set_filename(path, path)
  return doc
end

local function register_fallback(id, symbols)
  id = id or "test-lsp-provider-fallback"
  registered[#registered + 1] = id
  intelligence.register_provider({
    id = id,
    priority = 1,
    document_outline = function()
      return symbols or { { name = "fallback", kind = "function" } }
    end,
  })
end

local function fake_client(opts)
  opts = opts or {}
  return {
    server_id = opts.server_id or "fake-lsp",
    generation = opts.generation or 1,
    position_encoding = opts.position_encoding or "utf-16",
    capabilities = opts.capabilities or { documentSymbolProvider = true },
    sent = {},
    requests = {},
    send_notification = function(self, method, params)
      self.sent[#self.sent + 1] = { method = method, params = params }
      return true
    end,
    send_request = function(self, method, params, callback, request_opts)
      local id = #self.requests + 1
      self.requests[#self.requests + 1] = {
        id = id,
        method = method,
        params = params,
        callback = callback,
        opts = request_opts,
      }
      return id
    end,
  }
end

local function lsp_range(sl, sc, el, ec)
  return {
    start = { line = sl, character = sc },
    ["end"] = { line = el, character = ec },
  }
end

local function complete_request(client, index, result, err)
  local request = test.not_nil(client.requests[index])
  request.callback(result, err)
end

test.describe("core.lsp.provider document symbols", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-provider-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    mkdir(temp_root)
    provider.clear()
  end)

  test.after_each(function(context)
    for i = #registered, 1, -1 do
      intelligence.unregister_provider(registered[i])
    end
    registered = {}
    provider.clear()
    if context.docs then
      for _, doc in ipairs(context.docs) do pcall(function() doc:on_close() end) end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function track_doc(context, doc)
    context.docs = context.docs or {}
    context.docs[#context.docs + 1] = doc
    return doc
  end

  local function attach(context, opts)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), opts and opts.text or "class C {\n  void f();\n};"))
    local client = fake_client(opts)
    documents.attach(client, doc, { language_id = "cpp" })
    provider.register_client(client)
    return doc, client
  end

  test.test("pending documentSymbol request falls back to lower-priority provider", function(context)
    local doc, client = attach(context)
    register_fallback("test-provider-pending-fallback")

    local symbols, _reason, provider_id, status = intelligence.document_outline(doc)
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "textDocument/documentSymbol")
    test.equal(symbols[1].name, "fallback")
    test.equal(provider_id, "test-provider-pending-fallback")
    test.equal(status, "fresh")
  end)

  test.test("dedupes in-flight documentSymbol requests", function(context)
    local doc, client = attach(context)
    register_fallback("test-provider-dedupe-fallback")

    intelligence.document_outline(doc)
    intelligence.document_outline(doc)
    test.equal(#client.requests, 1)
  end)

  test.test("fresh cache hit returns LSP symbols and does not fall through", function(context)
    local doc, client = attach(context)
    register_fallback("test-provider-cache-fallback")

    intelligence.document_outline(doc)
    complete_request(client, 1, {
      {
        name = "C",
        kind = 5,
        range = lsp_range(0, 0, 2, 2),
        selectionRange = lsp_range(0, 6, 0, 7),
        children = {
          {
            name = "f",
            kind = 6,
            range = lsp_range(1, 2, 1, 11),
            selectionRange = lsp_range(1, 7, 1, 8),
          },
        },
      },
    })

    local symbols, reason, provider_id, status = intelligence.document_outline(doc)
    test.is_nil(reason)
    test.equal(provider_id, "lsp")
    test.equal(status, "fresh")
    test.equal(#symbols, 2)
    test.equal(symbols[1].name, "C")
    test.equal(symbols[1].kind, "class")
    test.equal(symbols[1].depth, 0)
    test.equal(symbols[1].children[1], 2)
    test.equal(symbols[2].name, "f")
    test.equal(symbols[2].kind, "method")
    test.equal(symbols[2].parent, 1)
    test.equal(symbols[2].depth, 1)
  end)

  test.test("maps flat SymbolInformation responses", function(context)
    local doc, client = attach(context)
    register_fallback("test-provider-flat-fallback")

    intelligence.document_outline(doc)
    complete_request(client, 1, {
      {
        name = "f",
        kind = 12,
        location = { uri = documents.state(client, doc).uri, range = lsp_range(1, 2, 1, 11) },
      },
      {
        name = "C",
        kind = 5,
        location = { uri = documents.state(client, doc).uri, range = lsp_range(0, 0, 2, 2) },
      },
    })

    local symbols = intelligence.document_outline(doc)
    test.equal(#symbols, 2)
    test.equal(symbols[1].name, "C")
    test.equal(symbols[1].kind, "class")
    test.equal(symbols[2].name, "f")
    test.equal(symbols[2].kind, "function")
    test.equal(symbols[2].parent, 1)
  end)

  test.test("stale cache returns stale and schedules refresh for current version", function(context)
    local doc, client = attach(context)
    intelligence.document_outline(doc)
    complete_request(client, 1, {
      { name = "old", kind = 12, range = lsp_range(0, 0, 0, 5), selectionRange = lsp_range(0, 0, 0, 3) },
    })

    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "// " } })
    documents.flush(client, doc)
    local symbols, reason, provider_id, status = intelligence.document_outline(doc)
    test.equal(symbols[1].name, "old")
    test.equal(reason, "refresh scheduled")
    test.equal(provider_id, "lsp")
    test.equal(status, "stale")
    test.equal(#client.requests, 2)
  end)

  test.test("stale version responses are discarded", function(context)
    local doc, client = attach(context)
    register_fallback("test-provider-stale-discard-fallback")
    intelligence.document_outline(doc)

    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "// " } })
    documents.flush(client, doc)
    complete_request(client, 1, {
      { name = "stale", kind = 12, range = lsp_range(0, 0, 0, 5), selectionRange = lsp_range(0, 0, 0, 5) },
    })

    local symbols, _reason, provider_id = intelligence.document_outline(doc)
    test.equal(symbols[1].name, "fallback")
    test.equal(provider_id, "test-provider-stale-discard-fallback")
    test.equal(#client.requests, 2)
  end)

  test.test("generation-stale responses are discarded", function(context)
    local doc, client = attach(context)
    register_fallback("test-provider-generation-fallback")
    intelligence.document_outline(doc)
    client.generation = client.generation + 1
    complete_request(client, 1, {
      { name = "stale", kind = 12, range = lsp_range(0, 0, 0, 5), selectionRange = lsp_range(0, 0, 0, 5) },
    })

    local symbols, _reason, provider_id = intelligence.document_outline(doc)
    test.equal(symbols[1].name, "fallback")
    test.equal(provider_id, "test-provider-generation-fallback")
  end)

  test.test("unsupported documentSymbol capability falls back", function(context)
    local doc, client = attach(context, { capabilities = {} })
    register_fallback("test-provider-unsupported-fallback")

    local symbols, _reason, provider_id = intelligence.document_outline(doc)
    test.equal(#client.requests, 0)
    test.equal(symbols[1].name, "fallback")
    test.equal(provider_id, "test-provider-unsupported-fallback")
  end)

  local function register_definition_fallback(id)
    registered[#registered + 1] = id
    intelligence.register_provider({
      id = id,
      priority = 1,
      definitions = function()
        return { { uri = "file:///fallback.cpp", origin = "local" } }
      end,
      declarations = function()
        return { { uri = "file:///fallback-decl.cpp", origin = "local" } }
      end,
      references = function()
        return { { uri = "file:///fallback-ref.cpp", origin = "local" } }
      end,
    })
  end

  local function attach_navigation(context, capabilities)
    return attach(context, {
      capabilities = capabilities or {
        definitionProvider = true,
        declarationProvider = true,
        referencesProvider = true,
      },
      text = "int value;\nint main() {\n  return value;\n}",
    })
  end

  test.test("definition request is async and falls back while pending", function(context)
    local doc, client = attach_navigation(context)
    register_definition_fallback("test-def-pending-fallback")

    local results, _reason, provider_id, status = intelligence.definitions(doc, 3, 10)
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "textDocument/definition")
    test.equal(client.requests[1].params.position.line, 2)
    test.equal(results[1].uri, "file:///fallback.cpp")
    test.equal(provider_id, "test-def-pending-fallback")
    test.equal(status, "fresh")
  end)

  test.test("definition scalar Location maps to structured same-file result", function(context)
    local doc, client = attach_navigation(context)
    register_definition_fallback("test-def-location-fallback")
    intelligence.definitions(doc, 3, 10)
    local document_uri = documents.state(client, doc).uri
    complete_request(client, 1, {
      uri = document_uri,
      range = lsp_range(0, 4, 0, 9),
    })

    local results, reason, provider_id, status = intelligence.definitions(doc, 3, 10)
    test.is_nil(reason)
    test.equal(provider_id, "lsp")
    test.equal(status, "fresh")
    test.equal(#results, 1)
    test.equal(results[1].uri, document_uri)
    test.equal(results[1].path, common.normalize_path(doc.abs_filename))
    test.equal(results[1].origin, "lsp")
    test.equal(results[1].kind, "definitions")
    test.equal(results[1].range.line1, 1)
    test.equal(results[1].range.col1, 5)
    test.equal(results[1].range.col2, 10)
    test.equal(results[1].selection_range.line1, 1)
  end)

  test.test("definition array maps cross-file locations without requiring target docs", function(context)
    local doc, client = attach_navigation(context)
    intelligence.definitions(doc, 3, 10)
    local other_path = join_path(temp_root, "other.cpp")
    local other_uri = require("core.lsp.uri").path_to_uri(other_path)
    complete_request(client, 1, {
      { uri = documents.state(client, doc).uri, range = lsp_range(0, 4, 0, 9) },
      { uri = other_uri, range = lsp_range(10, 2, 10, 8) },
    })

    local results = intelligence.definitions(doc, 3, 10)
    test.equal(#results, 2)
    test.equal(results[2].uri, other_uri)
    test.equal(results[2].path, common.normalize_path(other_path))
    test.is_nil(results[2].range)
    test.same(results[2].lsp_range, lsp_range(10, 2, 10, 8))
  end)

  test.test("declaration LocationLink maps target and selection ranges", function(context)
    local doc, client = attach_navigation(context)
    intelligence.declarations(doc, 3, 10)
    local document_uri = documents.state(client, doc).uri
    complete_request(client, 1, {
      {
        targetUri = document_uri,
        targetRange = lsp_range(0, 0, 0, 10),
        targetSelectionRange = lsp_range(0, 4, 0, 9),
      },
    })

    local results, _reason, provider_id = intelligence.declarations(doc, 3, 10)
    test.equal(provider_id, "lsp")
    test.equal(#results, 1)
    test.equal(results[1].kind, "declarations")
    test.equal(results[1].range.col1, 1)
    test.equal(results[1].selection_range.col1, 5)
  end)

  test.test("references include context and multiple structured results", function(context)
    local doc, client = attach_navigation(context)
    intelligence.references(doc, 3, 10, nil, nil, { include_declaration = false })
    test.equal(client.requests[1].method, "textDocument/references")
    test.equal(client.requests[1].params.context.includeDeclaration, false)
    local document_uri = documents.state(client, doc).uri
    complete_request(client, 1, {
      { uri = document_uri, range = lsp_range(0, 4, 0, 9) },
      { uri = document_uri, range = lsp_range(2, 9, 2, 14) },
    })

    local results, _reason, provider_id = intelligence.references(doc, 3, 10, nil, nil, { include_declaration = false })
    test.equal(provider_id, "lsp")
    test.equal(#results, 2)
    test.equal(results[2].kind, "references")
    test.equal(results[2].range.line1, 3)
  end)

  test.test("fresh empty definition result is authoritative", function(context)
    local doc, client = attach_navigation(context)
    register_definition_fallback("test-def-empty-fallback")
    intelligence.definitions(doc, 3, 10)
    complete_request(client, 1, {})

    local results, _reason, provider_id, status = intelligence.definitions(doc, 3, 10)
    test.same(results, {})
    test.equal(provider_id, "lsp")
    test.equal(status, "fresh")
  end)

  test.test("null definition result is cached as fresh empty", function(context)
    local doc, client = attach_navigation(context)
    intelligence.definitions(doc, 3, 10)
    complete_request(client, 1, require("core.lsp.json").null)

    local results, _reason, provider_id, status = intelligence.definitions(doc, 3, 10)
    test.same(results, {})
    test.equal(provider_id, "lsp")
    test.equal(status, "fresh")
  end)

  test.test("stale navigation cache returns stale and schedules refresh", function(context)
    local doc, client = attach_navigation(context)
    intelligence.definitions(doc, 3, 10)
    complete_request(client, 1, { uri = documents.state(client, doc).uri, range = lsp_range(0, 4, 0, 9) })

    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "// " } })
    documents.flush(client, doc)
    local results, reason, provider_id, status = intelligence.definitions(doc, 3, 10)
    test.equal(#results, 1)
    test.equal(reason, "refresh scheduled")
    test.equal(provider_id, "lsp")
    test.equal(status, "stale")
    test.equal(#client.requests, 2)
  end)

  test.test("stale navigation responses are discarded and in-flight requests dedupe", function(context)
    local doc, client = attach_navigation(context)
    register_definition_fallback("test-def-stale-fallback")
    intelligence.definitions(doc, 3, 10)
    intelligence.definitions(doc, 3, 10)
    test.equal(#client.requests, 1)

    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "// " } })
    documents.flush(client, doc)
    complete_request(client, 1, { uri = documents.state(client, doc).uri, range = lsp_range(0, 4, 0, 9) })
    local results, _reason, provider_id = intelligence.definitions(doc, 3, 10)
    test.equal(results[1].uri, "file:///fallback.cpp")
    test.equal(provider_id, "test-def-stale-fallback")
    test.equal(#client.requests, 2)
  end)

  test.test("generation-stale navigation responses are discarded", function(context)
    local doc, client = attach_navigation(context)
    register_definition_fallback("test-def-generation-fallback")
    intelligence.definitions(doc, 3, 10)
    client.generation = client.generation + 1
    complete_request(client, 1, { uri = documents.state(client, doc).uri, range = lsp_range(0, 4, 0, 9) })

    local results, _reason, provider_id = intelligence.definitions(doc, 3, 10)
    test.equal(results[1].uri, "file:///fallback.cpp")
    test.equal(provider_id, "test-def-generation-fallback")
  end)

  test.test("unsupported definition capability falls back", function(context)
    local doc, client = attach_navigation(context, { referencesProvider = true })
    register_definition_fallback("test-def-unsupported-fallback")
    local results, _reason, provider_id = intelligence.definitions(doc, 3, 10)
    test.equal(#client.requests, 0)
    test.equal(results[1].uri, "file:///fallback.cpp")
    test.equal(provider_id, "test-def-unsupported-fallback")
  end)
end)
