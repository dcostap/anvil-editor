#include "mapped_file.h"

#include <SDL3/SDL.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

bool anvil_mapped_file_open(const char *path, AnvilMappedFile *file) {
  file->data = NULL;
  file->size = 0;
#ifdef _WIN32
  int wide_len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  WCHAR *wide = wide_len > 0 ? SDL_malloc(sizeof(WCHAR) * wide_len) : NULL;
  if (!wide || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, wide_len)) {
    SDL_free(wide);
    return SDL_SetError("Could not map %s: invalid path", path);
  }
  HANDLE handle = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  SDL_free(wide);
  if (handle == INVALID_HANDLE_VALUE)
    return SDL_SetError("Could not open %s: error %lu", path, GetLastError());
  LARGE_INTEGER size;
  if (!GetFileSizeEx(handle, &size) || size.QuadPart <= 0 || (unsigned long long) size.QuadPart > SIZE_MAX) {
    CloseHandle(handle);
    return SDL_SetError("Could not map %s: empty or unreadable file", path);
  }
  HANDLE mapping = CreateFileMappingW(handle, NULL, PAGE_READONLY, 0, 0, NULL);
  DWORD error = mapping ? 0 : GetLastError();
  CloseHandle(handle);
  if (!mapping)
    return SDL_SetError("Could not map %s: error %lu", path, error);
  // The view keeps the file open after both handles close.
  file->data = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
  error = file->data ? 0 : GetLastError();
  CloseHandle(mapping);
  if (!file->data)
    return SDL_SetError("Could not map %s: error %lu", path, error);
  file->size = (size_t) size.QuadPart;
  return true;
#else
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    return SDL_SetError("Could not open %s: %s", path, strerror(errno));
  struct stat info;
  if (fstat(fd, &info) != 0 || info.st_size <= 0) {
    close(fd);
    return SDL_SetError("Could not map %s: empty or unreadable file", path);
  }
  void *data = mmap(NULL, (size_t) info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  int error = errno;
  close(fd);
  if (data == MAP_FAILED)
    return SDL_SetError("Could not map %s: %s", path, strerror(error));
  file->data = data;
  file->size = (size_t) info.st_size;
  return true;
#endif
}

void anvil_mapped_file_close(AnvilMappedFile *file) {
  if (!file->data) return;
#ifdef _WIN32
  UnmapViewOfFile(file->data);
#else
  munmap((void *) file->data, file->size);
#endif
  file->data = NULL;
  file->size = 0;
}
