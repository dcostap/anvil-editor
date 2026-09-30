#include "api.h"
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <ctype.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <SDL3/SDL.h>

#define INDEX_TYPE "LineSearchIndex"
#define MATCH_DATA_TYPE "LineSearchMatchData"

static int match_data_gc(lua_State *L) {
  pcre2_match_data **md = lua_touserdata(L, 1);
  pcre2_match_data_free(*md);
  *md = NULL;
  return 0;
}

typedef struct { uint32_t first, last; } Range;
typedef struct {
  size_t offset, count;
  Range *edited;
} Line;
typedef struct {
  Line *lines;
  size_t *prefix;
  size_t line_count, count, capacity;
  Range *ranges;
  int64_t *coverage_edges;
  int coverage_first, coverage_last;
  double coverage_geometry[5];
  size_t coverage_line, coverage_match;
  int coverage_wrapped;
  int sealed;
} Index;

static void *checked_realloc(lua_State *L, void *p, size_t n, size_t size) {
  if (n > SIZE_MAX / size) luaL_error(L, "line search index is too large");
  void *out = realloc(p, n * size);
  if (!out && n) luaL_error(L, "out of memory in line search");
  return out;
}

static void rebuild_prefix(Index *index) {
  index->sealed = 1;
  memset(index->prefix, 0, (index->line_count + 1) * sizeof(size_t));
  index->count = 0;
  for (size_t i = 1; i <= index->line_count; i++) {
    index->prefix[i] += index->lines[i - 1].count;
    index->count += index->lines[i - 1].count;
    size_t parent = i + (i & -i);
    if (parent <= index->line_count) index->prefix[parent] += index->prefix[i];
  }
}

static size_t prefix_count(Index *index, size_t line) {
  size_t count = 0;
  for (; line; line -= line & -line) count += index->prefix[line];
  return count;
}

static int index_gc(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  for (size_t i = 0; i < index->line_count; i++) free(index->lines[i].edited);
  free(index->lines);
  free(index->ranges);
  free(index->prefix);
  free(index->coverage_edges);
  memset(index, 0, sizeof(*index));
  return 0;
}

static void append_range(lua_State *L, Index *index, size_t first, size_t last) {
  if (index->count == index->capacity) {
    size_t capacity = index->capacity ? index->capacity * 2 : 256;
    if (capacity < index->capacity) luaL_error(L, "line search index is too large");
    index->ranges = checked_realloc(L, index->ranges, capacity, sizeof(Range));
    index->capacity = capacity;
  }
  index->ranges[index->count++] = (Range) { (uint32_t) first, (uint32_t) last };
}

static size_t plain_find(const char *text, size_t len, const char *query, size_t qlen, size_t pos,
                         int sensitive, const size_t *failure, const unsigned char *fold) {
  if (!qlen) return pos;
  if (qlen > len || pos > len - qlen) return SIZE_MAX;
  if (sensitive && qlen == 1) {
    const char *first = memchr(text + pos, (unsigned char) query[0], len - pos);
    return first ? (size_t) (first - text) : SIZE_MAX;
  }
  size_t matched = 0;
  for (; pos < len; pos++) {
    unsigned char ch = sensitive ? (unsigned char) text[pos] : fold[(unsigned char) text[pos]];
    while (matched && ch != (unsigned char) query[matched]) matched = failure[matched - 1];
    if (ch == (unsigned char) query[matched]) matched++;
    if (matched == qlen) return pos + 1 - qlen;
  }
  return SIZE_MAX;
}

/* PCRE2 receives the suffix, as regex.find_offsets does. Its exclusive end
 * becomes the old scanner's inclusive end before applying the EOL rule. */
