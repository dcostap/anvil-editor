#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../src/terminal_model.h"

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

int main(void) {
  for (int alternate = 0; alternate <= 1; alternate++)
    for (int utf8 = 0; utf8 <= 1; utf8++) CHECK(round_trip(alternate, utf8) == 0);
  puts("snapshots preserve both screens, history, cursor, and unfinished VT/UTF-8 input");
  return 0;
}
