/* The scan benchmark uses the same candidate patterns as the editor. */
#include "fuzzy.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

int main(int argc, char **argv) {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY);
#endif
  char text[32768];
  size_t len = fread(text, 1, sizeof(text), stdin);
  if (len == sizeof(text) || ferror(stdin)) return 2;
  unsigned runs = 1;
  bool sensitive = false;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--bench")) runs = 1000;
    else if (!strcmp(argv[i], "--case-sensitive")) sensitive = true;
    else return 2;
  }
  clock_t started = clock();
  for (unsigned i = 0; i < runs; ++i) {
    FuzzyLiteral *query = fuzzy_literal_create(text, (uint32_t)len, sensitive);
    if (!query) return 3;
    char *pattern = fuzzy_literal_pattern(query);
    fuzzy_literal_free(query);
    if (!pattern) return 4;
    if (runs == 1) puts(pattern);
    free(pattern);
  }
  if (runs > 1) printf("%.6f\n", 1000.0 * (clock() - started) / CLOCKS_PER_SEC / runs);
  return 0;
}
