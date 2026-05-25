#ifndef ANVIL_RESIZE_DIAGNOSTICS_H
#define ANVIL_RESIZE_DIAGNOSTICS_H

#include <stdbool.h>
#include <stdint.h>
#include <SDL3/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnvilResizeDiagEvent {
  const char *category;
  const char *name;
  const char *reason;
  const char *detail;
  uint32_t window_id;
  bool live_resize;
  bool in_run_step;
  int queue_depth;
  int point_w;
  int point_h;
  int pixel_w;
  int pixel_h;
  int client_w;
  int client_h;
  int count_a;
  int count_b;
  double ms_a;
  double ms_b;
  double ms_c;
} AnvilResizeDiagEvent;

bool anvil_resize_diag_enabled(void);
void anvil_resize_diag_log(const AnvilResizeDiagEvent *event);
void anvil_resize_diag_set_live_resize(bool live_resize);
bool anvil_resize_diag_live_resize(void);
double anvil_resize_diag_ticks_to_ms(uint64_t start_ns, uint64_t end_ns);
const char *anvil_resize_diag_event_reason(uint32_t sdl_event_type);

#ifdef __cplusplus
}
#endif

#endif /* ANVIL_RESIZE_DIAGNOSTICS_H */
