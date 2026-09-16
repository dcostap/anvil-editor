#include "shutdown_diagnostics.h"

#include <SDL3/SDL.h>
#include <stdarg.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#ifdef _WIN32
#include <share.h>
#include <wchar.h>
#endif

static SDL_InitState init;
static SDL_Mutex *mutex;
static FILE *file;
static SDL_AtomicInt enabled;
static Uint64 started_ns;
static size_t bytes;

static FILE *open_log(const char *path) {
#ifdef _WIN32
  wchar_t *wide = (wchar_t *)SDL_iconv_string("WCHAR_T", "UTF-8", path, SDL_strlen(path) + 1);
  if (!wide) return NULL;
  FILE *opened = _wfsopen(wide, L"wb", _SH_DENYNO);
  if (!opened) SDL_SetError("%s", strerror(errno));
  SDL_free(wide);
#else
  FILE *opened = fopen(path, "wb");
  if (!opened) SDL_SetError("%s", strerror(errno));
#endif
  if (opened) setvbuf(opened, NULL, _IONBF, 0);
  return opened;
}

bool anvil_shutdown_diag_enabled(void) {
  return SDL_GetAtomicInt(&enabled) != 0;
}

bool anvil_shutdown_diag_open(const char *path) {
  if (SDL_ShouldInit(&init)) {
    mutex = SDL_CreateMutex();
    SDL_SetInitialized(&init, mutex != NULL);
  }
  if (!mutex) return false;
  SDL_LockMutex(mutex);
  SDL_SetAtomicInt(&enabled, 0);
  if (file) fclose(file);
  file = path ? open_log(path) : NULL;
  started_ns = SDL_GetTicksNS();
  bytes = 0;
  bool ok = !path || file != NULL;
  SDL_SetAtomicInt(&enabled, file != NULL);
  SDL_UnlockMutex(mutex);
  if (path && ok) anvil_shutdown_diag_log("shutdown diagnostics started");
  return ok;
}

void anvil_shutdown_diag_log(const char *format, ...) {
  if (!anvil_shutdown_diag_enabled()) return;
  SDL_LockMutex(mutex);
  if (file && anvil_shutdown_diag_enabled()) {
    char line[4096];
    int prefix = snprintf(line, sizeof(line), "elapsed_ms=%.3f ticks_ms=%llu thread=%llu ",
      (double)(SDL_GetTicksNS() - started_ns) / 1000000.0,
      (unsigned long long)SDL_GetTicks(), (unsigned long long)SDL_GetCurrentThreadID());
    va_list args;
    va_start(args, format);
    SDL_vsnprintf(line + prefix, sizeof(line) - prefix, format, args);
    va_end(args);
    size_t length = SDL_strlen(line);
    if (length > sizeof(line) - 2) length = sizeof(line) - 2;
    /* Keep paths and messages on one line. Never record file contents. */
    for (size_t i = 0; i < length; i++) {
      if (line[i] == '\r' || line[i] == '\n') line[i] = ' ';
    }
    line[length++] = '\n';
    /* Write each line without buffering. Do not add disk-sync waits during shutdown. */
    if (fwrite(line, 1, length, file) != length) SDL_SetAtomicInt(&enabled, 0);
    bytes += length;
    if (bytes >= 2 * 1024 * 1024) {
      const char limit[] = "shutdown diagnostics size limit reached\n";
      fwrite(limit, 1, sizeof(limit) - 1, file);
      SDL_SetAtomicInt(&enabled, 0);
    }
  }
  SDL_UnlockMutex(mutex);
}
