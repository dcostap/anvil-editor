#include "embedded_runtime.h"

#include <stdio.h>

#ifdef _WIN32

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <shlobj.h>
#include <zlib.h>

#define ANVIL_RUNTIME_MAGIC "ANVRT001"
#define ANVIL_RUNTIME_MAX_FILES 10000u
#define ANVIL_RUNTIME_MAX_FILE_SIZE (64u * 1024u * 1024u)
#define ANVIL_RUNTIME_PATH_CAPACITY 32768

static void set_error(char *error, size_t size, const char *format, ...) {
  if (!error || size == 0) return;
  va_list args;
  va_start(args, format);
  vsnprintf(error, size, format, args);
  va_end(args);
  error[size - 1] = '\0';
}

static bool read_bytes(const uint8_t **cursor, const uint8_t *end, void *out, size_t size) {
  if ((size_t)(end - *cursor) < size) return false;
  memcpy(out, *cursor, size);
  *cursor += size;
  return true;
}

static bool read_u16(const uint8_t **cursor, const uint8_t *end, uint16_t *value) {
  uint8_t bytes[2];
  if (!read_bytes(cursor, end, bytes, sizeof(bytes))) return false;
  *value = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
  return true;
}

static bool read_u32(const uint8_t **cursor, const uint8_t *end, uint32_t *value) {
  uint8_t bytes[4];
  if (!read_bytes(cursor, end, bytes, sizeof(bytes))) return false;
  *value = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8)
         | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
  return true;
}

static bool read_u64(const uint8_t **cursor, const uint8_t *end, uint64_t *value) {
  uint8_t bytes[8];
  if (!read_bytes(cursor, end, bytes, sizeof(bytes))) return false;
  *value = 0;
  for (int index = 7; index >= 0; index--) {
    *value = (*value << 8) | bytes[index];
  }
  return true;
}

static bool append_path(wchar_t *path, size_t capacity, const wchar_t *part) {
  size_t used = wcslen(path);
  size_t length = wcslen(part);
  bool separator = used > 0 && path[used - 1] != L'\\' && path[used - 1] != L'/';
  if (used + (separator ? 1 : 0) + length + 1 > capacity) return false;
  if (separator) path[used++] = L'\\';
  memcpy(path + used, part, (length + 1) * sizeof(wchar_t));
  return true;
}

static bool create_directory_tree(wchar_t *path) {
  size_t length = wcslen(path);
  for (size_t index = 1; index < length; index++) {
    if (path[index] != L'\\' && path[index] != L'/') continue;
    if (index == 2 && path[1] == L':') continue;
    wchar_t saved = path[index];
    path[index] = L'\0';
    if (!CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
      path[index] = saved;
      return false;
    }
    path[index] = saved;
  }
  return CreateDirectoryW(path, NULL) || GetLastError() == ERROR_ALREADY_EXISTS;
}

static bool remove_tree(const wchar_t *root) {
  DWORD attributes = GetFileAttributesW(root);
  if (attributes == INVALID_FILE_ATTRIBUTES) return GetLastError() == ERROR_FILE_NOT_FOUND;
  if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    SetFileAttributesW(root, FILE_ATTRIBUTE_NORMAL);
    return DeleteFileW(root) != 0;
  }

  wchar_t pattern[ANVIL_RUNTIME_PATH_CAPACITY];
  if (wcslen(root) + 3 > ANVIL_RUNTIME_PATH_CAPACITY) return false;
  wcscpy(pattern, root);
  wcscat(pattern, L"\\*");

  WIN32_FIND_DATAW item;
  HANDLE search = FindFirstFileW(pattern, &item);
  if (search != INVALID_HANDLE_VALUE) {
    do {
      if (wcscmp(item.cFileName, L".") == 0 || wcscmp(item.cFileName, L"..") == 0) continue;
      wchar_t child[ANVIL_RUNTIME_PATH_CAPACITY];
      wcscpy(child, root);
      if (!append_path(child, ANVIL_RUNTIME_PATH_CAPACITY, item.cFileName)
          || !remove_tree(child)) {
        FindClose(search);
        return false;
      }
    } while (FindNextFileW(search, &item));
    FindClose(search);
  }
  SetFileAttributesW(root, FILE_ATTRIBUTE_NORMAL);
  return RemoveDirectoryW(root) != 0;
}

