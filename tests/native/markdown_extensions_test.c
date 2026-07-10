#include "markdown_extensions.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { \
  fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, #expr); \
  return 1; \
} } while (0)

typedef struct CaptureList {
  AnvilMarkdownExtensionCapture captures[64];
  uint32_t count;
} CaptureList;

static bool collect_capture(const AnvilMarkdownExtensionCapture *capture, void *payload) {
  CaptureList *list = (CaptureList *)payload;
  if (list->count >= 64) return false;
  list->captures[list->count++] = *capture;
  return true;
}

typedef struct CancelState {
  uint32_t calls;
  uint32_t cancel_after;
} CancelState;

static bool cancel_after(void *payload) {
  CancelState *state = (CancelState *)payload;
  state->calls++;
  return state->calls >= state->cancel_after;
}

static const AnvilMarkdownExtensionCapture *find_capture(const CaptureList *list, const char *name) {
  for (uint32_t i = 0; i < list->count; i++) {
    if (strcmp(list->captures[i].name, name) == 0) return &list->captures[i];
  }
  return NULL;
}

int main(void) {
  const char *lines[] = {
    "[[Note#Heading|Alias]] ![[image.png|640x480]] ==marked== `==raw==` #project/anvil #123 C#code \\#escaped\n",
    "%%comment\n",
    "continues%% \\[[escaped]] [[incomplete\n",
  };
  uint32_t lengths[3];
  for (uint32_t i = 0; i < 3; i++) lengths[i] = (uint32_t)strlen(lines[i]);
  char *error = NULL;
  AnvilTSSnapshot *snapshot = anvil_ts_snapshot_new_from_lines(lines, lengths, 3, &error);
  CHECK(snapshot != NULL);

  const char *raw = strstr(snapshot->bytes, "`==raw==`");
  CHECK(raw != NULL);
  AnvilMarkdownExclusion exclusion = {
    .start_byte = (uint32_t)(raw - snapshot->bytes),
    .end_byte = (uint32_t)(raw - snapshot->bytes + strlen("`==raw==`")),
  };
  CaptureList list = {0};
  CHECK(anvil_markdown_extensions_scan(
    snapshot, &exclusion, 1, collect_capture, &list, NULL, NULL
  ));

  const AnvilMarkdownExtensionCapture *wiki = find_capture(&list, "span.wiki_link");
  const AnvilMarkdownExtensionCapture *embed = find_capture(&list, "span.embed");
  const AnvilMarkdownExtensionCapture *highlight = find_capture(&list, "span.highlight");
  const AnvilMarkdownExtensionCapture *comment = find_capture(&list, "span.comment");
  const AnvilMarkdownExtensionCapture *tag = find_capture(&list, "span.tag");
  CHECK(wiki != NULL && wiki->start_byte == 0 && wiki->end_byte == 22);
  CHECK(embed != NULL && embed->start_byte == 23);
  CHECK(highlight != NULL);
  CHECK(comment != NULL);
  CHECK(tag != NULL);
  CHECK(tag->end_byte - tag->start_byte == strlen("#project/anvil"));
  CHECK(find_capture(&list, "content.tag")->match_id == tag->match_id);
  CHECK(wiki->match_id != embed->match_id);
  CHECK(wiki->match_id != highlight->match_id);
  CHECK(wiki->match_id != comment->match_id);
  CHECK(embed->match_id != highlight->match_id);
  CHECK(embed->match_id != comment->match_id);
  CHECK(highlight->match_id != comment->match_id);
  CHECK(find_capture(&list, "marker.wiki_open")->match_id == wiki->match_id);
  CHECK(find_capture(&list, "content.target")->match_id == wiki->match_id);
  CHECK(memchr(snapshot->bytes + comment->start_byte, '\n', comment->end_byte - comment->start_byte) != NULL);

  uint32_t wiki_count = 0, highlight_count = 0, tag_count = 0;
  for (uint32_t i = 0; i < list.count; i++) {
    if (strcmp(list.captures[i].name, "span.wiki_link") == 0) wiki_count++;
    if (strcmp(list.captures[i].name, "span.highlight") == 0) highlight_count++;
    if (strcmp(list.captures[i].name, "span.tag") == 0) tag_count++;
  }
  CHECK(wiki_count == 1);
  CHECK(highlight_count == 1);
  CHECK(tag_count == 1);

  anvil_ts_snapshot_free(snapshot);

  const char *empty_source[] = { "[[]] [[|Alias]] %%%% [[Valid]] %%valid%%\n" };
  uint32_t empty_length[] = { (uint32_t)strlen(empty_source[0]) };
  snapshot = anvil_ts_snapshot_new_from_lines(empty_source, empty_length, 1, &error);
  CHECK(snapshot != NULL);
  CaptureList mixed = {0};
  CHECK(anvil_markdown_extensions_scan(snapshot, NULL, 0, collect_capture, &mixed, NULL, NULL));
  wiki_count = 0;
  uint32_t comment_count = 0;
  for (uint32_t i = 0; i < mixed.count; i++) {
    if (strcmp(mixed.captures[i].name, "span.wiki_link") == 0) wiki_count++;
    if (strcmp(mixed.captures[i].name, "span.comment") == 0) comment_count++;
  }
  CHECK(wiki_count == 1);
  CHECK(comment_count == 1);
  anvil_ts_snapshot_free(snapshot);

  uint32_t pathological_len = 128 * 1024;
  char *pathological = (char *)malloc(pathological_len);
  CHECK(pathological != NULL);
  memset(pathological, '[', pathological_len);
  const char *pathological_lines[] = { pathological };
  uint32_t pathological_lengths[] = { pathological_len };
  snapshot = anvil_ts_snapshot_new_from_lines(
    pathological_lines, pathological_lengths, 1, &error
  );
  CHECK(snapshot != NULL);
  CaptureList empty = {0};
  CHECK(anvil_markdown_extensions_scan(snapshot, NULL, 0, collect_capture, &empty, NULL, NULL));
  CHECK(empty.count == 0);
  anvil_ts_snapshot_free(snapshot);

  memset(pathological, '\\', pathological_len);
  snapshot = anvil_ts_snapshot_new_from_lines(
    pathological_lines, pathological_lengths, 1, &error
  );
  CHECK(snapshot != NULL);
  memset(&empty, 0, sizeof(empty));
  CHECK(anvil_markdown_extensions_scan(snapshot, NULL, 0, collect_capture, &empty, NULL, NULL));
  CHECK(empty.count == 0);
  CancelState cancel = { .cancel_after = 2 };
  CHECK(!anvil_markdown_extensions_scan(
    snapshot, NULL, 0, collect_capture, &empty, cancel_after, &cancel
  ));
  CHECK(cancel.calls == 2);
  anvil_ts_snapshot_free(snapshot);
  free(pathological);
  return 0;
}
