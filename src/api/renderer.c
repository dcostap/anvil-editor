#include <string.h>
#include <assert.h>
#include <limits.h>
#include <math.h>
#include <lua.h>

#include "api.h"
#include "../renderer.h"
#include "../d3d11_backend.h"
#include "../display_packet.h"
#include "../rencache.h"
#include "../renwindow.h"
#include "utils/lxlauxlib.h"

// a reference index to a table that stores fonts during a render cycle
int RENDERER_FONT_REF = LUA_NOREF;
// a reference index to a table that stores canvases during a render cycle
int RENDERER_CANVAS_REF = LUA_NOREF;

typedef struct {
  RenDisplayPacket *packet;
  int font_refs;
} LuaDisplayPacket;

static void renderer_clear_font_refs(lua_State *L) {
  if (RENDERER_FONT_REF == LUA_NOREF) return;
  lua_newtable(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
}

static void renderer_clear_canvas_refs(lua_State *L) {
  if (RENDERER_CANVAS_REF == LUA_NOREF) return;
  lua_newtable(L);
  lua_rawseti(L, LUA_REGISTRYINDEX, RENDERER_CANVAS_REF);
}

typedef struct {
  char *text;
  size_t text_len;
  size_t count;
  uint32_t *byte_offsets;
  double *advances;
} LuaTextLayout;

static int font_get_options(
  lua_State *L,
  ERenFontAntialiasing *antialiasing,
  ERenFontHinting *hinting,
  int *style,
  int *ligatures
) {
  if (lua_gettop(L) > 2 && lua_istable(L, 3)) {
    lua_getfield(L, 3, "antialiasing");
    if (lua_isstring(L, -1)) {
      const char *antialiasing_str = lua_tostring(L, -1);
      if (antialiasing_str) {
        if (strcmp(antialiasing_str, "none") == 0) {
          *antialiasing = FONT_ANTIALIASING_NONE;
        } else if (strcmp(antialiasing_str, "grayscale") == 0) {
          *antialiasing = FONT_ANTIALIASING_GRAYSCALE;
        } else if (strcmp(antialiasing_str, "subpixel") == 0) {
          *antialiasing = FONT_ANTIALIASING_SUBPIXEL;
        } else {
          return luaL_error(
            L,
            "error in font options, unknown antialiasing option: \"%s\"",
            antialiasing_str
          );
        }
      }
    }
    lua_getfield(L, 3, "hinting");
    if (lua_isstring(L, -1)) {
      const char *hinting_str = lua_tostring(L, -1);
      if (hinting_str) {
        if (strcmp(hinting_str, "slight") == 0) {
          *hinting = FONT_HINTING_SLIGHT;
        } else if (strcmp(hinting_str, "none") == 0) {
          *hinting = FONT_HINTING_NONE;
        } else if (strcmp(hinting_str, "full") == 0) {
          *hinting = FONT_HINTING_FULL;
        } else {
          return luaL_error(
            L,
            "error in font options, unknown hinting option: \"%s\"",
            hinting
          );
        }
      }
    }
    int style_local = 0;
    lua_getfield(L, 3, "italic");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_ITALIC;
    lua_getfield(L, 3, "bold");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_BOLD;
    lua_getfield(L, 3, "underline");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_UNDERLINE;
    lua_getfield(L, 3, "smoothing");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_SMOOTH;
    lua_getfield(L, 3, "strikethrough");
    if (lua_toboolean(L, -1))
      style_local |= FONT_STYLE_STRIKETHROUGH;
    lua_getfield(L, 3, "ligatures");
    if (lua_isboolean(L, -1))
      *ligatures = lua_toboolean(L, -1);

    lua_pop(L, 8);

    if (style_local != 0)
      *style = style_local;
  }

  return 0;
}

static int f_font_load(lua_State *L) {
  const char *filename  = luaL_checkstring(L, 1);
  float size = luaL_checknumber(L, 2);
  int style = 0;
  int ligatures = false;
  ERenFontHinting hinting = FONT_HINTING_SLIGHT;
  ERenFontAntialiasing antialiasing = FONT_ANTIALIASING_SUBPIXEL;

  int ret_code = font_get_options(L, &antialiasing, &hinting, &style, &ligatures);
  if (ret_code > 0)
    return ret_code;

  RenFont** font = lua_newuserdata(L, sizeof(RenFont*));
  *font = ren_font_load(filename, size, antialiasing, hinting, style, ligatures);
  if (!*font)
    return luaL_error(L, "failed to load font: %s", SDL_GetError());
  luaL_setmetatable(L, API_TYPE_FONT);
  return 1;
}

static int f_font_copy(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);
  float size = lua_gettop(L) >= 2 ? luaL_checknumber(L, 2) : ren_font_group_get_height(fonts);
  int style = -1;
  int ligatures = -1;
  ERenFontHinting hinting = -1;
  ERenFontAntialiasing antialiasing = -1;

  int ret_code = font_get_options(L, &antialiasing, &hinting, &style, &ligatures);
  if (ret_code > 0)
    return ret_code;

  if (table) {
    lua_newtable(L);
    luaL_setmetatable(L, API_TYPE_FONT);
  }
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    RenFont** font = lua_newuserdata(L, sizeof(RenFont*));
    *font = ren_font_copy(fonts[i], size, antialiasing, hinting, style, ligatures);
    if (!*font)
      return luaL_error(L, "failed to copy font: %s", SDL_GetError());
    luaL_setmetatable(L, API_TYPE_FONT);
    if (table)
      lua_rawseti(L, -2, i+1);
  }
  return 1;
}

static int f_font_group(lua_State* L) {
  int table_size;
  luaL_checktype(L, 1, LUA_TTABLE);

  table_size = lua_rawlen(L, 1);
  if (table_size <= 0)
    return luaL_error(L, "failed to create font group: table is empty");
  if (table_size > FONT_FALLBACK_MAX)
    return luaL_error(L, "failed to create font group: table size too large");

  // we also need to ensure that there are no fontgroups inside it
  for (int i = 1; i <= table_size; i++) {
    if (lua_rawgeti(L, 1, i) != LUA_TUSERDATA)
      return luaL_typeerror(L, -1, API_TYPE_FONT "(userdata)");
    lua_pop(L, 1);
  }

  luaL_setmetatable(L, API_TYPE_FONT);
  return 1;
}

static int f_font_get_path(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);

  if (table) {
    lua_newtable(L);
  }
  for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
    const char* path = ren_font_get_path(fonts[i]);
    lua_pushstring(L, path);
    if (table)
      lua_rawseti(L, -2, i+1);
  }
  return 1;
}

