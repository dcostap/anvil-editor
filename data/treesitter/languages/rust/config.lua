return {
  id = "rust",
  name = "Rust",
  grammar = "rust",
  files = { "%.rs$" },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  member_completion_separators = { "::", "." },
  enum_completion_separator = "::",
  bare_completion_symbol_kinds = {
    "module", "struct", "union", "enum", "interface", "type", "function", "constant", "variable", "macro",
  },
  parse_timeout_ms = 5000,
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "usages.scm",
    usages = "usages.scm",
  },
}
