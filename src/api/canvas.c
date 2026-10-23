#include <lauxlib.h>
#include <lua.h>
#include <string.h>
#include <math.h>
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <assert.h>

#include "api.h"
#include "utils/lxlauxlib.h"
#include "../renderer.h"
#include "../rencache.h"
#include "../d3d11_backend.h"

extern int RENDERER_FONT_REF;
extern int RENDERER_CANVAS_REF;

static int f_new(lua_State *L) {
  lua_Number w = luaL_checknumber(L, 1);
  lua_Number h = luaL_checknumber(L, 2);
  RenColor color = luaXL_checkcolor(L, 3, 0);
  bool transparency = luaXL_optboolean(L, 4, true);

  SDL_Surface *surface = SDL_CreateSurface(
    w, h, transparency ? SDL_PIXELFORMAT_RGBA32 : SDL_PIXELFORMAT_RGB24
  );
  SDL_FillSurfaceRect(
    surface,
    NULL,
    SDL_MapSurfaceRGBA(surface, color.r, color.g, color.b, color.a)
  );

  RenCache *canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(canvas);
  canvas->rensurface.surface = surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
  rencache_begin_frame(canvas);

  return 1;
}


int api_canvas_push_image(lua_State *L, SDL_Surface *surface) {
  if (!surface) goto error;

  if (surface->format != SDL_PIXELFORMAT_RGBA32) {
    SDL_Surface *new = SDL_ConvertSurface(surface, SDL_PIXELFORMAT_RGBA32);
    SDL_DestroySurface(surface);
    if (!new) goto error;
    surface = new;
  }

  RenCache *canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(canvas);
  canvas->rensurface.surface = surface;
  canvas->rensurface.scale_x = 1;
  canvas->rensurface.scale_y = 1;
  rencache_begin_frame(canvas);
  return 1;

error:
  lua_pushnil(L);
  lua_pushstring(L, SDL_GetError());
  return 2;
}


static int f_load_image(lua_State *L) {
  const char *file = luaL_checkstring(L, 1);
  return api_canvas_push_image(L, IMG_Load(file));
}


static int f_load_image_data(lua_State *L) {
  size_t size;
  const char *data = luaL_checklstring(L, 1, &size);
  if (size == 0) {
    SDL_SetError("image data is empty");
    return api_canvas_push_image(L, NULL);
  }

  SDL_IOStream *stream = SDL_IOFromConstMem(data, size);
  if (!stream) return api_canvas_push_image(L, NULL);
  return api_canvas_push_image(L, IMG_Load_IO(stream, true));
}


static int f_load_svg_image(lua_State *L) {
  size_t len;
  const char *path = luaL_checklstring(L, 1, &len);
  const int w = luaL_checkinteger(L, 2);
  const int h = luaL_checkinteger(L, 3);
  SDL_IOStream *file = SDL_IOFromFile(path, "r");
  SDL_Surface *surface = IMG_LoadSizedSVG_IO(file, w, h);
  SDL_CloseIO(file);
  return api_canvas_push_image(L, surface);
}


/*
** An Animation streams frames from an IMG_AnimationDecoder into one canvas.
** Memory stays at one frame however long the animation is: each step decodes
** the next frame into the same surface, and the end of the stream rewinds.
*/
typedef struct {
  IMG_AnimationDecoder *decoder;
  void *data;          /* owned copy of in-memory image data, or NULL */
  RenCache *canvas;    /* the canvas userdata referenced by canvas_ref */
  int canvas_ref;
  int frame_index;     /* zero-based index of the frame in the canvas */
  int frame_count;     /* 0 until the stream has ended once */
  lua_Integer duration_ms;
} Animation;


static void animation_close(Animation *anim) {
  if (anim->decoder) {
    IMG_CloseAnimationDecoder(anim->decoder);
    anim->decoder = NULL;
  }
  if (anim->data) {
    SDL_free(anim->data);
    anim->data = NULL;
  }
}