static bool file_exists(const wchar_t *path) {
  DWORD attributes = GetFileAttributesW(path);
  return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

static bool complete_runtime_exists(const wchar_t *target) {
  wchar_t marker[ANVIL_RUNTIME_PATH_CAPACITY];
  wchar_t start_file[ANVIL_RUNTIME_PATH_CAPACITY];
  wcscpy(marker, target);
  wcscpy(start_file, target);
  return append_path(marker, ANVIL_RUNTIME_PATH_CAPACITY, L".complete")
      && append_path(start_file, ANVIL_RUNTIME_PATH_CAPACITY, L"data\\core\\start.lua")
      && file_exists(marker) && file_exists(start_file);
}

static bool utf8_to_wide(const char *text, int length, wchar_t *output, size_t capacity) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, length, NULL, 0);
  if (count <= 0 || (size_t)count + 1 > capacity) return false;
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, length, output, count) != count) {
    return false;
  }
  output[count] = L'\0';
  for (int index = 0; index < count; index++) {
    if (output[index] == L'/') output[index] = L'\\';
  }
  return true;
}

static bool wide_to_utf8(const wchar_t *text, char *output, size_t capacity) {
  int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
  if (count <= 0 || (size_t)count > capacity) return false;
  return WideCharToMultiByte(CP_UTF8, 0, text, -1, output, count, NULL, NULL) == count;
}

static bool safe_archive_name(const char *name, size_t length) {
  if (length == 0 || name[0] == '/' || name[0] == '\\') return false;
  if (length >= 2 && name[1] == ':') return false;
  size_t component_start = 0;
  for (size_t index = 0; index <= length; index++) {
    if (index < length && name[index] != '/' && name[index] != '\\') continue;
    size_t component_length = index - component_start;
    if (component_length == 0) return false;
    if (component_length == 1 && name[component_start] == '.') return false;
    if (component_length == 2 && name[component_start] == '.' && name[component_start + 1] == '.') {
      return false;
    }
    component_start = index + 1;
  }
  return true;
}

static bool write_all(HANDLE file, const uint8_t *data, size_t size) {
  while (size > 0) {
    DWORD chunk = size > UINT32_MAX ? UINT32_MAX : (DWORD)size;
    DWORD written = 0;
    if (!WriteFile(file, data, chunk, &written, NULL) || written == 0) return false;
    data += written;
    size -= written;
  }
  return true;
}

