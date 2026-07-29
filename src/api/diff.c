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

static int tokenize(const char *src, int len, const char **tokens, int max_tokens, char *scratch, int scratch_len) {
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

static double token_similarity(const char *a, const char *b, int len_a, int len_b) {
  const char *tokensA[MAX_TOKENS], *tokensB[MAX_TOKENS];
  char scratchA[SCRATCH_SIZE], scratchB[SCRATCH_SIZE];

  int countA = tokenize(a, len_a, tokensA, MAX_TOKENS, scratchA, SCRATCH_SIZE);
  int countB = tokenize(b, len_b, tokensB, MAX_TOKENS, scratchB, SCRATCH_SIZE);

  if (countA == 0 || countB == 0) return 0.0;

  int matches = 0;
  for (int i = 0; i < countA; i++) {
    for (int j = 0; j < countB; j++) {
      if (strcmp(tokensA[i], tokensB[j]) == 0) {
        matches++;
        break;
      }
    }
  }

  return 2.0 * matches / (countA + countB);
}

static int structural_prefix_key(const char *src, char *key, int key_size) {
  int out = 0;
  bool found_boundary = false;
  bool found_identifier = false;

  while (*src == ' ' || *src == '\t') src++;
  while (*src && *src != '\r' && *src != '\n') {
    char c = *src++;
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

static bool has_matching_structural_prefix(const char *a, const char *b) {
  char key_a[256], key_b[256];
  int len_a = structural_prefix_key(a, key_a, (int)sizeof(key_a));
  int len_b = structural_prefix_key(b, key_b, (int)sizeof(key_b));
  return len_a > 0 && len_a == len_b && strcmp(key_a, key_b) == 0;
}

static const char *comment_marker(const char *src) {
  while (*src == ' ' || *src == '\t') src++;
  if (src[0] == '/' && src[1] == '/') return "//";
  if (src[0] == '/' && src[1] == '*') return "/*";
  if (src[0] == '-' && src[1] == '-') return "--";
  if (src[0] == '#') return "#";
  if (src[0] == '*') return "*";
  return NULL;
}

static bool has_matching_comment_marker(const char *a, const char *b) {
  const char *marker_a = comment_marker(a);
  const char *marker_b = comment_marker(b);
  return marker_a && marker_b && strcmp(marker_a, marker_b) == 0;
}


static double similarity(const char *a, const char *b) {
  if (strcmp(a, b) == 0) return 1.0;

  int la = (int)strlen(a);
  int lb = (int)strlen(b);
  if (la == 0 || lb == 0) return 0.0;

  // Fast prefix/suffix heuristic
  int prefix = 0;
  while (prefix < la && prefix < lb && a[prefix] == b[prefix]) prefix++;

  int suffix = 0;
  while (suffix < la && suffix < lb && a[la - 1 - suffix] == b[lb - 1 - suffix]) suffix++;

  double fast_score = (double)(prefix + suffix) / (la > lb ? la : lb);
  if (has_matching_structural_prefix(a, b) || has_matching_comment_marker(a, b)) {
    double token_score = token_similarity(a, b, la, lb);
    return token_score > 0.5 ? token_score : 0.5;
  }
  if (fast_score >= 0.8 || la < 20 || lb < 20)
    return fast_score;

  // Fast whitespace-token-based fallback
  return token_similarity(a, b, la, lb);
}

static double table_line_similarity(lua_State *L, int Aidx, int ai, int Bidx, int bi) {
  lua_rawgeti(L, Aidx, ai);
  const char *a = lua_tostring(L, -1);
  lua_rawgeti(L, Bidx, bi);
  const char *b = lua_tostring(L, -1);
  double score = similarity(a, b);
  lua_pop(L, 2);
  return score;
}


static Pair *build_equal_pairs(lua_State *L, int Aidx, int Bidx, int *npairs) {
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

  Pair *pairs = anvil_diff_equal_pairs(a_lines, n, b_lines, m, npairs);
  SDL_free(a_lines);
  SDL_free(b_lines);
  if (!pairs) luaL_error(L, "histogram diff engine failed");
  return pairs;
}


static void push_edit(lua_State *L, const char *tag, const char *key, const char *val) {
  lua_newtable(L);
  lua_pushstring(L, tag);
  lua_setfield(L, -2, "tag");
  if (val != NULL && key != NULL) {
    lua_pushstring(L, val);
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
  const char *a = luaL_checkstring(L, 1);
  const char *b = luaL_checkstring(L, 2);
  if (strcmp(a, b) == 0) {
    lua_newtable(L);
    lua_pushstring(L, "equal");
    lua_setfield(L, -2, "tag");
    lua_pushstring(L, a);
    lua_setfield(L, -2, "val");
    lua_newtable(L);
    lua_rawseti(L, -2, 1); // { {tag="equal", val=a} }
    return 1;
  }

  int m = strlen(a), n = strlen(b);
  int **dp = SDL_malloc((m+1) * sizeof(int*));
  for (int i = 0; i <= m; i++) {
    dp[i] = SDL_calloc(n+1, sizeof(int));
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
static int f_diff(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  int Aidx = 1, Bidx = 2;
  int lenA = (int)lua_rawlen(L, Aidx);
  int lenB = (int)lua_rawlen(L, Bidx);

  int npairs;
  Pair *pairs = build_equal_pairs(L, Aidx, Bidx, &npairs);

  lua_newtable(L);
  int result_idx = lua_gettop(L);
  int out_i = 1;
  int ai = 1, bi = 1, pi = 0;

  while (ai <= lenA || bi <= lenB) {
    int mi = (pi < npairs) ? pairs[pi].i : lenA + 1;
    int mj = (pi < npairs) ? pairs[pi].j : lenB + 1;

    if (ai == mi && bi == mj) {
      lua_rawgeti(L, Aidx, ai);
      const char *a = lua_tostring(L, -1);
      lua_rawgeti(L, Bidx, bi);
      const char *b = lua_tostring(L, -1);

      push_edit(L, "equal", "a", a);
      lua_pushstring(L, b);
      lua_setfield(L, -2, "b");
      lua_rawseti(L, result_idx, out_i++);

      lua_pop(L, 2);
      ai++; bi++; pi++;
    }
    else if (mi > ai && mj > bi) {
      // fallback similarity check for modifications
      lua_rawgeti(L, Aidx, ai);
      const char *a = lua_tostring(L, -1);
      lua_rawgeti(L, Bidx, bi);
      const char *b = lua_tostring(L, -1);
      double sim_val = similarity(a, b);
      lua_pop(L, 2);

      if (sim_val >= 0.4) {
        push_edit(L, "modify", "a", a);
        lua_pushstring(L, b);
        lua_setfield(L, -2, "b");
        lua_rawseti(L, result_idx, out_i++);

        ai++; bi++;
        continue;
      }

      // Prefer an adjacent structural match over eagerly deleting the current
      // source line. This keeps a modification paired when one side inserted
      // a neighboring line before it.
      double skip_b = bi + 1 < mj
        ? table_line_similarity(L, Aidx, ai, Bidx, bi + 1) : 0.0;
      double skip_a = ai + 1 < mi
        ? table_line_similarity(L, Aidx, ai + 1, Bidx, bi) : 0.0;
      if (skip_b >= 0.4 && skip_b > skip_a) {
        lua_rawgeti(L, Bidx, bi);
        const char *inserted = lua_tostring(L, -1);
        push_edit(L, "insert", "b", inserted);
        lua_rawseti(L, result_idx, out_i++);
        lua_pop(L, 1);
        bi++;
        continue;
      }
    }

    if (mi > ai) {
      lua_rawgeti(L, Aidx, ai);
      const char *a = lua_tostring(L, -1);
      push_edit(L, "delete", "a", a);
      lua_rawseti(L, result_idx, out_i++);
      lua_pop(L, 1);
      ai++;
    } else if (mj > bi) {
      lua_rawgeti(L, Bidx, bi);
      const char *b = lua_tostring(L, -1);
      push_edit(L, "insert", "b", b);
      lua_rawseti(L, result_idx, out_i++);
      lua_pop(L, 1);
      bi++;
    }
  }

  anvil_diff_pairs_free(pairs);
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
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tostring(L, -1);
      lua_pop(L, 1);

      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tostring(L, -1);
      lua_pop(L, 1);

      push_edit(L, "equal", "a", a);
      lua_pushstring(L, b);
      lua_setfield(L, -2, "b");

      state->ai++; state->bi++; state->pi++;
      return 1;
    }

    if (state->ai < mi && state->bi < mj) {
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tostring(L, -1);
      lua_pop(L, 1);

      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tostring(L, -1);
      lua_pop(L, 1);

      double sim_val = similarity(a, b);
      if (sim_val >= 0.4) {
        push_edit(L, "modify", "a", a);
        lua_pushstring(L, b);
        lua_setfield(L, -2, "b");

        state->ai++; state->bi++;
        return 1;
      }

      double skip_b = state->bi + 1 < mj
        ? table_line_similarity(L, Aidx, state->ai, Bidx, state->bi + 1) : 0.0;
      double skip_a = state->ai + 1 < mi
        ? table_line_similarity(L, Aidx, state->ai + 1, Bidx, state->bi) : 0.0;
      if (skip_b >= 0.4 && skip_b > skip_a) {
        lua_rawgeti(L, Bidx, state->bi);
        const char *inserted = lua_tostring(L, -1);
        lua_pop(L, 1);
        push_edit(L, "insert", "b", inserted);
        state->bi++;
        return 1;
      }
    }

    if (state->ai < mi) {
      lua_rawgeti(L, Aidx, state->ai);
      const char *a = lua_tostring(L, -1);
      lua_pop(L, 1);

      push_edit(L, "delete", "a", a);
      state->ai++;
      return 1;
    }

    if (state->bi < mj) {
      lua_rawgeti(L, Bidx, state->bi);
      const char *b = lua_tostring(L, -1);
      lua_pop(L, 1);

      push_edit(L, "insert", "b", b);
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
  state->pairs = build_equal_pairs(L, 1, 2, &state->npairs);

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
