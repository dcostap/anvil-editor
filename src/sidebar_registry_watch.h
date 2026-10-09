#ifndef ANVIL_SIDEBAR_REGISTRY_WATCH_H
#define ANVIL_SIDEBAR_REGISTRY_WATCH_H
#include <stdbool.h>
#include <stdint.h>
#include <windows.h>

typedef struct AnvilSidebarWatch AnvilSidebarWatch;
/* File system setup and waits run on the owned worker. */
AnvilSidebarWatch *anvil_sidebar_watch_start(const char *userdir, HWND window, UINT message);
/* Retains storage on timeout. The caller must not destroy the Window first. */
bool anvil_sidebar_watch_stop(AnvilSidebarWatch *watch, uint64_t deadline);
#endif
