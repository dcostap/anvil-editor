#ifndef ANVIL_SESSION_END_H
#define ANVIL_SESSION_END_H

#include <stdbool.h>

#ifdef _WIN32
/* Register before starting shells or hosted processes. The notification thread never runs editor code. */
bool anvil_session_end_init(bool terminal_host);
bool anvil_session_end_pending(void);
unsigned long anvil_session_end_generation(void);
/* The host keeps this process handle open until it unregisters the shell with NULL. */
void anvil_session_end_watch_process(void *process);
bool anvil_session_end_interrupted(void);
void anvil_session_end_close(void);
#else
static inline bool anvil_session_end_init(bool terminal_host) { (void)terminal_host; return true; }
static inline bool anvil_session_end_pending(void) { return false; }
static inline unsigned long anvil_session_end_generation(void) { return 0; }
#endif

#endif
