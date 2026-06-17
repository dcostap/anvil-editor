project('tree-sitter-c', 'c', version: '0.24.2', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_c_inc = include_directories('src', 'bindings/c')

tree_sitter_c_lib = library(
  'tree-sitter-c',
  files('src/parser.c'),
  include_directories: tree_sitter_c_inc,
  install: false,
)

tree_sitter_c_dep = declare_dependency(
  link_with: tree_sitter_c_lib,
  include_directories: include_directories('bindings/c'),
)
