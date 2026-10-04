#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../src/terminal_model.h"
#include "../../src/terminal_snapshot.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static int compare(GhosttyTerminal a, GhosttyTerminal b) {
  const GhosttyTerminalData fields[] = { GHOSTTY_TERMINAL_DATA_CURSOR_X,
    GHOSTTY_TERMINAL_DATA_CURSOR_Y, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,
    GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN };
  for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
    size_t av = 0, bv = 0;
    CHECK(ghostty_terminal_get(a, fields[i], &av) == GHOSTTY_SUCCESS);
    CHECK(ghostty_terminal_get(b, fields[i], &bv) == GHOSTTY_SUCCESS);
    CHECK(av == bv);
  }
  GhosttyFormatter fa = NULL, fb = NULL;
  GhosttyFormatterTerminalOptions plain = {
    .size = sizeof(plain), .emit = GHOSTTY_FORMATTER_FORMAT_PLAIN,
  };
  uint8_t *at = NULL, *bt = NULL;
  size_t al = 0, bl = 0;
  CHECK(ghostty_formatter_terminal_new(NULL, &fa, a, plain) == GHOSTTY_SUCCESS);
  CHECK(ghostty_formatter_terminal_new(NULL, &fb, b, plain) == GHOSTTY_SUCCESS);
  CHECK(ghostty_formatter_format_alloc(fa, NULL, &at, &al) == GHOSTTY_SUCCESS);
  CHECK(ghostty_formatter_format_alloc(fb, NULL, &bt, &bl) == GHOSTTY_SUCCESS);
  CHECK(al == bl && memcmp(at, bt, al) == 0);
  ghostty_free(NULL, at, al); ghostty_free(NULL, bt, bl);
  ghostty_formatter_free(fa); ghostty_formatter_free(fb);
  return 0;
}

static int round_trip(int alternate, int utf8) {
  GhosttyTerminal a = NULL, b = NULL;
  size_t lines = 1000;
  CHECK(anvil_terminal_model_new(&a, 20, 3, 8, 16, &lines));
  const char *primary = "one\r\ntwo\r\nthree\r\nfour\r\nfive";
  ghostty_terminal_vt_write(a, (const uint8_t *)primary, strlen(primary));
  if (alternate) ghostty_terminal_vt_write(a, (const uint8_t *)"\033[?1049hALT\033[2;4H", 18);
  /* Snapshot between PTY reads, not just at a parser ground boundary. */
  const char *prefix = utf8 ? "\xe7\x95" : "\033[3";
  const char *suffix = utf8 ? "\x8c" : "1mred";
  ghostty_terminal_vt_write(a, (const uint8_t *)prefix, strlen(prefix));
  uint8_t *bytes = NULL; size_t length = 0;
  CHECK(ghostty_snapshot_encode_alloc(a, NULL, &bytes, &length) == GHOSTTY_SUCCESS);
  GhosttySnapshotDecoder decoder = NULL;
  CHECK(ghostty_snapshot_decoder_new_buf(NULL, &decoder, bytes, length) == GHOSTTY_SUCCESS);
  CHECK(ghostty_snapshot_decoder_ready(decoder, &b) == GHOSTTY_SUCCESS);
  GhosttyResult result;
  do { result = ghostty_snapshot_decoder_next(decoder); } while (result == GHOSTTY_SUCCESS);
  CHECK(result == GHOSTTY_NO_VALUE);
  size_t consumed = 0;
  CHECK(ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET,
    &consumed) == GHOSTTY_SUCCESS && consumed == length);
  ghostty_snapshot_decoder_free(decoder);
  CHECK(compare(a, b) == 0);
  ghostty_terminal_vt_write(a, (const uint8_t *)suffix, strlen(suffix));
  ghostty_terminal_vt_write(b, (const uint8_t *)suffix, strlen(suffix));
  CHECK(compare(a, b) == 0);
  if (alternate) {
    ghostty_terminal_vt_write(a, (const uint8_t *)"\033[?1049l", 8);
    ghostty_terminal_vt_write(b, (const uint8_t *)"\033[?1049l", 8);
    CHECK(compare(a, b) == 0);
  }
  ghostty_terminal_free(b); b = NULL;
  /* Neither truncated nor corrupt snapshots may publish a complete model. */
  CHECK(ghostty_snapshot_decoder_new_buf(NULL, &decoder, bytes, length - 1) == GHOSTTY_SUCCESS);
  CHECK(ghostty_snapshot_decoder_decode(decoder, &b) != GHOSTTY_SUCCESS && !b);
  ghostty_snapshot_decoder_free(decoder);
  bytes[length - 1] ^= 1;
  CHECK(ghostty_snapshot_decoder_new_buf(NULL, &decoder, bytes, length) == GHOSTTY_SUCCESS);
  CHECK(ghostty_snapshot_decoder_decode(decoder, &b) != GHOSTTY_SUCCESS && !b);
  ghostty_snapshot_decoder_free(decoder);
  ghostty_free(NULL, bytes, length); ghostty_terminal_free(a);
  return 0;
}

