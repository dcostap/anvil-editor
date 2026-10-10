#ifndef ANVIL_PROCESS_EXIT_H
#define ANVIL_PROCESS_EXIT_H
#include <stdbool.h>
#include <windows.h>

/* Process exit schedules every thread once. GPU drivers own idle-priority threads, which starve on a
 * saturated CPU until the Windows anti-starvation boost (about 4 s). Raising them first keeps exit prompt. */
void anvil_process_raise_idle_threads(DWORD pid);
/* Exit hook for the current process. ExitProcess also ends every other thread first. */
void anvil_process_prepare_exit(void);
/* Raises the process's starving threads, then terminates it. */
bool anvil_process_terminate(HANDLE process, UINT code);
#endif
