#include <SDL3/SDL.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <stdbool.h>

#include "api.h"
#include "../diff_engine.h"

#define MAX_TOKENS 64
#define SCRATCH_SIZE 1024

typedef AnvilDiffPair Pair;

typedef struct {
  Pair *pairs;
  int npairs;
  int ai, bi, pi;
  int lenA, lenB;
} DiffState;

static int diff_state_gc(lua_State *L) {
  DiffState *state = (DiffState *)lua_touserdata(L, 1);
  if (state && state->pairs) {
    anvil_diff_pairs_free(state->pairs);
    state->pairs = NULL;
  }
  return 0;
}

static bool is_token_char(char c) {
  return ((unsigned char)c >= 0x80) || // UTF-8 lead/continuation byte
         ((c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') ||
          c == '_');
}

static int tokenize(const char *src, size_t len, const char **tokens, int max_tokens, char *scratch, int scratch_len) {
  int count = 0, si = 0, ti = 0;

  while (si < len && count < max_tokens && ti < scratch_len - 1) {
    // Skip non-token chars
    while (si < len && !is_token_char(src[si])) si++;

    int start = si;
    while (si < len && is_token_char(src[si])) si++;

    int token_len = si - start;
    if (token_len > 0 && count < max_tokens) {
      if (ti + token_len + 1 >= scratch_len) break;
      memcpy(&scratch[ti], &src[start], token_len);
      scratch[ti + token_len] = '\0';
      tokens[count++] = &scratch[ti];
      ti += token_len + 1;
    }
  }

  return count;
}

static double token_similarity(const char *a, const char *b, size_t len_a, size_t len_b) {
  const char *tokensA[MAX_TOKENS], *tokensB[MAX_TOKENS];
  char scratchA[SCRATCH_SIZE], scratchB[SCRATCH_SIZE];

  int countA = tokenize(a, len_a, tokensA, MAX_TOKENS, scratchA, SCRATCH_SIZE);
  int countB = tokenize(b, len_b, tokensB, MAX_TOKENS, scratchB, SCRATCH_SIZE);

  if (countA == 0 || countB == 0) return 0.0;

  int matches = 0;
  bool used_b[MAX_TOKENS] = { false };
  for (int i = 0; i < countA; i++) {
    for (int j = 0; j < countB; j++) {
      if (!used_b[j] && strcmp(tokensA[i], tokensB[j]) == 0) {
        used_b[j] = true;
        matches++;
        break;
      }
    }
  }

  return 2.0 * matches / (countA + countB);
}

static int structural_prefix_key(const char *src, size_t len, char *key, int key_size) {
  int out = 0;
  size_t pos = 0;
  bool found_boundary = false;
  bool found_identifier = false;

  while (pos < len && (src[pos] == ' ' || src[pos] == '\t')) pos++;
  while (pos < len && src[pos] != '\r' && src[pos] != '\n') {
    char c = src[pos++];
    if (c == '"' || c == '\'' || c == '(' || c == '=') {
      found_boundary = true;
      break;
    }
    if (c == ' ' || c == '\t') continue;
    if (is_token_char(c)) found_identifier = true;
    if (out >= key_size - 1) return 0;
    key[out++] = c;
  }
  key[out] = '\0';
  return found_boundary && found_identifier && out >= 4 ? out : 0;
}

static bool has_matching_structural_prefix(const char *a, size_t len_a, const char *b, size_t len_b) {
  char key_a[256], key_b[256];
  int key_len_a = structural_prefix_key(a, len_a, key_a, (int)sizeof(key_a));
  int key_len_b = structural_prefix_key(b, len_b, key_b, (int)sizeof(key_b));
  return key_len_a > 0 && key_len_a == key_len_b && memcmp(key_a, key_b, (size_t)key_len_a) == 0;
}

static const char *comment_marker(const char *src, size_t len) {
  size_t pos = 0;
  while (pos < len && (src[pos] == ' ' || src[pos] == '\t')) pos++;
  if (pos + 1 < len && src[pos] == '/' && src[pos + 1] == '/') return "//";
  if (pos + 1 < len && src[pos] == '/' && src[pos + 1] == '*') return "/*";
  if (pos + 1 < len && src[pos] == '-' && src[pos + 1] == '-') return "--";
  if (pos < len && src[pos] == '#') return "#";
  if (pos < len && src[pos] == '*') return "*";
  return NULL;
}

static bool has_matching_comment_marker(const char *a, size_t len_a, const char *b, size_t len_b) {
  const char *marker_a = comment_marker(a, len_a);
  const char *marker_b = comment_marker(b, len_b);
  return marker_a && marker_b && strcmp(marker_a, marker_b) == 0;
}


static double similarity(const char *a, size_t la, const char *b, size_t lb) {
  // Indentation is not evidence that two different statements correspond.
  while (la && (*a == ' ' || *a == '\t')) { a++; la--; }
  while (lb && (*b == ' ' || *b == '\t')) { b++; lb--; }
  if (la == lb && memcmp(a, b, la) == 0) return 1.0;
  if (la == 0 || lb == 0) return 0.0;

  // Fast prefix/suffix heuristic
  size_t prefix = 0;
  while (prefix < la && prefix < lb && a[prefix] == b[prefix]) prefix++;

  size_t suffix = 0;
  while (suffix < la - prefix && suffix < lb - prefix && a[la - 1 - suffix] == b[lb - 1 - suffix]) suffix++;

  double fast_score = (double)(prefix + suffix) / (la > lb ? la : lb);
  if (has_matching_structural_prefix(a, la, b, lb) || has_matching_comment_marker(a, la, b, lb)) {
    double token_score = token_similarity(a, b, la, lb);
    return token_score > 0.5 ? token_score : 0.5;
  }
  if (fast_score >= 0.8 || la < 20 || lb < 20)
    return fast_score;

  // Fast whitespace-token-based fallback
  return token_similarity(a, b, la, lb);
}

// Refine only small gaps. Large unrelated blocks stay as deletions/additions.
// Exact and reindented anchors do not need this quadratic comparison.
static bool append_similar_pairs(const AnvilDiffLine *a, int alo, int ahi,
                                 const AnvilDiffLine *b, int blo, int bhi,
                                 Pair *out, int *count) {
  int n = ahi - alo, m = bhi - blo;
  if (!n || !m || (size_t)(n + 1) > 65536 / (size_t)(m + 1)) return true;
  typedef struct { double score; char step; } Cell;
  size_t width = (size_t)m + 1;
  Cell *cells = SDL_calloc((size_t)(n + 1) * width, sizeof(*cells));
  if (!cells) return false;
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      Cell *cell = &cells[(size_t)i * width + j];
      cell->score = cells[(size_t)(i + 1) * width + j].score;
      cell->step = 'a';
      double skip_b = cells[(size_t)i * width + j + 1].score;
      if (skip_b > cell->score) { cell->score = skip_b; cell->step = 'b'; }
      double score = similarity(a[alo + i].data, a[alo + i].length,
                                b[blo + j].data, b[blo + j].length);
      double paired = score + cells[(size_t)(i + 1) * width + j + 1].score;
      if (score >= 0.4 && paired >= cell->score) {
        cell->score = paired;
        cell->step = 'p';
      }
    }
  }
  int i = 0, j = 0;
  while (i < n && j < m) {
    char step = cells[(size_t)i * width + j].step;
    if (step == 'p') out[(*count)++] = (Pair){ alo + i + 1, blo + j + 1 };
    if (step != 'b') i++;
    if (step != 'a') j++;
  }
  SDL_free(cells);
  return true;
}