static bool extract_archive(
  const uint8_t *archive,
  size_t archive_size,
  const wchar_t *data_root,
  char *error,
  size_t error_size
) {
  const uint8_t *cursor = archive;
  const uint8_t *end = archive + archive_size;
  char magic[8];
  uint8_t identifier[16];
  uint32_t file_count = 0;
  if (!read_bytes(&cursor, end, magic, sizeof(magic))
      || memcmp(magic, ANVIL_RUNTIME_MAGIC, sizeof(magic)) != 0
      || !read_bytes(&cursor, end, identifier, sizeof(identifier))
      || !read_u32(&cursor, end, &file_count)
      || file_count == 0 || file_count > ANVIL_RUNTIME_MAX_FILES) {
    set_error(error, error_size, "The embedded runtime header is invalid.");
    return false;
  }

  for (uint32_t file_index = 0; file_index < file_count; file_index++) {
    uint16_t name_length = 0;
    uint64_t raw_size = 0;
    uint64_t compressed_size = 0;
    uint32_t expected_crc = 0;
    if (!read_u16(&cursor, end, &name_length)
        || !read_u64(&cursor, end, &raw_size)
        || !read_u64(&cursor, end, &compressed_size)
        || !read_u32(&cursor, end, &expected_crc)
        || name_length == 0
        || raw_size > ANVIL_RUNTIME_MAX_FILE_SIZE
        || compressed_size > (uint64_t)(end - cursor)
        || (uint64_t)(end - cursor) < (uint64_t)name_length + compressed_size) {
      set_error(error, error_size, "The embedded runtime entry %u is invalid.", file_index);
      return false;
    }

    const char *name = (const char *)cursor;
    cursor += name_length;
    if (!safe_archive_name(name, name_length)) {
      set_error(error, error_size, "The embedded runtime contains an unsafe path.");
      return false;
    }

    wchar_t relative[2048];
    if (!utf8_to_wide(name, name_length, relative, sizeof(relative) / sizeof(relative[0]))) {
      set_error(error, error_size, "The embedded runtime contains an invalid path.");
      return false;
    }

    wchar_t output_path[ANVIL_RUNTIME_PATH_CAPACITY];
    wcscpy(output_path, data_root);
    if (!append_path(output_path, ANVIL_RUNTIME_PATH_CAPACITY, relative)) {
      set_error(error, error_size, "An embedded runtime path is too long.");
      return false;
    }

    wchar_t parent[ANVIL_RUNTIME_PATH_CAPACITY];
    wcscpy(parent, output_path);
    wchar_t *separator = wcsrchr(parent, L'\\');
    if (!separator) {
      set_error(error, error_size, "An embedded runtime path has no parent.");
      return false;
    }
    *separator = L'\0';
    if (!create_directory_tree(parent)) {
      set_error(error, error_size, "Cannot create an embedded runtime directory (Windows error %lu).", GetLastError());
      return false;
    }

    size_t allocation_size = raw_size > 0 ? (size_t)raw_size : 1;
    uint8_t *raw = HeapAlloc(GetProcessHeap(), 0, allocation_size);
    if (!raw) {
      set_error(error, error_size, "Not enough memory to extract the embedded runtime.");
      return false;
    }
    uLongf produced = (uLongf)allocation_size;
    int zlib_result = uncompress(raw, &produced, cursor, (uLong)compressed_size);
    cursor += compressed_size;
    uint32_t actual_crc = (uint32_t)crc32(0L, raw, (uInt)raw_size);
    if (zlib_result != Z_OK || produced != raw_size || actual_crc != expected_crc) {
      HeapFree(GetProcessHeap(), 0, raw);
      set_error(error, error_size, "Embedded runtime entry %u failed validation.", file_index);
      return false;
    }

    HANDLE file = CreateFileW(
      output_path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL
    );
    bool wrote = file != INVALID_HANDLE_VALUE && write_all(file, raw, (size_t)raw_size);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    HeapFree(GetProcessHeap(), 0, raw);
    if (!wrote) {
      set_error(error, error_size, "Cannot write an embedded runtime file (Windows error %lu).", GetLastError());
      return false;
    }
  }

  if (cursor != end) {
    set_error(error, error_size, "The embedded runtime has trailing data.");
    return false;
  }
  return true;
}

static bool get_runtime_root(wchar_t *root, size_t capacity) {
  DWORD override_length = GetEnvironmentVariableW(
    L"ANVIL_EMBEDDED_RUNTIME_ROOT", root, (DWORD)capacity
  );
  if (override_length > 0 && override_length < capacity) return true;

  wchar_t local_app_data[MAX_PATH];
  if (SHGetFolderPathW(
        NULL, CSIDL_LOCAL_APPDATA | CSIDL_FLAG_CREATE, NULL,
        SHGFP_TYPE_CURRENT, local_app_data) != S_OK) {
    return false;
  }
  if (wcslen(local_app_data) + 24 > capacity) {
    return false;
  }
  wcscpy(root, local_app_data);
  return append_path(root, capacity, L"Anvil\\runtime");
}

static bool write_marker(const wchar_t *target, const char *identifier) {
  wchar_t marker[ANVIL_RUNTIME_PATH_CAPACITY];
  wcscpy(marker, target);
  if (!append_path(marker, ANVIL_RUNTIME_PATH_CAPACITY, L".complete")) return false;
  HANDLE file = CreateFileW(marker, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE) return false;
  bool result = write_all(file, (const uint8_t *)identifier, strlen(identifier));
  CloseHandle(file);
  return result;
}

