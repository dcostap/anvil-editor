#ifndef DISPLAY_PACKET_H
#define DISPLAY_PACKET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "renderer.h"

typedef struct RenCache RenCache;
typedef struct RenDisplayPacket RenDisplayPacket;

typedef enum {
  REN_DISPLAY_PACKET_TEXT,
  REN_DISPLAY_PACKET_RECT,
  REN_DISPLAY_PACKET_RECT_GRID,
} RenDisplayPacketCommandType;

typedef enum {
  REN_DISPLAY_PACKET_OK,
  REN_DISPLAY_PACKET_RELEASED,
  REN_DISPLAY_PACKET_NOT_SEALED,
  REN_DISPLAY_PACKET_STALE_FONT,
  REN_DISPLAY_PACKET_REJECTED,
  REN_DISPLAY_PACKET_FRAME_FAILED,
} RenDisplayPacketResult;

typedef struct {
  RenDisplayPacketCommandType type;
  int layer;
  int row;
  const char *text;
  size_t text_len;
  double x;
  double y;
  double bounds_x;
  double bounds_y;
  double bounds_width;
  double bounds_height;
  double step_x;
  double width;
  double height;
  int count;
  RenColor color;
  RenTab tab;
  int tab_size;
  size_t font_count;
} RenDisplayPacketCommandInfo;

RenDisplayPacket *ren_display_packet_new(void);
void ren_display_packet_free(RenDisplayPacket *packet);
void ren_display_packet_destroy(RenDisplayPacket *packet);
bool ren_display_packet_is_sealed(const RenDisplayPacket *packet);
bool ren_display_packet_is_released(const RenDisplayPacket *packet);
bool ren_display_packet_seal(RenDisplayPacket *packet);
size_t ren_display_packet_bytes(const RenDisplayPacket *packet);
size_t ren_display_packet_command_count(const RenDisplayPacket *packet);
bool ren_display_packet_command_info(
  const RenDisplayPacket *packet,
  size_t index,
  RenDisplayPacketCommandInfo *info
);

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
);
RenDisplayPacketResult ren_display_packet_add_rect(
  RenDisplayPacket *packet,
  int layer,
  int row,
  double x,
  double y,
  double width,
  double height,
  RenColor color
);
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
);

RenDisplayPacketResult ren_display_packet_replay(
  const RenDisplayPacket *packet,
  RenCache *cache,
  double origin_x,
  double origin_y,
  int layer,
  int first_row,
  int last_row,
  float surface_scale
);

const char *ren_display_packet_result_string(RenDisplayPacketResult result);

#endif
