project('tree-sitter-odin', 'c', version: '1.3.0', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_odin_inc = include_directories('src', 'bindings/c')

tree_sitter_odin_lib = library(
  'tree-sitter-odin',
  files('src/parser.c', 'src/scanner.c'),
  include_directories: tree_sitter_odin_inc,
  install: false,
)

tree_sitter_odin_dep = declare_dependency(
  link_with: tree_sitter_odin_lib,
  include_directories: include_directories('bindings/c'),
)