static void scan_line(lua_State *L, Index *out, const char *text, size_t len,
                      const char *query, size_t qlen, pcre2_code *re,
                      pcre2_match_data *md, int sensitive, const size_t *failure,
                      const unsigned char *fold) {
  if (len >= UINT32_MAX) luaL_error(L, "line search line exceeds 4GB");
  for (size_t pos = 0; pos < len;) {
    size_t first, end;
    if (re) {
      int rc = pcre2_match(re, (PCRE2_SPTR) text + pos, len - pos, 0, 0, md, NULL);
      if (rc == PCRE2_ERROR_NOMATCH) break;
      if (rc < 0) {
        PCRE2_UCHAR error[120];
        pcre2_get_error_message(rc, error, sizeof(error));
        luaL_error(L, "regex matching error %d: %s", rc, error);
      }
      PCRE2_SIZE *v = pcre2_get_ovector_pointer(md);
      if (v[0] > v[1]) luaL_error(L, "regex matching error: invalid match range");
      first = pos + v[0];
      end = pos + v[1] + 1; /* regex.find_offsets returns exclusive end + 1 */
    } else {
      first = plain_find(text, len, query, qlen, pos, sensitive, failure, fold);
      if (first == SIZE_MAX) break;
      end = first + qlen;
    }
    size_t s = first + 1;
    if (end >= s && (end != len || s != end))
      append_range(L, out, s, end == len ? end : end + 1);
    pos = end > first + 1 ? end : first + 1;
  }
}

static int index_len(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  lua_pushinteger(L, index->count);
  return 1;
}

static int index_get(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  if (!lua_isnumber(L, 2)) {
    luaL_getmetatable(L, INDEX_TYPE);
    lua_pushvalue(L, 2);
    lua_rawget(L, -2);
    return 1;
  }
  luaL_argcheck(L, index->sealed, 1, "scan is not finished");
  lua_Integer requested = lua_tointeger(L, 2);
  if (requested < 1 || (uint64_t) requested > index->count) return 0;
  size_t ordinal = requested - 1, line = 0, sum = 0, bit = 1;
  while (bit <= index->line_count / 2) bit *= 2;
  for (; bit; bit /= 2) {
    size_t next = line + bit;
    if (next <= index->line_count && sum + index->prefix[next] <= ordinal) {
      line = next;
      sum += index->prefix[next];
    }
  }
  Line *block = &index->lines[line];
  Range range = block->edited ? block->edited[ordinal - sum] : index->ranges[block->offset + ordinal - sum];
  lua_createtable(L, 0, 3);
  lua_pushinteger(L, line + 1); lua_setfield(L, -2, "line");
  lua_pushinteger(L, range.first); lua_setfield(L, -2, "col1");
  lua_pushinteger(L, range.last); lua_setfield(L, -2, "col2");
  return 1;
}

static int index_line_range(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  luaL_argcheck(L, index->sealed, 1, "scan is not finished");
  lua_Integer line = luaL_checkinteger(L, 2);
  if (line < 1 || (uint64_t) line > index->line_count) return 0;
  size_t first = prefix_count(index, line - 1);
  lua_pushinteger(L, first + 1);
  lua_pushinteger(L, first + index->lines[line - 1].count);
  return 2;
}

static size_t wrapped_row(lua_State *L, size_t line, uint32_t col, size_t rows) {
  lua_rawgeti(L, 2, line);
  size_t first = lua_tointeger(L, -1);
  lua_pop(L, 1);
  lua_rawgeti(L, 2, line + 1);
  size_t last = lua_isnil(L, -1) ? rows + 1 : (size_t) lua_tointeger(L, -1);
  lua_pop(L, 1);
  size_t lo = first, hi = last;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    lua_rawgeti(L, 3, mid * 2);
    uint32_t start = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (start <= col) lo = mid + 1; else hi = mid;
  }
  return lo > first ? lo - 1 : first;
}

static int pixel(double value) {
  value += .5;
  return value < 0 ? (int) ceil(value) : (int) floor(value);
}

static void uniform_coverage_delta(Index *index, size_t line, int64_t count) {
  double *g = index->coverage_geometry;
  double from = fmin(1, fmax(0, line * g[1] / g[0]));
  double to = fmin(1, fmax(from, (line + 1) * g[1] / g[0]));
  float height = fmin(g[3], fmax(g[4], (to - from) * g[3]));
  float top = fmin(g[2] + g[3] - height, fmax(g[2], g[2] + from * g[3]));
  int begin = pixel(top), finish = pixel((float) (top + height));
  if (begin >= index->coverage_first && finish <= index->coverage_last && finish > begin) {
    index->coverage_edges[begin - index->coverage_first] += count;
    index->coverage_edges[finish - index->coverage_first] -= count;
  }
}