static int f_font_set_tab_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  int n = luaL_checknumber(L, 2);
  ren_font_group_set_tab_size(fonts, n);
  return 0;
}

static int f_font_gc(lua_State *L) {
  if (lua_istable(L, 1)) return 0; // do not run if its FontGroup
  RenFont** self = luaL_checkudata(L, 1, API_TYPE_FONT);
  ren_font_free(*self);

  return 0;
}

static int f_font_get_width(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  RenTab tab = luaXL_checktab(L, 3);

  lua_pushnumber(L, ren_font_group_get_width(fonts, text, len, tab, NULL));
  return 1;
}

static int f_font_get_height(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_height(fonts));
  return 1;
}

static int f_font_get_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  lua_pushnumber(L, ren_font_group_get_size(fonts));
  return 1;
}

static int f_font_get_generation(lua_State *L) {
  RenFont *fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);
  if (table) lua_newtable(L);
  int count = 0;
  for (int index = 0; index < FONT_FALLBACK_MAX && fonts[index]; index++) {
    lua_pushinteger(L, (lua_Integer)ren_font_get_generation(fonts[index]));
    count++;
    if (table) lua_rawseti(L, -2, index + 1);
  }
  return table ? 1 : (count > 0 ? 1 : 0);
}

static int f_font_get_surface_scale(lua_State *L) {
  RenFont *fonts[FONT_FALLBACK_MAX];
  bool table = font_retrieve(L, fonts, 1);
  if (table) lua_newtable(L);
  int count = 0;
  for (int index = 0; index < FONT_FALLBACK_MAX && fonts[index]; index++) {
    lua_pushnumber(L, ren_font_get_surface_scale(fonts[index]));
    count++;
    if (table) lua_rawseti(L, -2, index + 1);
  }
  return table ? 1 : (count > 0 ? 1 : 0);
}

static int f_font_set_size(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  float size = luaL_checknumber(L, 2);
  float scale = 1.0;
#ifdef ANVIL_USE_SDL_RENDERER
  RenWindow *window = ren_get_target_window();
  if (window != NULL) {
    scale = rencache_get_surface(&window->cache).scale_x;
  }
#endif
  ren_font_group_set_size(fonts, size, scale);
  return 0;
}

static int f_font_get_metadata(lua_State *L) {
  const char* filenames[FONT_FALLBACK_MAX];
  int fonts_found = 0;
  bool table = false;
  if (lua_type(L, 1) == LUA_TSTRING) {
    fonts_found = 1;
    filenames[0] = luaL_checkstring(L, 1);
  } else {
    RenFont* fonts[FONT_FALLBACK_MAX];
    table = font_retrieve(L, fonts, 1);
    if (table)
      lua_newtable(L);
    for (int i = 0; i < FONT_FALLBACK_MAX && fonts[i]; ++i) {
      filenames[i] = ren_font_get_path(fonts[i]);
      fonts_found++;
    }
  }

  int ret_count = 1;

  for(int f=0; f<fonts_found; f++) {
    int found = 0;
    FontMetaData *data;
    bool monospaced = false;
    int error = ren_font_get_metadata(filenames[f], &data, &found, &monospaced);

    if ((error == 0 && found > 0) || fonts_found > 1) {
      int meta_idx = table ? 3 : 2;
      lua_newtable(L);
      for (int i=0; i<found; i++) {
        switch(data[i].tag) {
          case FONT_FAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "family");
            break;
          case FONT_SUBFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "subfamily");
            break;
          case FONT_ID:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "id");
            break;
          case FONT_FULLNAME:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "fullname");
            break;
          case FONT_VERSION:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "version");
            break;
          case FONT_PSNAME:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "psname");
            break;
          case FONT_TFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "tfamily");
            break;
          case FONT_TSUBFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "tsubfamily");
            break;
          case FONT_WWSFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "wwsfamily");
            break;
          case FONT_WWSSUBFAMILY:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "wwssubfamily");
            break;
          case FONT_SAMPLETEXT:
            lua_pushlstring(L, data[i].value, data[i].len);
            lua_setfield(L, meta_idx, "sampletext");
            break;
        }
        free(data[i].value);
      }

      lua_pushboolean(L, monospaced);
      lua_setfield(L, meta_idx, "monospace");
      free(data);

      if (table)
        lua_rawseti(L, 2, f+1);
    } else if (error == 2) {
      lua_pushnil(L);
      lua_pushstring(L, "could not retrieve the font meta data");
      ret_count = 2;
      break;
    } else {
      lua_pushnil(L);
      lua_pushstring(L, "no meta data found");
      ret_count = 2;
      break;
    }
  }

  return ret_count;
}


static int f_show_debug(lua_State *L) {
  luaL_checkany(L, 1);
  rencache_show_debug(lua_toboolean(L, 1));
  return 0;
}


static int f_get_size(lua_State *L) {
  int w = 0, h = 0;
  RenWindow *window = ren_get_target_window();
  if (window) {
    rencache_get_size(&window->cache, &w, &h);
  }
  lua_pushnumber(L, w);
  lua_pushnumber(L, h);
  return 2;
}


static int f_begin_frame(UNUSED lua_State *L) {
  assert(ren_get_target_window() == NULL);
  renderer_clear_font_refs(L);
  renderer_clear_canvas_refs(L);
  RenWindow *window = *(RenWindow**)luaL_checkudata(L, 1, API_TYPE_RENWINDOW);
  ren_set_target_window(window);
  rencache_begin_frame(&window->cache);
  return 0;
}


static int f_end_frame(UNUSED lua_State *L) {
  RenWindow *window = ren_get_target_window();
  assert(window != NULL);
  rencache_end_frame(&window->cache);
  ren_set_target_window(NULL);
  renderer_clear_font_refs(L);
  renderer_clear_canvas_refs(L);
  return 0;
}

static int f_frame_refs_begin(lua_State *L) {
  renderer_clear_font_refs(L);
  renderer_clear_canvas_refs(L);
  return 0;
}

static int f_frame_refs_end(lua_State *L) {
  renderer_clear_font_refs(L);
  renderer_clear_canvas_refs(L);
  return 0;
}

