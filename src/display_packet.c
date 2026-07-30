#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#include <SDL3/SDL.h>

#include "display_packet.h"
#include "rencache.h"

typedef struct {
  RenDisplayPacketCommandType type;
  int layer;
  int row;
  RenColor color;
  union {
    struct {
      RenFont *fonts[FONT_FALLBACK_MAX];
      uint32_t font_generations[FONT_FALLBACK_MAX];
      size_t font_count;
      char *text;
      size_t text_len;
      double x;
      double y;
      double bounds_x;
      double bounds_y;
      int bounds_width;
      int bounds_height;
      RenTab tab;
      int tab_size;
      float surface_scale;
    } text;
    struct {
      double x;
      double y;
      double width;
      double height;
    } rect;
    struct {
      double x;
      double y;
      double step_x;
      double width;
      double height;
      int count;
    } grid;
  } data;
} RenDisplayPacketCommand;

struct RenDisplayPacket {
  RenDisplayPacketCommand *commands;
  size_t count;
  size_t capacity;
  size_t text_bytes;
  bool sealed;
  bool released;
};

static bool finite_number(double value) {
  return isfinite(value) != 0;
}

static bool supported_coordinate(double value) {
  return finite_number(value)
    && value >= (double)INT_MIN / 2.0
    && value <= (double)INT_MAX / 2.0;
}

static bool supported_grid_endpoint(double value) {
  return finite_number(value)
    && value > (double)INT_MIN + 1.0
    && value < (double)INT_MAX - 1.0;
}

static bool valid_common(
  const RenDisplayPacket *packet,
  int layer,
  int row
) {
  return packet && !packet->released && !packet->sealed && layer >= 0 && row >= 1;
}

static bool reserve_commands(RenDisplayPacket *packet, size_t extra) {
  if (!packet || extra > SIZE_MAX - packet->count) return false;
  size_t wanted = packet->count + extra;
  if (wanted <= packet->capacity) return true;
  size_t capacity = packet->capacity ? packet->capacity : 16;
  while (capacity < wanted) {
    if (capacity > SIZE_MAX / 2) {
      capacity = wanted;
      break;
    }
    capacity *= 2;
  }
  if (capacity > SIZE_MAX / sizeof(*packet->commands)) return false;
  void *commands = SDL_realloc(
    packet->commands, capacity * sizeof(*packet->commands)
  );
  if (!commands) return false;
  packet->commands = commands;
  packet->capacity = capacity;
  return true;
}

RenDisplayPacket *ren_display_packet_new(void) {
  return SDL_calloc(1, sizeof(RenDisplayPacket));
}

void ren_display_packet_free(RenDisplayPacket *packet) {
  if (!packet) return;
  for (size_t index = 0; index < packet->count; index++) {
    RenDisplayPacketCommand *command = &packet->commands[index];
    if (command->type == REN_DISPLAY_PACKET_TEXT) {
      SDL_free(command->data.text.text);
      command->data.text.text = NULL;
    }
  }
  SDL_free(packet->commands);
  packet->commands = NULL;
  packet->count = 0;
  packet->capacity = 0;
  packet->text_bytes = 0;
  packet->sealed = false;
  packet->released = true;
}

void ren_display_packet_destroy(RenDisplayPacket *packet) {
  if (!packet) return;
  ren_display_packet_free(packet);
  SDL_free(packet);
}

bool ren_display_packet_is_sealed(const RenDisplayPacket *packet) {
  return packet && packet->sealed && !packet->released;
}

bool ren_display_packet_is_released(const RenDisplayPacket *packet) {
  return !packet || packet->released;
}

bool ren_display_packet_seal(RenDisplayPacket *packet) {
  if (!packet || packet->released) return false;
  packet->sealed = true;
  return true;
}

size_t ren_display_packet_bytes(const RenDisplayPacket *packet) {
  if (!packet || packet->released) return 0;
  if (packet->capacity > (SIZE_MAX - sizeof(*packet)) / sizeof(*packet->commands)) {
    return SIZE_MAX;
  }
  return sizeof(*packet)
    + packet->capacity * sizeof(*packet->commands)
    + packet->text_bytes;
}

