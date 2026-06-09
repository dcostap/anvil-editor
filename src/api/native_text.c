#include "api.h"

#include "text/buffer.h"
#include "text/buffer_manager.h"
#include "text/editor.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef struct NativeTextBuffer {
  Buffer buffer;
  BufferManager manager;
  bool initialized;
} NativeTextBuffer;

typedef struct NativeTextEditor {
  Editor editor;
  int buffer_ref;
  bool initialized;
} NativeTextEditor;

static NativeTextBuffer *check_buffer(lua_State *L, int index) {
  return (NativeTextBuffer *) luaL_checkudata(L, index, API_TYPE_NATIVE_TEXT_BUFFER);
}

static NativeTextEditor *check_editor(lua_State *L, int index) {
  return (NativeTextEditor *) luaL_checkudata(L, index, API_TYPE_NATIVE_TEXT_EDITOR);
}

static size_t check_offset(lua_State *L, int index) {
  lua_Number n = luaL_checknumber(L, index);
  luaL_argcheck(L, n >= 0, index, "expected non-negative byte offset");
  return (size_t) n;
}

static void push_cursor(lua_State *L, Cursor cursor) {
  lua_newtable(L);
  lua_pushnumber(L, (lua_Number) cursor.cursor);
  lua_setfield(L, -2, "cursor");
  if (cursor.selection != EDITOR_SELECTION_SENTINEL) {
    lua_pushnumber(L, (lua_Number) cursor.selection);
    lua_setfield(L, -2, "selection");
  }
}

static int l_buffer_gc(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  if (native->initialized) {
    buffer_manager_dispose(&native->manager);
    buffer_dispose(&native->buffer);
    native->initialized = false;
  }
  return 0;
}

static int l_buffer_path(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  const char *path = buffer_path(&native->buffer);
  if (path) lua_pushstring(L, path);
  else lua_pushnil(L);
  return 1;
}

static int l_buffer_is_dirty(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  lua_pushboolean(L, buffer_is_dirty(&native->buffer));
  return 1;
}

static int l_buffer_load_file(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  const char *path = luaL_checkstring(L, 2);
  lua_pushboolean(L, buffer_load_file(&native->buffer, path));
  return 1;
}

static int l_buffer_save_file(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  const char *path = luaL_optstring(L, 2, NULL);
  lua_pushboolean(L, buffer_save_file(&native->buffer, path));
  return 1;
}

static int l_buffer_len(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  lua_pushnumber(L, (lua_Number) buffer_len(&native->buffer));
  return 1;
}

static int l_buffer_text(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  size_t len = 0;
  char *text = buffer_to_string(&native->buffer, &len);
  if (!text) return luaL_error(L, "failed to read native buffer text");
  lua_pushlstring(L, text, len);
  free(text);
  return 1;
}

static int l_buffer_line_count(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  lua_pushnumber(L, (lua_Number) buffer_line_count(&native->buffer));
  return 1;
}

static int l_buffer_line(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  size_t line = check_offset(L, 2);
  size_t len = 0;
  char *text = buffer_get_line(&native->buffer, line, &len);
  if (!text) return luaL_error(L, "failed to read native buffer line");
  lua_pushlstring(L, text, len);
  free(text);
  return 1;
}

static int l_buffer_offset_to_line_col(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  size_t offset = check_offset(L, 2);
  BufferLineCol lc;
  if (!buffer_offset_to_line_col(&native->buffer, offset, &lc)) {
    lua_pushnil(L);
    return 1;
  }
  lua_newtable(L);
  lua_pushnumber(L, (lua_Number) lc.line);
  lua_setfield(L, -2, "line");
  lua_pushnumber(L, (lua_Number) lc.col);
  lua_setfield(L, -2, "col");
  return 1;
}

static int l_buffer_line_col_to_offset(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  size_t line = check_offset(L, 2);
  size_t col = check_offset(L, 3);
  size_t offset = 0;
  if (!buffer_line_col_to_offset(&native->buffer, line, col, &offset)) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushnumber(L, (lua_Number) offset);
  return 1;
}