static int f_frame_font_ref_count(lua_State *L) {
  int count = 0;
  if (RENDERER_FONT_REF != LUA_NOREF) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
    if (lua_istable(L, -1)) {
      lua_pushnil(L);
      while (lua_next(L, -2) != 0) {
        count++;
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
  }
  lua_pushinteger(L, count);
  return 1;
}

static int f_abandon_frame(lua_State *L) {
  RenWindow *window = ren_get_target_window();
  if (window) {
    rencache_abandon_frame(&window->cache);
    ren_set_target_window(NULL);
  }
  renderer_clear_font_refs(L);
  renderer_clear_canvas_refs(L);
  return 0;
}

static int f_frame_failed(lua_State *L) {
  RenWindow *window = ren_get_target_window();
  lua_pushboolean(L, window && rencache_frame_is_failed(&window->cache));
  return 1;
}


static RenRect rect_to_grid(lua_Number x, lua_Number y, lua_Number w, lua_Number h) {
  int x1 = (int) (x + 0.5), y1 = (int) (y + 0.5);
  int x2 = (int) (x + w + 0.5), y2 = (int) (y + h + 0.5);
  return (RenRect) {x1, y1, x2 - x1, y2 - y1};
}


static int f_set_clip_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  RenRect rect = rect_to_grid(x, y, w, h);
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    rencache_set_clip_rect(&window->cache, rect);
  }
  return 0;
}


static int f_draw_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  RenRect rect = rect_to_grid(x, y, w, h);
  RenColor color = luaXL_checkcolor(L, 5, 255);
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    rencache_draw_rect(&window->cache, rect, color, false);
  }
  return 0;
}

static LuaTextLayout *check_text_layout(lua_State *L, int index) {
  return (LuaTextLayout *)luaL_checkudata(L, index, API_TYPE_TEXT_LAYOUT);
}

static size_t text_layout_boundary_at_or_before(const LuaTextLayout *layout, size_t byte_offset) {
  size_t low = 0, high = layout->count;
  while (low + 1 < high) {
    size_t middle = low + (high - low) / 2;
    if (layout->byte_offsets[middle] <= byte_offset) low = middle;
    else high = middle;
  }
  return low;
}

static int f_text_layout_gc(lua_State *L) {
  LuaTextLayout *layout = check_text_layout(L, 1);
  SDL_free(layout->text);
  SDL_free(layout->byte_offsets);
  SDL_free(layout->advances);
  memset(layout, 0, sizeof(*layout));
  return 0;
}

static int f_text_layout_width(lua_State *L) {
  LuaTextLayout *layout = check_text_layout(L, 1);
  lua_pushnumber(L, layout->count ? layout->advances[layout->count - 1] : 0);
  return 1;
}

static int f_text_layout_width_at(lua_State *L) {
  LuaTextLayout *layout = check_text_layout(L, 1);
  lua_Integer raw = luaL_checkinteger(L, 2);
  size_t byte_offset = raw <= 0 ? 0 : (size_t)raw;
  if (byte_offset > layout->text_len) byte_offset = layout->text_len;
  lua_pushnumber(L, layout->advances[text_layout_boundary_at_or_before(layout, byte_offset)]);
  return 1;
}

static int f_text_layout_width_cursor_next(lua_State *L) {
  LuaTextLayout *layout = check_text_layout(L, lua_upvalueindex(1));
  lua_Integer raw = luaL_checkinteger(L, 1);
  size_t byte_offset = raw <= 0 ? 0 : (size_t)raw;
  if (byte_offset > layout->text_len) byte_offset = layout->text_len;
  size_t index = (size_t)lua_tointeger(L, lua_upvalueindex(2));
  if (index >= layout->count) index = layout->count ? layout->count - 1 : 0;
  if (layout->count > 0) {
    if (layout->byte_offsets[index] > byte_offset) {
      index = text_layout_boundary_at_or_before(layout, byte_offset);
    } else {
      while (index + 1 < layout->count
        && layout->byte_offsets[index + 1] <= byte_offset)
        index++;
    }
  }
  lua_pushinteger(L, (lua_Integer)index);
  lua_replace(L, lua_upvalueindex(2));
  lua_pushnumber(L, layout->count ? layout->advances[index] : 0);
  return 1;
}

static int f_text_layout_width_cursor(lua_State *L) {
  check_text_layout(L, 1);
  lua_pushvalue(L, 1);
  lua_pushinteger(L, 0);
  lua_pushcclosure(L, f_text_layout_width_cursor_next, 2);
  return 1;
}

static int f_text_layout_byte_at_x(lua_State *L) {
  LuaTextLayout *layout = check_text_layout(L, 1);
  double x = luaL_checknumber(L, 2);
  if (layout->count <= 1 || x <= 0) {
    lua_pushinteger(L, 0);
    return 1;
  }
  size_t low = 0, high = layout->count - 1;
  while (low + 1 < high) {
    size_t middle = low + (high - low) / 2;
    if (layout->advances[middle] < x) low = middle;
    else high = middle;
  }
  double midpoint = layout->advances[low]
    + (layout->advances[high] - layout->advances[low]) * 0.5;
  lua_pushinteger(L, (lua_Integer)layout->byte_offsets[x <= midpoint ? low : high]);
  return 1;
}

static int f_text_layout_wrap(lua_State *L) {
  LuaTextLayout *layout = check_text_layout(L, 1);
  double wrap_width = luaL_checknumber(L, 2);
  const char *mode = luaL_optstring(L, 3, "letter");
  lua_Integer raw_start = luaL_optinteger(L, 4, 0);
  double first_leading = luaL_optnumber(L, 5, 0);
  double continuation_leading = luaL_optnumber(L, 6, 0);
  size_t start_byte = raw_start <= 0 ? 0 : (size_t)raw_start;
  if (start_byte > layout->text_len) start_byte = layout->text_len;
  size_t start = text_layout_boundary_at_or_before(layout, start_byte);
  size_t row_start = start, last_space = SIZE_MAX;
  int out = 1;
  lua_createtable(L, 8, 0);
  lua_pushinteger(L, (lua_Integer)layout->byte_offsets[start]);
  lua_rawseti(L, -2, out++);
  for (size_t index = start + 1; index < layout->count; index++) {
    size_t char_start = layout->byte_offsets[index - 1];
    if (layout->text[char_start] == ' ' && layout->byte_offsets[index] == char_start + 1)
      last_space = index - 1;
    double leading = row_start == start ? first_leading : continuation_leading;
    double row_width = leading + layout->advances[index] - layout->advances[row_start];
    if (wrap_width > 0 && row_width > wrap_width && index - 1 > row_start) {
      size_t split = index - 1;
      if (strcmp(mode, "word") == 0 && last_space != SIZE_MAX && last_space >= row_start)
        split = last_space + 1;
      if (split <= row_start) split = index - 1;
      lua_pushinteger(L, (lua_Integer)layout->byte_offsets[split]);
      lua_rawseti(L, -2, out++);
      row_start = split;
      if (last_space != SIZE_MAX && last_space < row_start) last_space = SIZE_MAX;
    }
  }
  return 1;
}

