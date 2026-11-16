#include "memory_stats.h"
#include "treesitter/memory.h"
#include "treesitter/snapshot.h"
#include "treesitter/project_file.h"
#include "treesitter/project_index.h"
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

extern const TSLanguage *tree_sitter_c(void);
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static int parse(void *unused) {
  (void)unused;
  for (int i = 0; i < 100; i++) {
    TSParser *parser = ts_parser_new();
    CHECK(parser && ts_parser_set_language(parser, tree_sitter_c()));
    const char *source = "int example(int a) { return a + 1; }\n";
    TSTree *tree = ts_parser_parse_string(parser, NULL, source, (uint32_t)strlen(source));
    CHECK(tree);
    const char *replacement = "struct Changed { int value; };\n";
    TSInputEdit edit = { .start_byte = 0, .old_end_byte = (uint32_t)strlen(source),
      .new_end_byte = (uint32_t)strlen(replacement), .old_end_point = {1, 0}, .new_end_point = {1, 0} };
    ts_tree_edit(tree, &edit);
    TSTree *next = ts_parser_parse_string(parser, tree, replacement, (uint32_t)strlen(replacement));
    CHECK(next);
    uint32_t count;
    TSRange *ranges = ts_tree_get_changed_ranges(tree, next, &count);
    CHECK(ranges && count > 0);
    anvil_ts_memory_free(ranges);
    CHECK(anvil_memory_counter(ANVIL_MEMORY_TREESITTER).bytes > 0);
    ts_tree_delete(next);
    ts_tree_delete(tree);
    ts_parser_delete(parser);
  }
  return 0;
}

int main(void) {
  anvil_ts_memory_init();
  SDL_Thread *threads[4];
  for (size_t i = 0; i < 4; i++) {
    threads[i] = SDL_CreateThread(parse, "memory-parser", NULL);
    CHECK(threads[i]);
  }
  for (size_t i = 0; i < 4; i++) {
    int code;
    SDL_WaitThread(threads[i], &code);
    CHECK(code == 0);
  }
  AnvilMemoryCounter parser = anvil_memory_counter(ANVIL_MEMORY_TREESITTER);
  CHECK(parser.bytes == 0 && parser.objects == 0 && parser.peak_bytes > 0);

  const char *text = "int answer;\n";
  uint32_t length = (uint32_t)strlen(text);
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(&text, &length, 1, NULL);
  CHECK(snapshot);
  AnvilMemoryCounter before = anvil_memory_counter(ANVIL_MEMORY_TS_TEXT);
  CHECK(before.bytes >= length && before.objects == 1);
  anvil_ts_snapshot_retain(snapshot);
  anvil_ts_snapshot_free(snapshot);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_TEXT).bytes == before.bytes);
  AnvilTSProjectFileResult *file = anvil_ts_project_file_build(snapshot, "test.c", "test.c", "c", NULL, 0, NULL, 0, NULL);
  CHECK(file);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_FILES).bytes > 0);
  anvil_ts_project_file_retain(file);
  anvil_ts_project_file_free(file);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_FILES).objects == 1);
  uint64_t file_bytes = anvil_memory_counter(ANVIL_MEMORY_TS_FILES).bytes;
  AnvilTSProjectBuilder *builder = anvil_ts_project_builder_create(100);
  CHECK(builder && anvil_ts_project_builder_adopt(builder, file, "version", true, NULL));
  AnvilTSProjectSnapshot *index = anvil_ts_project_builder_snapshot(builder, "ready", true, NULL);
  CHECK(index && anvil_memory_counter(ANVIL_MEMORY_TS_INDEX).bytes > 0);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_FILES).bytes == file_bytes);
  anvil_ts_project_builder_close(builder);
  anvil_ts_project_builder_release(builder);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_FILES).bytes == file_bytes);
  anvil_ts_project_snapshot_release(index);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_INDEX).bytes == 0);
  anvil_ts_snapshot_free(snapshot);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_FILES).bytes == 0);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_TEXT).bytes == 0);

  /* Empty owned text follows a different allocation path. */
  char *empty = malloc(1);
  CHECK(empty);
  *empty = 0;
  snapshot = anvil_ts_snapshot_new_take_text(empty, 0, NULL);
  CHECK(snapshot && anvil_memory_counter(ANVIL_MEMORY_TS_TEXT).objects == 1);
  anvil_ts_snapshot_free(snapshot);
  CHECK(anvil_memory_counter(ANVIL_MEMORY_TS_TEXT).bytes == 0);

  uint64_t id = anvil_memory_lua_register("test worker");
  CHECK(id);
  anvil_memory_lua_sample(id, 12345);
  AnvilLuaMemory row;
  uint64_t omitted;
  CHECK(anvil_memory_lua_read(&row, 1, &omitted) == 1 && omitted == 0);
  CHECK(row.id == id && row.bytes == 12345 && !strcmp(row.name, "test worker"));
  anvil_memory_lua_remove(id);
  CHECK(anvil_memory_lua_read(&row, 1, &omitted) == 0);
  puts("Memory counters follow concurrent parser and shared snapshot lifetimes");
  return 0;
}
