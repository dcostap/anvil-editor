#ifndef ANVIL_EMBEDDED_RUNTIME_H
#define ANVIL_EMBEDDED_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>

#define ANVIL_RUNTIME_RESOURCE_ID 201

bool anvil_embedded_runtime_prepare(
  char *datadir_utf8,
  size_t datadir_size,
  char *error,
  size_t error_size
);

#endif
