#include "surface_protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char log_role[16];

bool anvil_surface_frame_matches(const AnvilSurfaceConfigure *config, const AnvilSurfaceFrame *frame) {
  return frame->configuration == config->configuration && frame->width == config->pixel_w && frame->height == config->pixel_h &&
    (frame->kind == ANVIL_SURFACE_FRAME_D3D11 || frame->kind == ANVIL_SURFACE_FRAME_SHARED_MEMORY) &&
    frame->name[0] && memchr(frame->name, 0, sizeof(frame->name));
}

bool anvil_surface_text_area(const AnvilSurfaceConfigure *config, const AnvilSurfaceTextInput *input, SDL_Rect *area, int *cursor) {
  if (input->configuration != config->configuration || input->w <= 0 || input->h <= 0) return false;
  /* Use 64-bit sums before clipping untrusted coordinates. */
  int64_t right = (int64_t)input->x + input->w;
  int64_t bottom = (int64_t)input->y + input->h;
  int x = SDL_clamp(input->x, 0, config->pixel_w - 1);
  int y = SDL_clamp(input->y, 0, config->pixel_h - 1);
  int w = (int)SDL_clamp(right - x, 1, config->pixel_w - x);
  int h = (int)SDL_clamp(bottom - y, 1, config->pixel_h - y);
  *area = (SDL_Rect){config->origin_x + x, config->origin_y + y, w, h};
  *cursor = (int)SDL_clamp((int64_t)input->x + input->cursor - x, 0, w);
  return true;
}

void anvil_surface_translate_input(const AnvilSurfaceConfigure *config, SDL_Event *event) {
  switch (event->type) {
    case SDL_EVENT_MOUSE_MOTION:
      event->motion.x -= config->origin_x;
      event->motion.y -= config->origin_y;
      break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
      event->button.x -= config->origin_x;
      event->button.y -= config->origin_y;
      break;
    case SDL_EVENT_MOUSE_WHEEL:
      event->wheel.mouse_x -= config->origin_x;
      event->wheel.mouse_y -= config->origin_y;
      break;
    case SDL_EVENT_DROP_POSITION:
    case SDL_EVENT_DROP_FILE:
    case SDL_EVENT_DROP_TEXT:
      event->drop.x -= config->origin_x;
      event->drop.y -= config->origin_y;
      break;
    default:
      break;
  }
}

static void SDLCALL write_surface_log(void *userdata, int category, SDL_LogPriority priority,
                                      const char *message) {
  (void)category;
  (void)priority;
  FILE *file = fopen((const char *)userdata, "ab");
  if (!file) return;
  fprintf(file, "%10.3f %s[%lu] %s\n", (double)SDL_GetTicksNS() / 1e9, log_role,
#ifdef _WIN32
          (unsigned long)GetCurrentProcessId(),
#else
          0ul,
#endif
          message);
  fclose(file);
}

void anvil_surface_log_init(const char *role) {
  const char *path = SDL_getenv("ANVIL_SURFACE_LOG");
  if (!path || !path[0]) return;
  SDL_strlcpy(log_role, role, sizeof(log_role));
  SDL_SetLogOutputFunction(write_surface_log, SDL_strdup(path));
}
