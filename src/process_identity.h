#ifndef ANVIL_PROCESS_IDENTITY_H
#define ANVIL_PROCESS_IDENTITY_H
#ifdef _WIN32
/* A process identity is its ID and its creation time, because Windows reuses process IDs.
   Records keep the creation time as 16 lowercase hexadecimal digits. */
#include <windows.h>
#include <stdbool.h>

#define ANVIL_PROCESS_TIME_LENGTH 16

bool anvil_process_creation_time(HANDLE process, char out[ANVIL_PROCESS_TIME_LENGTH + 1]);
/* True while `process` runs and has this ID and creation time. */
bool anvil_process_identity(HANDLE process, DWORD pid, const char *creation_time);
/* Opens the process with SYNCHRONIZE and PROCESS_QUERY_LIMITED_INFORMATION while it has this identity.
   NULL with ERROR_PROCESS_ABORTED proves that the process ended. Other errors prove nothing. */
HANDLE anvil_process_open(DWORD pid, const char *creation_time, DWORD *error);
#endif
#endif