static int f_font_text_layout(lua_State *L) {
  RenFont *fonts[FONT_FALLBACK_MAX]; font_retrieve(L, fonts, 1);
  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  RenTab tab = luaXL_checktab(L, 3);
  LuaTextLayout *layout = (LuaTextLayout *)lua_newuserdata(L, sizeof(*layout));
  memset(layout, 0, sizeof(*layout));
  layout->text = (char *)SDL_malloc(len + 1);
  layout->byte_offsets = (uint32_t *)SDL_malloc(sizeof(*layout->byte_offsets) * (len + 1));
  layout->advances = (double *)SDL_malloc(sizeof(*layout->advances) * (len + 1));
  if (!layout->text || !layout->byte_offsets || !layout->advances) {
    SDL_free(layout->text);
    SDL_free(layout->byte_offsets);
    SDL_free(layout->advances);
    memset(layout, 0, sizeof(*layout));
    return luaL_error(L, "out of memory creating text layout");
  }
  memcpy(layout->text, text, len);
  layout->text[len] = '\0';
  layout->text_len = len;
  layout->count = ren_font_group_get_advances(
    fonts, text, len, tab, layout->byte_offsets, layout->advances
  );
  if (layout->count > 1) {
    double shaped_width = ren_font_group_get_width(fonts, text, len, tab, NULL);
    double advance_width = layout->advances[layout->count - 1];
    if (advance_width > 0 && shaped_width != advance_width) {
      double scale = shaped_width / advance_width;
      for (size_t index = 1; index < layout->count; index++)
        layout->advances[index] *= scale;
    }
  }
  luaL_setmetatable(L, API_TYPE_TEXT_LAYOUT);
  return 1;
}


static int f_draw_rounded_rect(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);
  lua_Number radius = luaL_checknumber(L, 5);
  RenRect rect = rect_to_grid(x, y, w, h);
  RenColor color = luaXL_checkcolor(L, 6, 255);
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    rencache_draw_rounded_rect(&window->cache, rect, radius, color);
  }
  return 0;
}


static int f_draw_poly(lua_State *L) {
  static const char normal_tag[] = { POLY_NORMAL };
  static const char conic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CONIC, POLY_NORMAL };
  static const char cubic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CUBIC, POLY_CONTROL_CUBIC, POLY_NORMAL };

  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  }

  luaL_checktype(L, 1, LUA_TTABLE);
  RenColor color = luaXL_checkcolor(L, 2, 255);
  lua_settop(L, 2);

  int len = luaL_len(L, 1);
  RenPoint *points = NULL; int npoints = 0;
  for (int i = 1; i <= len; i++) {
    lua_rawgeti(L, 1, i); luaL_checktype(L, -1, LUA_TTABLE);
    const char *current_tag = NULL; int coord_len = luaL_len(L, -1);
    switch (coord_len) {
      case 2: current_tag = normal_tag;       break; // 1 curve point
      case 6: current_tag = conic_bezier_tag; break; // a conic bezier with 2 curve points and 1 control point
      case 8: current_tag = cubic_bezier_tag; break; // a cubic bezier with 2 curve points and 2 control points
      default: return luaL_error(L, "invalid number of points, expected 2, 6 and 8, got %d", coord_len);
    }
    if (npoints + coord_len / 2 > MAX_POLY_POINTS) return luaL_error(L, "too many points");
    points = SDL_realloc(points, (npoints + coord_len / 2) * sizeof(RenPoint));
    for (int lidx = 1; lidx <= coord_len; lidx += 2) {
      points[npoints].x = (lua_rawgeti(L, -1, lidx),   luaL_checknumber(L, -1));
      points[npoints].y = (lua_rawgeti(L, -2, lidx+1), luaL_checknumber(L, -1));
      points[npoints++].tag = current_tag[(lidx-1)/2];
      lua_pop(L, 2);
    }
  }
  RenRect res = rencache_draw_poly(&window->cache, points, npoints, color);
  if (points) SDL_free(points);
  lua_pushinteger(L, res.x);     lua_pushinteger(L, res.y);
  lua_pushinteger(L, res.width); lua_pushinteger(L, res.height);
  return 4;
}


static int f_draw_text(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 1);

#ifndef LUA_JITLIBNAME
  // stores a reference to this font to the reference table
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  if (lua_istable(L, -1))
  {
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  } else {
    fprintf(stderr, "warning: failed to reference count fonts\n");
  }
  lua_pop(L, 1);
#endif

  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  double x = luaL_checknumber(L, 3);
  double y = luaL_checknumber(L, 4);
  RenColor color = luaXL_checkcolor(L, 5, 255);
  RenTab tab = luaXL_checktab(L, 6);
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    x = rencache_draw_text(&window->cache, fonts, text, len, x, y, color, tab);
  }
  lua_pushnumber(L, x);
  return 1;
}

static int f_draw_text_known_bounds(lua_State *L) {
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 1);

#ifndef LUA_JITLIBNAME
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  if (lua_istable(L, -1))
  {
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  } else {
    fprintf(stderr, "warning: failed to reference count fonts\n");
  }
  lua_pop(L, 1);
#endif

  size_t len;
  const char *text = luaL_checklstring(L, 2, &len);
  double x = luaL_checknumber(L, 3);
  double y = luaL_checknumber(L, 4);
  RenRect rect = {
    luaL_checkinteger(L, 5),
    luaL_checkinteger(L, 6),
    luaL_checkinteger(L, 7),
    luaL_checkinteger(L, 8)
  };
  RenColor color = luaXL_checkcolor(L, 9, 255);
  RenTab tab = luaXL_checktab(L, 10);
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    x = rencache_draw_text_known_bounds(&window->cache, fonts, text, len, x, y, rect, color, tab);
  }
  lua_pushnumber(L, x);
  return 1;
}

static void ref_canvas(lua_State *L) {
#ifndef LUA_JITLIBNAME
  // stores a reference to this canvas to the reference table
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_CANVAS_REF);
  if (lua_istable(L, -1))
  {
    lua_pushvalue(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  } else {
    fprintf(stderr, "warning: failed to reference count canvas\n");
  }
  lua_pop(L, 1);
#else
  (void)L;
#endif
}

