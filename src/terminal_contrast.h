#ifndef ANVIL_TERMINAL_CONTRAST_H
#define ANVIL_TERMINAL_CONTRAST_H

#include <stdbool.h>
#include <stdint.h>

#define TERMINAL_CONTRAST_CACHE_SIZE 512

typedef struct {
  uint32_t foreground;
  uint8_t alpha;
} TerminalInk;

typedef struct {
  uint32_t foreground;
  uint32_t background;
  uint8_t alpha;
  bool valid;
  TerminalInk result;
} TerminalContrastEntry;

typedef struct {
  double minimum;
  double vividness;
  TerminalContrastEntry entries[TERMINAL_CONTRAST_CACHE_SIZE];
} TerminalContrast;

uint32_t terminal_color_blend(uint32_t foreground, uint32_t background, uint8_t alpha);
bool terminal_contrast_graphics(uint32_t codepoint);
TerminalInk terminal_contrast_ink(
  TerminalContrast *contrast, uint32_t foreground, uint32_t background,
  uint8_t alpha, uint32_t codepoint
);

#endif