size_t ren_display_packet_command_count(const RenDisplayPacket *packet) {
  return packet && !packet->released ? packet->count : 0;
}

bool ren_display_packet_command_info(
  const RenDisplayPacket *packet,
  size_t index,
  RenDisplayPacketCommandInfo *info
) {
  if (!packet || packet->released || !info || index >= packet->count) return false;
  const RenDisplayPacketCommand *command = &packet->commands[index];
  memset(info, 0, sizeof(*info));
  info->type = command->type;
  info->layer = command->layer;
  info->row = command->row;
  info->color = command->color;
  switch (command->type) {
    case REN_DISPLAY_PACKET_TEXT:
      info->text = command->data.text.text;
      info->text_len = command->data.text.text_len;
      info->x = command->data.text.x;
      info->y = command->data.text.y;
      info->bounds_x = command->data.text.bounds_x;
      info->bounds_y = command->data.text.bounds_y;
      info->bounds_width = command->data.text.bounds_width;
      info->bounds_height = command->data.text.bounds_height;
      info->tab = command->data.text.tab;
      info->tab_size = command->data.text.tab_size;
      info->font_count = command->data.text.font_count;
      break;
    case REN_DISPLAY_PACKET_RECT:
      info->x = command->data.rect.x;
      info->y = command->data.rect.y;
      info->width = command->data.rect.width;
      info->height = command->data.rect.height;
      break;
    case REN_DISPLAY_PACKET_RECT_GRID:
      info->x = command->data.grid.x;
      info->y = command->data.grid.y;
      info->step_x = command->data.grid.step_x;
      info->width = command->data.grid.width;
      info->height = command->data.grid.height;
      info->count = command->data.grid.count;
      break;
  }
  return true;
}

RenDisplayPacketResult ren_display_packet_add_text(
  RenDisplayPacket *packet,
  int layer,
  int row,
  RenFont **fonts,
  const char *text,
  size_t text_len,
  double x,
  double y,
  RenColor color,
  RenTab tab,
  int tab_size,
  float surface_scale,
  double *next_x
) {
  if (!valid_common(packet, layer, row) || !fonts || !fonts[0]
    || !text || text_len > INT_MAX - 1
    || !supported_coordinate(x) || !supported_coordinate(y)
    || (!isnan(tab.offset) && !finite_number(tab.offset))
    || tab_size <= 0 || tab_size > INT8_MAX
    || !finite_number(surface_scale) || surface_scale <= 0) {
    return REN_DISPLAY_PACKET_REJECTED;
  }
  if (text_len == SIZE_MAX || packet->text_bytes > SIZE_MAX - text_len - 1
    || rencache_text_command_storage_size(text_len) == SIZE_MAX) {
    return REN_DISPLAY_PACKET_REJECTED;
  }

  RenFont *snapshot[FONT_FALLBACK_MAX] = { 0 };
  size_t font_count = 0;
  while (font_count < FONT_FALLBACK_MAX && fonts[font_count]) {
    snapshot[font_count] = fonts[font_count];
    font_count++;
  }
  if (font_count == 0) return REN_DISPLAY_PACKET_REJECTED;

  ren_font_group_set_tab_size(snapshot, tab_size);
  int x_offset = 0;
  double width = ren_font_group_get_width(
    snapshot, text, text_len, tab, &x_offset
  );
  int height = ren_font_group_get_height(snapshot);
  double bounds_width = width - x_offset;
  if (!supported_coordinate(width) || width < 0 || height <= 0
    || bounds_width < 0 || bounds_width > INT_MAX - 1.0
    || !supported_grid_endpoint(x + x_offset)
    || !supported_grid_endpoint(x + x_offset + bounds_width)
    || !supported_grid_endpoint(y + height)) {
    return REN_DISPLAY_PACKET_REJECTED;
  }

  char *owned_text = SDL_malloc(text_len + 1);
  if (!owned_text) return REN_DISPLAY_PACKET_REJECTED;
  memcpy(owned_text, text, text_len);
  owned_text[text_len] = '\0';
  if (!reserve_commands(packet, 1)) {
    SDL_free(owned_text);
    return REN_DISPLAY_PACKET_REJECTED;
  }

  RenDisplayPacketCommand *command = &packet->commands[packet->count++];
  memset(command, 0, sizeof(*command));
  command->type = REN_DISPLAY_PACKET_TEXT;
  command->layer = layer;
  command->row = row;
  command->color = color;
  command->data.text.text = owned_text;
  command->data.text.text_len = text_len;
  command->data.text.x = x;
  command->data.text.y = y;
  command->data.text.bounds_x = x + x_offset;
  command->data.text.bounds_y = y;
  command->data.text.bounds_width = (int)bounds_width;
  command->data.text.bounds_height = height;
  command->data.text.tab = tab;
  command->data.text.tab_size = tab_size;
  command->data.text.surface_scale = surface_scale;
  command->data.text.font_count = font_count;
  for (size_t index = 0; index < font_count; index++) {
    command->data.text.fonts[index] = snapshot[index];
    command->data.text.font_generations[index] =
      ren_font_get_generation(snapshot[index]);
  }
  packet->text_bytes += text_len + 1;
  if (next_x) *next_x = x + width;
  return REN_DISPLAY_PACKET_OK;
}

