#include "file_trash.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#include <objbase.h>
#include <wchar.h>
#endif

bool anvil_file_trash(const char *const *paths, size_t count, char *error, size_t error_size) {
  if (!count) return true;
#ifdef _WIN32
  size_t total = 1;
  for (size_t i = 0; i < count; ++i) {
    const char *path = paths[i];
    size_t length = strlen(path);
    bool drive = length >= 3 && ((path[0] >= 'A' && path[0] <= 'Z') ||
      (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':' && (path[2] == '\\' || path[2] == '/');
    bool unc = length >= 3 && path[0] == '\\' && path[1] == '\\';
    if ((!drive && !unc) || length > INT_MAX || strpbrk(path, "*?")) {
      snprintf(error, error_size, "Recycle Bin requires absolute paths without wildcards");
      return false;
    }
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!size || size > 32767 || (size_t)size > SIZE_MAX / sizeof(wchar_t) - total) {
      snprintf(error, error_size, "Invalid or oversized Recycle Bin path");
      return false;
    }
    total += (size_t)size;
  }
  wchar_t *from = calloc(total, sizeof(*from));
  if (!from) {
    snprintf(error, error_size, "Not enough memory for Recycle Bin paths");
    return false;
  }
  size_t offset = 0;
  for (size_t i = 0; i < count; ++i) {
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, paths[i], -1, from + offset,
      (int)(total - offset > INT_MAX ? INT_MAX : total - offset));
    for (int j = 0; j < size; ++j) if (from[offset + j] == '/') from[offset + j] = '\\';
    DWORD attributes = GetFileAttributesW(from + offset);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
      DWORD code = GetLastError();
      if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) continue;
      snprintf(error, error_size, "Cannot inspect Recycle Bin source (Windows error %lu)", (unsigned long)code);
      free(from);
      return false;
    }
    offset += (size_t)size;
  }
  from[offset] = L'\0';
  if (!offset) { free(from); return true; }
  HRESULT initialized = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
    snprintf(error, error_size, "Cannot initialize Recycle Bin operation (HRESULT %lx)", (unsigned long)initialized);
    free(from);
    return false;
  }
  SHFILEOPSTRUCTW operation = {0};
  operation.wFunc = FO_DELETE;
  operation.pFrom = from;
  operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;
  int code = SHFileOperationW(&operation);
  if (SUCCEEDED(initialized)) CoUninitialize();
  free(from);
  if (code || operation.fAnyOperationsAborted) {
    snprintf(error, error_size, "Recycle Bin operation failed or was cancelled (code %d)", code);
    return false;
  }
  return true;
#else
  (void)paths;
  snprintf(error, error_size, "Recycle Bin is only available on Windows");
  return false;
#endif
}
