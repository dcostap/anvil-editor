local intelligence = require "core.language_intelligence"
local test = require "core.test"

local registered = {}

local function register(provider)
  registered[#registered + 1] = provider.id
  return intelligence.register_provider(provider)
end

local function cleanup()
  for i = #registered, 1, -1 do
    intelligence.unregister_provider(registered[i])
  end
  registered = {}
end

test.describe("core.language_intelligence async/cache statuses", function()
  test.after_each(function()
    cleanup()
  end)

  test.test("fresh empty result is authoritative and does not fall through", function()
    register({
      id = "test-lsp-empty",
      priority = 1000,
      document_outline = function()
        return {}, nil, "fresh"
      end,
    })
    register({
      id = "test-fallback-outline",
      priority = 1,
      document_outline = function()
        return { { name = "fallback" } }
      end,
    })

    local symbols, reason, provider_id, status = intelligence.document_outline({})
    test.same(symbols, {})
    test.is_nil(reason)
    test.equal(provider_id, "test-lsp-empty")
    test.equal(status, "fresh")
  end)

  test.test("legacy empty tables still fall through to preserve existing provider behavior", function()
    register({
      id = "test-legacy-empty",
      priority = 1000,
      document_outline = function()
        return {}
      end,
    })
    register({
      id = "test-legacy-fallback",
      priority = 1,
      document_outline = function()
        return { { name = "fallback" } }
      end,
    })

    local symbols, _reason, provider_id, status = intelligence.document_outline({})
    test.equal(#symbols, 1)
    test.equal(symbols[1].name, "fallback")
    test.equal(provider_id, "test-legacy-fallback")
    test.equal(status, "fresh")
  end)

  test.test("pending unavailable and error statuses fall through to lower priority providers", function()
    register({
      id = "test-pending",
      priority = 1000,
      document_outline = function()
        return nil, "refresh scheduled", "pending"
      end,
    })
    register({
      id = "test-error",
      priority = 900,
      document_outline = function()
        return nil, "server failed", "error"
      end,
    })
    register({
      id = "test-unavailable",
      priority = 800,
      document_outline = function()
        return nil, "unsupported", "unavailable"
      end,
    })
    register({
      id = "test-local-fallback",
      priority = 1,
      document_outline = function()
        return { { name = "local" } }
      end,
    })

    local symbols, _reason, provider_id, status = intelligence.document_outline({})
    test.equal(#symbols, 1)
    test.equal(symbols[1].name, "local")
    test.equal(provider_id, "test-local-fallback")
    test.equal(status, "fresh")
  end)

  test.test("stale cached data is returned with stale status", function()
    register({
      id = "test-stale",
      priority = 1000,
      document_outline = function()
        return { { name = "cached" } }, "refresh scheduled", "stale"
      end,
    })
    register({
      id = "test-stale-fallback",
      priority = 1,
      document_outline = function()
        return { { name = "fallback" } }
      end,
    })

    local symbols, reason, provider_id, status = intelligence.document_outline({})
    test.equal(#symbols, 1)
    test.equal(symbols[1].name, "cached")
    test.equal(reason, "refresh scheduled")
    test.equal(provider_id, "test-stale")
    test.equal(status, "stale")
  end)

  test.test("provider filtering can ask for LSP-only behavior", function()
    register({
      id = "lsp",
      priority = 1000,
      kind = "semantic-project",
      document_outline = function()
        return nil, "initializing", "pending"
      end,
    })
    register({
      id = "test-local-only-filter",
      priority = 1,
      document_outline = function()
        return { { name = "local" } }
      end,
    })

    local symbols, reason, provider_id, status = intelligence.document_outline({}, { lsp_only = true })
    test.same(symbols, {})
    test.equal(reason, "initializing")
    test.is_nil(provider_id)
    test.equal(status, "pending")
  end)

  test.test("generic semantic APIs dispatch status-aware results", function()
    register({
      id = "test-semantic",
      priority = 1000,
      definitions = function()
        return {}, nil, "fresh"
      end,
      declarations = function()
        return { { uri = "file:///decl.cpp" } }, nil, "fresh"
      end,
      references = function()
        return nil, "waiting", "pending"
      end,
      diagnostics = function()
        return {}, nil, "fresh"
      end,
    })
    register({
      id = "test-semantic-fallback",
      priority = 1,
      references = function()
        return { { uri = "file:///ref.cpp" } }
      end,
    })

    local definitions, _, provider_id, status = intelligence.definitions({}, 1, 1)
    test.same(definitions, {})
    test.equal(provider_id, "test-semantic")
    test.equal(status, "fresh")

    local declarations = intelligence.declarations({}, 1, 1)
    test.equal(declarations[1].uri, "file:///decl.cpp")

    local references, _reason, ref_provider = intelligence.references({}, 1, 1)
    test.equal(references[1].uri, "file:///ref.cpp")
    test.equal(ref_provider, "test-semantic-fallback")

    local diagnostics, _diag_reason, diag_provider, diag_status = intelligence.diagnostics({})
    test.same(diagnostics, {})
    test.equal(diag_provider, "test-semantic")
    test.equal(diag_status, "fresh")
  end)

  test.test("providers_for preserves priority ordering and availability filtering", function()
    register({
      id = "test-unavailable-provider",
      priority = 1000,
      is_available = function() return false end,
      document_outline = function()
        return { { name = "no" } }
      end,
    })
    register({
      id = "test-available-provider",
      priority = 100,
      document_outline = function()
        return { { name = "yes" } }
      end,
    })

    local providers = intelligence.providers_for("document_outline", {})
    for _, provider in ipairs(providers) do
      test.not_equal(provider.id, "test-unavailable-provider")
    end
    local symbols = intelligence.document_outline({})
    test.equal(symbols[1].name, "yes")
  end)
end)
