#ifndef ANVIL_FILE_TRASH_H
#define ANVIL_FILE_TRASH_H

#include <stdbool.h>
#include <stddef.h>

/* Blocking operation. Call from a worker, not the UI or server loop. */
bool anvil_file_trash(const char *const *paths, size_t count, char *error, size_t error_size);

#endif