static int l_buffer_set_line_ending_mode(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  const char *mode = luaL_checkstring(L, 2);
  BufferLineEndingMode ending = BUFFER_LINE_ENDING_LF;
  if (strcmp(mode, "lf") == 0) {
    ending = BUFFER_LINE_ENDING_LF;
  } else if (strcmp(mode, "crlf") == 0) {
    ending = BUFFER_LINE_ENDING_CRLF;
  } else {
    return luaL_error(L, "line ending mode must be 'lf' or 'crlf'");
  }
  lua_pushboolean(L, buffer_set_line_ending_mode(&native->buffer, ending));
  return 1;
}

static int l_buffer_new_editor(lua_State *L) {
  NativeTextBuffer *native = check_buffer(L, 1);
  NativeTextEditor *editor = (NativeTextEditor *) lua_newuserdata(L, sizeof(NativeTextEditor));
  memset(editor, 0, sizeof(*editor));
  editor->buffer_ref = LUA_NOREF;
  if (!editor_init(&editor->editor, &native->manager)) {
    return luaL_error(L, "failed to create native editor");
  }
  editor->initialized = true;

  luaL_getmetatable(L, API_TYPE_NATIVE_TEXT_EDITOR);
  lua_setmetatable(L, -2);

  lua_pushvalue(L, 1);
  editor->buffer_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  return 1;
}

static int l_editor_gc(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  if (native->initialized) {
    editor_dispose(&native->editor);
    native->initialized = false;
  }
  if (native->buffer_ref != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, native->buffer_ref);
    native->buffer_ref = LUA_NOREF;
  }
  return 0;
}

static int l_editor_cursor_count(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushnumber(L, (lua_Number) editor_cursor_count(&native->editor));
  return 1;
}

static int l_editor_cursor(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t index = (size_t) luaL_optinteger(L, 2, 1);
  luaL_argcheck(L, index >= 1, 2, "cursor index is 1-based");
  push_cursor(L, editor_get_cursor(&native->editor, index - 1));
  return 1;
}

static int l_editor_set_cursor(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t cursor = check_offset(L, 2);
  size_t selection = lua_isnoneornil(L, 3) ? EDITOR_SELECTION_SENTINEL : check_offset(L, 3);
  lua_pushboolean(L, editor_set_cursor(&native->editor, cursor, selection));
  return 1;
}

static int l_editor_add_cursor(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t cursor = check_offset(L, 2);
  size_t selection = lua_isnoneornil(L, 3) ? EDITOR_SELECTION_SENTINEL : check_offset(L, 3);
  lua_pushboolean(L, editor_add_cursor(&native->editor, cursor, selection));
  return 1;
}

static int l_editor_clear_multi_cursors(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  editor_clear_multi_cursors(&native->editor);
  return 0;
}

static int l_editor_insert(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t len = 0;
  const char *text = luaL_checklstring(L, 2, &len);
  lua_pushboolean(L, editor_insert_buffer(&native->editor, text, len));
  return 1;
}

static int l_editor_newline(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_insert_newline(&native->editor));
  return 1;
}

static int l_editor_backspace(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_backspace(&native->editor));
  return 1;
}

static int l_editor_delete(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_del(&native->editor));
  return 1;
}

static int l_editor_paste(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t len = 0;
  const char *text = luaL_checklstring(L, 2, &len);
  lua_pushboolean(L, editor_paste(&native->editor, text, len));
  return 1;
}

static int l_editor_copy_selection(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t len = 0;
  char *text = editor_copy_selection(&native->editor, &len);
  if (!text) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, text, len);
  free(text);
  return 1;
}

static int l_editor_cut_selection(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  size_t len = 0;
  char *text = editor_cut_selection(&native->editor, &len);
  if (!text) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, text, len);
  free(text);
  return 1;
}

static int l_editor_undo(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_undo(&native->editor));
  return 1;
}

static int l_editor_redo(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_redo(&native->editor));
  return 1;
}

