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
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
