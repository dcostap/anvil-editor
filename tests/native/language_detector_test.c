#include "language_detector.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "check failed at %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    return 1; \
  } \
} while (0)

static const char *best_language(const AnvilLanguageDetection *detection, float *confidence) {
  size_t best = 0;
  for (size_t i = 1; i < ANVIL_LANGUAGE_DETECTOR_CLASS_COUNT; i++) {
    if (detection->probabilities[i] > detection->probabilities[best]) best = i;
  }
  if (confidence) *confidence = detection->probabilities[best];
  return anvil_language_detector_slug(best);
}

static int expect_language(const char *model, const char *source, const char *expected) {
  AnvilLanguageDetection detection;
  char *error = NULL;
  CHECK(anvil_language_detect(model, source, strlen(source), &detection, &error));
  CHECK(error == NULL);
  float confidence = 0.0f;
  const char *actual = best_language(&detection, &confidence);
  if (strcmp(actual, expected) != 0) {
    fprintf(stderr, "expected %s, got %s (%.4f) for:\n%s\n", expected, actual, confidence, source);
    return 1;
  }
  CHECK(confidence > 0.2f);
  return 0;
}

int main(int argc, char **argv) {
  CHECK(argc == 2);
  const char *model = argv[1];
  CHECK(expect_language(model,
    "fn main() {\n    println!(\"hello from Anvil\");\n}\n", "rust") == 0);
  CHECK(expect_language(model,
    "def greet(name):\n    print(f\"hello {name}\")\n\ngreet(\"Anvil\")\n", "python") == 0);
  CHECK(expect_language(model,
    "package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"hello\") }\n", "go") == 0);
  return 0;
}
