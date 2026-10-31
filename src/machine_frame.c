#include "machine_frame.h"
#include <stdlib.h>
#include <string.h>

static void write_u32(uint8_t *out, uint32_t value) {
  out[0] = (uint8_t)(value >> 24); out[1] = (uint8_t)(value >> 16);
  out[2] = (uint8_t)(value >> 8); out[3] = (uint8_t)value;
}

static uint32_t read_u32(const uint8_t *in) {
  return (uint32_t)in[0] << 24 | (uint32_t)in[1] << 16 | (uint32_t)in[2] << 8 | in[3];
}

void anvil_machine_frame_write_header(uint8_t out[ANVIL_MACHINE_FRAME_HEADER], const AnvilMachineFrameHeader *header) {
  out[0] = header->type;
  write_u32(out + 1, header->id);
  write_u32(out + 5, header->json_length);
  write_u32(out + 9, header->bytes_length);
}

void anvil_machine_decoder_init(AnvilMachineDecoder *decoder, uint32_t max_json, uint32_t max_bytes) {
  memset(decoder, 0, sizeof(*decoder));
  decoder->max_json = max_json < ANVIL_MACHINE_FRAME_MAX_JSON ? max_json : ANVIL_MACHINE_FRAME_MAX_JSON;
  decoder->max_bytes = max_bytes < ANVIL_MACHINE_FRAME_MAX_BYTES ? max_bytes : ANVIL_MACHINE_FRAME_MAX_BYTES;
}

void anvil_machine_decoder_free(AnvilMachineDecoder *decoder) {
  free(decoder->data);
  memset(decoder, 0, sizeof(*decoder));
}

bool anvil_machine_decoder_feed(AnvilMachineDecoder *decoder, const void *data, size_t length) {
  if (decoder->start > 0) {
    decoder->length -= decoder->start;
    memmove(decoder->data, decoder->data + decoder->start, decoder->length);
    decoder->start = 0;
  }
  if (length > SIZE_MAX - decoder->length) return false;
  if (decoder->length + length > decoder->capacity) {
    size_t capacity = decoder->capacity ? decoder->capacity : 4096;
    while (capacity < decoder->length + length) capacity = capacity > SIZE_MAX / 2 ? decoder->length + length : capacity * 2;
    uint8_t *grown = realloc(decoder->data, capacity);
    if (!grown) return false;
    decoder->data = grown;
    decoder->capacity = capacity;
  }
  memcpy(decoder->data + decoder->length, data, length);
  decoder->length += length;
  return true;
}

int anvil_machine_decoder_next(AnvilMachineDecoder *decoder, AnvilMachineFrameHeader *header,
    const uint8_t **json, const uint8_t **bytes) {
  size_t available = decoder->length - decoder->start;
  if (available < ANVIL_MACHINE_FRAME_HEADER) return 0;
  const uint8_t *in = decoder->data + decoder->start;
  header->type = in[0];
  header->id = read_u32(in + 1);
  header->json_length = read_u32(in + 5);
  header->bytes_length = read_u32(in + 9);
  if ((header->type != ANVIL_MACHINE_FRAME_REQUEST && header->type != ANVIL_MACHINE_FRAME_REPLY)
      || header->json_length > decoder->max_json || header->bytes_length > decoder->max_bytes) return -1;
  size_t size = ANVIL_MACHINE_FRAME_HEADER + (size_t)header->json_length + header->bytes_length;
  if (available < size) return 0;
  *json = in + ANVIL_MACHINE_FRAME_HEADER;
  *bytes = *json + header->json_length;
  decoder->start += size;
  return 1;
}
