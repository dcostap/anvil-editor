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
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
