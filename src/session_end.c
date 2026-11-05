#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <SDL3/SDL_log.h>
#include "session_end.h"

static HWND window;
static HANDLE thread, ready;
static volatile LONG pending, generation;
static DWORD startup_error;
static bool attempted;
static SRWLOCK watch_lock = SRWLOCK_INIT;
static HANDLE watched_process;
static bool watched_running, watched_interrupted;

static bool startup_failed(DWORD error) {
  SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Session-end notification unavailable: error=%lu; keep running",
    (unsigned long)error);
  SetLastError(error);
  return false;
}

static LRESULT CALLBACK session_end_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  /* Restart Manager closes one application, not the Windows session. It can leave an application running. */
  if ((message == WM_QUERYENDSESSION || message == WM_ENDSESSION) &&
      (lparam & ENDSESSION_CLOSEAPP) && !(lparam & ENDSESSION_LOGOFF)) return TRUE;
  if (message == WM_QUERYENDSESSION) {
    AcquireSRWLockExclusive(&watch_lock);
    if (!InterlockedExchange(&pending, 1)) {
      watched_running = watched_process && WaitForSingleObject(watched_process, 0) == WAIT_TIMEOUT;
      InterlockedIncrement(&generation);
    }
    ReleaseSRWLockExclusive(&watch_lock);
    return TRUE;
  }
  if (message == WM_ENDSESSION) {
    /* Another application can cancel the query. Normal operation must then resume. */
    AcquireSRWLockExclusive(&watch_lock);
    if (watched_running && WaitForSingleObject(watched_process, 0) == WAIT_OBJECT_0)
      watched_interrupted = true;
    InterlockedExchange(&pending, wparam ? 1 : 0);
    if (!wparam) watched_running = false;
    ReleaseSRWLockExclusive(&watch_lock);
    return 0;
  }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

static DWORD WINAPI session_end_thread(void *unused) {
  (void)unused;
  WNDCLASSW cls = {0};
  cls.lpfnWndProc = session_end_proc;
  cls.hInstance = GetModuleHandleW(NULL);
  cls.lpszClassName = L"AnvilSessionEnd";
  if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    startup_error = GetLastError(); SetEvent(ready); return 0;
  }
  wchar_t name[32];
  swprintf(name, 32, L"%lu", (unsigned long)GetCurrentProcessId());
  /* A message-only window receives no session-end broadcast. This window stays hidden.
     Its thread can answer while Lua, a disk write, or ConPTY blocks another thread. */
  window = CreateWindowExW(0, cls.lpszClassName, name, 0, 0, 0, 0, 0, NULL, NULL, cls.hInstance, NULL);
  if (!window) startup_error = GetLastError();
  SetEvent(ready);
  if (!window) return 0;
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return 0;
}

bool anvil_session_end_init(bool terminal_host) {
  if (attempted) return window != NULL;
  attempted = true;
  /* Editors stop recovery first, then hosts protect records, then normal shells and programs end.
     0x300..0x3ff is the application-first range. Windows starts other processes at 0x280. */
  if (!SetProcessShutdownParameters(terminal_host ? 0x3fe : 0x3ff, SHUTDOWN_NORETRY))
    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Session-end priority unavailable: error=%lu", (unsigned long)GetLastError());
  ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!ready) return startup_failed(GetLastError());
  thread = CreateThread(NULL, 0, session_end_thread, NULL, 0, NULL);
  if (!thread) { DWORD error = GetLastError(); CloseHandle(ready); ready = NULL; return startup_failed(error); }
  WaitForSingleObject(ready, INFINITE);
  CloseHandle(ready); ready = NULL;
  if (startup_error) { anvil_session_end_close(); return startup_failed(startup_error); }
  atexit(anvil_session_end_close);
  return true;
}

bool anvil_session_end_pending(void) {
  return InterlockedCompareExchange(&pending, 0, 0) != 0 || GetSystemMetrics(SM_SHUTTINGDOWN) != 0;
}

unsigned long anvil_session_end_generation(void) {
  return (unsigned long)InterlockedCompareExchange(&generation, 0, 0);
}

void anvil_session_end_watch_process(void *process) {
  AcquireSRWLockExclusive(&watch_lock);
  watched_process = process;
  watched_running = process && pending && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
  watched_interrupted = false;
  ReleaseSRWLockExclusive(&watch_lock);
}

bool anvil_session_end_interrupted(void) {
  AcquireSRWLockShared(&watch_lock);
  bool ending = (watched_running && pending) || GetSystemMetrics(SM_SHUTTINGDOWN) != 0;
  bool interrupted = watched_interrupted || (ending && watched_process &&
    WaitForSingleObject(watched_process, 0) == WAIT_OBJECT_0);
  /* Windows can finish its console termination after CANCEL. An ordinary exit after
     cancellation is not an interruption; require Windows' termination status. */
  if (!interrupted && watched_process && generation) {
    DWORD code;
    if (GetExitCodeProcess(watched_process, &code) && code == 0x40010004u)
      interrupted = true;
  }
  ReleaseSRWLockShared(&watch_lock);
  return interrupted;
}

void anvil_session_end_close(void) {
  if (window) PostMessageW(window, WM_CLOSE, 0, 0);
  if (thread) { WaitForSingleObject(thread, 5000); CloseHandle(thread); }
  thread = NULL;
  window = NULL;
}
