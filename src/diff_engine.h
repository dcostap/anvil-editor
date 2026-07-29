#ifndef ANVIL_DIFF_ENGINE_H
#define ANVIL_DIFF_ENGINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilDiffLine {
  const char *data;
  size_t length;
} AnvilDiffLine;

typedef struct AnvilDiffPair {
  int i;
  int j;
} AnvilDiffPair;

/*
 * Find exact equal-line pairs using histogram anchors and a shortest-edit-script
 * fallback. Returned indices are one-based. The caller owns the result and must
 * release it with anvil_diff_pairs_free(). On allocation/engine failure, NULL is
 * returned and *pair_count is set to -1.
 */
AnvilDiffPair *anvil_diff_equal_pairs(
  const AnvilDiffLine *a, int a_count,
  const AnvilDiffLine *b, int b_count,
  int *pair_count
);

void anvil_diff_pairs_free(AnvilDiffPair *pairs);

#ifdef __cplusplus
}
#endif

#endif
