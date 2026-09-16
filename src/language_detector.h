#ifndef ANVIL_LANGUAGE_DETECTOR_H
#define ANVIL_LANGUAGE_DETECTOR_H

#include <stdbool.h>
#include <stddef.h>

#define ANVIL_LANGUAGE_DETECTOR_CLASS_COUNT 48

typedef struct AnvilLanguageDetection {
  float probabilities[ANVIL_LANGUAGE_DETECTOR_CLASS_COUNT];
} AnvilLanguageDetection;

const char *anvil_language_detector_slug(size_t index);

bool anvil_language_detect(
  const char *model_path,
  const char *source,
  size_t source_len,
  AnvilLanguageDetection *detection,
  char **error
);

#endif
