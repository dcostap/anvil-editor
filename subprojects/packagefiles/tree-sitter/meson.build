project('tree-sitter', 'c', version: '0.27.0', license: 'MIT', default_options: ['c_std=c11'])

tree_sitter_inc = include_directories('lib/include', 'lib/src')

tree_sitter_sources = files(
  'lib/src/alloc.c',
  'lib/src/get_changed_ranges.c',
  'lib/src/language.c',
  'lib/src/lexer.c',
  'lib/src/node.c',
  'lib/src/parser.c',
  'lib/src/point.c',
  'lib/src/query.c',
  'lib/src/stack.c',
  'lib/src/subtree.c',
  'lib/src/tree.c',
  'lib/src/tree_cursor.c',
  'lib/src/wasm_store.c',
)

tree_sitter_lib = library(
  'tree-sitter',
  tree_sitter_sources,
  include_directories: tree_sitter_inc,
  c_args: ['-D_POSIX_C_SOURCE=200112L', '-D_DEFAULT_SOURCE', '-D_BSD_SOURCE', '-D_DARWIN_C_SOURCE'],
  install: false,
)

tree_sitter_dep = declare_dependency(
  link_with: tree_sitter_lib,
  include_directories: include_directories('lib/include'),
)
