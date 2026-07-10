#ifndef ANVIL_MARKDOWN_EXTENSIONS_H
#define ANVIL_MARKDOWN_EXTENSIONS_H

#include <stdbool.h>
#include <stdint.h>

#include "treesitter/snapshot.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilMarkdownExclusion {
  uint32_t start_byte;
  uint32_t end_byte;
} AnvilMarkdownExclusion;

typedef struct AnvilMarkdownExtensionCapture {
  const char *name;
  uint32_t start_byte;
  uint32_t end_byte;
} AnvilMarkdownExtensionCapture;

typedef bool (*AnvilMarkdownExtensionCaptureCallback)(
  const AnvilMarkdownExtensionCapture *capture,
  void *payload
);

typedef bool (*AnvilMarkdownExtensionCancelCallback)(void *payload);

bool anvil_markdown_extensions_scan(
  const AnvilTSSnapshot *snapshot,
  const AnvilMarkdownExclusion *exclusions,
  uint32_t exclusion_count,
  AnvilMarkdownExtensionCaptureCallback capture_callback,
  void *capture_payload,
  AnvilMarkdownExtensionCancelCallback cancel_callback,
  void *cancel_payload
);

#ifdef __cplusplus
}
#endif

#endif