static int f_draw_canvas(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_checknumber(L, 2);
  lua_Number y = luaL_checknumber(L, 3);

  ref_canvas(L);

  RenRect rect = {
    .x = x, .y = y,
    .width = canvas->rensurface.surface->w,
    .height = canvas->rensurface.surface->h
  };
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    rencache_draw_canvas(&window->cache, rect, canvas);
  }
  return 0;
}

static int f_draw_canvas_scaled(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_checknumber(L, 2);
  lua_Number y = luaL_checknumber(L, 3);
  lua_Number w = luaL_checknumber(L, 4);
  lua_Number h = luaL_checknumber(L, 5);

  ref_canvas(L);

  RenRect rect = { .x = x, .y = y, .width = w, .height = h };
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    rencache_draw_canvas(&window->cache, rect, canvas);
  }
  return 0;
}

static int f_is_present_paced(lua_State *L) {
  lua_pushboolean(L, anvil_d3d11_is_present_paced());
  return 1;
}

static int f_get_last_frame_stats(lua_State *L) {
  const RenCacheFrameStats *rc_stats = rencache_get_last_frame_stats();
  const RenTextFrameStats *text_stats = ren_text_get_last_frame_stats();
  lua_createtable(L, 0, 64);
  lua_pushstring(L, anvil_d3d11_last_frame_path());
  lua_setfield(L, -2, "path");
  lua_pushinteger(L, anvil_d3d11_last_sync_interval());
  lua_setfield(L, -2, "sync_interval");
  lua_pushnumber(L, anvil_d3d11_last_present_ms());
  lua_setfield(L, -2, "present_ms");
  lua_pushinteger(L, anvil_d3d11_last_draw_calls());
  lua_setfield(L, -2, "draw_calls");
  lua_pushinteger(L, anvil_d3d11_last_quad_instances());
  lua_setfield(L, -2, "quad_instances");
  lua_pushinteger(L, anvil_d3d11_last_texture_quads());
  lua_setfield(L, -2, "texture_quads");
  lua_pushinteger(L, anvil_d3d11_last_texture_uploads());
  lua_setfield(L, -2, "texture_uploads");
  lua_pushinteger(L, (lua_Integer)anvil_d3d11_last_texture_upload_bytes());
  lua_setfield(L, -2, "texture_upload_bytes");
  lua_pushnumber(L, anvil_d3d11_last_glyph_push_ms());
  lua_setfield(L, -2, "d3d11_glyph_push_ms");
  lua_pushnumber(L, anvil_d3d11_last_flush_quads_ms());
  lua_setfield(L, -2, "d3d11_flush_quads_ms");
  lua_pushnumber(L, anvil_d3d11_last_dwm_flush_ms());
  lua_setfield(L, -2, "d3d11_dwm_flush_ms");
  lua_pushnumber(L, anvil_d3d11_last_clear_state_ms());
  lua_setfield(L, -2, "d3d11_clear_state_ms");
  lua_pushinteger(L, rc_stats ? rc_stats->commands : 0);
  lua_setfield(L, -2, "rencache_commands");
  lua_pushinteger(L, rc_stats ? rc_stats->text_commands : 0);
  lua_setfield(L, -2, "rencache_text_commands");
  lua_pushinteger(L, rc_stats ? rc_stats->rect_commands : 0);
  lua_setfield(L, -2, "rencache_rect_commands");
  lua_pushinteger(L, rc_stats ? rc_stats->set_clip_commands : 0);
  lua_setfield(L, -2, "rencache_set_clip_commands");
  lua_pushinteger(L, rc_stats ? (lua_Integer)rc_stats->command_bytes : 0);
  lua_setfield(L, -2, "rencache_command_bytes");
  lua_pushinteger(L, rc_stats ? (lua_Integer)rc_stats->text_bytes : 0);
  lua_setfield(L, -2, "rencache_text_bytes");
  lua_pushinteger(L, rc_stats ? (lua_Integer)rc_stats->max_text_bytes : 0);
  lua_setfield(L, -2, "rencache_max_text_bytes");
  lua_pushnumber(L, rc_stats ? rc_stats->draw_text_ms : 0.0);
  lua_setfield(L, -2, "rencache_draw_text_ms");
  lua_pushnumber(L, rc_stats ? rc_stats->draw_text_width_ms : 0.0);
  lua_setfield(L, -2, "rencache_draw_text_width_ms");
  lua_pushinteger(L, rc_stats ? rc_stats->display_packet_replays : 0);
  lua_setfield(L, -2, "display_packet_replays");
  lua_pushinteger(L, rc_stats ? rc_stats->display_packet_commands_replayed : 0);
  lua_setfield(L, -2, "display_packet_commands_replayed");
  lua_pushinteger(L, rc_stats ? rc_stats->display_packet_text_commands_replayed : 0);
  lua_setfield(L, -2, "display_packet_text_commands_replayed");
  lua_pushinteger(L, rc_stats ? rc_stats->display_packet_rect_commands_replayed : 0);
  lua_setfield(L, -2, "display_packet_rect_commands_replayed");
  lua_pushinteger(L, rc_stats ? (lua_Integer)rc_stats->display_packet_source_bytes : 0);
  lua_setfield(L, -2, "display_packet_source_bytes");
  lua_pushinteger(L, rc_stats ? (lua_Integer)rc_stats->display_packet_frame_bytes_copied : 0);
  lua_setfield(L, -2, "display_packet_frame_bytes_copied");
  lua_pushnumber(L, rc_stats ? rc_stats->display_packet_replay_ms : 0.0);
  lua_setfield(L, -2, "display_packet_replay_ms");
  lua_pushinteger(L, rc_stats ? rc_stats->display_packet_frame_allocation_failures : 0);
  lua_setfield(L, -2, "display_packet_frame_allocation_failures");
  lua_pushboolean(L, rc_stats ? rc_stats->rencache_frame_failed : false);
  lua_setfield(L, -2, "rencache_frame_failed");
#define PUSH_TEXT_STAT_INTEGER(name) \
  lua_pushinteger(L, text_stats ? (lua_Integer)text_stats->name : 0); \
  lua_setfield(L, -2, "text_" #name)
#define PUSH_TEXT_STAT_NUMBER(name) \
  lua_pushnumber(L, text_stats ? text_stats->name : 0.0); \
  lua_setfield(L, -2, "text_" #name)
  PUSH_TEXT_STAT_INTEGER(width_calls);
  PUSH_TEXT_STAT_INTEGER(width_bytes);
  PUSH_TEXT_STAT_INTEGER(width_chars);
  PUSH_TEXT_STAT_INTEGER(width_shaped_runs);
  PUSH_TEXT_STAT_INTEGER(width_unshaped_runs);
  PUSH_TEXT_STAT_INTEGER(width_shape_probe_bytes);
  PUSH_TEXT_STAT_INTEGER(width_hb_shapes);
  PUSH_TEXT_STAT_INTEGER(width_shaped_cache_hits);
  PUSH_TEXT_STAT_INTEGER(width_shaped_cache_misses);
  PUSH_TEXT_STAT_NUMBER(width_hb_shape_ms);
  PUSH_TEXT_STAT_INTEGER(render_calls);
  PUSH_TEXT_STAT_INTEGER(render_bytes);
  PUSH_TEXT_STAT_INTEGER(render_chars);
  PUSH_TEXT_STAT_INTEGER(render_shaped_runs);
  PUSH_TEXT_STAT_INTEGER(render_unshaped_runs);
  PUSH_TEXT_STAT_INTEGER(render_shape_probe_bytes);
  PUSH_TEXT_STAT_INTEGER(render_hb_shapes);
  PUSH_TEXT_STAT_INTEGER(render_shaped_cache_hits);
  PUSH_TEXT_STAT_INTEGER(render_shaped_cache_misses);
  PUSH_TEXT_STAT_INTEGER(render_glyphs);
  PUSH_TEXT_STAT_INTEGER(render_whitespace_chars);
  PUSH_TEXT_STAT_INTEGER(render_chars_after_clip);
  PUSH_TEXT_STAT_INTEGER(render_top_clip_breaks);
  PUSH_TEXT_STAT_NUMBER(render_hb_shape_ms);
#undef PUSH_TEXT_STAT_INTEGER
#undef PUSH_TEXT_STAT_NUMBER
  return 1;
}

static int f_to_canvas(lua_State *L) {
  lua_Number x = luaL_checknumber(L, 1);
  lua_Number y = luaL_checknumber(L, 2);
  lua_Number w = luaL_checknumber(L, 3);
  lua_Number h = luaL_checknumber(L, 4);

  // TODO: this is duplicated code from canvas.f_new, maybe add this to the utils?
  SDL_Surface *dst = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
  RenSurface rs;
  RenWindow *window = ren_get_target_window();
  if (!window) {
    return luaL_error(L, "no target window found");
  } else {
    rs = rencache_get_surface(&window->cache);
  }
  SDL_Rect rect = { .x = x, .y = y, .w = w, .h = h };
  SDL_BlitSurface(rs.surface, &rect, dst, NULL);

  RenCache *canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(canvas);
  canvas->rensurface = rs;
  canvas->rensurface.surface = dst;
  rencache_begin_frame(canvas);

  return 1;
}

static LuaDisplayPacket *check_display_packet(lua_State *L, int index) {
  LuaDisplayPacket *userdata = (LuaDisplayPacket *)luaL_checkudata(
    L, index, API_TYPE_DISPLAY_PACKET
  );
  if (!userdata->packet) luaL_error(L, "Display Packet has been collected");
  return userdata;
}

static float current_surface_scale(void) {
#ifdef ANVIL_USE_SDL_RENDERER
  RenWindow *window = ren_get_target_window();
  if (window) {
    float scale = rencache_get_surface(&window->cache).scale_x;
    return scale > 0 ? scale : 1.0f;
  }
#endif
  return 1.0f;
}

static void clear_display_packet_refs(lua_State *L, LuaDisplayPacket *userdata) {
  if (userdata->font_refs == LUA_NOREF) return;
  luaL_unref(L, LUA_REGISTRYINDEX, userdata->font_refs);
  userdata->font_refs = LUA_NOREF;
}

static void retain_display_packet_fonts(
  lua_State *L, LuaDisplayPacket *userdata, int font_index
) {
  font_index = lua_absindex(L, font_index);
  lua_rawgeti(L, LUA_REGISTRYINDEX, userdata->font_refs);
  int refs = lua_gettop(L);
  if (!lua_istable(L, refs)) luaL_error(L, "Display Packet Font references are unavailable");

  if (lua_istable(L, font_index)) {
    size_t count = lua_rawlen(L, font_index);
    if (count > FONT_FALLBACK_MAX) count = FONT_FALLBACK_MAX;
    for (size_t index = 1; index <= count; index++) {
      lua_rawgeti(L, font_index, (lua_Integer)index);
      luaL_checkudata(L, -1, API_TYPE_FONT);
      lua_pushvalue(L, -1);
      lua_pushboolean(L, true);
      lua_rawset(L, refs);
      lua_pop(L, 1);
    }
  } else {
    luaL_checkudata(L, font_index, API_TYPE_FONT);
    lua_pushvalue(L, font_index);
    lua_pushboolean(L, true);
    lua_rawset(L, refs);
  }
  lua_pop(L, 1);
}

static void pin_display_packet_fonts(lua_State *L, int packet_index) {
  if (RENDERER_FONT_REF == LUA_NOREF) return;
  LuaDisplayPacket *userdata = check_display_packet(L, packet_index);
  lua_rawgeti(L, LUA_REGISTRYINDEX, RENDERER_FONT_REF);
  int active_refs = lua_gettop(L);
  if (!lua_istable(L, active_refs)) {
    lua_pop(L, 1);
    return;
  }
  lua_rawgeti(L, LUA_REGISTRYINDEX, userdata->font_refs);
  int packet_refs = lua_gettop(L);
  if (!lua_istable(L, packet_refs)) {
    lua_pop(L, 2);
    return;
  }
  lua_pushnil(L);
  while (lua_next(L, packet_refs) != 0) {
    lua_pop(L, 1);
    lua_pushvalue(L, -1);
    lua_pushboolean(L, true);
    lua_rawset(L, active_refs);
  }
  lua_pop(L, 2);
}

static int f_display_packet_new(lua_State *L) {
  LuaDisplayPacket *userdata = (LuaDisplayPacket *)lua_newuserdata(
    L, sizeof(*userdata)
  );
  userdata->packet = ren_display_packet_new();
  userdata->font_refs = LUA_NOREF;
  if (!userdata->packet) return luaL_error(L, "out of memory creating Display Packet");
  luaL_setmetatable(L, API_TYPE_DISPLAY_PACKET);
  lua_newtable(L);
  userdata->font_refs = luaL_ref(L, LUA_REGISTRYINDEX);
  return 1;
}

static int f_display_packet_test_fail_next_reserve(lua_State *L) {
  (void)L;
  rencache_test_fail_next_packet_reserve();
  return 0;
}

static void check_packet_builder_state(lua_State *L, LuaDisplayPacket *userdata) {
  if (ren_display_packet_is_released(userdata->packet))
    luaL_error(L, "cannot mutate a released Display Packet");
  if (ren_display_packet_is_sealed(userdata->packet))
    luaL_error(L, "cannot mutate a sealed Display Packet");
}

static int check_packet_layer(lua_State *L, int index) {
  lua_Integer value = luaL_checkinteger(L, index);
  if (value < 0 || value > INT_MAX) luaL_argerror(L, index, "invalid layer");
  return (int)value;
}

static int check_packet_row(lua_State *L, int index) {
  lua_Integer value = luaL_checkinteger(L, index);
  if (value < 1 || value > INT_MAX) luaL_argerror(L, index, "invalid visual row");
  return (int)value;
}

static double check_finite_number(lua_State *L, int index) {
  double value = luaL_checknumber(L, index);
  if (!isfinite(value)) luaL_argerror(L, index, "number must be finite");
  return value;
}

static int f_display_packet_add_text(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  check_packet_builder_state(L, userdata);
  int layer = check_packet_layer(L, 2);
  int row = check_packet_row(L, 3);
  RenFont *fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 4);
  size_t text_len;
  const char *text = luaL_checklstring(L, 5, &text_len);
  double x = check_finite_number(L, 6);
  double y = check_finite_number(L, 7);
  RenColor color = luaXL_checkcolor(L, 8, 255);
  RenTab tab = { .offset = NAN };
  if (!lua_isnoneornil(L, 9)) tab.offset = check_finite_number(L, 9);
  lua_Integer raw_tab_size = luaL_checkinteger(L, 10);
  if (raw_tab_size <= 0 || raw_tab_size > INT8_MAX)
    return luaL_argerror(L, 10, "tab size must be between 1 and 127");

  double next_x = x;
  RenDisplayPacketResult result = ren_display_packet_add_text(
    userdata->packet, layer, row, fonts, text, text_len, x, y, color, tab,
    (int)raw_tab_size, current_surface_scale(), &next_x
  );
  if (result != REN_DISPLAY_PACKET_OK) {
    return luaL_error(
      L, "failed to add Display Packet text: %s",
      ren_display_packet_result_string(result)
    );
  }
  retain_display_packet_fonts(L, userdata, 4);
  lua_pushnumber(L, next_x);
  return 1;
}

static int f_display_packet_add_rect(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  check_packet_builder_state(L, userdata);
  RenDisplayPacketResult result = ren_display_packet_add_rect(
    userdata->packet,
    check_packet_layer(L, 2),
    check_packet_row(L, 3),
    check_finite_number(L, 4),
    check_finite_number(L, 5),
    check_finite_number(L, 6),
    check_finite_number(L, 7),
    luaXL_checkcolor(L, 8, 255)
  );
  if (result != REN_DISPLAY_PACKET_OK) {
    return luaL_error(
      L, "failed to add Display Packet rectangle: %s",
      ren_display_packet_result_string(result)
    );
  }
  return 0;
}

static int f_display_packet_add_rect_grid(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  check_packet_builder_state(L, userdata);
  lua_Integer raw_count = luaL_checkinteger(L, 9);
  if (raw_count <= 0 || raw_count > INT_MAX)
    return luaL_argerror(L, 9, "invalid rectangle-grid count");
  RenDisplayPacketResult result = ren_display_packet_add_rect_grid(
    userdata->packet,
    check_packet_layer(L, 2),
    check_packet_row(L, 3),
    check_finite_number(L, 4),
    check_finite_number(L, 5),
    check_finite_number(L, 6),
    check_finite_number(L, 7),
    check_finite_number(L, 8),
    (int)raw_count,
    luaXL_checkcolor(L, 10, 255)
  );
  if (result != REN_DISPLAY_PACKET_OK) {
    return luaL_error(
      L, "failed to add Display Packet rectangle grid: %s",
      ren_display_packet_result_string(result)
    );
  }
  return 0;
}

static int f_display_packet_seal(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  if (!ren_display_packet_seal(userdata->packet))
    return luaL_error(L, "cannot seal a released Display Packet");
  lua_settop(L, 1);
  return 1;
}

static int f_display_packet_bytes(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  lua_pushinteger(L, (lua_Integer)ren_display_packet_bytes(userdata->packet));
  return 1;
}

static void push_color(lua_State *L, RenColor color) {
  lua_createtable(L, 4, 0);
  lua_pushinteger(L, color.r); lua_rawseti(L, -2, 1);
  lua_pushinteger(L, color.g); lua_rawseti(L, -2, 2);
  lua_pushinteger(L, color.b); lua_rawseti(L, -2, 3);
  lua_pushinteger(L, color.a); lua_rawseti(L, -2, 4);
}

static int f_display_packet_inspect(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  size_t count = ren_display_packet_command_count(userdata->packet);
  lua_createtable(L, (int)(count > INT_MAX ? INT_MAX : count), 0);
  for (size_t index = 0; index < count; index++) {
    RenDisplayPacketCommandInfo info;
    if (!ren_display_packet_command_info(userdata->packet, index, &info)) continue;
    lua_createtable(L, 0, 20);
    const char *type = info.type == REN_DISPLAY_PACKET_TEXT ? "text"
      : info.type == REN_DISPLAY_PACKET_RECT ? "rect" : "rect_grid";
    lua_pushstring(L, type); lua_setfield(L, -2, "type");
    lua_pushinteger(L, info.layer); lua_setfield(L, -2, "layer");
    lua_pushinteger(L, info.row); lua_setfield(L, -2, "row");
    lua_pushnumber(L, info.x); lua_setfield(L, -2, "x");
    lua_pushnumber(L, info.y); lua_setfield(L, -2, "y");
    lua_pushnumber(L, info.width); lua_setfield(L, -2, "width");
    lua_pushnumber(L, info.height); lua_setfield(L, -2, "height");
    push_color(L, info.color); lua_setfield(L, -2, "color");
    if (info.type == REN_DISPLAY_PACKET_TEXT) {
      lua_pushlstring(L, info.text, info.text_len); lua_setfield(L, -2, "text");
      lua_pushnumber(L, info.bounds_x); lua_setfield(L, -2, "bounds_x");
      lua_pushnumber(L, info.bounds_y); lua_setfield(L, -2, "bounds_y");
      lua_pushnumber(L, info.bounds_width); lua_setfield(L, -2, "bounds_width");
      lua_pushnumber(L, info.bounds_height); lua_setfield(L, -2, "bounds_height");
      lua_pushnumber(L, info.tab.offset); lua_setfield(L, -2, "tab_offset");
      lua_pushinteger(L, info.tab_size); lua_setfield(L, -2, "tab_size");
      lua_pushinteger(L, (lua_Integer)info.font_count);
      lua_setfield(L, -2, "font_count");
    } else if (info.type == REN_DISPLAY_PACKET_RECT_GRID) {
      lua_pushnumber(L, info.step_x); lua_setfield(L, -2, "step_x");
      lua_pushinteger(L, info.count); lua_setfield(L, -2, "count");
    }
    lua_rawseti(L, -2, (lua_Integer)index + 1);
  }
  return 1;
}

static int f_display_packet_draw(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  double origin_x = check_finite_number(L, 2);
  double origin_y = check_finite_number(L, 3);
  int layer = check_packet_layer(L, 4);
  int first_row = check_packet_row(L, 5);
  int last_row = check_packet_row(L, 6);
  if (last_row < first_row)
    return luaL_argerror(L, 6, "last visual row precedes first visual row");
  if (ren_display_packet_is_released(userdata->packet)) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "released");
    return 2;
  }
  if (!ren_display_packet_is_sealed(userdata->packet)) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "not_sealed");
    return 2;
  }
  RenWindow *window = ren_get_target_window();
  if (!window) {
    lua_pushboolean(L, false);
    lua_pushliteral(L, "no_target");
    return 2;
  }
  RenDisplayPacketResult result = ren_display_packet_replay(
    userdata->packet, &window->cache, origin_x, origin_y, layer,
    first_row, last_row, current_surface_scale()
  );
  if (result == REN_DISPLAY_PACKET_OK) {
    pin_display_packet_fonts(L, 1);
    lua_pushboolean(L, true);
    return 1;
  }
  lua_pushboolean(L, false);
  lua_pushstring(L, ren_display_packet_result_string(result));
  return 2;
}

