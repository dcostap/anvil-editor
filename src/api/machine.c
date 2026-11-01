#include "api.h"
#include <stdint.h>
#include <psa/crypto.h>
#include "../machine_frame.h"
#ifdef _WIN32
#include <windows.h>
#include <dpapi.h>
#include <SDL3/SDL.h>
#include "../utfconv.h"
#else
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <unistd.h>
#endif

#define API_TYPE_MACHINE_DECODER "MachineDecoder"

static const char *const frame_types[] = { "request", "reply", NULL };

/* machine.frame(type, id, json[, bytes]) returns one encoded frame. */
static int f_frame(lua_State *L) {
  AnvilMachineFrameHeader header;
  header.type = (uint8_t)(luaL_checkoption(L, 1, NULL, frame_types) + 1);
  lua_Integer id = luaL_checkinteger(L, 2);
  size_t json_length, bytes_length = 0;
  const char *json = luaL_checklstring(L, 3, &json_length);
  const char *bytes = luaL_optlstring(L, 4, "", &bytes_length);
  luaL_argcheck(L, id >= 0 && id <= UINT32_MAX, 2, "request ID out of range");
  luaL_argcheck(L, json_length <= ANVIL_MACHINE_FRAME_MAX_JSON, 3, "JSON too large");
  luaL_argcheck(L, bytes_length <= ANVIL_MACHINE_FRAME_MAX_BYTES, 4, "bytes too large");
  header.id = (uint32_t)id;
  header.json_length = (uint32_t)json_length;
  header.bytes_length = (uint32_t)bytes_length;
  uint8_t out[ANVIL_MACHINE_FRAME_HEADER];
  anvil_machine_frame_write_header(out, &header);
  luaL_Buffer buffer;
  luaL_buffinit(L, &buffer);
  luaL_addlstring(&buffer, (const char *)out, sizeof(out));
  luaL_addlstring(&buffer, json, json_length);
  luaL_addlstring(&buffer, bytes, bytes_length);
  luaL_pushresult(&buffer);
  return 1;
}

static uint32_t check_limit(lua_State *L, int index, lua_Integer fallback) {
  lua_Integer limit = luaL_optinteger(L, index, fallback);
  luaL_argcheck(L, limit >= 0, index, "negative limit");
  return limit > UINT32_MAX ? UINT32_MAX : (uint32_t)limit;
}

/* machine.decoder([max_json, max_bytes]) returns a decoder for one connection. */
static int f_decoder(lua_State *L) {
  uint32_t max_json = check_limit(L, 1, ANVIL_MACHINE_FRAME_MAX_JSON);
  uint32_t max_bytes = check_limit(L, 2, ANVIL_MACHINE_FRAME_MAX_BYTES);
  AnvilMachineDecoder *decoder = lua_newuserdata(L, sizeof(AnvilMachineDecoder));
  anvil_machine_decoder_init(decoder, max_json, max_bytes);
  luaL_setmetatable(L, API_TYPE_MACHINE_DECODER);
  return 1;
}

/* decoder:limits(max_json, max_bytes) applies from the next frame header. */
static int m_decoder_limits(lua_State *L) {
  AnvilMachineDecoder *decoder = luaL_checkudata(L, 1, API_TYPE_MACHINE_DECODER);
  decoder->max_json = check_limit(L, 2, ANVIL_MACHINE_FRAME_MAX_JSON);
  decoder->max_bytes = check_limit(L, 3, ANVIL_MACHINE_FRAME_MAX_BYTES);
  return 0;
}

static int m_decoder_feed(lua_State *L) {
  AnvilMachineDecoder *decoder = luaL_checkudata(L, 1, API_TYPE_MACHINE_DECODER);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  if (!anvil_machine_decoder_feed(decoder, data, length)) return luaL_error(L, "out of memory");
  return 0;
}

/* Returns type, id, json, bytes for the next frame; nothing when it needs more data; or nil, error. */
static int m_decoder_next(lua_State *L) {
  AnvilMachineDecoder *decoder = luaL_checkudata(L, 1, API_TYPE_MACHINE_DECODER);
  AnvilMachineFrameHeader header;
  const uint8_t *json, *bytes;
  int status = anvil_machine_decoder_next(decoder, &header, &json, &bytes);
  if (status == 0) return 0;
  if (status < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "invalid frame");
    return 2;
  }
  lua_pushstring(L, frame_types[header.type - 1]);
  lua_pushinteger(L, header.id);
  lua_pushlstring(L, (const char *)json, header.json_length);
  lua_pushlstring(L, (const char *)bytes, header.bytes_length);
  return 4;
}

