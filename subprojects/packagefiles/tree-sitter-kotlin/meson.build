project('tree-sitter-kotlin', 'c', version: '0.4.0', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_kotlin_inc = include_directories('src', 'bindings/c')

tree_sitter_kotlin_lib = library(
  'tree-sitter-kotlin',
  files('src/parser.c', 'src/scanner.c'),
  include_directories: tree_sitter_kotlin_inc,
  install: false,
)

tree_sitter_kotlin_dep = declare_dependency(
  link_with: tree_sitter_kotlin_lib,
  include_directories: include_directories('bindings/c'),
)
