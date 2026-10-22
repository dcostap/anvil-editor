#include "api.h"

#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// The rows and row heights of a Text View.
//
// Lua decides which rows a line has and measures each row. C keeps the rows
// in flat arrays. Lua calls this module once for each change, and C moves
// the rows after the change and their lines. The map from lines to rows and
// the sums of the heights update lazily, so a change costs no Lua work for
// the rows that it does not touch.

#define API_TYPE_ROW_HEIGHTS "LayoutRowHeights"
#define API_TYPE_ROWS "LayoutRows"
#define ROW_FIELDS 5

typedef struct {
  int count;
  int capacity;
  double *height;
  double *plan;
  // prefix[i] is the sum of the heights of rows 1..i. Entries 0..valid are current.
  double *prefix;
  int valid;
} RowHeights;

static RowHeights *check_heights(lua_State *L) {
  return (RowHeights *)luaL_checkudata(L, 1, API_TYPE_ROW_HEIGHTS);
}

static void reserve_heights(lua_State *L, RowHeights *h, int count) {
  if (count <= h->capacity) return;
  int capacity = h->capacity > 0 ? h->capacity : 64;
  while (capacity < count) {
    if (capacity > INT_MAX / 2) luaL_error(L, "too many layout rows");
    capacity *= 2;
  }
  double *height = realloc(h->height, sizeof(double) * capacity);
  if (height) h->height = height;
  double *plan = realloc(h->plan, sizeof(double) * capacity);
  if (plan) h->plan = plan;
  double *prefix = realloc(h->prefix, sizeof(double) * ((size_t)capacity + 1));
  if (prefix) h->prefix = prefix;
  if (!height || !plan || !prefix) luaL_error(L, "out of memory for layout rows");
  h->capacity = capacity;
}

static void update_prefix(RowHeights *h, int row) {
  for (int i = h->valid; i < row; i++) h->prefix[i + 1] = h->prefix[i] + h->height[i];
  if (row > h->valid) h->valid = row;
}

static void invalidate_prefix(RowHeights *h, int row) {
  if (row - 1 < h->valid) h->valid = row - 1 < 0 ? 0 : row - 1;
}

static int check_row(lua_State *L, RowHeights *h, int arg) {
  lua_Integer row = luaL_checkinteger(L, arg);
  luaL_argcheck(L, row >= 1 && row <= h->count, arg, "row out of range");
  return (int)row;
}

static int f_heights_new(lua_State *L) {
  RowHeights *h = lua_newuserdata(L, sizeof(RowHeights));
  memset(h, 0, sizeof(RowHeights));
  luaL_setmetatable(L, API_TYPE_ROW_HEIGHTS);
  reserve_heights(L, h, 1);
  h->prefix[0] = 0;
  return 1;
}

static int f_heights_gc(lua_State *L) {
  RowHeights *h = check_heights(L);
  free(h->height);
  free(h->plan);
  free(h->prefix);
  memset(h, 0, sizeof(RowHeights));
  return 0;
}

static int f_heights_count(lua_State *L) {
  lua_pushinteger(L, check_heights(L)->count);
  return 1;
}

static int f_heights_total(lua_State *L) {
  RowHeights *h = check_heights(L);
  update_prefix(h, h->count);
  lua_pushnumber(L, h->prefix[h->count]);
  return 1;
}

// heights:get(row) -> height, plan
static int f_heights_get(lua_State *L) {
  RowHeights *h = check_heights(L);
  int row = check_row(L, h, 2);
  lua_pushnumber(L, h->height[row - 1]);
  lua_pushnumber(L, h->plan[row - 1]);
  return 2;
}

// heights:set(row, height, plan) -> previous height
static int f_heights_set(lua_State *L) {
  RowHeights *h = check_heights(L);
  int row = check_row(L, h, 2);
  double height = luaL_checknumber(L, 3);
  double previous = h->height[row - 1];
  h->height[row - 1] = height;
  h->plan[row - 1] = luaL_optnumber(L, 4, 0);
  if (height != previous) invalidate_prefix(h, row);
  lua_pushnumber(L, previous);
  return 1;
}

