local test = require "core.test"

local required_rule_ids = {
  "javascript", "typescript", "jsx", "tsx", "python", "java", "c", "cpp", "csharp", "go",
  "rust", "php", "ruby", "lua", "shell", "powershell", "kotlin", "swift", "objective_c", "scala",
  "dart", "r", "julia", "perl", "groovy", "haskell", "ocaml", "elixir", "erlang", "clojure",
  "fsharp", "sql", "html", "css", "scss", "less", "json", "jsonc", "yaml", "toml",
  "xml", "markdown", "dockerfile", "makefile", "cmake", "nix", "terraform", "vue", "svelte", "zig",
}

test.describe("smart indent rules", function()
  test.it("prefills central rules for the initial top language set", function()
    local rules = require "plugins.smart_indent_rules"
    test.ok(type(rules.rules) == "table")
    for _, id in ipairs(required_rule_ids) do
      local rule = rules.rules[id]
      test.ok(rule, "missing smart indent rule: " .. id)
      test.ok(type(rule.extensions) == "table" or type(rule.filenames) == "table", "rule has no file matchers: " .. id)
    end
  end)
end)