static bool disk_encode(GhosttyTerminal model, uint8_t **bytes, size_t *length) {
  return anvil_terminal_snapshot_encode(model, bytes, length) &&
    anvil_terminal_disk_snapshot_prepare(bytes, length, NULL);
}

static int disk_bounds(void) {
  GhosttyTerminal model = NULL, restored = NULL;
  size_t lines = 100000;
  CHECK(anvil_terminal_model_new(&model, 80, 24, 8, 16, &lines));
  for (int i = 0; i < 40000; i++) {
    char line[128]; int count = snprintf(line, sizeof(line), "%06d a retained row with enough text to fill many history pages\r\n", i);
    ghostty_terminal_vt_write(model, (const uint8_t *)line, count);
  }
  const char *tail = "RECENT_DISK_SNAPSHOT_TEXT";
  ghostty_terminal_vt_write(model, (const uint8_t *)tail, strlen(tail));
  size_t before = 0, after = 0, kept = 0;
  ghostty_terminal_get(model, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &before);
  uint8_t *bytes = NULL; size_t length = 0;
  CHECK(disk_encode(model, &bytes, &length));
  CHECK(length <= ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT);
  CHECK(anvil_terminal_snapshot_decode(bytes, length, &restored));
  ghostty_terminal_get(model, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &after);
  ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &kept);
  CHECK(before == after && kept <= before && kept > 0);
  GhosttyFormatter formatter = NULL;
  GhosttyFormatterTerminalOptions plain = { .size = sizeof(plain), .emit = GHOSTTY_FORMATTER_FORMAT_PLAIN };
  CHECK(ghostty_formatter_terminal_new(NULL, &formatter, restored, plain) == GHOSTTY_SUCCESS);
  uint8_t *text = NULL; size_t text_length = 0;
  CHECK(ghostty_formatter_format_alloc(formatter, NULL, &text, &text_length) == GHOSTTY_SUCCESS);
  CHECK(text_length >= strlen(tail));
  bool found = false;
  for (size_t i = 0; i + strlen(tail) <= text_length; i++) if (!memcmp(text + i, tail, strlen(tail))) found = true;
  CHECK(found);
  ghostty_free(NULL, text, text_length); ghostty_formatter_free(formatter);
  ghostty_terminal_free(restored); free(bytes); bytes = NULL;
  /* An unfinished graphics payload cannot be trimmed as history. Reject it
     rather than publish an oversized or partial checkpoint. */
  ghostty_terminal_vt_write(model, (const uint8_t *)"\033_G", 3);
  size_t oversized = ANVIL_TERMINAL_DISK_SNAPSHOT_LIMIT + 1024;
  uint8_t *payload = malloc(oversized); CHECK(payload); memset(payload, 'A', oversized);
  ghostty_terminal_vt_write(model, payload, oversized); free(payload);
  CHECK(!disk_encode(model, &bytes, &length));
  ghostty_terminal_get(model, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &after);
  CHECK(before == after);
  ghostty_terminal_free(model); free(bytes);
  return 0;
}

