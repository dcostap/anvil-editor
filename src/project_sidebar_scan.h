#ifndef ANVIL_PROJECT_SIDEBAR_SCAN_H
#define ANVIL_PROJECT_SIDEBAR_SCAN_H
#ifdef _WIN32
#include "project_sidebar.h"
#include <SDL3/SDL.h>
typedef struct AnvilSidebarScan AnvilSidebarScan;
/* One job owns copies of all inputs. No live Project objects enter the worker. */
AnvilSidebarScan *anvil_sidebar_scan_start(const char *userdir, const char *recents,
                                           const AnvilSidebarModel *known,
                                           wchar_t *(*resolve)(const char *), bool delay);
bool anvil_sidebar_scan_done(AnvilSidebarScan *job);
const AnvilSidebarModel *anvil_sidebar_scan_result(AnvilSidebarScan *job, bool *limited);
bool anvil_sidebar_scan_stop(AnvilSidebarScan *job, Uint64 deadline);
void anvil_sidebar_scan_free(AnvilSidebarScan *job);
#endif
#endif