static bool animation_decode_into(Animation *anim, SDL_Surface *dst) {
  SDL_Surface *frame = NULL;
  Uint64 duration = 0;
  if (!IMG_GetAnimationDecoderFrame(anim->decoder, &frame, &duration)) return false;
  bool ok = true;
  if (frame->w == dst->w && frame->h == dst->h) {
    SDL_SetSurfaceBlendMode(frame, SDL_BLENDMODE_NONE);
    ok = SDL_BlitSurface(frame, NULL, dst, NULL);
  } else {
    SDL_FillSurfaceRect(dst, NULL, 0);
    SDL_SetSurfaceBlendMode(frame, SDL_BLENDMODE_NONE);
    ok = SDL_BlitSurfaceScaled(frame, NULL, dst, NULL, SDL_SCALEMODE_LINEAR);
  }
  SDL_DestroySurface(frame);
  anim->duration_ms = (lua_Integer) duration;
  return ok;
}


static void animation_mark_changed(Animation *anim) {
  SDL_PropertiesID props = SDL_GetSurfaceProperties(anim->canvas->rensurface.surface);
  SDL_SetNumberProperty(props, "anvil_d3d11_generation",
                        SDL_GetNumberProperty(props, "anvil_d3d11_generation", 0) + 1);
  anvil_d3d11_note_surface_generation();
  anim->canvas->content_version++;
}


static int push_animation(lua_State *L, IMG_AnimationDecoder *decoder, void *data) {
  if (!decoder) {
    SDL_free(data);
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  Animation *anim = lua_newuserdata(L, sizeof(Animation));
  memset(anim, 0, sizeof(Animation));
  anim->decoder = decoder;
  anim->data = data;
  anim->canvas_ref = LUA_NOREF;
  luaL_setmetatable(L, API_TYPE_ANIMATION);

  SDL_Surface *first = NULL;
  Uint64 duration = 0;
  if (!IMG_GetAnimationDecoderFrame(decoder, &first, &duration)) {
    const char *err = SDL_GetError();
    animation_close(anim);
    lua_pushnil(L);
    lua_pushstring(L, err && *err ? err : "animation has no frames");
    return 2;
  }
  anim->duration_ms = (lua_Integer) duration;

  /* api_canvas_push_image takes ownership of the first frame and leaves the canvas on
  ** the stack. Later frames are copied into this same surface. */
  if (api_canvas_push_image(L, first) != 1) {
    animation_close(anim);
    return 2;
  }
  anim->canvas = lua_touserdata(L, -1);
  anim->canvas_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  return 1;
}


static int f_open_animation(lua_State *L) {
  const char *file = luaL_checkstring(L, 1);
  const char *type = luaL_optstring(L, 2, NULL);
  if (!type) return push_animation(L, IMG_CreateAnimationDecoder(file), NULL);
  /* A type overrides the extension, e.g. for a cached download named *.img. */
  SDL_IOStream *stream = SDL_IOFromFile(file, "rb");
  if (!stream) return push_animation(L, NULL, NULL);
  return push_animation(L, IMG_CreateAnimationDecoder_IO(stream, true, type), NULL);
}


static int f_open_animation_data(lua_State *L) {
  size_t size;
  const char *data = luaL_checklstring(L, 1, &size);
  const char *type = luaL_checkstring(L, 2);
  if (size == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "image data is empty");
    return 2;
  }
  /* The decoder reads lazily, so it needs its own copy of the data. */
  void *copy = SDL_malloc(size);
  if (!copy) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  memcpy(copy, data, size);
  SDL_IOStream *stream = SDL_IOFromConstMem(copy, size);
  if (!stream) return push_animation(L, NULL, copy);
  return push_animation(L, IMG_CreateAnimationDecoder_IO(stream, true, type), copy);
}


static Animation *check_open_animation(lua_State *L) {
  Animation *anim = luaL_checkudata(L, 1, API_TYPE_ANIMATION);
  if (!anim->decoder) luaL_error(L, "animation is closed");
  return anim;
}