static AnvilDiffLine without_indent(AnvilDiffLine line) {
  while (line.length && (*line.data == ' ' || *line.data == '\t')) {
    line.data++;
    line.length--;
  }
  return line;
}

static bool append_reindented_pairs(AnvilDiffLine *a, int alo, int ahi,
                                    AnvilDiffLine *b, int blo, int bhi,
                                    Pair *out, int *count) {
  if (alo == ahi || blo == bhi) return true;
  // These arrays contain references, not source text. Keep the Lua text intact.
  for (int i = alo; i < ahi; i++) a[i] = without_indent(a[i]);
  for (int j = blo; j < bhi; j++) b[j] = without_indent(b[j]);
  int anchor_count = 0;
  Pair *anchors = anvil_diff_equal_pairs(a + alo, ahi - alo, b + blo, bhi - blo, &anchor_count);
  if (!anchors) return false;
  int ai = alo, bi = blo;
  bool ok = true;
  for (int k = 0; k <= anchor_count; k++) {
    int mi = k < anchor_count ? alo + anchors[k].i - 1 : ahi;
    int mj = k < anchor_count ? blo + anchors[k].j - 1 : bhi;
    if (!append_similar_pairs(a, ai, mi, b, bi, mj, out, count)) { ok = false; break; }
    if (k < anchor_count) out[(*count)++] = (Pair){ mi + 1, mj + 1 };
    ai = mi + 1;
    bi = mj + 1;
  }
  anvil_diff_pairs_free(anchors);
  return ok;
}

