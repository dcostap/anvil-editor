project('tree-sitter-typescript', 'c', version: '0.23.2', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_typescript_lib = library(
  'tree-sitter-typescript',
  files('typescript/src/parser.c', 'typescript/src/scanner.c'),
  include_directories: include_directories('typescript/src'),
  install: false,
)

tree_sitter_tsx_lib = library(
  'tree-sitter-tsx',
  files('tsx/src/parser.c', 'tsx/src/scanner.c'),
  include_directories: include_directories('tsx/src'),
  install: false,
)

tree_sitter_typescript_dep = declare_dependency(link_with: tree_sitter_typescript_lib)
tree_sitter_tsx_dep = declare_dependency(link_with: tree_sitter_tsx_lib)