static int index_coverage(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  luaL_argcheck(L, index->sealed, 1, "scan is not finished");
  int wrapped = !lua_isnil(L, 2);
  size_t wrapped_count = wrapped ? lua_rawlen(L, 3) / 2 : 0;
  if (wrapped_count == index->line_count) wrapped = 0;
  double size = luaL_checknumber(L, 4), unit = luaL_checknumber(L, 5);
  double y = luaL_checknumber(L, 6), h = luaL_checknumber(L, 7), minimum = luaL_checknumber(L, 8);
  int first_pixel = pixel((float) y), last_pixel = pixel((float) ((float) y + (float) h));
  if (h <= 0 || last_pixel <= first_pixel) { lua_newtable(L); return 1; }
  size_t pixels = last_pixel - first_pixel;
  double geometry[5] = { size, unit, y, h, minimum };
  if (!index->coverage_edges || index->coverage_wrapped != wrapped
      || (wrapped && lua_toboolean(L, 10))
      || memcmp(geometry, index->coverage_geometry, sizeof(geometry))) {
    int64_t *edges = calloc(pixels + 1, sizeof(int64_t));
    if (!edges) return luaL_error(L, "out of memory building search coverage");
    free(index->coverage_edges);
    index->coverage_edges = edges;
    memcpy(index->coverage_geometry, geometry, sizeof(geometry));
    index->coverage_first = first_pixel; index->coverage_last = last_pixel;
    index->coverage_line = index->coverage_match = 0;
    index->coverage_wrapped = wrapped;
  }
  double seconds = luaL_optnumber(L, 9, 0);
  uint64_t deadline = seconds > 0 ? SDL_GetPerformanceCounter()
    + (uint64_t) (seconds * SDL_GetPerformanceFrequency()) : 0;
  int64_t *edges = index->coverage_edges;
  size_t work = 0;
  while (index->coverage_line < index->line_count) {
    size_t line = index->coverage_line;
    Line *block = &index->lines[line];
    if (!wrapped || !block->count) {
      if (!wrapped) uniform_coverage_delta(index, line, block->count);
      index->coverage_line++;
      if (deadline && ++work % 64 == 0 && SDL_GetPerformanceCounter() >= deadline) {
        lua_pushnil(L); return 1;
      }
      continue;
    }
    Range *ranges = block->edited ? block->edited : index->ranges + block->offset;
    while (index->coverage_match < block->count) {
      size_t i = index->coverage_match++;
      size_t start = wrapped_row(L, line + 1, ranges[i].first, wrapped_count) - 1;
      size_t end = wrapped_row(L, line + 1, ranges[i].last - 1, wrapped_count);
      double from = fmin(1, fmax(0, start * unit / size));
      double to = fmin(1, fmax(from, end * unit / size));
      float height = fmin(h, fmax(minimum, (to - from) * h));
      float top = fmin(y + h - height, fmax(y, y + from * h));
      int begin = pixel(top) - first_pixel, finish = pixel((float) (top + height)) - first_pixel;
      if (begin >= 0 && finish <= (int) pixels && finish > begin) {
        edges[begin]++;
        edges[finish]--;
      }
      if (deadline && ++work % 64 == 0 && SDL_GetPerformanceCounter() >= deadline) {
        lua_pushnil(L); return 1;
      }
    }
    index->coverage_line++;
    index->coverage_match = 0;
  }
  lua_createtable(L, pixels, 0);
  int64_t count = 0;
  for (size_t row = 0; row < pixels; row++) {
    count += edges[row];
    lua_pushinteger(L, count);
    lua_rawseti(L, -2, row + first_pixel);
  }
  return 1;
}

