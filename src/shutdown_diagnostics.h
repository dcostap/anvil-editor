#ifndef ANVIL_SHUTDOWN_DIAGNOSTICS_H
#define ANVIL_SHUTDOWN_DIAGNOSTICS_H

#include <stdbool.h>

/* NULL closes the log. Calls can come from Lua or native worker threads. */
bool anvil_shutdown_diag_open(const char *path);
bool anvil_shutdown_diag_enabled(void);
void anvil_shutdown_diag_log(const char *format, ...);

#endif
