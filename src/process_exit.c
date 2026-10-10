#include "process_exit.h"
#include <tlhelp32.h>

void anvil_process_raise_idle_threads(DWORD pid) {
  if (!pid) return;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return;
  THREADENTRY32 entry = {.dwSize = sizeof(entry)};
  for (BOOL more = Thread32First(snapshot, &entry); more; more = Thread32Next(snapshot, &entry)) {
    if (entry.th32OwnerProcessID != pid) continue;
    HANDLE thread = OpenThread(THREAD_QUERY_LIMITED_INFORMATION | THREAD_SET_LIMITED_INFORMATION, FALSE,
                               entry.th32ThreadID);
    if (!thread) continue;
    int priority = GetThreadPriority(thread);
    if (priority != THREAD_PRIORITY_ERROR_RETURN && priority < THREAD_PRIORITY_NORMAL)
      SetThreadPriority(thread, THREAD_PRIORITY_NORMAL);
    CloseHandle(thread);
  }
  CloseHandle(snapshot);
}

void anvil_process_prepare_exit(void) { anvil_process_raise_idle_threads(GetCurrentProcessId()); }

bool anvil_process_terminate(HANDLE process, UINT code) {
  anvil_process_raise_idle_threads(GetProcessId(process));
  return TerminateProcess(process, code) != 0;
}
