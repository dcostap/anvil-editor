#ifndef ANVIL_SHARED_FILE_H
#define ANVIL_SHARED_FILE_H

#include <windows.h>
#include <stdbool.h>

/* Writers hold the per-path lock through replacement and name publication. */
HANDLE anvil_file_replace_begin(const wchar_t *path, DWORD *error);
bool anvil_file_replace_end(HANDLE lock, const wchar_t *path, bool replaced, DWORD *error);
/* Open readers keep their old file. A missing name is checked again under the writer's lock. */
HANDLE anvil_shared_file_open(const wchar_t *path, DWORD *error);

#endif