static size_t scan_lines(lua_State *L, Index *out, int lines_arg, int query_arg,
                       int regex_arg, int case_arg, size_t first, size_t last,
                       size_t base, uint64_t deadline, size_t long_limit,
                       Range *nearest, size_t *nearest_line, size_t caret_line, size_t caret_col,
                       int stop_on_nearest) {
  size_t qlen;
  const char *query = luaL_checklstring(L, query_arg, &qlen);
  pcre2_code *re = lua_isnil(L, regex_arg) ? NULL : api_regex_compiled(L, regex_arg);
  pcre2_match_data **guard = lua_newuserdata(L, sizeof(*guard));
  *guard = NULL;
  luaL_setmetatable(L, MATCH_DATA_TYPE);
  pcre2_match_data *md = *guard = re ? pcre2_match_data_create_from_pattern(re, NULL) : NULL;
  if (re && !md) luaL_error(L, "out of memory matching regex");
  size_t *failure = lua_newuserdata(L, (qlen ? qlen : 1) * sizeof(size_t));
  failure[0] = 0;
  for (size_t i = 1, j = 0; i < qlen; i++) {
    while (j && query[i] != query[j]) j = failure[j - 1];
    if (query[i] == query[j]) j++;
    failure[i] = j;
  }
  unsigned char fold[256];
  for (int i = 0; i < 256; i++) fold[i] = tolower(i);
  const char *previous_text = NULL;
  size_t previous_len = 0;
  size_t line;
  for (line = first; line <= last; line++) {
    lua_rawgeti(L, lines_arg, line);
    size_t len;
    const char *text = luaL_checklstring(L, -1, &len);
    Line *block = &out->lines[line - base];
    if (long_limit && len > long_limit) {
      block->offset = out->count;
      lua_pop(L, 1);
      break;
    }
    if (line > first && text == previous_text && len == previous_len) {
      *block = out->lines[line - base - 1];
      lua_pop(L, 1);
    } else {
      block->offset = out->count;
      scan_line(L, out, text, len, query, qlen, re, md, lua_toboolean(L, case_arg), failure, fold);
      block->count = out->count - block->offset;
      previous_text = text; previous_len = len;
      lua_pop(L, 1);
    }
    if (nearest_line && !*nearest_line && block->count) {
      for (size_t i = 0; i < block->count; i++) {
        Range range = out->ranges[block->offset + i];
        if (line != caret_line || range.first >= caret_col) {
          *nearest = range; *nearest_line = line;
          break;
        }
      }
    }
    if (stop_on_nearest && nearest_line && *nearest_line) { line++; break; }
    if (deadline && line % 32 == 0 && SDL_GetTicksNS() >= deadline) { line++; break; }
  }
  pcre2_match_data_free(md);
  *guard = NULL;
  lua_pop(L, 2);
  return line;
}

static Index *new_index(lua_State *L, size_t lines) {
  Index *out = lua_newuserdata(L, sizeof(Index));
  memset(out, 0, sizeof(*out));
  luaL_setmetatable(L, INDEX_TYPE);
  out->lines = calloc(lines, sizeof(Line));
  out->prefix = calloc(lines + 1, sizeof(size_t));
  if ((!out->lines && lines) || !out->prefix) luaL_error(L, "out of memory indexing lines");
  out->line_count = lines;
  return out;
}

static int search_scan(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  size_t lines = lua_rawlen(L, 1);
  Index *out = new_index(L, lines);
  scan_lines(L, out, 1, 2, 3, 4, 1, lines, 1, 0, 0, NULL, NULL, 0, 0, 0);
  rebuild_prefix(out);
  return 1;
}

static int search_begin(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  new_index(L, lua_rawlen(L, 1));
  return 1;
}

