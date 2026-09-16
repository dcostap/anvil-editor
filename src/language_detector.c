#include "language_detector.h"

/*
 * Scalar C port of the Betlang 0.1.1 inference path.
 * Betlang is Copyright (c) Dioxus Labs and uses the MIT License.
 */

#include <SDL3/SDL.h>

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MODEL_SIZE 47840u
#define SCALE_COUNT 6u
#define BINS 1024u
#define MAX_UNITS 2048u
#define EMBED 24u
#define CONV0_KERNEL 7u
#define CONV0_CHANNELS 64u
#define CONV0_POOL 4u
#define CONV1_KERNEL 5u
#define CONV1_CHANNELS 128u
#define CONV1_POOL 2u
#define CONV2_KERNEL 3u
#define CONV2_CHANNELS 128u
#define POOLED (CONV2_CHANNELS * 2u)
#define DENSE 96u
#define CLASSES ANVIL_LANGUAGE_DETECTOR_CLASS_COUNT
#define WORD_MASK 0x00ffffffu
#define PUNCT_FLAG 0x10000000u
#define INDENT_FLAG 0x20000000u
#define NUM_FLAG 0x40000000u
#define BRACKET_FLAG 0x50000000u

static const uint8_t model_magic[8] = { 0x4d, 0x53, 0x51, 0x31, 0x01, 0x00, 0x00, 0x00 };

static const char *language_slugs[CLASSES] = {
  "asm", "batch", "c", "clojure", "cmake", "cobol", "cpp", "cs",
  "css", "dart", "dockerfile", "elixir", "erlang", "gemfile", "gemspec", "go",
  "gradle", "groovy", "haskell", "html", "ini", "java", "javascript", "json",
  "julia", "kotlin", "lisp", "lua", "markdown", "objectivec", "ocaml", "perl",
  "php", "powershell", "python", "r", "ruby", "rust", "scala", "shell", "sql",
  "swift", "toml", "typescript", "vba", "verilog", "xml", "yaml"
};

typedef struct Model {
  float *embedding;
  float *conv0_kernel;
  float conv0_bias[CONV0_CHANNELS];
  float *conv1_kernel;
  float conv1_bias[CONV1_CHANNELS];
  float *conv2_kernel;
  float conv2_bias[CONV2_CHANNELS];
  float *dense_kernel;
  float dense_bias[DENSE];
  float *output_kernel;
  float output_bias[CLASSES];
} Model;

typedef enum TokenKind {
  TOKEN_EMPTY,
  TOKEN_WORD,
  TOKEN_NUMBER,
  TOKEN_PUNCT,
} TokenKind;

typedef struct TokenBuffer {
  TokenKind kind;
  uint8_t bytes[2048];
  size_t len;
} TokenBuffer;

const char *anvil_language_detector_slug(size_t index) {
  return index < CLASSES ? language_slugs[index] : NULL;
}

static void set_error(char **error, const char *message) {
  if (!error || *error) return;
  *error = SDL_strdup(message ? message : "language detection failed");
}