// heights:replace(row, remove_count, heights, plans) -> removed height
// Replace `remove_count` rows from `row` with the rows of the arrays.
static int f_heights_replace(lua_State *L) {
  RowHeights *h = check_heights(L);
  lua_Integer row = luaL_checkinteger(L, 2);
  lua_Integer remove = luaL_checkinteger(L, 3);
  luaL_checktype(L, 4, LUA_TTABLE);
  bool has_plans = !lua_isnoneornil(L, 5);
  if (has_plans) luaL_checktype(L, 5, LUA_TTABLE);
  luaL_argcheck(L, row >= 1 && row <= (lua_Integer)h->count + 1, 2, "row out of range");
  luaL_argcheck(L, remove >= 0 && remove <= h->count - row + 1, 3, "remove count out of range");
  int insert = (int)lua_rawlen(L, 4);
  int first = (int)row - 1;
  int count = h->count - (int)remove + insert;
  // Read every value before a change, so a bad value changes nothing.
  double *incoming = lua_newuserdata(L, sizeof(double) * 2 * (insert > 0 ? insert : 1));
  for (int i = 0; i < insert; i++) {
    lua_rawgeti(L, 4, i + 1);
    if (!lua_isnumber(L, -1)) return luaL_error(L, "row height %d is not a number", i + 1);
    incoming[i * 2] = lua_tonumber(L, -1);
    lua_pop(L, 1);
    incoming[i * 2 + 1] = 0;
    if (has_plans) {
      lua_rawgeti(L, 5, i + 1);
      incoming[i * 2 + 1] = lua_tonumber(L, -1);
      lua_pop(L, 1);
    }
  }
  reserve_heights(L, h, count);
  update_prefix(h, first + (int)remove);
  double removed = h->prefix[first + remove] - h->prefix[first];
  int tail = h->count - first - (int)remove;
  memmove(h->height + first + insert, h->height + first + remove, sizeof(double) * tail);
  memmove(h->plan + first + insert, h->plan + first + remove, sizeof(double) * tail);
  for (int i = 0; i < insert; i++) {
    h->height[first + i] = incoming[i * 2];
    h->plan[first + i] = incoming[i * 2 + 1];
  }
  h->count = count;
  invalidate_prefix(h, first + 1);
  lua_pushnumber(L, removed);
  return 1;
}

// heights:y_offset(row) -> the sum of the heights of the rows before `row`.
static int f_heights_y_offset(lua_State *L) {
  RowHeights *h = check_heights(L);
  lua_Integer row = luaL_checkinteger(L, 2);
  if (row < 1) row = 1;
  if (row > (lua_Integer)h->count + 1) row = h->count + 1;
  update_prefix(h, (int)row - 1);
  lua_pushnumber(L, h->prefix[row - 1]);
  return 1;
}

// heights:row_at_y(y) -> the row at offset `y`, from 1 to the row count.
static int f_heights_row_at_y(lua_State *L) {
  RowHeights *h = check_heights(L);
  double y = luaL_checknumber(L, 2);
  update_prefix(h, h->count);
  // The last row whose start is at or above y.
  int low = 0, high = h->count;
  while (low < high) {
    int mid = low + (high - low + 1) / 2;
    if (h->prefix[mid] <= y) low = mid; else high = mid - 1;
  }
  int result = low + 1;
  if (result > h->count) result = h->count;
  if (result < 1) result = 1;
  lua_pushinteger(L, result);
  return 1;
}

static const luaL_Reg heights_methods[] = {
  { "__gc", f_heights_gc },
  { "count", f_heights_count },
  { "total", f_heights_total },
  { "get", f_heights_get },
  { "set", f_heights_set },
  { "replace", f_heights_replace },
  { "y_offset", f_heights_y_offset },
  { "row_at_y", f_heights_row_at_y },
  { NULL, NULL }
};


