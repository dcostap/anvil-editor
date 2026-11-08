/* Before file_drag.h, which includes windows.h: COM calls use the C macros. */
#define COBJMACROS
#include "file_drag.h"

#include <string.h>

bool anvil_file_drag_list_valid(const char *list, size_t size) {
  if (!list || size < 2 || list[size - 1] || !list[0]) return false;
  for (size_t i = 1; i < size; i++)
    if (!list[i] && !list[i - 1]) return false;
  return true;
}

#ifdef _WIN32
#include <shlobj.h>
#include <shobjidl.h>
#include <stdlib.h>
#include <SDL3/SDL.h>

#define FILE_DRAG_MAX_PATHS 4096

static PIDLIST_ABSOLUTE parse_path(const char *path) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (length <= 0) return NULL;
  wchar_t *wide = malloc((size_t)length * sizeof(*wide));
  if (!wide) return NULL;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length);
  PIDLIST_ABSOLUTE item = NULL;
  HRESULT hr = SHParseDisplayName(wide, NULL, &item, 0, NULL);
  free(wide);
  if (FAILED(hr)) {
    SDL_Log("File drag left out a path that Windows could not parse: hr=0x%08lx", (unsigned long)hr);
    return NULL;
  }
  return item;
}

bool anvil_file_drag_run(HWND hwnd, const char *list, size_t size) {
  if (!anvil_file_drag_list_valid(list, size)) return false;
  PIDLIST_ABSOLUTE *items = calloc(FILE_DRAG_MAX_PATHS, sizeof(*items));
  if (!items) return false;
  UINT count = 0;
  for (const char *path = list; path < list + size && count < FILE_DRAG_MAX_PATHS; path += strlen(path) + 1) {
    PIDLIST_ABSOLUTE item = parse_path(path);
    if (item) items[count++] = item;
  }
  bool started = false;
  IShellItemArray *array = NULL;
  IDataObject *data = NULL;
  HRESULT hr = count ? SHCreateShellItemArrayFromIDLists(count, (PCIDLIST_ABSOLUTE_ARRAY)items, &array) : E_FAIL;
  if (SUCCEEDED(hr)) hr = IShellItemArray_BindToHandler(array, NULL, &BHID_DataObject, &IID_IDataObject, (void **)&data);
  if (SUCCEEDED(hr)) {
    /* The helper draws the files' icons under the pointer when the window draws no drag image of its own. */
    IDragSourceHelper *helper = NULL;
    if (SUCCEEDED(CoCreateInstance(&CLSID_DragDropHelper, NULL, CLSCTX_INPROC_SERVER, &IID_IDragSourceHelper,
                                   (void **)&helper))) {
      IDragSourceHelper_InitializeFromWindow(helper, hwnd, NULL, data);
      IDragSourceHelper_Release(helper);
    }
    DWORD effect = DROPEFFECT_NONE;
    hr = SHDoDragDrop(hwnd, data, NULL, DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK, &effect);
    started = SUCCEEDED(hr);
    SDL_Log("File drag ended: files=%u hr=0x%08lx effect=%lu", count, (unsigned long)hr, (unsigned long)effect);
  } else if (count) {
    SDL_Log("File drag could not make its data: files=%u hr=0x%08lx", count, (unsigned long)hr);
  }
  if (data) IDataObject_Release(data);
  if (array) IShellItemArray_Release(array);
  for (UINT i = 0; i < count; i++) ILFree(items[i]);
  free(items);
  return started;
}
#endif
