#ifndef ANVIL_FILE_DRAG_H
#define ANVIL_FILE_DRAG_H

#include <stdbool.h>
#include <stddef.h>

/* A file drag list is UTF-8 paths, each ended by a NUL byte. It has at least one path and no empty path. */
bool anvil_file_drag_list_valid(const char *list, size_t size);

#ifdef _WIN32
#include <windows.h>
/* Drags the files to other programs, as Explorer does. The left button must be down. Blocks in the Windows drag
 * loop until the drop or the cancel. Paths that Windows cannot parse are left out. Returns false when no
 * path remains or the drag could not start. */
bool anvil_file_drag_run(HWND hwnd, const char *list, size_t size);
#endif

#endif
