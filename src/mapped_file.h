#ifndef ANVIL_MAPPED_FILE_H
#define ANVIL_MAPPED_FILE_H

#include <stdbool.h>
#include <stddef.h>

// A read-only view of a whole file. The OS shares its pages between all views of the file,
// so they add no private memory.
typedef struct {
  const unsigned char *data;
  size_t size;
} AnvilMappedFile;

// Maps the file at the UTF-8 `path`. On failure it returns false and sets the SDL error.
// An empty file cannot be mapped.
bool anvil_mapped_file_open(const char *path, AnvilMappedFile *file);
void anvil_mapped_file_close(AnvilMappedFile *file);

#endif
