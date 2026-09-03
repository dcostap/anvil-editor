project('tree-sitter-javascript', 'c', version: '0.25.0', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_javascript_inc = include_directories('src', 'bindings/c')

tree_sitter_javascript_lib = library(
  'tree-sitter-javascript',
  files('src/parser.c', 'src/scanner.c'),
  include_directories: tree_sitter_javascript_inc,
  install: false,
)

tree_sitter_javascript_dep = declare_dependency(
  link_with: tree_sitter_javascript_lib,
  include_directories: include_directories('bindings/c'),
)
