#ifndef ANVIL_MACHINE_FRAME_H
#define ANVIL_MACHINE_FRAME_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* One Machine protocol frame: a 13-byte header, a JSON body, then raw bytes.
 * The header holds the type (1 byte), then the request ID, the JSON length and
 * the byte length (4 bytes each, big-endian). A reply carries its request's ID.
 * This file has no Lua or SDL headers, so the Companion uses it too. */
#define ANVIL_MACHINE_FRAME_HEADER 13
#define ANVIL_MACHINE_FRAME_MAX_JSON (1u << 20)
#define ANVIL_MACHINE_FRAME_MAX_BYTES (64u << 20)

enum { ANVIL_MACHINE_FRAME_REQUEST = 1, ANVIL_MACHINE_FRAME_REPLY = 2 };

typedef struct {
  uint8_t type;
  uint32_t id;
  uint32_t json_length;
  uint32_t bytes_length;
} AnvilMachineFrameHeader;

void anvil_machine_frame_write_header(uint8_t out[ANVIL_MACHINE_FRAME_HEADER], const AnvilMachineFrameHeader *header);

/* Collects received data and splits it into frames. Each limit applies before the body arrives. */
typedef struct {
  uint8_t *data;
  size_t length, capacity, start;
  uint32_t max_json, max_bytes;
} AnvilMachineDecoder;

void anvil_machine_decoder_init(AnvilMachineDecoder *decoder, uint32_t max_json, uint32_t max_bytes);
void anvil_machine_decoder_free(AnvilMachineDecoder *decoder);
/* Returns false when memory runs out. */
bool anvil_machine_decoder_feed(AnvilMachineDecoder *decoder, const void *data, size_t length);
/* Returns 1 for a frame, 0 when it needs more data, and -1 for an invalid header.
 * The JSON and byte pointers stay valid until the next feed. After -1, close the connection. */
int anvil_machine_decoder_next(AnvilMachineDecoder *decoder, AnvilMachineFrameHeader *header,
  const uint8_t **json, const uint8_t **bytes);
#endif
