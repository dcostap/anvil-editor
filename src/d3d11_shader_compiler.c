#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3dcompiler.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

static bool read_file(const char *path, char **data, size_t *size) {
  FILE *file = fopen(path, "rb");
  if (!file) return false;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return false;
  }
  long length = ftell(file);
  if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return false;
  }
  char *buffer = malloc((size_t)length);
  if (!buffer) {
    fclose(file);
    return false;
  }
  bool ok = fread(buffer, 1, (size_t)length, file) == (size_t)length;
  fclose(file);
  if (!ok) {
    free(buffer);
    return false;
  }
  *data = buffer;
  *size = (size_t)length;
  return true;
}

static ID3DBlob *compile_shader(const char *source, size_t source_size,
                                const char *source_path, const char *entry,
                                const char *profile) {
  ID3DBlob *bytecode = NULL;
  ID3DBlob *errors = NULL;
  HRESULT result = D3DCompile(
    source, source_size, source_path, NULL, NULL, entry, profile,
    D3DCOMPILE_ENABLE_STRICTNESS, 0, &bytecode, &errors
  );
  if (FAILED(result)) {
    fprintf(stderr, "Failed to compile %s as %s (0x%08lx).\n",
            entry, profile, (unsigned long)result);
    if (errors) {
      fwrite(errors->lpVtbl->GetBufferPointer(errors), 1,
             errors->lpVtbl->GetBufferSize(errors), stderr);
      fputc('\n', stderr);
    }
  }
  if (errors) errors->lpVtbl->Release(errors);
  return SUCCEEDED(result) ? bytecode : NULL;
}

static bool write_byte_array(FILE *file, const char *name, ID3DBlob *blob) {
  const unsigned char *bytes = blob->lpVtbl->GetBufferPointer(blob);
  size_t size = blob->lpVtbl->GetBufferSize(blob);
  if (fprintf(file, "static const unsigned char %s[] = {\n", name) < 0) return false;
  for (size_t offset = 0; offset < size; offset++) {
    if (offset % 12 == 0 && fputs("  ", file) == EOF) return false;
    if (fprintf(file, "0x%02x%s", bytes[offset], offset + 1 == size ? "" : ", ") < 0) {
      return false;
    }
    if (offset % 12 == 11 || offset + 1 == size) {
      if (fputc('\n', file) == EOF) return false;
    }
  }
  return fputs("};\n\n", file) != EOF;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "Usage: %s INPUT.hlsl OUTPUT.h\n", argv[0]);
    return 2;
  }

  char *source = NULL;
  size_t source_size = 0;
  if (!read_file(argv[1], &source, &source_size)) {
    fprintf(stderr, "Failed to read %s.\n", argv[1]);
    return 1;
  }

  ID3DBlob *vertex = compile_shader(source, source_size, argv[1], "vs_main", "vs_4_0");
  ID3DBlob *pixel = compile_shader(source, source_size, argv[1], "ps_main", "ps_4_0");
  free(source);
  if (!vertex || !pixel) {
    if (vertex) vertex->lpVtbl->Release(vertex);
    if (pixel) pixel->lpVtbl->Release(pixel);
    return 1;
  }

  FILE *output = fopen(argv[2], "wb");
  if (!output) {
    fprintf(stderr, "Failed to open %s.\n", argv[2]);
    vertex->lpVtbl->Release(vertex);
    pixel->lpVtbl->Release(pixel);
    return 1;
  }

  bool ok = fputs(
    "/* Generated from d3d11_quad.hlsl. Do not edit. */\n"
    "#ifndef ANVIL_D3D11_QUAD_SHADER_H\n"
    "#define ANVIL_D3D11_QUAD_SHADER_H\n\n",
    output
  ) != EOF;
  ok = ok && write_byte_array(output, "anvil_quad_vertex_shader", vertex);
  ok = ok && write_byte_array(output, "anvil_quad_pixel_shader", pixel);
  ok = ok && fputs("#endif\n", output) != EOF;
  ok = fclose(output) == 0 && ok;

  vertex->lpVtbl->Release(vertex);
  pixel->lpVtbl->Release(pixel);
  if (!ok) {
    remove(argv[2]);
    fprintf(stderr, "Failed to write %s.\n", argv[2]);
    return 1;
  }
  return 0;
}
