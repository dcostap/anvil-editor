project('tree-sitter-cpp', 'c', version: '0.23.4', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_cpp_inc = include_directories('src', 'bindings/c')

tree_sitter_cpp_lib = library(
  'tree-sitter-cpp',
  files('src/parser.c', 'src/scanner.c'),
  include_directories: tree_sitter_cpp_inc,
  install: false,
)

tree_sitter_cpp_dep = declare_dependency(
  link_with: tree_sitter_cpp_lib,
  include_directories: include_directories('bindings/c'),
)
