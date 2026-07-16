return {
  id = "odin",
  name = "Odin",
  grammar = "odin",
  files = {
    "%.odin$",
  },
  headers = {},
  line_comments = { "//" },
  block_comment = { "/*", "*/" },
  member_completion_separators = { "." },
  enum_completion_separator = ".",
  bare_completion_symbol_kinds = {
    "function", "struct", "enum", "union", "type", "constant", "variable", "module", "namespace",
  },
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
