#pragma once

#include <stdbool.h>
#include <SDL3/SDL.h>

struct RenWindow;

#if defined(_WIN32)

bool win32_frame_enable(struct RenWindow *ren, bool enable);
bool win32_frame_get_metrics(struct RenWindow *ren, int *button_width, int *title_height, int *resize_border);
bool win32_frame_is_resizing(struct RenWindow *ren);
void win32_frame_set_hit_test(struct RenWindow *ren, int title_height, int controls_width, int resize_border, int client_x, int client_width);
void win32_frame_destroy(struct RenWindow *ren);

#else

static inline bool win32_frame_enable(struct RenWindow *ren, bool enable) { (void)ren; (void)enable; return false; }
static inline bool win32_frame_get_metrics(struct RenWindow *ren, int *button_width, int *title_height, int *resize_border) { (void)ren; (void)button_width; (void)title_height; (void)resize_border; return false; }
static inline bool win32_frame_is_resizing(struct RenWindow *ren) { (void)ren; return false; }
static inline void win32_frame_set_hit_test(struct RenWindow *ren, int title_height, int controls_width, int resize_border, int client_x, int client_width) { (void)ren; (void)title_height; (void)controls_width; (void)resize_border; (void)client_x; (void)client_width; }
static inline void win32_frame_destroy(struct RenWindow *ren) { (void)ren; }

#endif