// A composed row. `kind` is 0 for a text row, 1 for a fold row, and 2 for a
// row without a position, such as a provider row. A text row or a fold row is
// the position of the lines `line..last_line`. `payload` is a Lua handle, or 0.
typedef struct {
  int kind;
  int line;
  int last_line;
  int row_in_line;
  int payload;
} Row;

typedef struct {
  int count;
  int capacity;
  Row *rows;
  // positions[line] is the row of `line`, or 0. It is current when
  // positions_valid is true.
  int *positions;
  int position_capacity;
  int position_count;
  bool positions_valid;
} Rows;

static Rows *check_rows(lua_State *L) {
  return (Rows *)luaL_checkudata(L, 1, API_TYPE_ROWS);
}

static void reserve_rows(lua_State *L, Rows *r, int count) {
  if (count <= r->capacity) return;
  int capacity = r->capacity > 0 ? r->capacity : 64;
  while (capacity < count) {
    if (capacity > INT_MAX / 2) luaL_error(L, "too many layout rows");
    capacity *= 2;
  }
  Row *rows = realloc(r->rows, sizeof(Row) * capacity);
  if (!rows) luaL_error(L, "out of memory for layout rows");
  r->rows = rows;
  r->capacity = capacity;
}

static void update_positions(lua_State *L, Rows *r) {
  if (r->positions_valid) return;
  int line_count = 0;
  for (int i = 0; i < r->count; i++) {
    if (r->rows[i].last_line > line_count) line_count = r->rows[i].last_line;
  }
  if (line_count + 1 > r->position_capacity) {
    int *positions = realloc(r->positions, sizeof(int) * ((size_t)line_count + 1));
    if (!positions) luaL_error(L, "out of memory for layout rows");
    r->positions = positions;
    r->position_capacity = line_count + 1;
  }
  memset(r->positions, 0, sizeof(int) * ((size_t)line_count + 1));
  r->position_count = line_count;
  for (int i = 0; i < r->count; i++) {
    const Row *row = &r->rows[i];
    if (row->kind == 2 || (row->kind == 0 && row->row_in_line != 1) || row->line < 1) continue;
    for (int line = row->line; line <= row->last_line; line++) {
      if (r->positions[line] == 0) r->positions[line] = i + 1;
    }
  }
  r->positions_valid = true;
}

static int f_rows_new(lua_State *L) {
  Rows *r = lua_newuserdata(L, sizeof(Rows));
  memset(r, 0, sizeof(Rows));
  luaL_setmetatable(L, API_TYPE_ROWS);
  return 1;
}

static int f_rows_gc(lua_State *L) {
  Rows *r = check_rows(L);
  free(r->rows);
  free(r->positions);
  memset(r, 0, sizeof(Rows));
  return 0;
}

static int f_rows_count(lua_State *L) {
  lua_pushinteger(L, check_rows(L)->count);
  return 1;
}

// rows:get(row) -> kind, line, row_in_line, payload
static int f_rows_get(lua_State *L) {
  Rows *r = check_rows(L);
  lua_Integer index = luaL_checkinteger(L, 2);
  luaL_argcheck(L, index >= 1 && index <= r->count, 2, "row out of range");
  const Row *row = &r->rows[index - 1];
  lua_pushinteger(L, row->kind);
  lua_pushinteger(L, row->line);
  lua_pushinteger(L, row->row_in_line);
  lua_pushinteger(L, row->payload);
  return 4;
}

// rows:first_row(line) -> the first row whose line is `line` or later, or
// the row count + 1.
static int f_rows_first_row(lua_State *L) {
  Rows *r = check_rows(L);
  lua_Integer line = luaL_checkinteger(L, 2);
  int low = 0, high = r->count;
  while (low < high) {
    int mid = low + (high - low) / 2;
    if (r->rows[mid].line < line) low = mid + 1; else high = mid;
  }
  lua_pushinteger(L, low + 1);
  return 1;
}