static int f_animation_get_canvas(lua_State *L) {
  Animation *anim = luaL_checkudata(L, 1, API_TYPE_ANIMATION);
  if (anim->canvas_ref == LUA_NOREF) return 0;
  lua_rawgeti(L, LUA_REGISTRYINDEX, anim->canvas_ref);
  return 1;
}


static int f_animation_get_frame_duration(lua_State *L) {
  Animation *anim = luaL_checkudata(L, 1, API_TYPE_ANIMATION);
  lua_pushinteger(L, anim->duration_ms);
  return 1;
}


/*
** Decodes the next frame into the canvas and returns its duration in
** milliseconds. After the last frame it rewinds to the first one. Returns
** false for an animation with one frame, and nil plus an error on failure.
*/
static int f_animation_next_frame(lua_State *L) {
  Animation *anim = check_open_animation(L);
  if (anim->frame_count == 1) {
    lua_pushboolean(L, false);
    return 1;
  }
  SDL_Surface *dst = anim->canvas->rensurface.surface;
  if (animation_decode_into(anim, dst)) {
    anim->frame_index++;
    animation_mark_changed(anim);
    lua_pushinteger(L, anim->duration_ms);
    return 1;
  }
  if (IMG_GetAnimationDecoderStatus(anim->decoder) != IMG_DECODER_STATUS_COMPLETE) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  anim->frame_count = anim->frame_index + 1;
  if (anim->frame_count == 1) {
    lua_pushboolean(L, false);
    return 1;
  }
  if (!IMG_ResetAnimationDecoder(anim->decoder) || !animation_decode_into(anim, dst)) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  anim->frame_index = 0;
  animation_mark_changed(anim);
  lua_pushinteger(L, anim->duration_ms);
  return 1;
}


static int f_animation_close(lua_State *L) {
  Animation *anim = luaL_checkudata(L, 1, API_TYPE_ANIMATION);
  animation_close(anim);
  return 0;
}


static int f_animation_gc(lua_State *L) {
  Animation *anim = luaL_checkudata(L, 1, API_TYPE_ANIMATION);
  animation_close(anim);
  if (anim->canvas_ref != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, anim->canvas_ref);
    anim->canvas_ref = LUA_NOREF;
    anim->canvas = NULL;
  }
  return 0;
}


static int f_get_size(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_pushinteger(L, canvas->rensurface.surface->w);
  lua_pushinteger(L, canvas->rensurface.surface->h);
  return 2;
}


static int f_get_pixels(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  lua_Integer x = luaL_optinteger(L, 2, 0);
  lua_Integer y = luaL_optinteger(L, 3, 0);
  lua_Integer w = luaL_optinteger(L, 4, canvas->rensurface.surface->w);
  lua_Integer h = luaL_optinteger(L, 5, canvas->rensurface.surface->h);

  SDL_Surface *dst = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
  SDL_Rect rect = { .x = x, .y = y, .w = w, .h = h };
  SDL_BlitSurface(canvas->rensurface.surface, &rect, dst, NULL);

  const SDL_PixelFormatDetails *details = SDL_GetPixelFormatDetails(SDL_PIXELFORMAT_RGBA32);
  lua_pushlstring(L, dst->pixels, details->bytes_per_pixel * w * h);

  SDL_DestroySurface(dst);
  return 1;
}


static int f_set_pixels(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  size_t len;
  const char *bytes = luaL_checklstring(L, 2, &len);

  lua_Integer x = luaL_checkinteger(L, 3);
  lua_Integer y = luaL_checkinteger(L, 4);
  lua_Integer w = luaL_checkinteger(L, 5);
  lua_Integer h = luaL_checkinteger(L, 6);
  luaL_argcheck(L, w > 0, 5, "must be a positive non-zero integer");
  luaL_argcheck(L, h > 0, 6, "must be a positive non-zero integer");
  RenRect rect = { .x = x, .y = y, .width = w, .height = h };

  rencache_draw_pixels(canvas, rect, bytes, len);
  return 0;
}