static Pair *build_line_pairs(lua_State *L, int Aidx, int Bidx, int *npairs) {
  int n = (int)lua_rawlen(L, Aidx);
  int m = (int)lua_rawlen(L, Bidx);
  AnvilDiffLine *a_lines = SDL_malloc((size_t)(n > 0 ? n : 1) * sizeof(*a_lines));
  AnvilDiffLine *b_lines = SDL_malloc((size_t)(m > 0 ? m : 1) * sizeof(*b_lines));
  if (!a_lines || !b_lines) {
    SDL_free(a_lines);
    SDL_free(b_lines);
    luaL_error(L, "out of memory preparing histogram diff");
  }
  for (int i = 1; i <= n; i++) {
    size_t len = 0;
    lua_rawgeti(L, Aidx, i);
    a_lines[i - 1].data = lua_tolstring(L, -1, &len);
    a_lines[i - 1].length = len;
    lua_pop(L, 1);
  }
  for (int i = 1; i <= m; i++) {
    size_t len = 0;
    lua_rawgeti(L, Bidx, i);
    b_lines[i - 1].data = lua_tolstring(L, -1, &len);
    b_lines[i - 1].length = len;
    lua_pop(L, 1);
  }

  int exact_count = 0;
  Pair *exact = anvil_diff_equal_pairs(a_lines, n, b_lines, m, &exact_count);
  int capacity = n < m ? n : m;
  Pair *pairs = malloc((size_t)(capacity > 0 ? capacity : 1) * sizeof(*pairs));
  bool ok = exact && pairs;
  *npairs = 0;
  int ai = 0, bi = 0;
  for (int k = 0; ok && k <= exact_count; k++) {
    int mi = k < exact_count ? exact[k].i - 1 : n;
    int mj = k < exact_count ? exact[k].j - 1 : m;
    ok = append_reindented_pairs(a_lines, ai, mi, b_lines, bi, mj, pairs, npairs);
    if (ok && k < exact_count) pairs[(*npairs)++] = exact[k];
    ai = mi + 1;
    bi = mj + 1;
  }
  anvil_diff_pairs_free(exact);
  SDL_free(a_lines);
  SDL_free(b_lines);
  if (!ok) {
    free(pairs);
    luaL_error(L, "line diff engine failed");
  }
  return pairs;
}


static void push_edit(lua_State *L, const char *tag, const char *key, const char *val, size_t val_len) {
  lua_newtable(L);
  lua_pushstring(L, tag);
  lua_setfield(L, -2, "tag");
  if (val != NULL && key != NULL) {
    lua_pushlstring(L, val, val_len);
    lua_setfield(L, -2, key);
  }
}


/*
 * diff.split(str, mode)
 *
 * Arguments:
 *  str the string to split
 *  mode The splitting mode which can be "char" or "line" (defaults to line)
 *
 * Returns:
 *  A table with the splitted values
 */
static int f_split(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *mode = luaL_optstring(L, 2, "line");

  lua_newtable(L);
  int idx = 1;

  if (strcmp(mode, "char") == 0) {
    for (const char *p = str; *p; ++p) {
      lua_pushlstring(L, p, 1);
      lua_rawseti(L, -2, idx++);
    }
  } else {
    const char *start = str;
    const char *p = str;
    while (*p) {
      if (*p == '\r' && *(p + 1) == '\n') {
        lua_pushlstring(L, start, p - start);
        lua_rawseti(L, -2, idx++);
        p += 2;
        start = p;
      } else if (*p == '\n') {
        lua_pushlstring(L, start, p - start);
        lua_rawseti(L, -2, idx++);
        p++;
        start = p;
      } else {
        p++;
      }
    }

    // Always push the final segment, even if empty
    lua_pushlstring(L, start, p - start);
    lua_rawseti(L, -2, idx++);
  }

  return 1;
}


