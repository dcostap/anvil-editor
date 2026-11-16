#define WIN32_LEAN_AND_MEAN
#include "process_identity.h"
#include <winternl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

bool anvil_process_creation_time(HANDLE process, char out[ANVIL_PROCESS_TIME_LENGTH + 1]) {
  FILETIME created, exited, kernel, user;
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return false;
  uint64_t value = ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
  snprintf(out, ANVIL_PROCESS_TIME_LENGTH + 1, "%016llx", (unsigned long long)value);
  return true;
}

bool anvil_process_identity(HANDLE process, DWORD pid, const char *time) {
  char actual[ANVIL_PROCESS_TIME_LENGTH + 1];
  return process && time && GetProcessId(process) == pid &&
    WaitForSingleObject(process, 0) == WAIT_TIMEOUT && anvil_process_creation_time(process, actual) &&
    strcmp(actual, time) == 0;
}

/* A protected process can reuse the ID of an old process. The system list gives its creation time
   without granting a process handle. A failed or incomplete query proves nothing. */
static DWORD inaccessible_state(DWORD pid, const char *time) {
  typedef NTSTATUS (NTAPI *QueryProcesses)(SYSTEM_INFORMATION_CLASS, void *, ULONG, ULONG *);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  QueryProcesses query = ntdll ? (QueryProcesses)GetProcAddress(ntdll, "NtQuerySystemInformation") : NULL;
  if (!query) return ERROR_ACCESS_DENIED;
  ULONG capacity = 65536;
  for (unsigned attempt = 0; attempt < 4 && capacity <= 16 * 1024 * 1024; attempt++) {
    uint8_t *bytes = malloc(capacity);
    if (!bytes) return ERROR_NOT_ENOUGH_MEMORY;
    ULONG length = 0;
    NTSTATUS status = query(SystemProcessInformation, bytes, capacity, &length);
    if ((ULONG)status == 0xc0000004u) { /* STATUS_INFO_LENGTH_MISMATCH */
      free(bytes);
      capacity = length > capacity ? length : capacity * 2;
      continue;
    }
    DWORD result = ERROR_ACCESS_DENIED;
    if (status >= 0 && length <= capacity) {
      size_t offset = 0;
      while (offset <= length && length - offset >= sizeof(SYSTEM_PROCESS_INFORMATION)) {
        SYSTEM_PROCESS_INFORMATION *entry = (SYSTEM_PROCESS_INFORMATION *)(bytes + offset);
        if ((uintptr_t)entry->UniqueProcessId == pid) {
          char actual[ANVIL_PROCESS_TIME_LENGTH + 1];
          snprintf(actual, sizeof(actual), "%016llx", (unsigned long long)entry->CreateTime.QuadPart);
          result = strcmp(actual, time) ? ERROR_PROCESS_ABORTED : ERROR_ACCESS_DENIED;
          break;
        }
        if (!entry->NextEntryOffset) { result = ERROR_PROCESS_ABORTED; break; }
        if (entry->NextEntryOffset < sizeof(*entry) || entry->NextEntryOffset > length - offset) break;
        offset += entry->NextEntryOffset;
      }
    }
    free(bytes);
    return result;
  }
  return ERROR_ACCESS_DENIED;
}

HANDLE anvil_process_open(DWORD pid, const char *time, DWORD *error) {
  *error = ERROR_INVALID_DATA;
  if (!pid || !time || strlen(time) != ANVIL_PROCESS_TIME_LENGTH ||
      strspn(time, "0123456789abcdef") != ANVIL_PROCESS_TIME_LENGTH) return NULL;
  HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) {
    *error = GetLastError();
    if (*error == ERROR_INVALID_PARAMETER) *error = ERROR_PROCESS_ABORTED;
    else if (*error == ERROR_ACCESS_DENIED) *error = inaccessible_state(pid, time);
    return NULL;
  }
  char actual[ANVIL_PROCESS_TIME_LENGTH + 1];
  DWORD waited = WaitForSingleObject(process, 0);
  if (waited == WAIT_OBJECT_0) *error = ERROR_PROCESS_ABORTED;
  else if (waited != WAIT_TIMEOUT || !anvil_process_creation_time(process, actual)) *error = GetLastError();
  else if (strcmp(actual, time)) *error = ERROR_PROCESS_ABORTED;
  else { *error = ERROR_SUCCESS; return process; }
  if (*error == ERROR_SUCCESS) *error = ERROR_GEN_FAILURE;
  CloseHandle(process);
  return NULL;
}