static int f_copy(lua_State *L) {
  // TODO: should we make this COW, so when the copy or the original get changed, we make the actual copy
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_optnumber(L, 2, 0);
  lua_Number y = luaL_optnumber(L, 3, 0);
  lua_Number w = luaL_optnumber(L, 4, canvas->rensurface.surface->w);
  lua_Number h = luaL_optnumber(L, 5, canvas->rensurface.surface->h);
  lua_Number new_w = luaL_optnumber(L, 6, w);
  lua_Number new_h = luaL_optnumber(L, 7, h);
  const char *mode_str = luaL_optstring(L, 8, "linear");
  SDL_ScaleMode mode = SDL_SCALEMODE_INVALID;
  if (strcmp(mode_str, "nearest") == 0) {
    mode = SDL_SCALEMODE_NEAREST;
  } else if (strcmp(mode_str, "linear") == 0) {
    mode = SDL_SCALEMODE_LINEAR;
  }
  #if 0 // SDL_SCALEMODE_PIXELART doesn't seem to be actually available (as of SDL 3.2.20)
  else if (strcmp(mode_str, "pixelart") == 0) {
    mode = SDL_SCALEMODE_PIXELART;
  }
  #endif

  RenCache *new_canvas = lua_newuserdata(L, sizeof(RenCache));
  luaL_setmetatable(L, API_TYPE_CANVAS);
  rencache_init(new_canvas);

  bool full_surface = (
    x == 0 && y == 0
    &&
    w == canvas->rensurface.surface->w
    &&
    h == canvas->rensurface.surface->h
  );
  bool scaled = (new_w != w || new_h != h);
  SDL_Surface *surface_copy;
  if (full_surface && !scaled) {
    surface_copy = SDL_DuplicateSurface(canvas->rensurface.surface);
    // DuplicateSurface copies the clip rect, so we reset it
    SDL_SetSurfaceClipRect(surface_copy, NULL);
  } else if (full_surface) {
    surface_copy = SDL_ScaleSurface(canvas->rensurface.surface, new_w, new_h, mode);
  } else {
    surface_copy = SDL_CreateSurface(new_w, new_h, canvas->rensurface.surface->format);
    SDL_Rect src_rect = {.x = x, .y = y, .w = w, .h = h};
    SDL_BlitSurfaceScaled(canvas->rensurface.surface, &src_rect, surface_copy, NULL, mode);
  }

  if(!surface_copy) {
    lua_pushnil(L);
    lua_pushfstring(L, "Error creating new canvas: %s", SDL_GetError());
    return 2;
  }

  new_canvas->rensurface.surface = surface_copy;
  new_canvas->rensurface.scale_x = 1;
  new_canvas->rensurface.scale_y = 1;
  rencache_begin_frame(new_canvas);

  return 1;
}


static int f_scaled(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number new_w = luaL_checknumber(L, 2);
  lua_Number new_h = luaL_checknumber(L, 3);
  const char *mode = luaL_optstring(L, 4, "linear");

  lua_settop(L, 1); // keep only the canvas

  lua_pushnumber(L, 0); // x
  lua_pushnumber(L, 0); // y
  lua_pushnumber(L, canvas->rensurface.surface->w); // w
  lua_pushnumber(L, canvas->rensurface.surface->h); // h
  lua_pushnumber(L, new_w);
  lua_pushnumber(L, new_h);
  lua_pushstring(L, mode);

  return f_copy(L);
}


static int f_clear(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  RenColor color;
  if (lua_isnoneornil(L, 2))
    color = (RenColor) { .r = 0, .g = 0, .b = 0, .a = 0 };
  else
    color = luaXL_checkcolor(L, 6, 255);

  int w, h;
  ren_get_size(&canvas->rensurface, &w, &h);
  RenRect rect = { .x = 0, .y = 0, .width = w, .height = h };

  rencache_draw_rect(canvas, rect, color, true);

  return 0;
}