bool anvil_embedded_runtime_prepare(
  char *datadir_utf8,
  size_t datadir_size,
  char *error,
  size_t error_size
) {
  HMODULE module = GetModuleHandleW(NULL);
  HRSRC resource = FindResourceW(
    module, MAKEINTRESOURCEW(ANVIL_RUNTIME_RESOURCE_ID), MAKEINTRESOURCEW(10)
  );
  if (!resource) {
    set_error(error, error_size, "This executable has no embedded Anvil runtime.");
    return false;
  }
  HGLOBAL loaded = LoadResource(module, resource);
  const uint8_t *archive = loaded ? LockResource(loaded) : NULL;
  DWORD archive_size = SizeofResource(module, resource);
  if (!archive || archive_size < 28) {
    set_error(error, error_size, "The embedded Anvil runtime cannot be read.");
    return false;
  }
  if (memcmp(archive, ANVIL_RUNTIME_MAGIC, 8) != 0) {
    set_error(error, error_size, "The embedded Anvil runtime has an invalid signature.");
    return false;
  }

  char identifier[33];
  for (int index = 0; index < 16; index++) {
    snprintf(identifier + index * 2, 3, "%02x", archive[8 + index]);
  }
  identifier[32] = '\0';

  wchar_t root[ANVIL_RUNTIME_PATH_CAPACITY] = L"";
  if (!get_runtime_root(root, ANVIL_RUNTIME_PATH_CAPACITY)
      || !create_directory_tree(root)) {
    set_error(error, error_size, "Cannot create the Anvil runtime root (Windows error %lu).", GetLastError());
    return false;
  }

  wchar_t identifier_wide[33];
  if (!utf8_to_wide(identifier, 32, identifier_wide, 33)) {
    set_error(error, error_size, "The embedded runtime identifier is invalid.");
    return false;
  }

  wchar_t mutex_name[96];
  swprintf(mutex_name, 96, L"Local\\Anvil.EmbeddedRuntime.%ls", identifier_wide);
  HANDLE mutex = CreateMutexW(NULL, FALSE, mutex_name);
  if (!mutex) {
    set_error(error, error_size, "Cannot create the embedded runtime lock.");
    return false;
  }
  DWORD wait = WaitForSingleObject(mutex, 60000);
  if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
    CloseHandle(mutex);
    set_error(error, error_size, "Timed out while waiting for embedded runtime extraction.");
    return false;
  }

  bool success = false;
  wchar_t target[ANVIL_RUNTIME_PATH_CAPACITY];
  wcscpy(target, root);
  if (!append_path(target, ANVIL_RUNTIME_PATH_CAPACITY, identifier_wide)) {
    set_error(error, error_size, "The embedded runtime target path is too long.");
    goto finish;
  }

  if (!complete_runtime_exists(target)) {
    if (GetFileAttributesW(target) != INVALID_FILE_ATTRIBUTES && !remove_tree(target)) {
      set_error(error, error_size, "Cannot remove an incomplete embedded runtime.");
      goto finish;
    }

    wchar_t temporary[ANVIL_RUNTIME_PATH_CAPACITY];
    swprintf(
      temporary, ANVIL_RUNTIME_PATH_CAPACITY, L"%ls\\%ls.tmp",
      root, identifier_wide
    );
    if (GetFileAttributesW(temporary) != INVALID_FILE_ATTRIBUTES && !remove_tree(temporary)) {
      set_error(error, error_size, "Cannot remove a stale embedded runtime directory.");
      goto finish;
    }

    wchar_t temporary_data[ANVIL_RUNTIME_PATH_CAPACITY];
    wcscpy(temporary_data, temporary);
    if (!append_path(temporary_data, ANVIL_RUNTIME_PATH_CAPACITY, L"data")
        || !create_directory_tree(temporary_data)) {
      set_error(error, error_size, "Cannot create the embedded runtime staging directory.");
      goto finish;
    }

    if (!extract_archive(archive, archive_size, temporary_data, error, error_size)
        || !write_marker(temporary, identifier)) {
      remove_tree(temporary);
      if (!error || !error[0]) {
        set_error(error, error_size, "Cannot complete embedded runtime extraction.");
      }
      goto finish;
    }

    if (!MoveFileExW(temporary, target, MOVEFILE_WRITE_THROUGH)) {
      DWORD move_error = GetLastError();
      remove_tree(temporary);
      set_error(error, error_size, "Cannot activate the embedded runtime (Windows error %lu).", move_error);
      goto finish;
    }
  }

  wchar_t datadir[ANVIL_RUNTIME_PATH_CAPACITY];
  wcscpy(datadir, target);
  if (!append_path(datadir, ANVIL_RUNTIME_PATH_CAPACITY, L"data")
      || !wide_to_utf8(datadir, datadir_utf8, datadir_size)) {
    set_error(error, error_size, "The embedded runtime data path is too long.");
    goto finish;
  }
  success = true;

finish:
  ReleaseMutex(mutex);
  CloseHandle(mutex);
  return success;
}

#else

bool anvil_embedded_runtime_prepare(
  char *datadir_utf8,
  size_t datadir_size,
  char *error,
  size_t error_size
) {
  (void)datadir_utf8;
  (void)datadir_size;
  if (error && error_size) {
    snprintf(error, error_size, "Embedded runtime extraction is only available on Windows.");
  }
  return false;
}

#endif
