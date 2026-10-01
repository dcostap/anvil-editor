-- mod-version:3
local syntax = require "core.syntax"
local language = require("core.treesitter.registry").get_by_id("rust")

-- Tree-sitter supplies Rust colors. Register the Language Mode for all Buffers.
syntax.add {
  name = language.name,
  files = language.files,
  comment = language.line_comments[1],
  block_comment = language.block_comment,
  patterns = {},
  symbols = {},
}