// rows:position_row(line) -> the text row or fold row of `line`, or nil.
static int f_rows_position_row(lua_State *L) {
  Rows *r = check_rows(L);
  lua_Integer line = luaL_checkinteger(L, 2);
  update_positions(L, r);
  if (line < 1 || line > r->position_count || r->positions[line] == 0) {
    lua_pushnil(L);
  } else {
    lua_pushinteger(L, r->positions[line]);
  }
  return 1;
}

// rows:replace(row, remove_count, records, line_delta) -> removed payloads
// Replace `remove_count` rows from `row` with the rows of `records`, a flat
// array with the fields kind, line, last_line, row_in_line, and payload of
// each row. Then move the lines of every later row by `line_delta`. Return
// the nonzero payloads of the removed rows in an array.
static int f_rows_replace(lua_State *L) {
  Rows *r = check_rows(L);
  lua_Integer index = luaL_checkinteger(L, 2);
  lua_Integer remove = luaL_checkinteger(L, 3);
  luaL_checktype(L, 4, LUA_TTABLE);
  lua_Integer line_delta = luaL_optinteger(L, 5, 0);
  luaL_argcheck(L, index >= 1 && index <= (lua_Integer)r->count + 1, 2, "row out of range");
  luaL_argcheck(L, remove >= 0 && remove <= r->count - index + 1, 3, "remove count out of range");
  int fields = (int)lua_rawlen(L, 4);
  luaL_argcheck(L, fields % ROW_FIELDS == 0, 4, "incomplete row record");
  int insert = fields / ROW_FIELDS;
  int first = (int)index - 1;
  int count = r->count - (int)remove + insert;

  // Read every record before a change, so a bad record changes nothing.
  Row *incoming = lua_newuserdata(L, sizeof(Row) * (insert > 0 ? insert : 1));
  for (int i = 0; i < insert; i++) {
    int values[ROW_FIELDS];
    for (int field = 0; field < ROW_FIELDS; field++) {
      lua_rawgeti(L, 4, i * ROW_FIELDS + field + 1);
      if (!lua_isnumber(L, -1)) return luaL_error(L, "row record %d has a field that is not a number", i + 1);
      values[field] = (int)lua_tointeger(L, -1);
      lua_pop(L, 1);
    }
    incoming[i].kind = values[0];
    incoming[i].line = values[1];
    incoming[i].last_line = values[2] < values[1] ? values[1] : values[2];
    incoming[i].row_in_line = values[3];
    incoming[i].payload = values[4];
  }
  reserve_rows(L, r, count);

  lua_createtable(L, 0, 0);
  int removed = 0;
  for (int i = first; i < first + remove; i++) {
    if (r->rows[i].payload != 0) {
      lua_pushinteger(L, r->rows[i].payload);
      lua_rawseti(L, -2, ++removed);
    }
  }

  int tail = r->count - first - (int)remove;
  memmove(r->rows + first + insert, r->rows + first + remove, sizeof(Row) * tail);
  memcpy(r->rows + first, incoming, sizeof(Row) * insert);
  if (line_delta != 0) {
    for (int i = first + insert; i < count; i++) {
      r->rows[i].line += (int)line_delta;
      r->rows[i].last_line += (int)line_delta;
    }
  }
  r->count = count;
  r->positions_valid = false;
  return 1;
}

static const luaL_Reg rows_methods[] = {
  { "__gc", f_rows_gc },
  { "count", f_rows_count },
  { "get", f_rows_get },
  { "first_row", f_rows_first_row },
  { "position_row", f_rows_position_row },
  { "replace", f_rows_replace },
  { NULL, NULL }
};

static const luaL_Reg lib[] = {
  { "heights", f_heights_new },
  { "rows", f_rows_new },
  { NULL, NULL }
};

int luaopen_layout_rows(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_ROW_HEIGHTS);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, heights_methods, 0);
  lua_pop(L, 1);
  luaL_newmetatable(L, API_TYPE_ROWS);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, rows_methods, 0);
  lua_pop(L, 1);
  luaL_newlib(L, lib);
  return 1;
}