static int l_editor_left(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_left(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_right(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_right(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_line_up(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_line_up(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_line_down(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_line_down(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_word_left(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_word_left(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_word_right(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_word_right(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_home_toggle_of_line(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_home_toggle_of_line(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_end_of_line(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_end_of_line(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_start_of_buffer(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_start_of_buffer(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_end_of_buffer(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_end_of_buffer(&native->editor, lua_toboolean(L, 2)));
  return 1;
}

static int l_editor_dup_cursor_up(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_dup_cursor_up(&native->editor));
  return 1;
}

static int l_editor_dup_cursor_down(lua_State *L) {
  NativeTextEditor *native = check_editor(L, 1);
  lua_pushboolean(L, editor_dup_cursor_down(&native->editor));
  return 1;
}

static int l_new_buffer(lua_State *L) {
  size_t len = 0;
  const char *text = lua_isnoneornil(L, 1) ? "" : luaL_checklstring(L, 1, &len);
  NativeTextBuffer *native = (NativeTextBuffer *) lua_newuserdata(L, sizeof(NativeTextBuffer));
  memset(native, 0, sizeof(*native));
  if (!buffer_init(&native->buffer, text, len)) {
    return luaL_error(L, "failed to create native buffer");
  }
  buffer_manager_init(&native->manager, &native->buffer);
  native->initialized = true;
  luaL_getmetatable(L, API_TYPE_NATIVE_TEXT_BUFFER);
  lua_setmetatable(L, -2);
  return 1;
}

static const luaL_Reg buffer_methods[] = {
  { "path", l_buffer_path },
  { "is_dirty", l_buffer_is_dirty },
  { "load_file", l_buffer_load_file },
  { "save_file", l_buffer_save_file },
  { "len", l_buffer_len },
  { "text", l_buffer_text },
  { "line_count", l_buffer_line_count },
  { "line", l_buffer_line },
  { "offset_to_line_col", l_buffer_offset_to_line_col },
  { "line_col_to_offset", l_buffer_line_col_to_offset },
  { "set_line_ending_mode", l_buffer_set_line_ending_mode },
  { "new_editor", l_buffer_new_editor },
  { NULL, NULL }
};

static const luaL_Reg buffer_meta[] = {
  { "__gc", l_buffer_gc },
  { NULL, NULL }
};

static const luaL_Reg editor_methods[] = {
  { "cursor_count", l_editor_cursor_count },
  { "cursor", l_editor_cursor },
  { "set_cursor", l_editor_set_cursor },
  { "add_cursor", l_editor_add_cursor },
  { "clear_multi_cursors", l_editor_clear_multi_cursors },
  { "insert", l_editor_insert },
  { "newline", l_editor_newline },
  { "backspace", l_editor_backspace },
  { "delete", l_editor_delete },
  { "paste", l_editor_paste },
  { "copy_selection", l_editor_copy_selection },
  { "cut_selection", l_editor_cut_selection },
  { "undo", l_editor_undo },
  { "redo", l_editor_redo },
  { "left", l_editor_left },
  { "right", l_editor_right },
  { "line_up", l_editor_line_up },
  { "line_down", l_editor_line_down },
  { "word_left", l_editor_word_left },
  { "word_right", l_editor_word_right },
  { "home_toggle_of_line", l_editor_home_toggle_of_line },
  { "end_of_line", l_editor_end_of_line },
  { "start_of_buffer", l_editor_start_of_buffer },
  { "end_of_buffer", l_editor_end_of_buffer },
  { "dup_cursor_up", l_editor_dup_cursor_up },
  { "dup_cursor_down", l_editor_dup_cursor_down },
  { NULL, NULL }
};

static const luaL_Reg editor_meta[] = {
  { "__gc", l_editor_gc },
  { NULL, NULL }
};

static void create_type(lua_State *L, const char *name, const luaL_Reg *methods, const luaL_Reg *meta) {
  luaL_newmetatable(L, name);
  luaL_setfuncs(L, meta, 0);
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

int luaopen_native_text(lua_State *L) {
  create_type(L, API_TYPE_NATIVE_TEXT_BUFFER, buffer_methods, buffer_meta);
  create_type(L, API_TYPE_NATIVE_TEXT_EDITOR, editor_methods, editor_meta);

  lua_newtable(L);
  lua_pushcfunction(L, l_new_buffer);
  lua_setfield(L, -2, "new_buffer");
  return 1;
}