static int mm_decoder_gc(lua_State *L) {
  anvil_machine_decoder_free(luaL_checkudata(L, 1, API_TYPE_MACHINE_DECODER));
  return 0;
}

/* A file's content version: the SHA-256 of its bytes. Clients compare versions only for equality. */
static int f_content_version(lua_State *L) {
  size_t length;
  const char *bytes = luaL_checklstring(L, 1, &length);
  uint8_t hash[32];
  size_t hash_length = 0;
  if (psa_crypto_init() != PSA_SUCCESS ||
      psa_hash_compute(PSA_ALG_SHA_256, (const uint8_t *)bytes, length, hash, sizeof(hash), &hash_length) != PSA_SUCCESS)
    return luaL_error(L, "Cannot compute a content version");
  static const char hex[] = "0123456789abcdef";
  char text[64];
  for (size_t i = 0; i < sizeof(hash); i++) {
    text[i * 2] = hex[hash[i] >> 4];
    text[i * 2 + 1] = hex[hash[i] & 15];
  }
  lua_pushlstring(L, text, sizeof(text));
  return 1;
}

/* machine.protect(bytes) and machine.unprotect(bytes) keep a secret for the current Windows user with DPAPI.
   Other platforms return the bytes unchanged: their secrets rely on a private folder. Returns nil, error on failure. */
static int protect_data(lua_State *L, int unprotect) {
  size_t length;
  const char *bytes = luaL_checklstring(L, 1, &length);
#ifdef _WIN32
  DATA_BLOB in = { (DWORD)length, (BYTE *)bytes }, out = { 0 };
  BOOL ok = unprotect
    ? CryptUnprotectData(&in, NULL, NULL, NULL, NULL, CRYPTPROTECT_UI_FORBIDDEN, &out)
    : CryptProtectData(&in, L"Anvil Machine", NULL, NULL, NULL, CRYPTPROTECT_UI_FORBIDDEN, &out);
  if (!ok) {
    lua_pushnil(L);
    lua_pushfstring(L, "DPAPI failed with error %d", (int)GetLastError());
    return 2;
  }
  lua_pushlstring(L, (const char *)out.pbData, out.cbData);
  LocalFree(out.pbData);
#else
  (void)unprotect;
  lua_pushlstring(L, bytes, length);
#endif
  return 1;
}

static int f_protect(lua_State *L) { return protect_data(L, 0); }
static int f_unprotect(lua_State *L) { return protect_data(L, 1); }

/* machine.claim(path) keeps the lock file open without sharing until the process ends, also after a crash.
   Returns true when this process holds it, false when another process holds it. */
static int f_claim(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  LPWSTR wide = utfconv_utf8towc(path);
  if (!wide) return luaL_error(L, UTFCONV_ERROR_INVALID_CONVERSION);
  HANDLE file = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  SDL_free(wide);
  lua_pushboolean(L, file != INVALID_HANDLE_VALUE);
#else
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  int held = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0;
  if (fd >= 0 && !held) close(fd);
  lua_pushboolean(L, held);
#endif
  return 1;
}

/* machine.process_alive(pid) tells if a process with this ID runs. */
static int f_process_alive(lua_State *L) {
  lua_Integer pid = luaL_checkinteger(L, 1);
#ifdef _WIN32
  HANDLE process = pid > 0 ? OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid) : NULL;
  lua_pushboolean(L, process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT);
  if (process) CloseHandle(process);
#else
  lua_pushboolean(L, pid > 0 && (kill((pid_t)pid, 0) == 0 || errno == EPERM));
#endif
  return 1;
}

static const luaL_Reg machine_lib[] = {
  { "frame",           f_frame           },
  { "decoder",         f_decoder         },
  { "content_version", f_content_version },
  { "protect",         f_protect         },
  { "unprotect",       f_unprotect       },
  { "claim",           f_claim           },
  { "process_alive",   f_process_alive   },
  { NULL, NULL }
};

static const luaL_Reg decoder_object[] = {
  { "feed", m_decoder_feed },
  { "next", m_decoder_next },
  { "limits", m_decoder_limits },
  { "__gc", mm_decoder_gc  },
  { NULL, NULL }
};

int luaopen_machine(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_MACHINE_DECODER);
  luaL_setfuncs(L, decoder_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, machine_lib);
  return 1;
}
