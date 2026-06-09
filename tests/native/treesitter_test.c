#include "text/buffer.h"
#include "text/buffer_manager.h"
#include "text/treesitter.h"
#include "thread_pool.h"

#include <SDL3/SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { \
  if (!(expr)) { \
    fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); \
    return 1; \
  } \
} while (0)

static int span_matches(Buffer *buffer, const NativeTreeSitterHighlightSpan *span, const char *capture, const char *text) {
  if (!span || strcmp(span->capture_name, capture) != 0) return 0;
  size_t len = 0;
  char *bytes = buffer_range_to_string(buffer, span->start_offset, span->end_offset, &len);
  if (!bytes) return 0;
  int ok = strlen(text) == len && memcmp(bytes, text, len) == 0;
  free(bytes);
  return ok;
}

static int has_highlight(Buffer *buffer, const char *capture, const char *text) {
  size_t count = 0;
  NativeTreeSitterHighlightSpan *spans = buffer_tree_sitter_highlights(buffer, 0, buffer_len(buffer), &count);
  int found = 0;
  for (size_t i = 0; i < count; ++i) {
    if (span_matches(buffer, &spans[i], capture, text)) {
      found = 1;
      break;
    }
  }
  buffer_tree_sitter_highlights_free(spans, count);
  return found;
}

static int test_language_registry_detects_c_files(void) {
  CHECK(strcmp(native_treesitter_language_for_filename("foo.c"), "c") == 0);
  CHECK(strcmp(native_treesitter_language_for_filename("C:/tmp/foo.H"), "c") == 0);
  CHECK(native_treesitter_language_for_filename("foo.txt") == NULL);
  return 0;
}

static int test_parse_and_highlight_c_buffer(void) {
  Buffer buffer;
  const char *source = "int main(void) {\n  return 1;\n}\n";
  CHECK(buffer_init(&buffer, source, strlen(source)));
  CHECK(buffer_enable_tree_sitter(&buffer, "c"));
  CHECK(strcmp(buffer_tree_sitter_language_name(&buffer), "c") == 0);
  CHECK(strcmp(buffer_tree_sitter_root_kind(&buffer), "translation_unit") == 0);
  CHECK(has_highlight(&buffer, "type", "int"));
  CHECK(has_highlight(&buffer, "function", "main"));
  CHECK(has_highlight(&buffer, "keyword", "return"));
  CHECK(has_highlight(&buffer, "number", "1"));
  buffer_dispose(&buffer);
  return 0;
}

static int test_single_edit_incrementally_reparses(void) {
  Buffer buffer;
  BufferManager manager;
  const char *source = "int main(void) {\n  return 1;\n}\n";
  CHECK(buffer_init(&buffer, source, strlen(source)));
  buffer_manager_init(&manager, &buffer);
  CHECK(buffer_enable_tree_sitter(&buffer, "c"));

  BatchEditItem edit;
  memset(&edit, 0, sizeof(edit));
  edit.start_offset = 0;
  edit.end_offset = 0;
  edit.text = "static ";
  edit.text_len = 7;
  BatchEditResult result = buffer_manager_apply_edits(&manager, &edit, 1);
  CHECK(result.applied);
  batch_edit_result_dispose(&result);

  CHECK(buffer_tree_sitter_is_dirty(&buffer));
  CHECK(buffer_reparse_tree_sitter(&buffer));
  CHECK(!buffer_tree_sitter_is_dirty(&buffer));
  CHECK(strcmp(buffer_tree_sitter_root_kind(&buffer), "translation_unit") == 0);
  CHECK(has_highlight(&buffer, "keyword", "static"));
  CHECK(has_highlight(&buffer, "function", "main"));

  buffer_manager_dispose(&manager);
  buffer_dispose(&buffer);
  return 0;
}

static int test_async_reparse_applies_completed_tree(void) {
  Buffer buffer;
  BufferManager manager;
  const char *source = "int main(void) {\n  return 1;\n}\n";
  CHECK(buffer_init(&buffer, source, strlen(source)));
  buffer_manager_init(&manager, &buffer);
  CHECK(buffer_enable_tree_sitter(&buffer, "c"));

  BatchEditItem edit;
  memset(&edit, 0, sizeof(edit));
  edit.start_offset = 0;
  edit.end_offset = 0;
  edit.text = "static ";
  edit.text_len = 7;
  BatchEditResult result = buffer_manager_apply_edits(&manager, &edit, 1);
  CHECK(result.applied);
  batch_edit_result_dispose(&result);

  CHECK(buffer_tree_sitter_is_dirty(&buffer));
  CHECK(buffer_schedule_tree_sitter_reparse(&buffer));
  CHECK(buffer_tree_sitter_parse_pending(&buffer));

  int applied = 0;
  for (int i = 0; i < 500; ++i) {
    if (buffer_poll_tree_sitter_reparse(&buffer)) {
      applied = 1;
      break;
    }
    SDL_Delay(1);
  }
  CHECK(applied);
  CHECK(!buffer_tree_sitter_is_dirty(&buffer));
  CHECK(!buffer_tree_sitter_parse_pending(&buffer));
  CHECK(has_highlight(&buffer, "keyword", "static"));

  buffer_manager_dispose(&manager);
  buffer_dispose(&buffer);
  return 0;
}

static int test_multi_edit_falls_back_to_full_reparse(void) {
  Buffer buffer;
  BufferManager manager;
  const char *source = "int main(void) {\n  return 1;\n}\n";
  CHECK(buffer_init(&buffer, source, strlen(source)));
  buffer_manager_init(&manager, &buffer);
  CHECK(buffer_enable_tree_sitter(&buffer, "c"));

  BatchEditItem edits[2];
  memset(edits, 0, sizeof(edits));
  edits[0].start_offset = 0;
  edits[0].end_offset = 0;
  edits[0].text = "// hello\n";
  edits[0].text_len = 9;
  edits[1].start_offset = 26;
  edits[1].end_offset = 27;
  edits[1].text = "2";
  edits[1].text_len = 1;
  BatchEditResult result = buffer_manager_apply_edits(&manager, edits, 2);
  CHECK(result.applied);
  batch_edit_result_dispose(&result);

  CHECK(buffer_tree_sitter_is_dirty(&buffer));
  CHECK(buffer_reparse_tree_sitter(&buffer));
  CHECK(!buffer_tree_sitter_is_dirty(&buffer));
  CHECK(strcmp(buffer_tree_sitter_root_kind(&buffer), "translation_unit") == 0);
  CHECK(has_highlight(&buffer, "comment", "// hello"));
  CHECK(has_highlight(&buffer, "number", "2"));

  buffer_manager_dispose(&manager);
  buffer_dispose(&buffer);
  return 0;
}

int main(void) {
  if (!SDL_Init(SDL_INIT_EVENTS)) {
    fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
    return 1;
  }
  if (!anvil_thread_pool_startup(2)) {
    fprintf(stderr, "thread pool startup failed: %s\n", SDL_GetError());
    SDL_Quit();
    return 1;
  }

  int rc = 0;
  rc |= test_language_registry_detects_c_files();
  rc |= test_parse_and_highlight_c_buffer();
  rc |= test_single_edit_incrementally_reparses();
  rc |= test_async_reparse_applies_completed_tree();
  rc |= test_multi_edit_falls_back_to_full_reparse();

  anvil_thread_pool_shutdown();
  SDL_Quit();
  return rc;
}