RenDisplayPacketResult ren_display_packet_add_rect(
  RenDisplayPacket *packet,
  int layer,
  int row,
  double x,
  double y,
  double width,
  double height,
  RenColor color
) {
  if (!valid_common(packet, layer, row)
    || !supported_coordinate(x) || !supported_coordinate(y)
    || !supported_coordinate(width) || !supported_coordinate(height)
    || width <= 0 || height <= 0
    || !supported_grid_endpoint(x + width)
    || !supported_grid_endpoint(y + height)) {
    return REN_DISPLAY_PACKET_REJECTED;
  }
  if (!reserve_commands(packet, 1)) return REN_DISPLAY_PACKET_REJECTED;
  RenDisplayPacketCommand *command = &packet->commands[packet->count++];
  memset(command, 0, sizeof(*command));
  command->type = REN_DISPLAY_PACKET_RECT;
  command->layer = layer;
  command->row = row;
  command->color = color;
  command->data.rect.x = x;
  command->data.rect.y = y;
  command->data.rect.width = width;
  command->data.rect.height = height;
  return REN_DISPLAY_PACKET_OK;
}

RenDisplayPacketResult ren_display_packet_add_rect_grid(
  RenDisplayPacket *packet,
  int layer,
  int row,
  double x,
  double y,
  double step_x,
  double width,
  double height,
  int count,
  RenColor color
) {
  if (!valid_common(packet, layer, row)
    || !supported_coordinate(x) || !supported_coordinate(y)
    || !supported_coordinate(step_x)
    || !supported_coordinate(width) || !supported_coordinate(height)
    || step_x <= 0 || width <= 0 || height <= 0 || count <= 0
    || !supported_grid_endpoint(
      x + step_x * (double)(count - 1) + width
    )
    || !supported_grid_endpoint(y + height)) {
    return REN_DISPLAY_PACKET_REJECTED;
  }
  if (!reserve_commands(packet, 1)) return REN_DISPLAY_PACKET_REJECTED;
  RenDisplayPacketCommand *command = &packet->commands[packet->count++];
  memset(command, 0, sizeof(*command));
  command->type = REN_DISPLAY_PACKET_RECT_GRID;
  command->layer = layer;
  command->row = row;
  command->color = color;
  command->data.grid.x = x;
  command->data.grid.y = y;
  command->data.grid.step_x = step_x;
  command->data.grid.width = width;
  command->data.grid.height = height;
  command->data.grid.count = count;
  return REN_DISPLAY_PACKET_OK;
}