static int index_advance(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  luaL_argcheck(L, !index->sealed, 1, "scan is already finished");
  size_t first = luaL_checkinteger(L, 6);
  luaL_argcheck(L, first >= 1 && first <= index->line_count + 1, 6, "invalid scan line");
  double budget = luaL_checknumber(L, 7);
  size_t limit = luaL_checkinteger(L, 8);
  size_t last = luaL_checkinteger(L, 9), caret_line = luaL_checkinteger(L, 10), caret_col = luaL_checkinteger(L, 11);
  luaL_argcheck(L, last <= index->line_count, 9, "invalid last scan line");
  Range nearest = {0};
  size_t nearest_line = 0;
  size_t next = scan_lines(L, index, 2, 3, 4, 5, first, last, 1,
    SDL_GetTicksNS() + (uint64_t) (budget * 1000000000), limit, &nearest, &nearest_line,
    caret_line, caret_col, lua_toboolean(L, 12));
  int long_line = 0;
  if (next <= last) {
    lua_rawgeti(L, 2, next);
    size_t len;
    lua_tolstring(L, -1, &len);
    lua_pop(L, 1);
    long_line = len > limit;
  }
  lua_pushinteger(L, next);
  lua_pushboolean(L, long_line);
  if (!nearest_line) lua_pushnil(L);
  else {
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, nearest_line); lua_setfield(L, -2, "line");
    lua_pushinteger(L, nearest.first); lua_setfield(L, -2, "col1");
    lua_pushinteger(L, nearest.last); lua_setfield(L, -2, "col2");
  }
  return 3;
}

static int index_finish(lua_State *L) {
  rebuild_prefix(luaL_checkudata(L, 1, INDEX_TYPE));
  return 0;
}

static int index_add_ranges(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  luaL_argcheck(L, !index->sealed, 1, "scan is already finished");
  size_t line = luaL_checkinteger(L, 2);
  luaL_argcheck(L, line >= 1 && line <= index->line_count, 2, "invalid scan line");
  size_t count = lua_rawlen(L, 3);
  luaL_argcheck(L, count % 2 == 0, 3, "invalid range batch");
  for (size_t i = 1; i <= count; i += 2) {
    lua_rawgeti(L, 3, i); lua_rawgeti(L, 3, i + 1);
    size_t first = luaL_checkinteger(L, -2), last = luaL_checkinteger(L, -1);
    lua_pop(L, 2);
    append_range(L, index, first, last);
    index->lines[line - 1].count++;
  }
  return 0;
}

static int index_replace(lua_State *L) {
  Index *index = luaL_checkudata(L, 1, INDEX_TYPE);
  luaL_argcheck(L, index->sealed, 1, "scan is not finished");
  luaL_checktype(L, 2, LUA_TTABLE);
  size_t old_first = luaL_checkinteger(L, 6), old_last = luaL_checkinteger(L, 7);
  size_t new_first = luaL_checkinteger(L, 8), new_last = luaL_checkinteger(L, 9);
  luaL_argcheck(L, old_first >= 1 && old_last >= old_first && old_last <= index->line_count, 6, "invalid old lines");
  luaL_argcheck(L, new_first == old_first && new_last >= new_first && new_last <= lua_rawlen(L, 2), 8, "invalid new lines");
  size_t removed = old_last - old_first + 1, added = new_last - new_first + 1;
  Index *replacement = new_index(L, added);
  scan_lines(L, replacement, 2, 3, 4, 5, new_first, new_last, new_first, 0, 0, NULL, NULL, 0, 0, 0);
  for (size_t i = 0; i < added; i++) {
    Line *line = &replacement->lines[i];
    if (line->count) {
      line->edited = checked_realloc(L, NULL, line->count, sizeof(Range));
      memcpy(line->edited, replacement->ranges + line->offset, line->count * sizeof(Range));
    }
  }
  if (removed == added) {
    if (index->coverage_wrapped) {
      free(index->coverage_edges);
      index->coverage_edges = NULL;
    }
    for (size_t i = 0; i < added; i++) {
      size_t at = old_first - 1 + i, before = index->lines[at].count;
      int covered = index->coverage_edges && at < index->coverage_line;
      if (covered) uniform_coverage_delta(index, at, -(int64_t) before);
      free(index->lines[at].edited);
      index->lines[at] = replacement->lines[i];
      replacement->lines[i].edited = NULL;
      /* Unsigned subtraction is valid for the count delta modulo SIZE_MAX. */
      size_t delta = index->lines[at].count - before;
      index->count += delta;
      if (covered) uniform_coverage_delta(index, at, index->lines[at].count);
      for (size_t p = at + 1; p <= index->line_count; p += p & -p) index->prefix[p] += delta;
    }
  } else {
    free(index->coverage_edges);
    index->coverage_edges = NULL;
    size_t count = index->line_count - removed + added;
    /* Allocate before moving ownership so allocation failure leaves a valid index. */
    if (count > SIZE_MAX / sizeof(Line) || count >= SIZE_MAX / sizeof(size_t))
      return luaL_error(L, "line search index is too large");
    Line *lines = malloc(count * sizeof(Line));
    size_t *prefix = malloc((count + 1) * sizeof(size_t));
    if ((!lines && count) || !prefix) {
      free(lines); free(prefix);
      return luaL_error(L, "out of memory replacing search lines");
    }
    for (size_t i = old_first - 1; i < old_last; i++) free(index->lines[i].edited);
    memcpy(lines, index->lines, (old_first - 1) * sizeof(Line));
    memcpy(lines + old_first - 1, replacement->lines, added * sizeof(Line));
    memcpy(lines + old_first - 1 + added, index->lines + old_last, (index->line_count - old_last) * sizeof(Line));
    for (size_t i = 0; i < added; i++) replacement->lines[i].edited = NULL;
    free(index->lines); free(index->prefix);
    index->lines = lines; index->prefix = prefix; index->line_count = count;
    rebuild_prefix(index);
  }
  return 0;
}

