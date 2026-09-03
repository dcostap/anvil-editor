return {
  id = "typescript",
  name = "TypeScript",
  grammar = "typescript",
  files = {
    "%.ts$",
    "%.mts$",
    "%.cts$",
  },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  autocomplete_languages = { "javascript", "typescript", "tsx" },
  member_completion_separators = { "." },
  bare_completion_symbol_kinds = {
    "class", "interface", "type", "function", "variable", "enum", "enum_member",
  },
  parse_timeout_ms = 5000,
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
