cmake_minimum_required(VERSION 3.22)
project(anvil_companion C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The shared C files come from the desktop sources and the Meson subprojects. Nothing is copied.
get_filename_component(REPO "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(SUBPROJECTS "${REPO}/subprojects")
if(NOT EXISTS "${SUBPROJECTS}/tree-sitter/lib/src/lib.c")
  message(FATAL_ERROR "The Meson subprojects are missing. Configure the desktop build first.")
endif()

add_library(tree-sitter STATIC "${SUBPROJECTS}/tree-sitter/lib/src/lib.c")
target_include_directories(tree-sitter
  PUBLIC "${SUBPROJECTS}/tree-sitter/lib/include"
  PRIVATE "${SUBPROJECTS}/tree-sitter/lib/src")
target_compile_definitions(tree-sitter PRIVATE _POSIX_C_SOURCE=200112L _DEFAULT_SOURCE)

# Each grammar has its own copy of tree_sitter/parser.h, so each one builds alone.
set(GRAMMARS)
function(add_grammar name dir)
  file(GLOB sources "${dir}/parser.c" "${dir}/scanner.c")
  add_library(${name} STATIC ${sources})
  target_include_directories(${name} PRIVATE "${dir}")
  target_compile_options(${name} PRIVATE -w)
  set(GRAMMARS ${GRAMMARS} ${name} PARENT_SCOPE)
endfunction()

# languages.c registers every desktop grammar.
add_grammar(ts-c "${SUBPROJECTS}/tree-sitter-c/src")
add_grammar(ts-cpp "${SUBPROJECTS}/tree-sitter-cpp/src")
add_grammar(ts-odin "${SUBPROJECTS}/tree-sitter-odin/src")
add_grammar(ts-kotlin "${SUBPROJECTS}/tree-sitter-kotlin/src")
add_grammar(ts-rust "${SUBPROJECTS}/tree-sitter-rust/src")
add_grammar(ts-javascript "${SUBPROJECTS}/tree-sitter-javascript/src")
add_grammar(ts-typescript "${SUBPROJECTS}/tree-sitter-typescript/typescript/src")
add_grammar(ts-tsx "${SUBPROJECTS}/tree-sitter-typescript/tsx/src")
add_grammar(ts-markdown "${SUBPROJECTS}/tree-sitter-markdown/tree-sitter-markdown/src")
add_grammar(ts-markdown-inline "${SUBPROJECTS}/tree-sitter-markdown/tree-sitter-markdown-inline/src")

add_library(anvil_companion SHARED
  machine_frames.c
  markdown_styles.c
  "${REPO}/src/machine_frame.c"
  "${REPO}/src/markdown_parser.c"
  "${REPO}/src/markdown_extensions.c"
  "${REPO}/src/treesitter/languages.c"
  "${REPO}/src/treesitter/snapshot.c")
# The sdl folder goes first: it gives the SDL calls of the shared modules without SDL.
target_include_directories(anvil_companion PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/sdl" "${REPO}/src")
target_compile_options(anvil_companion PRIVATE -Wall)
target_link_libraries(anvil_companion PRIVATE tree-sitter ${GRAMMARS})
