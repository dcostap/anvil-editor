return {
  id = "c",
  name = "C",
  grammar = "c",
  files = {
    "%.c$",
    "%.h$",
  },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  member_completion_separators = { "." },
  bare_completion_symbol_kinds = {
    "function", "macro", "struct", "union", "enum", "enum_member", "type",
  },
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
