project(
  'tree-sitter-markdown',
  'c',
  version: '0.5.3',
  license: 'MIT',
  default_options: ['c_std=c11'],
)

markdown_inc = include_directories(
  'tree-sitter-markdown/src',
  'tree-sitter-markdown/bindings/c',
)
markdown_inline_inc = include_directories(
  'tree-sitter-markdown-inline/src',
  'tree-sitter-markdown-inline/bindings/c',
)

tree_sitter_markdown_lib = static_library(
  'tree-sitter-markdown',
  files(
    'tree-sitter-markdown/src/parser.c',
    'tree-sitter-markdown/src/scanner.c',
  ),
  include_directories: markdown_inc,
  install: false,
)

tree_sitter_markdown_inline_lib = static_library(
  'tree-sitter-markdown-inline',
  files(
    'tree-sitter-markdown-inline/src/parser.c',
    'tree-sitter-markdown-inline/src/scanner.c',
  ),
  include_directories: markdown_inline_inc,
  install: false,
)

tree_sitter_markdown_dep = declare_dependency(
  link_with: tree_sitter_markdown_lib,
  include_directories: include_directories('tree-sitter-markdown/bindings/c'),
)

tree_sitter_markdown_inline_dep = declare_dependency(
  link_with: tree_sitter_markdown_inline_lib,
  include_directories: include_directories('tree-sitter-markdown-inline/bindings/c'),
)
