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
  queries = {
    highlights = "highlights.scm",
    outline = "outline.scm",
    locals = "locals.scm",
  },
}
