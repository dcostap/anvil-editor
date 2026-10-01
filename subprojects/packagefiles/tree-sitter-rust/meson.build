project('tree-sitter-rust', 'c', version: '0.24.2', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_rust_lib = library(
  'tree-sitter-rust',
  files('src/parser.c', 'src/scanner.c'),
  include_directories: include_directories('src'),
  install: false,
)

tree_sitter_rust_dep = declare_dependency(
  link_with: tree_sitter_rust_lib,
  include_directories: include_directories('bindings/c'),
)
