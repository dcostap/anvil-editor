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
  queries = {
    highlights = "highlights.scm",
  },
}