static int f_display_packet_release(lua_State *L) {
  LuaDisplayPacket *userdata = check_display_packet(L, 1);
  ren_display_packet_free(userdata->packet);
  clear_display_packet_refs(L, userdata);
  return 0;
}

static int f_display_packet_gc(lua_State *L) {
  LuaDisplayPacket *userdata = (LuaDisplayPacket *)luaL_checkudata(
    L, 1, API_TYPE_DISPLAY_PACKET
  );
  clear_display_packet_refs(L, userdata);
  ren_display_packet_destroy(userdata->packet);
  userdata->packet = NULL;
  return 0;
}

static const luaL_Reg lib[] = {
  { "show_debug",         f_show_debug         },
  { "get_size",           f_get_size           },
  { "begin_frame",        f_begin_frame        },
  { "end_frame",          f_end_frame          },
  { "abandon_frame",      f_abandon_frame      },
  { "frame_failed",       f_frame_failed       },
  { "_frame_refs_begin",  f_frame_refs_begin   },
  { "_frame_refs_end",    f_frame_refs_end     },
  { "_frame_font_ref_count", f_frame_font_ref_count },
  { "is_present_paced",   f_is_present_paced   },
  { "get_last_frame_stats", f_get_last_frame_stats },
  { "set_clip_rect",      f_set_clip_rect      },
  { "draw_rect",          f_draw_rect          },
  { "draw_rounded_rect",  f_draw_rounded_rect  },
  { "draw_text",          f_draw_text          },
  { "draw_text_known_bounds", f_draw_text_known_bounds },
  { "draw_poly",          f_draw_poly          },
  { "draw_canvas",        f_draw_canvas        },
  { "draw_canvas_scaled", f_draw_canvas_scaled },
  { "to_canvas",          f_to_canvas          },
  { NULL,                 NULL                 }
};

