return {
  id = "javascript",
  name = "JavaScript",
  grammar = "javascript",
  files = {
    "%.js$",
    "%.mjs$",
    "%.cjs$",
    "%.jsx$",
  },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  autocomplete_languages = { "javascript", "typescript", "tsx" },
  member_completion_separators = { "." },
  bare_completion_symbol_kinds = {
    "class", "function", "variable",
  },
  parse_timeout_ms = 5000,
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
