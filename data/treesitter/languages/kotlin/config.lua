return {
  id = "kotlin",
  name = "Kotlin",
  grammar = "kotlin",
  files = {
    "%.kt$",
    "%.kts$",
  },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  member_completion_separators = { "." },
  enum_completion_separator = ".",
  parse_timeout_ms = 5000,
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
    usages = "usages.scm",
  },
}