/*
 * diff.inline_diff(str_a, str_b)
 *
 * Arguments:
 *  str_a a string to compare against string_b
 *  str_b a string to compare against string_a
 *
 * Returns:
 *  A table with the differences in the two strings
 */
static int f_inline_diff(lua_State *L) {
  size_t a_len = 0, b_len = 0;
  const char *a = luaL_checklstring(L, 1, &a_len);
  const char *b = luaL_checklstring(L, 2, &b_len);
  lua_Integer budget = luaL_optinteger(L, 3, 4 * 1024 * 1024);
  if (budget < 0 || (a_len + 1) > (size_t)budget / (b_len + 1)) {
    lua_pushnil(L);
    lua_pushliteral(L, "inline diff input is too large");
    return 2;
  }
  if (a_len == b_len && memcmp(a, b, a_len) == 0) {
    lua_newtable(L);
    lua_pushstring(L, "equal");
    lua_setfield(L, -2, "tag");
    lua_pushlstring(L, a, a_len);
    lua_setfield(L, -2, "val");
    lua_newtable(L);
    lua_rawseti(L, -2, 1); // { {tag="equal", val=a} }
    return 1;
  }

  int m = (int)a_len, n = (int)b_len;
  int **dp = SDL_calloc((size_t)m + 1, sizeof(int*));
  if (!dp) return luaL_error(L, "out of memory preparing inline diff");
  for (int i = 0; i <= m; i++) {
    dp[i] = SDL_calloc(n+1, sizeof(int));
    if (!dp[i]) {
      for (int k = 0; k < i; k++) SDL_free(dp[k]);
      SDL_free(dp);
      return luaL_error(L, "out of memory preparing inline diff");
    }
  }

  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (a[i-1] == b[j-1])
        dp[i][j] = dp[i-1][j-1] + 1;
      else
        dp[i][j] = fmax(dp[i-1][j], dp[i][j-1]);
    }
  }

  lua_newtable(L); // result table
  int edit_idx = 1;
  int i = m, j = n;

  while (i > 0 && j > 0) {
    if (a[i-1] == b[j-1]) {
      lua_newtable(L);
      lua_pushstring(L, "equal");
      lua_setfield(L, -2, "tag");
      lua_pushlstring(L, &a[i-1], 1);
      lua_setfield(L, -2, "val");
      lua_rawseti(L, -2, edit_idx++);
      i--; j--;
    } else if (dp[i-1][j] >= dp[i][j-1]) {
      lua_newtable(L);
      lua_pushstring(L, "delete");
      lua_setfield(L, -2, "tag");
      lua_pushlstring(L, &a[i-1], 1);
      lua_setfield(L, -2, "val");
      lua_rawseti(L, -2, edit_idx++);
      i--;
    } else {
      lua_newtable(L);
      lua_pushstring(L, "insert");
      lua_setfield(L, -2, "tag");
      lua_pushlstring(L, &b[j-1], 1);
      lua_setfield(L, -2, "val");
      lua_rawseti(L, -2, edit_idx++);
      j--;
    }
  }

  while (i > 0) {
    lua_newtable(L);
    lua_pushstring(L, "delete");
    lua_setfield(L, -2, "tag");
    lua_pushlstring(L, &a[i-1], 1);
    lua_setfield(L, -2, "val");
    lua_rawseti(L, -2, edit_idx++);
    i--;
  }

  while (j > 0) {
    lua_newtable(L);
    lua_pushstring(L, "insert");
    lua_setfield(L, -2, "tag");
    lua_pushlstring(L, &b[j-1], 1);
    lua_setfield(L, -2, "val");
    lua_rawseti(L, -2, edit_idx++);
    j--;
  }

  // Reverse result table
  lua_newtable(L);
  int total = edit_idx - 1;
  for (int k = 1; k <= total; k++) {
    lua_rawgeti(L, -2, total - k + 1);
    lua_rawseti(L, -2, k);
  }

  lua_remove(L, -2); // remove un-reversed table

  for (int k = 0; k <= m; k++) SDL_free(dp[k]);
  SDL_free(dp);

  return 1;
}