/* Stream a KMP search through the line table. No Buffer-sized text or lowercase copy. */
static int search_next(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  size_t qlen;
  const char *query = luaL_checklstring(L, 2, &qlen);
  if (!qlen) return 0;
  size_t line = luaL_checkinteger(L, 3), col = luaL_checkinteger(L, 4), lines = lua_rawlen(L, 1);
  int sensitive = lua_toboolean(L, 5);
  if (line < 1 || line > lines || col < 1) return 0;
  size_t *failure = lua_newuserdata(L, qlen * sizeof(size_t));
  unsigned char fold[256];
  for (int i = 0; i < 256; i++) fold[i] = tolower(i);
  failure[0] = 0;
  for (size_t i = 1, j = 0; i < qlen; i++) {
    while (j && query[i] != query[j]) j = failure[j - 1];
    if (query[i] == query[j]) j++;
    failure[i] = j;
  }
  size_t matched = 0;
  for (; line <= lines; line++, col = 1) {
    lua_rawgeti(L, 1, line);
    size_t len;
    const char *text = luaL_checklstring(L, -1, &len);
    for (; col <= len; col++) {
      unsigned char ch = text[col - 1];
      if (!sensitive) ch = fold[ch];
      while (matched && ch != (unsigned char) query[matched]) matched = failure[matched - 1];
      if (ch == (unsigned char) query[matched]) matched++;
      if (matched == qlen) {
        size_t first_line = line, first_col = col + 1, back = qlen;
        lua_pop(L, 1);
        while (back >= first_col && first_line > 1) {
          back -= first_col - 1;
          lua_rawgeti(L, 1, --first_line);
          size_t previous;
          lua_tolstring(L, -1, &previous);
          lua_pop(L, 1);
          first_col = previous + 1;
        }
        first_col -= back;
        lua_pushinteger(L, first_line); lua_pushinteger(L, first_col);
        lua_pushinteger(L, col == len && line < lines ? line + 1 : line);
        lua_pushinteger(L, col == len && line < lines ? 1 : col + 1);
        return 4;
      }
    }
    lua_pop(L, 1);
  }
  return 0;
}

int luaopen_line_search(lua_State *L) {
  luaL_newmetatable(L, MATCH_DATA_TYPE);
  lua_pushcfunction(L, match_data_gc); lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  static const luaL_Reg methods[] = {
    { "__gc", index_gc }, { "__len", index_len }, { "__index", index_get },
    { "line_range", index_line_range }, { "replace", index_replace },
    { "coverage", index_coverage }, { "advance", index_advance },
    { "add_ranges", index_add_ranges }, { "finish", index_finish }, { NULL, NULL }
  };
  luaL_newmetatable(L, INDEX_TYPE);
  luaL_setfuncs(L, methods, 0);
  lua_pop(L, 1);
  static const luaL_Reg functions[] = { { "scan", search_scan }, { "begin", search_begin },
    { "next", search_next }, { NULL, NULL } };
  luaL_newlib(L, functions);
  return 1;
}