static int f_set_clip_rect(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_checknumber(L, 2);
  lua_Number y = luaL_checknumber(L, 3);
  lua_Number w = luaL_checknumber(L, 4);
  lua_Number h = luaL_checknumber(L, 5);

  RenRect rect = { .x = x, .y = y, .width = w, .height = h };
  rencache_set_clip_rect(canvas, rect);

  return 0;
}


static int f_draw_rect(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  lua_Number x = luaL_checknumber(L, 2);
  lua_Number y = luaL_checknumber(L, 3);
  lua_Number w = luaL_checknumber(L, 4);
  lua_Number h = luaL_checknumber(L, 5);
  RenColor color = luaXL_checkcolor(L, 6, 255);
  bool replace = luaXL_optboolean(L, 7, false);

  RenRect rect = { .x = x, .y = y, .width = w, .height = h };
  rencache_draw_rect(canvas, rect, color, replace);

  return 0;
}


static int f_draw_poly(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);

  static const char normal_tag[] = { POLY_NORMAL };
  static const char conic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CONIC, POLY_NORMAL };
  static const char cubic_bezier_tag[] = { POLY_NORMAL, POLY_CONTROL_CUBIC, POLY_CONTROL_CUBIC, POLY_NORMAL };

  luaL_checktype(L, 2, LUA_TTABLE);
  RenColor color = luaXL_checkcolor(L, 3, 255);
  lua_settop(L, 3);

  int len = luaL_len(L, 2);
  RenPoint *points = NULL; int npoints = 0;
  for (int i = 1; i <= len; i++) {
    lua_rawgeti(L, 2, i); luaL_checktype(L, -1, LUA_TTABLE);
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
  RenRect res = rencache_draw_poly(canvas, points, npoints, color);
  if (points) SDL_free(points);
  lua_pushinteger(L, res.x);     lua_pushinteger(L, res.y);
  lua_pushinteger(L, res.width); lua_pushinteger(L, res.height);
  return 4;
}


static int f_draw_text(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 2);

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
  const char *text = luaL_checklstring(L, 3, &len);
  double x = luaL_checknumber(L, 4);
  int y = luaL_checkinteger(L, 5);
  RenColor color = luaXL_checkcolor(L, 6, 255);
  RenTab tab = luaXL_checktab(L, 7);

  double end_x = rencache_draw_text(canvas, fonts, text, len, x, y, color, tab);
  lua_pushnumber(L, end_x);

  return 1;
}

static int f_draw_text_cells(lua_State *L) {
  RenCache *canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  RenFont* fonts[FONT_FALLBACK_MAX];
  font_retrieve(L, fonts, 2);

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

  size_t len, cells_len;
  const char *text = luaL_checklstring(L, 3, &len);
  const uint8_t *cells = (const uint8_t *)luaL_checklstring(L, 4, &cells_len);
  double x = luaL_checknumber(L, 5);
  double y = luaL_checknumber(L, 6);
  double cell_width = luaL_checknumber(L, 7);
  RenColor color = luaXL_checkcolor(L, 8, 255);
  int columns = 0;
  if (!ren_text_cells_measure(cells, cells_len, len, &columns))
    return luaL_argerror(L, 4, "cells do not describe the text");
  if (!isfinite(cell_width) || cell_width <= 0)
    return luaL_argerror(L, 7, "cell width must be positive");

  double end_x = rencache_draw_text_cells(
    canvas, fonts, text, len, cells, cells_len / REN_TEXT_CELL_BYTES,
    columns, x, y, cell_width, color
  );
  lua_pushnumber(L, end_x);
  return 1;
}