/*
 * diff.diff(strings_table_a, strings_table_b)
 *
 * Arguments:
 *  strings_table_a a list of strings to compare against strings_table_b
 *  strings_table_b a list of strings to compare against strings_table_a
 *
 * Returns:
 *  A table with the differences per line for a and b.
 */
static int f_diff_iter(lua_State *L);

static int f_diff(lua_State *L) {
  f_diff_iter(L);
  int iterator_idx = lua_gettop(L);
  lua_newtable(L);
  int result_idx = lua_gettop(L);
  for (int i = 1; ; i++) {
    lua_pushvalue(L, iterator_idx);
    lua_call(L, 0, 1);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); break; }
    lua_rawseti(L, result_idx, i);
  }
  return 1;
}


/* Closure for the diff.diff_iter */
static int diff_iterator(lua_State *L) {
  int Aidx = lua_upvalueindex(1);
  int Bidx = lua_upvalueindex(2);
  DiffState *state = (DiffState*)lua_touserdata(L, lua_upvalueindex(3));

  int lenA = state->lenA;
  int lenB = state->lenB;
  Pair *pairs = state->pairs;
  int npairs = state->npairs;

  while (state->ai <= lenA || state->bi <= lenB) {
    int mi = (state->pi < npairs) ? pairs[state->pi].i : lenA + 1;
    int mj = (state->pi < npairs) ? pairs[state->pi].j : lenB + 1;

    if (state->ai == mi && state->bi == mj) {
      size_t a_len = 0, b_len = 0;
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tolstring(L, -1, &a_len);
      lua_pop(L, 1);

      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tolstring(L, -1, &b_len);
      lua_pop(L, 1);

      bool equal = a_len == b_len && memcmp(a, b, a_len) == 0;
      push_edit(L, equal ? "equal" : "modify", "a", a, a_len);
      lua_pushlstring(L, b, b_len);
      lua_setfield(L, -2, "b");

      state->ai++; state->bi++; state->pi++;
      return 1;
    }

    if (state->ai < mi) {
      size_t a_len = 0;
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tolstring(L, -1, &a_len);
      lua_pop(L, 1);

      push_edit(L, "delete", "a", a, a_len);
      state->ai++;
      return 1;
    }

    if (state->bi < mj) {
      size_t b_len = 0;
      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tolstring(L, -1, &b_len);
      lua_pop(L, 1);

      push_edit(L, "insert", "b", b, b_len);
      state->bi++;
      return 1;
    }
  }

  if (state->pairs) {
    anvil_diff_pairs_free(state->pairs);
    state->pairs = NULL;
  }

  return 0;
}

/*
 * diff.diff_iter(strings_table_a, strings_table_b)
 *
 * Arguments:
 *  strings_table_a a list of strings to compare against strings_table_b
 *  strings_table_b a list of strings to compare against strings_table_a
 *
 * Returns:
 *  An iterator that yields the differences per line for a and b
 */
static int f_diff_iter(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  DiffState *state = (DiffState *)lua_newuserdata(L, sizeof(DiffState));
  int state_idx = lua_gettop(L);
  memset(state, 0, sizeof(*state));
  luaL_getmetatable(L, "diff.iterator_state");
  lua_setmetatable(L, -2);
  state->lenA = (int)lua_rawlen(L, 1);
  state->lenB = (int)lua_rawlen(L, 2);
  state->ai = 1;
  state->bi = 1;
  state->pi = 0;
  state->pairs = build_line_pairs(L, 1, 2, &state->npairs);

  /* Push tables and the owning userdata to the closure. */
  lua_pushvalue(L, 1);
  lua_pushvalue(L, 2);
  lua_pushvalue(L, state_idx);

  lua_pushcclosure(L, diff_iterator, 3);
  return 1;
}


static const struct luaL_Reg lib[] = {
  {"split", f_split},
  {"inline_diff", f_inline_diff},
  {"diff", f_diff},
  {"diff_iter", f_diff_iter},
  {NULL, NULL}
};


int luaopen_diff(lua_State *L) {
  if (luaL_newmetatable(L, "diff.iterator_state")) {
    lua_pushcfunction(L, diff_state_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
  luaL_newlib(L, lib);
  return 1;
}