static bool command_selected(
  const RenDisplayPacketCommand *command,
  int layer,
  int first_row,
  int last_row
) {
  return command->layer == layer
    && command->row >= first_row
    && command->row <= last_row;
}

static bool text_font_is_current(
  const RenDisplayPacketCommand *command,
  float surface_scale
) {
  if (command->data.text.surface_scale != surface_scale) return false;
  for (size_t index = 0; index < command->data.text.font_count; index++) {
    RenFont *font = command->data.text.fonts[index];
    if (!font
      || ren_font_get_generation(font)
        != command->data.text.font_generations[index]
      || ren_font_get_surface_scale(font) != surface_scale) {
      return false;
    }
  }
  return true;
}

RenDisplayPacketResult ren_display_packet_replay(
  const RenDisplayPacket *packet,
  RenCache *cache,
  double origin_x,
  double origin_y,
  int layer,
  int first_row,
  int last_row,
  float surface_scale
) {
  if (!packet || packet->released) return REN_DISPLAY_PACKET_RELEASED;
  if (!packet->sealed) return REN_DISPLAY_PACKET_NOT_SEALED;
  if (!cache || layer < 0 || first_row < 1 || last_row < first_row
    || !finite_number(origin_x) || !finite_number(origin_y)
    || !finite_number(surface_scale) || surface_scale <= 0) {
    return REN_DISPLAY_PACKET_REJECTED;
  }
  if (rencache_frame_is_failed(cache)) return REN_DISPLAY_PACKET_FRAME_FAILED;

  size_t reserve_bytes = 0;
  for (size_t index = 0; index < packet->count; index++) {
    const RenDisplayPacketCommand *command = &packet->commands[index];
    if (command->type == REN_DISPLAY_PACKET_TEXT
      && !text_font_is_current(command, surface_scale)) {
      return REN_DISPLAY_PACKET_STALE_FONT;
    }
    if (!command_selected(command, layer, first_row, last_row)) continue;
    switch (command->type) {
      case REN_DISPLAY_PACKET_TEXT:
        if (!supported_coordinate(origin_x + command->data.text.x)
          || !supported_coordinate(origin_y + command->data.text.y)
          || !supported_coordinate(origin_x + command->data.text.bounds_x)
          || !supported_coordinate(origin_y + command->data.text.bounds_y)
          || !supported_grid_endpoint(
            origin_x + command->data.text.bounds_x
              + command->data.text.bounds_width
          )
          || !supported_grid_endpoint(
            origin_y + command->data.text.bounds_y
              + command->data.text.bounds_height
          )) {
          return REN_DISPLAY_PACKET_REJECTED;
        }
        break;
      case REN_DISPLAY_PACKET_RECT:
        if (!supported_coordinate(origin_x + command->data.rect.x)
          || !supported_coordinate(origin_y + command->data.rect.y)
          || !supported_grid_endpoint(
            origin_x + command->data.rect.x + command->data.rect.width
          )
          || !supported_grid_endpoint(
            origin_y + command->data.rect.y + command->data.rect.height
          )) {
          return REN_DISPLAY_PACKET_REJECTED;
        }
        break;
      case REN_DISPLAY_PACKET_RECT_GRID:
        if (!supported_coordinate(origin_x + command->data.grid.x)
          || !supported_coordinate(origin_y + command->data.grid.y)
          || !supported_coordinate(
            origin_x + command->data.grid.x
              + command->data.grid.step_x * (double)(command->data.grid.count - 1)
          )
          || !supported_grid_endpoint(
            origin_x + command->data.grid.x
              + command->data.grid.step_x * (double)(command->data.grid.count - 1)
              + command->data.grid.width
          )
          || !supported_grid_endpoint(
            origin_y + command->data.grid.y + command->data.grid.height
          )) {
          return REN_DISPLAY_PACKET_REJECTED;
        }
        break;
    }
    size_t command_bytes = 0;
    switch (command->type) {
      case REN_DISPLAY_PACKET_TEXT:
        command_bytes = rencache_text_command_storage_size(
          command->data.text.text_len
        );
        break;
      case REN_DISPLAY_PACKET_RECT:
        command_bytes = rencache_rect_command_storage_size();
        break;
      case REN_DISPLAY_PACKET_RECT_GRID:
        command_bytes = rencache_rect_grid_command_storage_size();
        break;
    }
    if (command_bytes == SIZE_MAX || reserve_bytes > SIZE_MAX - command_bytes) {
      return REN_DISPLAY_PACKET_REJECTED;
    }
    reserve_bytes += command_bytes;
  }

  if (!rencache_reserve_command_bytes(cache, reserve_bytes)) {
    return REN_DISPLAY_PACKET_FRAME_FAILED;
  }

  uint64_t started = SDL_GetPerformanceCounter();
  size_t replayed = 0, text_commands = 0, rect_commands = 0;
  size_t source_bytes = 0, frame_bytes = 0;
  for (size_t index = 0; index < packet->count; index++) {
    const RenDisplayPacketCommand *command = &packet->commands[index];
    if (!command_selected(command, layer, first_row, last_row)) continue;
    size_t before = cache->command_buf_idx;
    switch (command->type) {
      case REN_DISPLAY_PACKET_TEXT: {
        RenFont *fonts[FONT_FALLBACK_MAX] = { 0 };
        memcpy(
          fonts, command->data.text.fonts,
          sizeof(command->data.text.fonts)
        );
        RenRect bounds = {
          (RECT_TYPE)(origin_x + command->data.text.bounds_x),
          (RECT_TYPE)(origin_y + command->data.text.bounds_y),
          (RECT_TYPE)command->data.text.bounds_width,
          (RECT_TYPE)command->data.text.bounds_height,
        };
        rencache_draw_text_known_bounds_captured(
          cache,
          fonts,
          command->data.text.text,
          command->data.text.text_len,
          origin_x + command->data.text.x,
          origin_y + command->data.text.y,
          bounds,
          command->color,
          command->data.text.tab,
          command->data.text.tab_size
        );
      } break;
      case REN_DISPLAY_PACKET_RECT: {
        RenRect rect = rencache_rect_from_floats(
          origin_x + command->data.rect.x,
          origin_y + command->data.rect.y,
          command->data.rect.width,
          command->data.rect.height
        );
        rencache_draw_rect(cache, rect, command->color, false);
      } break;
      case REN_DISPLAY_PACKET_RECT_GRID:
        rencache_draw_rect_grid(
          cache,
          origin_x + command->data.grid.x,
          origin_y + command->data.grid.y,
          command->data.grid.step_x,
          command->data.grid.width,
          command->data.grid.height,
          command->data.grid.count,
          command->color
        );
        break;
    }
    if (cache->command_buf_idx > before) {
      replayed++;
      frame_bytes += cache->command_buf_idx - before;
      if (command->type == REN_DISPLAY_PACKET_TEXT) {
        text_commands++;
        source_bytes += command->data.text.text_len;
      } else {
        rect_commands++;
      }
    }
  }
  rencache_record_display_packet_replay(
    cache,
    replayed,
    text_commands,
    rect_commands,
    source_bytes,
    frame_bytes,
    started
  );
  return rencache_frame_is_failed(cache)
    ? REN_DISPLAY_PACKET_FRAME_FAILED
    : REN_DISPLAY_PACKET_OK;
}

const char *ren_display_packet_result_string(RenDisplayPacketResult result) {
  switch (result) {
    case REN_DISPLAY_PACKET_OK: return "ok";
    case REN_DISPLAY_PACKET_RELEASED: return "released";
    case REN_DISPLAY_PACKET_NOT_SEALED: return "not_sealed";
    case REN_DISPLAY_PACKET_STALE_FONT: return "stale_font";
    case REN_DISPLAY_PACKET_REJECTED: return "rejected";
    case REN_DISPLAY_PACKET_FRAME_FAILED: return "frame_failed";
  }
  return "unknown";
}
