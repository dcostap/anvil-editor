#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../src/terminal_model.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL: %s\n", #x); return 1; } } while (0)

static GhosttyFormatterTerminalOptions options(void) {
  return (GhosttyFormatterTerminalOptions) {
    .size = sizeof(GhosttyFormatterTerminalOptions), .emit = GHOSTTY_FORMATTER_FORMAT_VT,
    .extra = { .size = sizeof(GhosttyFormatterTerminalExtra),
      .palette = true, .modes = true, .scrolling_region = true,
      .tabstops = true, .pwd = true, .keyboard = true,
      .screen = { .size = sizeof(GhosttyFormatterScreenExtra), .cursor = true,
        .style = true, .hyperlink = true, .kitty_keyboard = true, .charsets = true } }
  };
}

static int compare(GhosttyTerminal a, GhosttyTerminal b) {
  bool same = true;
  const GhosttyTerminalData fields[] = { GHOSTTY_TERMINAL_DATA_CURSOR_X,
    GHOSTTY_TERMINAL_DATA_CURSOR_Y, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,
    GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN };
  for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
    size_t av = 0, bv = 0;
    CHECK(ghostty_terminal_get(a, fields[i], &av) == GHOSTTY_SUCCESS);
    CHECK(ghostty_terminal_get(b, fields[i], &bv) == GHOSTTY_SUCCESS);
    if (av != bv) fprintf(stderr, "field %d: %zu != %zu\n", fields[i], av, bv);
    if (av != bv) same = false;
  }
  GhosttyFormatter fa = NULL, fb = NULL;
  GhosttyFormatterTerminalOptions plain = options();
  plain.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  uint8_t *at = NULL, *bt = NULL;
  size_t al = 0, bl = 0;
  CHECK(ghostty_formatter_terminal_new(NULL, &fa, a, plain) == GHOSTTY_SUCCESS);
  CHECK(ghostty_formatter_terminal_new(NULL, &fb, b, plain) == GHOSTTY_SUCCESS);
  CHECK(ghostty_formatter_format_alloc(fa, NULL, &at, &al) == GHOSTTY_SUCCESS);
  CHECK(ghostty_formatter_format_alloc(fb, NULL, &bt, &bl) == GHOSTTY_SUCCESS);
  if (al != bl || memcmp(at, bt, al) != 0) {
    fprintf(stderr, "rows A (%zu): [%.*s]\nrows B (%zu): [%.*s]\n", al, (int)al, at, bl, (int)bl, bt);
  }
  if (al != bl || memcmp(at, bt, al) != 0) same = false;
  ghostty_free(NULL, at, al); ghostty_free(NULL, bt, bl);
  ghostty_formatter_free(fa); ghostty_formatter_free(fb);
  return same ? 0 : 1;
}

int main(void) {
  for (int alternate = 0; alternate <= 1; alternate++) {
    GhosttyTerminal a = NULL, b = NULL;
    CHECK(ghostty_terminal_new(NULL, &a, 20, 3) == GHOSTTY_SUCCESS);
    CHECK(ghostty_terminal_new(NULL, &b, 20, 3) == GHOSTTY_SUCCESS);
    const char *primary = "one\r\ntwo\r\nthree\r\nfour\r\nfive";
    ghostty_terminal_vt_write(a, (const uint8_t *)primary, strlen(primary));
    if (alternate) {
      const char *alt = "\033[?1049hALT\033[2;4H";
      ghostty_terminal_vt_write(a, (const uint8_t *)alt, strlen(alt));
    }
    GhosttyFormatter formatter = NULL;
    CHECK(ghostty_formatter_terminal_new(NULL, &formatter, a, options()) == GHOSTTY_SUCCESS);
    uint8_t *vt = NULL; size_t len = 0;
    CHECK(ghostty_formatter_format_alloc(formatter, NULL, &vt, &len) == GHOSTTY_SUCCESS);
    ghostty_terminal_vt_write(b, vt, len);
    printf("formatter %s screen matches: %s\n", alternate ? "alternate" : "primary",
      compare(a, b) == 0 ? "yes" : "no");
    if (alternate) {
      const char *leave = "\033[?1049l";
      ghostty_terminal_vt_write(a, (const uint8_t *)leave, strlen(leave));
      ghostty_terminal_vt_write(b, (const uint8_t *)leave, strlen(leave));
      printf("formatter retained primary after alternate: %s\n", compare(a, b) == 0 ? "yes" : "no");
    }
    ghostty_free(NULL, vt, len); ghostty_formatter_free(formatter);
    ghostty_terminal_free(a); ghostty_terminal_free(b);
    CHECK(ghostty_terminal_new(NULL, &a, 20, 3) == GHOSTTY_SUCCESS);
    CHECK(ghostty_terminal_new(NULL, &b, 20, 3) == GHOSTTY_SUCCESS);
    /* The fallback must start at byte zero, never at a truncated VT prefix. */
    const char *raw = alternate ? "one\r\ntwo\r\nthree\r\nfour\r\nfive\033[?1049hALT\033[2;4H" : primary;
    ghostty_terminal_vt_write(a, (const uint8_t *)raw, strlen(raw));
    AnvilTerminalReplay replay = {0};
    size_t split = strlen(raw) / 2;
    anvil_terminal_replay_append(&replay, (const uint8_t *)raw, split);
    anvil_terminal_replay_append(&replay, (const uint8_t *)raw + split, strlen(raw) - split);
    CHECK(!replay.overflow);
    ghostty_terminal_vt_write(b, replay.bytes, replay.length);
    CHECK(compare(a, b) == 0);
    if (alternate) {
      ghostty_terminal_vt_write(a, (const uint8_t *)"\033[?1049l", 8);
      ghostty_terminal_vt_write(b, (const uint8_t *)"\033[?1049l", 8);
      CHECK(compare(a, b) == 0);
    }
    ghostty_terminal_free(a); ghostty_terminal_free(b);
    /* An incomplete prefix must not become a suffix replay. */
    anvil_terminal_replay_append(&replay, (const uint8_t *)raw, ANVIL_TERMINAL_REPLAY_LIMIT);
    CHECK(replay.overflow && !replay.bytes && replay.length == 0);
    anvil_terminal_replay_append(&replay, (const uint8_t *)raw, strlen(raw));
    CHECK(replay.overflow && !replay.bytes && replay.length == 0);
    anvil_terminal_replay_free(&replay);
  }
  puts("raw replay preserves primary scrollback, alternate screen, and cursor");
  return 0;
}