static int f_draw_canvas(lua_State *L) {
  RenCache *canvas_dst = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  RenCache *canvas_src = luaL_checkudata(L, 2, API_TYPE_CANVAS);

  lua_Number x = luaL_checknumber(L, 3);
  lua_Number y = luaL_checknumber(L, 4);
  bool blend = luaXL_optboolean(L, 5, true);

  SDL_Rect rect = { .x = x, .y = y, .w = canvas_src->rensurface.surface->w, .h = canvas_src->rensurface.surface->h };
  SDL_BlendMode src_mode;
  SDL_GetSurfaceBlendMode(canvas_src->rensurface.surface, &src_mode);
  SDL_SetSurfaceBlendMode(canvas_src->rensurface.surface, blend ? SDL_BLENDMODE_BLEND : SDL_BLENDMODE_NONE);

  SDL_BlitSurface(canvas_src->rensurface.surface, NULL, canvas_dst->rensurface.surface, &rect);

  SDL_SetSurfaceBlendMode(canvas_src->rensurface.surface, src_mode);

  return 0;
}


static int f_render(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  rencache_end_frame(canvas);
  return 0;
}


static int f_save_image(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  const char *file = luaL_checkstring(L, 2);
  const char *type = luaL_optstring(L, 3, "png");
  int quality = luaL_optinteger(L, 4, 100);

  bool saved = false;
  if (strcmp(type, "png") == 0) {
    saved = IMG_SavePNG(canvas->rensurface.surface, file);
  } else if (strcmp(type, "jpg") == 0) {
    saved = IMG_SaveJPG(canvas->rensurface.surface, file, quality);
  } else if (strcmp(type, "avif") == 0) {
    saved = IMG_SaveAVIF(canvas->rensurface.surface, file, quality);
  }

  if (saved) {
    lua_pushboolean(L, true);
    return 1;
  }

  lua_pushboolean(L, false);
  lua_pushstring(L, SDL_GetError());
  return 2;
}


static int f_gc(lua_State *L) {
  RenCache* canvas = luaL_checkudata(L, 1, API_TYPE_CANVAS);
  if (canvas->rensurface.surface) {
    anvil_d3d11_forget_surface(canvas->rensurface.surface);
    SDL_DestroySurface(canvas->rensurface.surface);
  }
  rencache_uninit(canvas);
  return 0;
}


static const luaL_Reg canvasLib[] = {
  { "get_pixels",    f_get_pixels    },
  { "set_pixels",    f_set_pixels    },
  { "get_size",      f_get_size      },
  { "copy",          f_copy          },
  { "scaled",        f_scaled        },
  { "clear",         f_clear         },
  { "set_clip_rect", f_set_clip_rect },
  { "draw_rect",     f_draw_rect     },
  { "draw_text",     f_draw_text     },
  { "draw_text_cells", f_draw_text_cells },
  { "draw_poly",     f_draw_poly     },
  { "draw_canvas",   f_draw_canvas   },
  { "render",        f_render        },
  { "save_image",    f_save_image    },
  { "__gc",          f_gc            },
  { NULL,            NULL            }
};

static const luaL_Reg lib[] = {
  { "new",             f_new             },
  { "load_image",      f_load_image      },
  { "load_image_data", f_load_image_data },
  { "load_svg_image",  f_load_svg_image  },
  { "open_animation",      f_open_animation      },
  { "open_animation_data", f_open_animation_data },
  { NULL,               NULL              }
};

static const luaL_Reg animationLib[] = {
  { "get_canvas",         f_animation_get_canvas         },
  { "get_frame_duration", f_animation_get_frame_duration },
  { "next_frame",         f_animation_next_frame         },
  { "close",              f_animation_close              },
  { "__gc",               f_animation_gc                 },
  { NULL,                 NULL                           }
};

int luaopen_canvas(lua_State *L) {
  luaL_newlib(L, lib);

  luaL_newmetatable(L, API_TYPE_CANVAS);
  luaL_setfuncs(L, canvasLib, 0);
  lua_setfield(L, -1, "__index");

  luaL_newmetatable(L, API_TYPE_ANIMATION);
  luaL_setfuncs(L, animationLib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  return 1;
}
