#include "text/buffer.h"
#include "text/buffer_manager.h"
#include "text/treesitter.h"

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

  CHECK(strcmp(buffer_tree_sitter_root_kind(&buffer), "translation_unit") == 0);
  CHECK(has_highlight(&buffer, "keyword", "static"));
  CHECK(has_highlight(&buffer, "function", "main"));

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

  CHECK(strcmp(buffer_tree_sitter_root_kind(&buffer), "translation_unit") == 0);
  CHECK(has_highlight(&buffer, "comment", "// hello"));
  CHECK(has_highlight(&buffer, "number", "2"));

  buffer_manager_dispose(&manager);
  buffer_dispose(&buffer);
  return 0;
}

int main(void) {
  int rc = 0;
  rc |= test_parse_and_highlight_c_buffer();
  rc |= test_single_edit_incrementally_reparses();
  rc |= test_multi_edit_falls_back_to_full_reparse();
  return rc;
}