static const luaL_Reg fontLib[] = {
  { "__gc",               f_font_gc                 },
  { "load",               f_font_load               },
  { "copy",               f_font_copy               },
  { "group",              f_font_group              },
  { "set_tab_size",       f_font_set_tab_size       },
  { "get_width",          f_font_get_width          },
  { "text_layout",        f_font_text_layout        },
  { "get_height",         f_font_get_height         },
  { "get_size",           f_font_get_size           },
  { "get_generation",     f_font_get_generation     },
  { "get_surface_scale",  f_font_get_surface_scale  },
  { "set_size",           f_font_set_size           },
  { "get_path",           f_font_get_path           },
  { "get_metadata",       f_font_get_metadata       },
  { NULL, NULL }
};

static const luaL_Reg textLayoutLib[] = {
  { "__gc",      f_text_layout_gc        },
  { "width",     f_text_layout_width     },
  { "width_at",  f_text_layout_width_at  },
  { "width_cursor", f_text_layout_width_cursor },
  { "byte_at_x", f_text_layout_byte_at_x },
  { "wrap",      f_text_layout_wrap      },
  { NULL, NULL }
};

static const luaL_Reg displayPacketLib[] = {
  { "__gc",          f_display_packet_gc            },
  { "add_text",      f_display_packet_add_text      },
  { "add_rect",      f_display_packet_add_rect      },
  { "add_rect_grid", f_display_packet_add_rect_grid },
  { "seal",          f_display_packet_seal          },
  { "bytes",         f_display_packet_bytes         },
  { "inspect",       f_display_packet_inspect       },
  { "draw",          f_display_packet_draw          },
  { "release",       f_display_packet_release       },
  { NULL, NULL }
};

int luaopen_renderer(lua_State *L) {
  // gets a reference on the registry to store font data
  lua_newtable(L);
  RENDERER_FONT_REF = luaL_ref(L, LUA_REGISTRYINDEX);

  // gets a reference on the registry to store canvas data
  lua_newtable(L);
  RENDERER_CANVAS_REF = luaL_ref(L, LUA_REGISTRYINDEX);

  luaL_newlib(L, lib);
  luaL_newmetatable(L, API_TYPE_FONT);
  luaL_setfuncs(L, fontLib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_setfield(L, -2, "font");
  luaL_newmetatable(L, API_TYPE_TEXT_LAYOUT);
  luaL_setfuncs(L, textLayoutLib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newmetatable(L, API_TYPE_DISPLAY_PACKET);
  luaL_setfuncs(L, displayPacketLib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  lua_createtable(L, 0, 4);
  lua_pushcfunction(L, f_display_packet_new);
  lua_setfield(L, -2, "new");
  lua_pushcfunction(L, f_display_packet_test_fail_next_reserve);
  lua_setfield(L, -2, "_test_fail_next_reserve");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "CONTENT");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "FOREGROUND_GUIDES");
  lua_setfield(L, -2, "display_packet");
  return 1;
}