static float read_f32(const uint8_t *bytes) {
  uint32_t bits = (uint32_t)bytes[0]
    | ((uint32_t)bytes[1] << 8)
    | ((uint32_t)bytes[2] << 16)
    | ((uint32_t)bytes[3] << 24);
  float value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

static bool read_f32_array(
  const uint8_t *bytes, size_t len, size_t *cursor, float *out, size_t count
) {
  if (*cursor > len || count > (len - *cursor) / 4u) return false;
  for (size_t i = 0; i < count; i++) out[i] = read_f32(bytes + *cursor + i * 4u);
  *cursor += count * 4u;
  return true;
}

static float *read_int4(
  const uint8_t *bytes, size_t len, size_t *cursor, size_t count, float scale
) {
  size_t byte_count = (count + 1u) / 2u;
  if (*cursor > len || byte_count > len - *cursor) return NULL;
  float *out = (float *)SDL_malloc(count * sizeof(*out));
  if (!out) return NULL;
  for (size_t i = 0; i < count; i++) {
    uint8_t packed = bytes[*cursor + i / 2u];
    int value = (int)((i & 1u) ? packed >> 4 : packed & 0x0f) - 8;
    out[i] = (float)value * scale;
  }
  *cursor += byte_count;
  return out;
}

static float *read_ternary(
  const uint8_t *bytes, size_t len, size_t *cursor, size_t count, float scale
) {
  size_t byte_count = (count + 3u) / 4u;
  if (*cursor > len || byte_count > len - *cursor) return NULL;
  float *out = (float *)SDL_malloc(count * sizeof(*out));
  if (!out) return NULL;
  for (size_t i = 0; i < count; i++) {
    uint8_t code = (bytes[*cursor + i / 4u] >> ((i & 3u) * 2u)) & 3u;
    out[i] = code == 0 ? -scale : (code == 2 ? scale : 0.0f);
  }
  *cursor += byte_count;
  return out;
}

static void free_model(Model *model) {
  if (!model) return;
  SDL_free(model->embedding);
  SDL_free(model->conv0_kernel);
  SDL_free(model->conv1_kernel);
  SDL_free(model->conv2_kernel);
  SDL_free(model->dense_kernel);
  SDL_free(model->output_kernel);
  memset(model, 0, sizeof(*model));
}

static bool load_model(const char *path, Model *model, char **error) {
  bool ok = false;
  FILE *file = NULL;
  uint8_t *bytes = NULL;
  size_t cursor = 0;
  float scales[SCALE_COUNT];
  memset(model, 0, sizeof(*model));

  file = fopen(path, "rb");
  if (!file) {
    set_error(error, "could not open the language detection model");
    goto done;
  }
  bytes = (uint8_t *)SDL_malloc(MODEL_SIZE);
  if (!bytes) {
    set_error(error, "out of memory loading the language detection model");
    goto done;
  }
  if (fread(bytes, 1, MODEL_SIZE, file) != MODEL_SIZE || fgetc(file) != EOF) {
    set_error(error, "the language detection model has an invalid size");
    goto done;
  }
  if (memcmp(bytes, model_magic, sizeof(model_magic)) != 0) {
    set_error(error, "the language detection model has an invalid header");
    goto done;
  }
  cursor = sizeof(model_magic);
  if (!read_f32_array(bytes, MODEL_SIZE, &cursor, scales, SCALE_COUNT)) goto invalid;
  model->embedding = read_int4(bytes, MODEL_SIZE, &cursor, BINS * EMBED, scales[0]);
  model->conv0_kernel = read_ternary(
    bytes, MODEL_SIZE, &cursor, CONV0_KERNEL * EMBED * CONV0_CHANNELS, scales[1]
  );
  if (!read_f32_array(bytes, MODEL_SIZE, &cursor, model->conv0_bias, CONV0_CHANNELS)) goto invalid;
  model->conv1_kernel = read_ternary(
    bytes, MODEL_SIZE, &cursor, CONV1_KERNEL * CONV0_CHANNELS * CONV1_CHANNELS, scales[2]
  );
  if (!read_f32_array(bytes, MODEL_SIZE, &cursor, model->conv1_bias, CONV1_CHANNELS)) goto invalid;
  model->conv2_kernel = read_ternary(
    bytes, MODEL_SIZE, &cursor, CONV2_KERNEL * CONV1_CHANNELS * CONV2_CHANNELS, scales[3]
  );
  if (!read_f32_array(bytes, MODEL_SIZE, &cursor, model->conv2_bias, CONV2_CHANNELS)) goto invalid;
  model->dense_kernel = read_ternary(bytes, MODEL_SIZE, &cursor, POOLED * DENSE, scales[4]);
  if (!read_f32_array(bytes, MODEL_SIZE, &cursor, model->dense_bias, DENSE)) goto invalid;
  model->output_kernel = read_int4(bytes, MODEL_SIZE, &cursor, DENSE * CLASSES, scales[5]);
  if (!read_f32_array(bytes, MODEL_SIZE, &cursor, model->output_bias, CLASSES)) goto invalid;
  if (!model->embedding || !model->conv0_kernel || !model->conv1_kernel
      || !model->conv2_kernel || !model->dense_kernel || !model->output_kernel) {
    set_error(error, "out of memory decoding the language detection model");
    goto done;
  }
  if (cursor != MODEL_SIZE) goto invalid;
  ok = true;
  goto done;

invalid:
  set_error(error, "the language detection model is invalid");
done:
  if (file) fclose(file);
  SDL_free(bytes);
  if (!ok) free_model(model);
  return ok;
}

static float gelu(float x) {
  float inner = 0.7978846f * (x + 0.044715f * x * x * x);
  if (inner < -5.0f) inner = -5.0f;
  if (inner > 5.0f) inner = 5.0f;
  float x2 = inner * inner;
  float numerator = inner * (135135.0f + x2 * (17325.0f + x2 * (378.0f + x2)));
  float denominator = 135135.0f + x2 * (62370.0f + x2 * (3150.0f + x2 * 28.0f));
  return 0.5f * x * (1.0f + numerator / denominator);
}

static uint32_t hash_bytes(const uint8_t *bytes, size_t len) {
  uint32_t hash = 0;
  for (size_t i = 0; i < len; i++) hash = hash * 2654435761u + bytes[i];
  return hash;
}

static void flush_token(TokenBuffer *token, uint32_t *units, size_t *unit_count) {
  uint32_t flag;
  if (!token->len || *unit_count >= MAX_UNITS) return;
  switch (token->kind) {
    case TOKEN_NUMBER: flag = NUM_FLAG; break;
    case TOKEN_PUNCT: flag = PUNCT_FLAG; break;
    default: flag = 0; break;
  }
  units[(*unit_count)++] = (hash_bytes(token->bytes, token->len) & WORD_MASK) | flag;
  token->kind = TOKEN_EMPTY;
  token->len = 0;
}

static void push_token(
  TokenBuffer *token, TokenKind kind, uint8_t value, uint32_t *units, size_t *unit_count
) {
  if (token->kind != kind) {
    flush_token(token, units, unit_count);
    token->kind = kind;
  }
  if (token->len < sizeof(token->bytes)) token->bytes[token->len++] = value;
}

static void push_indent(uint32_t indent, uint32_t *units, size_t *unit_count) {
  if (indent && *unit_count < MAX_UNITS) {
    units[(*unit_count)++] = (indent > 63u ? 63u : indent) | INDENT_FLAG;
  }
}

static size_t build_window(const char *source, size_t source_len, uint8_t window[2048]) {
  if (!source_len) return 0;
  size_t block = source_len < 4096u ? source_len : 4096u;
  size_t begin_start = 0;
  while (begin_start < block && SDL_isspace((unsigned char)source[begin_start])) begin_start++;
  if (block - begin_start < 8u) return 0;
  size_t end_source_start = source_len - block;
  size_t end_source_end = source_len;
  while (end_source_end > end_source_start
      && SDL_isspace((unsigned char)source[end_source_end - 1u])) end_source_end--;
  size_t begin_len = block - begin_start;
  if (begin_len > 1024u) begin_len = 1024u;
  size_t end_len = end_source_end - end_source_start;
  if (end_len > 1024u) end_len = 1024u;
  memset(window, 0, 2048u);
  memcpy(window, source + begin_start, begin_len);
  size_t end_start = 1024u + (1024u - end_len);
  memcpy(window + end_start, source + end_source_end - end_len, end_len);
  if (begin_len < 1024u) return begin_len;
  if (end_start > 1024u) return 1024u;
  return 2048u;
}

static size_t tokenize(const uint8_t *bytes, size_t len, uint32_t units[MAX_UNITS]) {
  size_t unit_count = 0;
  bool at_line_start = true;
  uint32_t indent = 0;
  TokenBuffer token = { TOKEN_EMPTY, { 0 }, 0 };
  for (size_t i = 0; i < len && unit_count < MAX_UNITS; i++) {
    uint8_t value = bytes[i];
    if (value >= 'A' && value <= 'Z') value = (uint8_t)(value + ('a' - 'A'));
    bool letter = (value >= 'a' && value <= 'z') || value == '_';
    bool digit = value >= '0' && value <= '9';
    bool space = value == ' ' || value == '\t';
    bool bracket = value == '(' || value == ')' || value == '[' || value == ']'
      || value == '{' || value == '}';
    if (letter) {
      if (at_line_start) push_indent(indent, units, &unit_count);
      at_line_start = false; indent = 0;
      push_token(&token, TOKEN_WORD, value, units, &unit_count);
    } else if (digit || value == '.') {
      if (value == '.' && token.kind != TOKEN_NUMBER) {
        if (at_line_start) push_indent(indent, units, &unit_count);
        at_line_start = false; indent = 0;
        flush_token(&token, units, &unit_count);
        push_token(&token, TOKEN_PUNCT, value, units, &unit_count);
      } else {
        if (at_line_start) push_indent(indent, units, &unit_count);
        at_line_start = false; indent = 0;
        push_token(&token, TOKEN_NUMBER, value, units, &unit_count);
      }
    } else if (value == '\n') {
      flush_token(&token, units, &unit_count);
      if (at_line_start) push_indent(indent, units, &unit_count);
      if (unit_count < MAX_UNITS) units[unit_count++] = (uint32_t)'\n' | PUNCT_FLAG;
      at_line_start = true; indent = 0;
    } else if (value == '\r') {
      flush_token(&token, units, &unit_count);
    } else if (at_line_start && space) {
      indent += value == ' ' ? 1u : 4u;
    } else {
      if (at_line_start) push_indent(indent, units, &unit_count);
      at_line_start = false; indent = 0;
      if (space) {
        flush_token(&token, units, &unit_count);
        uint32_t space_unit = (uint32_t)' ' | PUNCT_FLAG;
        if ((!unit_count || units[unit_count - 1u] != space_unit) && unit_count < MAX_UNITS) {
          units[unit_count++] = space_unit;
        }
      } else if (bracket) {
        flush_token(&token, units, &unit_count);
        if (unit_count < MAX_UNITS) units[unit_count++] = (uint32_t)value | BRACKET_FLAG;
      } else {
        push_token(&token, TOKEN_PUNCT, value, units, &unit_count);
      }
    }
  }
  flush_token(&token, units, &unit_count);
  return unit_count;
}

static size_t hash_bin(uint32_t unit, size_t head) {
  static const uint32_t primes[4] = { 2654435761u, 2246822519u, 3266489917u, 668265263u };
  uint32_t hash = unit * primes[head & 3u];
  hash ^= hash >> 13;
  hash *= primes[(head + 1u) & 3u];
  return (size_t)(hash % BINS);
}

static void embed_units(
  const Model *model, const uint32_t *units, size_t unit_count, float *rows
) {
  memset(rows, 0, MAX_UNITS * EMBED * sizeof(*rows));
  for (size_t i = 0; i < unit_count; i++) {
    size_t bins[3] = { hash_bin(units[i], 0), hash_bin(units[i], 1), hash_bin(units[i], 2) };
    for (size_t c = 0; c < EMBED; c++) {
      float value = model->embedding[bins[0] * EMBED + c]
        + model->embedding[bins[1] * EMBED + c]
        + model->embedding[bins[2] * EMBED + c];
      rows[i * EMBED + c] = gelu(value);
    }
  }
}

static void conv_gelu_maxpool(
  const float *input, size_t input_rows, size_t input_channels,
  const float *kernel, size_t kernel_size, const float *bias,
  size_t output_channels, size_t pool_size, float *output
) {
  size_t output_rows = (input_rows + pool_size - 1u) / pool_size;
  for (size_t i = 0; i < output_rows * output_channels; i++) output[i] = -FLT_MAX;
  size_t padding = (kernel_size - 1u) / 2u;
  float accum[CONV1_CHANNELS];
  for (size_t row = 0; row < input_rows; row++) {
    memcpy(accum, bias, output_channels * sizeof(*accum));
    for (size_t k = 0; k < kernel_size; k++) {
      ptrdiff_t source_row = (ptrdiff_t)row + (ptrdiff_t)k - (ptrdiff_t)padding;
      if (source_row < 0 || (size_t)source_row >= input_rows) continue;
      const float *source = input + (size_t)source_row * input_channels;
      for (size_t channel = 0; channel < input_channels; channel++) {
        float value = source[channel];
        const float *weights = kernel + (k * input_channels + channel) * output_channels;
        for (size_t out = 0; out < output_channels; out++) {
          accum[out] += value * weights[out];
        }
      }
    }
    float *target = output + (row / pool_size) * output_channels;
    for (size_t out = 0; out < output_channels; out++) {
      float value = gelu(accum[out]);
      if (value > target[out]) target[out] = value;
    }
  }
}

static void dense(
  const float *input, size_t input_count, const float *kernel,
  const float *bias, size_t output_count, float *output
) {
  memcpy(output, bias, output_count * sizeof(*output));
  for (size_t i = 0; i < input_count; i++) {
    const float *weights = kernel + i * output_count;
    for (size_t out = 0; out < output_count; out++) output[out] += input[i] * weights[out];
  }
}

bool anvil_language_detect(
  const char *model_path,
  const char *source,
  size_t source_len,
  AnvilLanguageDetection *detection,
  char **error
) {
  if (error) *error = NULL;
  if (!model_path || !source || !detection) {
    set_error(error, "language detection requires a model, source, and result");
    return false;
  }
  memset(detection, 0, sizeof(*detection));
  uint8_t window[2048];
  size_t window_len = build_window(source, source_len, window);
  if (!window_len) return true;

  Model model;
  if (!load_model(model_path, &model, error)) return false;
  uint32_t units[MAX_UNITS];
  size_t unit_count = tokenize(window, window_len, units);
  float *embed = (float *)SDL_malloc(MAX_UNITS * EMBED * sizeof(*embed));
  float *pool0 = (float *)SDL_malloc((MAX_UNITS / CONV0_POOL) * CONV0_CHANNELS * sizeof(*pool0));
  float *pool1 = (float *)SDL_malloc(
    (MAX_UNITS / CONV0_POOL / CONV1_POOL) * CONV1_CHANNELS * sizeof(*pool1)
  );
  float *conv2 = (float *)SDL_malloc(
    (MAX_UNITS / CONV0_POOL / CONV1_POOL) * CONV2_CHANNELS * sizeof(*conv2)
  );
  if (!embed || !pool0 || !pool1 || !conv2) {
    set_error(error, "out of memory running language detection");
    SDL_free(embed); SDL_free(pool0); SDL_free(pool1); SDL_free(conv2);
    free_model(&model);
    return false;
  }

  embed_units(&model, units, unit_count, embed);
  conv_gelu_maxpool(embed, MAX_UNITS, EMBED, model.conv0_kernel, CONV0_KERNEL,
    model.conv0_bias, CONV0_CHANNELS, CONV0_POOL, pool0);
  conv_gelu_maxpool(pool0, MAX_UNITS / CONV0_POOL, CONV0_CHANNELS,
    model.conv1_kernel, CONV1_KERNEL, model.conv1_bias, CONV1_CHANNELS, CONV1_POOL, pool1);
  conv_gelu_maxpool(pool1, MAX_UNITS / CONV0_POOL / CONV1_POOL, CONV1_CHANNELS,
    model.conv2_kernel, CONV2_KERNEL, model.conv2_bias, CONV2_CHANNELS, 1u, conv2);

  float pooled[POOLED];
  size_t conv2_rows = MAX_UNITS / CONV0_POOL / CONV1_POOL;
  for (size_t channel = 0; channel < CONV2_CHANNELS; channel++) {
    float maximum = -FLT_MAX;
    float sum = 0.0f;
    for (size_t row = 0; row < conv2_rows; row++) {
      float value = conv2[row * CONV2_CHANNELS + channel];
      if (value > maximum) maximum = value;
      sum += value;
    }
    pooled[channel] = maximum;
    pooled[CONV2_CHANNELS + channel] = sum / (float)conv2_rows;
  }
  float hidden[DENSE];
  dense(pooled, POOLED, model.dense_kernel, model.dense_bias, DENSE, hidden);
  for (size_t i = 0; i < DENSE; i++) hidden[i] = gelu(hidden[i]);
  float logits[CLASSES];
  dense(hidden, DENSE, model.output_kernel, model.output_bias, CLASSES, logits);
  float maximum = -FLT_MAX;
  for (size_t i = 0; i < CLASSES; i++) if (logits[i] > maximum) maximum = logits[i];
  float denominator = 0.0f;
  for (size_t i = 0; i < CLASSES; i++) {
    detection->probabilities[i] = expf(logits[i] - maximum);
    denominator += detection->probabilities[i];
  }
  if (isfinite(denominator) && denominator > 0.0f) {
    for (size_t i = 0; i < CLASSES; i++) detection->probabilities[i] /= denominator;
  } else {
    memset(detection, 0, sizeof(*detection));
  }

  SDL_free(embed); SDL_free(pool0); SDL_free(pool1); SDL_free(conv2);
  free_model(&model);
  return true;
}
