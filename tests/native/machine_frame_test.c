#include <stdio.h>
#include <string.h>
#include "machine_frame.h"

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    return 1; \
  } \
} while (0)

/* A stored reply frame: request 258, JSON {"result":{}}, bytes "hi". Other Clients decode the same bytes. */
static const unsigned char stored_reply[] = {
  2, 0, 0, 1, 2, 0, 0, 0, 13, 0, 0, 0, 2,
  '{', '"', 'r', 'e', 's', 'u', 'l', 't', '"', ':', '{', '}', '}', 'h', 'i',
};

int main(void) {
  unsigned char header[ANVIL_MACHINE_FRAME_HEADER];
  AnvilMachineFrameHeader frame = { ANVIL_MACHINE_FRAME_REPLY, 258, 13, 2 };
  anvil_machine_frame_write_header(header, &frame);
  CHECK(!memcmp(header, stored_reply, sizeof(header)));

  /* A frame that arrives one byte at a time decodes once, when its last byte arrives. */
  AnvilMachineDecoder decoder;
  anvil_machine_decoder_init(&decoder, 1024, 1024);
  const unsigned char *json, *bytes;
  for (size_t i = 0; i < sizeof(stored_reply); i++) {
    CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == 0);
    CHECK(anvil_machine_decoder_feed(&decoder, stored_reply + i, 1));
  }
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == 1);
  CHECK(frame.type == ANVIL_MACHINE_FRAME_REPLY && frame.id == 258);
  CHECK(frame.json_length == 13 && !memcmp(json, "{\"result\":{}}", 13));
  CHECK(frame.bytes_length == 2 && !memcmp(bytes, "hi", 2));
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == 0);

  /* Two frames in one chunk decode in order. */
  unsigned char two[sizeof(stored_reply) * 2];
  memcpy(two, stored_reply, sizeof(stored_reply));
  memcpy(two + sizeof(stored_reply), stored_reply, sizeof(stored_reply));
  two[sizeof(stored_reply) + 4] = 3;
  CHECK(anvil_machine_decoder_feed(&decoder, two, sizeof(two)));
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == 1 && frame.id == 258);
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == 1 && frame.id == 259);
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == 0);
  anvil_machine_decoder_free(&decoder);

  /* A header with an unknown type or a length above the decoder's limit is invalid at once. */
  unsigned char bad[sizeof(stored_reply)];
  memcpy(bad, stored_reply, sizeof(bad));
  bad[0] = 9;
  anvil_machine_decoder_init(&decoder, 1024, 1024);
  CHECK(anvil_machine_decoder_feed(&decoder, bad, ANVIL_MACHINE_FRAME_HEADER));
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == -1);
  anvil_machine_decoder_free(&decoder);
  anvil_machine_decoder_init(&decoder, 1024, 1);
  CHECK(anvil_machine_decoder_feed(&decoder, stored_reply, ANVIL_MACHINE_FRAME_HEADER));
  CHECK(anvil_machine_decoder_next(&decoder, &frame, &json, &bytes) == -1);
  anvil_machine_decoder_free(&decoder);
  return 0;
}