static int disk_atomic_and_quota(void) {
  char temp[MAX_PATH], directory[MAX_PATH + 40], path[MAX_PATH + 340], id[33];
  CHECK(GetTempPathA(MAX_PATH, temp));
  snprintf(directory, sizeof(directory), "%sanvil-snapshots-%lu", temp, (unsigned long)GetCurrentProcessId());
  CHECK(CreateDirectoryA(directory, NULL));
  GhosttyTerminal model = NULL, restored = NULL;
  CHECK(anvil_terminal_model_new(&model, 20, 3, 8, 16, NULL));
  ghostty_terminal_vt_write(model, (const uint8_t *)"atomic saved screen", 19);
  uint8_t *bytes = NULL; size_t length = 0; DWORD error;
  CHECK(disk_encode(model, &bytes, &length));
  for (unsigned i = 0; i <= ANVIL_TERMINAL_PROJECT_SNAPSHOTS; i++) {
    snprintf(id, sizeof(id), "%032x", i);
    snprintf(path, sizeof(path), "%s/%s.snapshot", directory, id);
    CHECK(anvil_terminal_snapshot_store(path, "project-one", id, bytes, length, false, &error));
  }
  char pattern[MAX_PATH + 80]; snprintf(pattern, sizeof(pattern), "%s/*.snapshot", directory);
  WIN32_FIND_DATAA entry; HANDLE scan = FindFirstFileA(pattern, &entry); unsigned count = 0;
  CHECK(scan != INVALID_HANDLE_VALUE);
  do { count++; } while (FindNextFileA(scan, &entry)); FindClose(scan);
  CHECK(count == ANVIL_TERMINAL_PROJECT_SNAPSHOTS);
  CHECK(!anvil_terminal_snapshot_store(path, "project-one", id, bytes, length - 1, false, &error));
  GhosttyTerminal replacement = NULL;
  CHECK(anvil_terminal_model_new(&replacement, 20, 3, 8, 16, NULL));
  ghostty_terminal_vt_write(replacement, (const uint8_t *)"unpublished text", 16);
  uint8_t *next = NULL; size_t next_length = 0;
  CHECK(disk_encode(replacement, &next, &next_length));
  HANDLE locked = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  CHECK(locked != INVALID_HANDLE_VALUE);
  CHECK(!anvil_terminal_snapshot_store(path, "project-one", id, next, next_length, true, &error));
  CloseHandle(locked); free(next); ghostty_terminal_free(replacement);
  CHECK(anvil_terminal_snapshot_load(path, "project-one", id, &restored, &error));
  CHECK(compare(model, restored) == 0); ghostty_terminal_free(restored); restored = NULL;
  CHECK(!anvil_terminal_snapshot_load(path, "project-two", id, &restored, &error));
  snprintf(id, sizeof(id), "%032x", 999);
  snprintf(path, sizeof(path), "%s/%s.snapshot", directory, id);
  CHECK(anvil_terminal_snapshot_store(path, "project-two", id, bytes, length, true, &error));
  scan = FindFirstFileA(pattern, &entry); count = 0;
  CHECK(scan != INVALID_HANDLE_VALUE);
  do { count++; snprintf(path, sizeof(path), "%s/%s", directory, entry.cFileName); DeleteFileA(path); }
    while (FindNextFileA(scan, &entry)); FindClose(scan);
  CHECK(count == ANVIL_TERMINAL_PROJECT_SNAPSHOTS + 1);
  CHECK(RemoveDirectoryA(directory));
  free(bytes); ghostty_terminal_free(model);
  return 0;
}

int main(void) {
  CHECK(disk_bounds() == 0);
  CHECK(disk_atomic_and_quota() == 0);
  for (int alternate = 0; alternate <= 1; alternate++)
    for (int utf8 = 0; utf8 <= 1; utf8++) CHECK(round_trip(alternate, utf8) == 0);
  puts("snapshots preserve both screens, history, cursor, and unfinished VT/UTF-8 input");
  return 0;
}
