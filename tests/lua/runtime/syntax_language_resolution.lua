local syntax = require "core.syntax"
local test = require "core.test"

local function syntax_named(name)
  for _, item in ipairs(syntax.items) do
    if item.name == name then
      return item
    end
  end
end

test.describe("syntax language resolution", function()
  test.test("resolves aliases, canonical names, prefixes, and metadata", function()
    local javascript = syntax_named("JavaScript")
    local python = syntax_named("Python")
    local cpp = syntax_named("C++")
    test.not_nil(javascript)
    test.not_nil(python)
    test.not_nil(cpp)

    local resolved, metadata = syntax.resolve_language("  JS title=\"example\"  ", {
      source = "markdown-fence"
    })
    test.equal(resolved, javascript)
    test.equal(metadata.requested, "JS")
    test.equal(metadata.normalized, "js")
    test.equal(metadata.canonical_id, "javascript")
    test.equal(metadata.reason, "alias")

    resolved, metadata = syntax.resolve_language("language-PY extra")
    test.equal(resolved, python)
    test.equal(metadata.normalized, "py")
    test.equal(metadata.canonical_id, "python")
    test.equal(metadata.reason, "alias")

    resolved, metadata = syntax.resolve_language("lang-c++")
    test.equal(resolved, cpp)
    test.equal(metadata.canonical_id, "cpp")
    test.equal(metadata.reason, "alias")

    resolved, metadata = syntax.resolve_language("lua ignored metadata")
    test.equal(resolved, syntax_named("Lua"))
    test.equal(metadata.reason, "extension")
  end)

  test.test("distinguishes empty and missing languages from plain text", function()
    local resolved, metadata = syntax.resolve_language("   ")
    test.is_nil(resolved)
    test.equal(metadata.reason, "empty")
    test.equal(metadata.normalized, "")

    resolved, metadata = syntax.resolve_language("anvil-language-that-does-not-exist")
    test.is_nil(resolved)
    test.equal(metadata.reason, "missing")
    test.equal(metadata.normalized, "anvil-language-that-does-not-exist")
    test.not_equal(resolved, syntax.plain_text_syntax)
  end)

  test.test("keeps the first alias registration unless replacement is explicit", function()
    local alias = "anvil-resolver-conflict-test"
    local before = syntax.get_registry_generation()
    test.equal(syntax.add_language_alias(alias, "lua"), true)
    test.ok(syntax.get_registry_generation() > before)
    test.equal(syntax.add_language_alias(alias, "javascript"), false)

    local resolved, metadata = syntax.resolve_language(alias)
    test.equal(resolved, syntax_named("Lua"))
    test.equal(metadata.canonical_id, "lua")

    test.equal(syntax.add_language_alias(alias, "javascript", { replace = true }), true)
    resolved, metadata = syntax.resolve_language(alias)
    test.equal(resolved, syntax_named("JavaScript"))
    test.equal(metadata.canonical_id, "javascript")
  end)

  test.test("notifies listeners and invalidates cached misses after registration", function()
    local alias = "anvil-resolver-late-test"
    local listener = {}
    local calls = 0
    local observed_generation
    local observed_reason
    syntax.add_registry_listener(listener, function(generation, reason)
      calls = calls + 1
      observed_generation = generation
      observed_reason = reason
    end)

    local resolved = syntax.resolve_language(alias)
    test.is_nil(resolved)
    test.equal(syntax.add_language_alias(alias, "lua"), true)
    test.equal(calls, 1)
    test.equal(observed_generation, syntax.get_registry_generation())
    test.equal(observed_reason, "alias")
    resolved = syntax.resolve_language(alias)
    test.equal(resolved, syntax_named("Lua"))

    syntax.remove_registry_listener(listener)
    test.equal(syntax.add_language_alias(alias .. "-unused", "lua"), true)
    test.equal(calls, 1)
  end)
end)
