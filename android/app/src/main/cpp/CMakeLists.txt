cmake_minimum_required(VERSION 3.22)
project(anvil_companion C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The shared C files come from the desktop sources. Nothing is copied.
get_filename_component(REPO "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

add_library(anvil_companion SHARED
  machine_frames.c
  "${REPO}/src/machine_frame.c")
target_include_directories(anvil_companion PRIVATE "${REPO}/src")
target_compile_options(anvil_companion PRIVATE -Wall)
