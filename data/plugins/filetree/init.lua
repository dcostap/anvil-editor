-- mod-version:3
-- Editable, dired/mini.files-like project file panel.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local file_context = require "core.file_context"
local project_paths = require "core.project_paths"
local sidepanel = require "core.sidepanel"
local storage = require "core.storage"
local DirWatch = require "core.dirwatch"
local git_backend = require "plugins.git.backend"
local filetree_render = require "plugins.filetree.render"

local FILETREE_SETTINGS_MODULE = "filetree"
local FILETREE_SETTINGS_KEY = "settings"
local DEFAULT_SORT_MODE = "name"
local SORT_LABELS = {
  name = "filename",
  modified = "date modified",
}

local function normalize_sort_mode(mode)
  if mode == "name" or mode == "modified" then return mode end
  return nil
end

local function load_saved_sort_mode()
  local settings = storage.load(FILETREE_SETTINGS_MODULE, FILETREE_SETTINGS_KEY)
  if type(settings) == "table" then
    return normalize_sort_mode(settings.sort_mode)
  end
end

local function save_sort_mode(sort_mode)
  storage.save(FILETREE_SETTINGS_MODULE, FILETREE_SETTINGS_KEY, {
    sort_mode = sort_mode,
  })
end

local filetree_config = config.plugins.filetree
filetree_config.sort_mode = normalize_sort_mode(filetree_config.sort_mode)
  or load_saved_sort_mode()
  or DEFAULT_SORT_MODE

local INDENT = 1
local INDENT_TEXT = "\t"
local NO_META = false
local LINE_HINT_COUNT_WORKER_BUDGET = 0.008
local LINE_HINT_COUNT_CHILD_BUDGET = 0.004
local GIT_STATUS_REFRESH_INTERVAL = 2

local function perf_stats()
  return core.docview_frame_stats
end

local function perf_add(stats, key, amount)
  if stats then stats[key] = (stats[key] or 0) + (amount or 1) end
end

local function perf_start(stats)
  return stats and system.get_time()
end

local function perf_finish(stats, key, start)
  if stats and start then stats[key] = (stats[key] or 0) + (system.get_time() - start) * 1000 end
end

local function perf_call(stats, key)
  perf_add(stats, key, 1)
  return perf_start(stats)
end

local GIT_STATUS_MAX_OUTPUT = 2 * 1024 * 1024
local MONTH_NAMES = {
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

local function indent_prefix(level)
  return string.rep(INDENT_TEXT, level)
end

local function indent_size()
  return math.max(1, tonumber(config and config.indent_size) or 4)
end

local function parse_leading_indent(text)
  local raw = text:match("^([\t ]*)") or ""
  local spaces = 0
  local level = 0

  for i = 1, #raw do
    local ch = raw:sub(i, i)
    if ch == "\t" then
      level = level + 1
    else
      spaces = spaces + 1
    end
  end

  local size = indent_size()
  if spaces % size ~= 0 then
    return nil, #raw + 1, string.format(
      "space indentation must be a multiple of %d", size
    )
  end

  return level + (spaces / size), #raw + 1
end

local function leading_indent_level(text)
  local level = parse_leading_indent(text)
  if level then return level end

  local raw = text:match("^([\t ]*)") or ""
  local tabs = 0
  local spaces = 0
  for i = 1, #raw do
    local ch = raw:sub(i, i)
    if ch == "\t" then tabs = tabs + 1 else spaces = spaces + 1 end
  end
  return tabs + math.ceil(spaces / indent_size())
end

local function strip_indent_levels(text, levels)
  local raw = text:match("^([\t ]*)") or ""
  local consumed = 0
  local spaces = 0

  for i = 1, #raw do
    local ch = raw:sub(i, i)
    if ch == "\t" then
      consumed = consumed + 1
      spaces = 0
    else
      spaces = spaces + 1
      if spaces == indent_size() then
        consumed = consumed + 1
        spaces = 0
      end
    end

    if consumed == levels then
      return text:sub(i + 1)
    end
  end

  return text:sub(#raw + 1)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function has_dir_suffix(s)
  return s:sub(-1) == "/" or s:sub(-1) == "\\"
end

local function strip_dir_suffix(s)
  if has_dir_suffix(s) then return s:sub(1, -2) end
  return s
end

local function normalize_slashes(s)
  return (s:gsub("[\\/]+", PATHSEP))
end

local function path_join(a, b)
  if a:sub(-1) == PATHSEP then return a .. b end
  return a .. PATHSEP .. b
end

local function path_depth(path)
  local n, i = 0, 1
  while true do
    local s = path:find(PATHSEP, i, true)
    if not s then break end
    n, i = n + 1, s + 1
  end
  return n
end

local function line_text(line)
  line = line or ""
  return line:sub(-1) == "\n" and line:sub(1, -2) or line
end

local function set_doc_lines(doc, lines)
  doc:reset()
  doc.lines = #lines > 0 and lines or { "\n" }
  doc.clean_lines = {}
  doc.highlighter:soft_reset()
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function item_name_less(a, b)
  if a.sort_name ~= b.sort_name then return a.sort_name < b.sort_name end
  return a.name < b.name
end

local function item_modified_less(a, b)
  local am = tonumber(a.modified) or -math.huge
  local bm = tonumber(b.modified) or -math.huge
  if am ~= bm then return am > bm end
  return item_name_less(a, b)
end

local function filetree_item_less(a, b)
  if a.type ~= b.type then return a.type == "dir" end
  if filetree_config.sort_mode == "modified" then
    return item_modified_less(a, b)
  end
  return item_name_less(a, b)
end

local function sorted_dir(path, show_hidden)
  local items = {}
  for _, name in ipairs(system.list_dir(path) or {}) do
    if show_hidden or name:sub(1, 1) ~= "." then
      local abs = path_join(path, name)
      local info = system.get_file_info(abs)
      if info then
        table.insert(items, {
          name = name,
          sort_name = name:lower(),
          abs = abs,
          type = info.type,
          size = info.size,
          modified = info.modified,
          display = name .. (info.type == "dir" and "/" or "")
        })
      end
    end
  end
  table.sort(items, filetree_item_less)
  return items
end

local function format_file_size(size)
  local units = { "B", "K", "M", "G", "T", "P" }
  local value = math.max(0, tonumber(size) or 0)
  local unit = 1
  while value >= 1024 and unit < #units do
    value = value / 1024
    unit = unit + 1
  end

  local rounded = math.floor(value + 0.5)
  if rounded >= 1000 and unit < #units then
    value = value / 1024
    unit = unit + 1
    rounded = math.floor(value + 0.5)
  end
  return string.format("%3d %s", rounded, units[unit])
end

local function format_modified_time(modified)
  local value = tonumber(modified)
  if not value then return nil end
  local t = os.date("*t", value)
  if not t then return nil end
  return string.format(
    "%04d %s %2d %02d:%02d",
    t.year, MONTH_NAMES[t.month] or "???", t.day, t.hour, t.min
  )
end

local function count_direct_children(path, show_hidden, yield_budget)
  local names, err = system.list_dir(path)
  if not names then return nil, nil, err or "unable to list directory" end

  local folders, files = 0, 0
  local start_time = system.get_time()
  for _, name in ipairs(names) do
    if show_hidden or name:sub(1, 1) ~= "." then
      local info = system.get_file_info(path_join(path, name))
      if info and info.type == "dir" then
        folders = folders + 1
      elseif info and info.type == "file" then
        files = files + 1
      end
    end
    if yield_budget and system.get_time() - start_time > yield_budget then
      coroutine.yield(0)
      start_time = system.get_time()
    end
  end
  return folders, files
end

local function path_key(path)
  return common.path_compare_key(path) or tostring(path)
end

local function in_project(abs, project_root)
  return common.path_equals(abs, project_root) or common.path_belongs_to(abs, project_root)
end

local function update_open_docs_after_rename(old_abs, new_abs, entry_type)
  for _, doc in ipairs(core.docs) do
    local filename = doc.abs_filename
    local mapped
    if common.path_equals(filename, old_abs) then
      mapped = new_abs
    elseif entry_type == "dir" and filename and common.path_belongs_to(filename, old_abs) then
      mapped = new_abs .. filename:sub(#old_abs + 1)
    end
    if mapped then
      doc:set_filename(core.normalize_to_project_dir(mapped), mapped)
      doc:reset_syntax()
    end
  end
end

local function parent_dir(path)
  return common.dirname(path)
end

local function rel_path(path)
  local root = core.root_project and core.root_project()
  if root and in_project(path, root.path) then
    return common.relative_path(root.path, path)
  end
  return path
end

local function op_path(path)
  local path = rel_path(path):gsub("\\", "/")
  return path
end

local function run_process_capture(args, options, max_stdout)
  if not process or not process.start then return nil, "", "process API unavailable" end

  options = options or {}
  options.stdout = process.REDIRECT_PIPE
  options.stderr = process.REDIRECT_PIPE
  options.stdin = process.REDIRECT_DISCARD

  local proc, start_err = process.start(args, options)
  if not proc then return nil, "", start_err or "process start failed" end

  local stdout_chunks, stderr_chunks = {}, {}
  local stdout_size, stderr_size = 0, 0
  max_stdout = max_stdout or GIT_STATUS_MAX_OUTPUT

  local function read_available(stream, chunks, size, cap)
    while true do
      local chunk, errmsg, errcode = proc:read(stream, 8192)
      if chunk and #chunk > 0 then
        chunks[#chunks + 1] = chunk
        size = size + #chunk
        if size > cap then proc:kill(); return size, false, "output too large" end
      elseif errcode == process.ERROR_WOULDBLOCK or chunk == "" then
        return size, true
      elseif not chunk then
        if errcode == process.ERROR_PIPE then return size, true end
        return size, false, errmsg or "process read failed"
      else
        return size, true
      end
    end
  end

  while proc:running() do
    local ok, err
    stdout_size, ok, err = read_available(process.STREAM_STDOUT, stdout_chunks, stdout_size, max_stdout)
    if not ok then return nil, table.concat(stdout_chunks), err end
    stderr_size, ok, err = read_available(process.STREAM_STDERR, stderr_chunks, stderr_size, 64 * 1024)
    if not ok then return nil, table.concat(stdout_chunks), err end
    coroutine.yield(0.02)
  end

  stdout_size = select(1, read_available(process.STREAM_STDOUT, stdout_chunks, stdout_size, max_stdout))
  stderr_size = select(1, read_available(process.STREAM_STDERR, stderr_chunks, stderr_size, 64 * 1024))
  return proc:returncode() or 0, table.concat(stdout_chunks), table.concat(stderr_chunks)
end

local function split_nul(text)
  local out, i = {}, 1
  while i <= #text do
    local j = text:find("%z", i)
    if not j then
      if i <= #text then out[#out + 1] = text:sub(i) end
      break
    end
    out[#out + 1] = text:sub(i, j - 1)
    i = j + 1
  end
  return out
end

local function normalize_git_rel(path)
  if type(path) ~= "string" then return nil end
  path = path:gsub("\\", "/")
  path = path:gsub("^%./", "")
  if path == "" then return nil end
  return path
end

local function git_abs(root, rel)
  rel = normalize_git_rel(rel)
  if not rel then return nil end
  return common.normalize_path(path_join(root, rel:gsub("/", PATHSEP)))
end

local function parent_rel_paths(rel)
  local parents = {}
  rel = normalize_git_rel(rel)
  if not rel then return parents end
  local current = common.dirname(rel:gsub("/", PATHSEP))
  while current and current ~= "." and current ~= "" do
    parents[#parents + 1] = current:gsub("\\", "/")
    current = common.dirname(current)
  end
  return parents
end

local function git_status_kind(xy)
  if xy == "!!" then return "ignored" end
  if xy == "??" then return "untracked" end
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  if x == "D" or y == "D" then return "deleted" end
  if x == "A" or y == "A" then return "added" end
  if x ~= " " or y ~= " " then return "modified" end
  return nil
end

local function stronger_git_kind(a, b)
  return filetree_render.stronger_git_kind(a, b)
end

local function is_rename_op(op)
  local from_dir, to_dir = common.dirname(op.from), common.dirname(op.to)
  return from_dir == to_dir or common.path_equals(from_dir, to_dir)
end

local function clone_meta(meta, seen)
  if type(meta) ~= "table" then return NO_META end
  seen = seen or {}
  if seen[meta] then return seen[meta] end
  local copy = {}
  seen[meta] = copy
  for k, v in pairs(meta) do
    copy[k] = type(v) == "table" and clone_meta(v, seen) or v
  end
  return copy
end

local function make_meta(item)
  return {
    original_abs = item.abs,
    original_type = item.type,
    original_size = item.size,
    original_modified = item.modified,
    expanded = false,
    project_path_role = item.project_path_role,
    project_path_label = item.project_path_label,
    project_path_id = item.project_path_id,
    project_path_separator = item.project_path_separator,
    project_path_root = item.project_path_root,
    project_path_missing = item.project_path_missing,
    project_path_readonly = item.project_path_readonly,
    project_path_display = item.project_path_display,
  }
end

local function cached_info_from_meta(meta, abs, entry_type)
  if type(meta) ~= "table" then return nil end
  if not meta.original_abs or meta.original_type ~= entry_type then return nil end
  if not common.path_equals(meta.original_abs, abs) then return nil end
  if meta.original_modified == nil then return nil end
  return {
    type = entry_type,
    size = meta.original_size,
    modified = meta.original_modified,
  }
end

local function filetree_clipboard_metas_for_lines(view, lines, start, count)
  local payload = core.filetree_clipboard
  local items = payload and payload.items
  if not items or #items == 0 or count <= 0 or count % #items ~= 0 then return nil end

  if view.last_text_change_type ~= "undo" then
    local clipboard = system.get_clipboard()
    if not payload.text or clipboard ~= payload.text then return nil end
  end

  local metas = {}
  for i = 1, count do
    local item = items[((i - 1) % #items) + 1]
    if line_text(lines[start + i - 1] or "") ~= item.text then return nil end
    metas[i] = clone_meta(item.meta)
  end
  return metas
end

local function copy_file(src, dest)
  local input, err = io.open(src, "rb")
  if not input then return nil, err end
  local output
  output, err = io.open(dest, "wb")
  if not output then input:close(); return nil, err end
  while true do
    local chunk = input:read(1024 * 1024)
    if not chunk then break end
    local ok
    ok, err = output:write(chunk)
    if not ok then input:close(); output:close(); return nil, err end
  end
  input:close()
  output:close()
  return true
end

local function copy_recursive(src, dest, entry_type)
  local info = system.get_file_info(src)
  if not info then return nil, "source does not exist: " .. src end
  entry_type = entry_type or info.type
  if entry_type == "dir" then
    local ok, err, path = common.mkdirp(dest)
    if not ok then return nil, string.format("mkdir failed: %s: %s", path or dest, err) end
    for _, name in ipairs(system.list_dir(src) or {}) do
      local child_src = path_join(src, name)
      local child_dest = path_join(dest, name)
      local child_info = system.get_file_info(child_src)
      if child_info then
        ok, err = copy_recursive(child_src, child_dest, child_info.type)
        if not ok then return nil, err end
      end
    end
    return true
  end

  local parent = parent_dir(dest)
  if parent and not system.get_file_info(parent) then
    local ok, err, path = common.mkdirp(parent)
    if not ok then return nil, string.format("mkdir failed: %s: %s", path or parent, err) end
  end
  return copy_file(src, dest)
end

local function delete_permanent(path)
  local info = system.get_file_info(path)
  if not info then return true end
  if info.type == "dir" then
    local ok, err, failed_path = common.rm(path, true)
    if not ok then return nil, string.format("%s: %s", failed_path or path, err) end
    return true
  end
  local ok, err = os.remove(path)
  if not ok then return nil, err end
  return true
end

local function ps_single_quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local function shell_quote_arg(s)
  return '"' .. s:gsub('"', '\\"') .. '"'
end

local function wait_paths_gone(paths, timeout)
  local deadline = system.get_time() + (timeout or 30)
  while system.get_time() < deadline do
    local remaining = false
    for _, path in ipairs(paths) do
      if system.get_file_info(path) then remaining = true; break end
    end
    if not remaining then return true end
    system.sleep(0.05)
  end
  for _, path in ipairs(paths) do
    if system.get_file_info(path) then return nil, "Recycle Bin operation did not complete: " .. path end
  end
  return true
end

local function trash_windows_ffi(paths)
  local ok, ffi = pcall(require, "ffi")
  if not ok then return nil, "LuaJIT FFI unavailable" end
  local ok_bit, bit = pcall(require, "bit")
  if not ok_bit then return nil, "LuaJIT bit library unavailable" end

  if not core.filetree_wintrash_ffi_defined then
    ffi.cdef[[
typedef void* HWND;
typedef unsigned int UINT;
typedef int BOOL;
typedef const wchar_t* LPCWSTR;
typedef struct _SHFILEOPSTRUCTW {
  HWND hwnd;
  UINT wFunc;
  LPCWSTR pFrom;
  LPCWSTR pTo;
  unsigned short fFlags;
  BOOL fAnyOperationsAborted;
  void* hNameMappings;
  LPCWSTR lpszProgressTitle;
} SHFILEOPSTRUCTW;
int SHFileOperationW(SHFILEOPSTRUCTW *lpFileOp);
int MultiByteToWideChar(UINT CodePage, unsigned long dwFlags, const char *lpMultiByteStr,
  int cbMultiByte, wchar_t *lpWideCharStr, int cchWideChar);
unsigned long GetLastError(void);
]]
    core.filetree_wintrash_ffi_defined = true
  end

  local shell32 = ffi.load("shell32")
  local kernel32 = ffi.load("kernel32")
  local CP_UTF8 = 65001
  local FO_DELETE = 0x0003
  local FOF_SILENT = 0x0004
  local FOF_NOCONFIRMATION = 0x0010
  local FOF_ALLOWUNDO = 0x0040
  local FOF_NOCONFIRMMKDIR = 0x0200
  local FOF_NOERRORUI = 0x0400

  local converted, total = {}, 1
  for _, path in ipairs(paths) do
    local normalized = common.normalize_path(path):gsub("/", "\\")
    local len = kernel32.MultiByteToWideChar(CP_UTF8, 0, normalized, #normalized, nil, 0)
    if len <= 0 then
      return nil, string.format("MultiByteToWideChar length failed for %s (%s)", path, tonumber(kernel32.GetLastError()))
    end
    converted[#converted + 1] = { path = normalized, len = len }
    total = total + len + 1
  end

  local from = ffi.new("wchar_t[?]", total)
  local offset = 0
  for _, item in ipairs(converted) do
    local written = kernel32.MultiByteToWideChar(CP_UTF8, 0, item.path, #item.path, from + offset, item.len)
    if written ~= item.len then
      return nil, string.format("MultiByteToWideChar failed for %s (%s)", item.path, tonumber(kernel32.GetLastError()))
    end
    offset = offset + item.len
    from[offset] = 0
    offset = offset + 1
  end
  from[offset] = 0

  local op = ffi.new("SHFILEOPSTRUCTW")
  op.hwnd = nil
  op.wFunc = FO_DELETE
  op.pFrom = from
  op.pTo = nil
  op.fFlags = bit.bor(FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_SILENT, FOF_NOERRORUI, FOF_NOCONFIRMMKDIR)

  local rc = shell32.SHFileOperationW(op)
  if rc ~= 0 then return nil, "SHFileOperationW failed: " .. tostring(tonumber(rc)) end
  if op.fAnyOperationsAborted ~= 0 then return nil, "SHFileOperationW operation was aborted" end
  return wait_paths_gone(paths, 30)
end

local function trash_windows_powershell(paths)
  local dir = USERDIR .. PATHSEP .. "storage"
  common.mkdirp(dir)
  local script = path_join(dir, "filetree-trash-" .. tostring(system.get_time()):gsub("%W", "") .. ".ps1")
  local fp, err = io.open(script, "wb")
  if not fp then return nil, err end
  fp:write("$ErrorActionPreference = 'Stop'\r\n")
  fp:write("$paths = @(\r\n")
  for i, path in ipairs(paths) do
    fp:write("  " .. ps_single_quote(path) .. (i < #paths and "," or "") .. "\r\n")
  end
  fp:write(")\r\n")
  fp:write("$shell = New-Object -ComObject 'Shell.Application'\r\n")
  fp:write("foreach ($literal in $paths) {\r\n")
  fp:write("  if (-not (Test-Path -LiteralPath $literal)) { continue }\r\n")
  fp:write("  $path = Get-Item -LiteralPath $literal\r\n")
  fp:write("  $folder = $shell.NameSpace($path.DirectoryName)\r\n")
  fp:write("  if ($null -eq $folder) { throw 'Could not open parent shell namespace' }\r\n")
  fp:write("  $item = $folder.ParseName($path.Name)\r\n")
  fp:write("  if ($null -eq $item) { throw 'Could not resolve shell item' }\r\n")
  fp:write("  $item.InvokeVerb('delete')\r\n")
  fp:write("}\r\n")
  fp:write("$deadline = (Get-Date).AddSeconds(30)\r\n")
  fp:write("while ((Get-Date) -lt $deadline) {\r\n")
  fp:write("  $remaining = @($paths | Where-Object { Test-Path -LiteralPath $_ })\r\n")
  fp:write("  if ($remaining.Count -eq 0) { exit 0 }\r\n")
  fp:write("  Start-Sleep -Milliseconds 50\r\n")
  fp:write("}\r\n")
  fp:write("throw ('Recycle Bin operation did not complete: ' + (($paths | Where-Object { Test-Path -LiteralPath $_ }) -join ', '))\r\n")
  fp:close()
  local ok, why, code = os.execute("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " .. shell_quote_arg(script))
  os.remove(script)
  if ok ~= true and ok ~= 0 then
    return nil, string.format("PowerShell trash failed (%s %s)", tostring(why), tostring(code))
  end
  return true
end

local function trash_paths(paths)
  if #paths == 0 then return true end
  if PLATFORM == "Windows" and filetree_config.delete_to_trash then
    local ok, err = trash_windows_ffi(paths)
    if ok then return true end
    core.log("File Tree: SHFileOperationW trash failed, falling back to PowerShell: %s", err)
    local ps_ok, ps_err = trash_windows_powershell(paths)
    if ps_ok then return true end
    return nil, string.format("%s; PowerShell fallback: %s", err, ps_err)
  end
  for _, path in ipairs(paths) do
    local ok, err = delete_permanent(path)
    if not ok then return nil, err end
  end
  return true
end

local function ordered_moves_or_cycle(moves)
  local by_from = {}
  for _, op in ipairs(moves or {}) do by_from[path_key(op.from)] = op end

  local ordered, visiting, visited = {}, {}, {}
  local function visit(op)
    local from_key = path_key(op.from)
    if visited[from_key] then return true end
    if visiting[from_key] then
      return nil, "move cycle detected involving " .. op_path(op.from) .. " -> " .. op_path(op.to), op
    end
    visiting[from_key] = true

    -- If this move targets another source, or a descendant of another source,
    -- that source must be vacated first. If this move's source is inside a
    -- destination created by another move, that parent move must happen first.
    -- This supports chains like A->B, B->C and moved-away subtrees, while
    -- rejecting ancestor cycles like A->B, B->A/child.
    for dep_from, dep in pairs(by_from) do
      local needs_dep = dep ~= op and (
        common.path_equals(op.to, dep_from)
        or common.path_belongs_to(op.to, dep_from)
        or common.path_belongs_to(op.from, dep.to)
      )
      if needs_dep then
        local ok, err, err_op = visit(dep)
        if not ok then return nil, err, err_op or op end
      end
    end

    visiting[from_key] = nil
    visited[from_key] = true
    ordered[#ordered + 1] = op
    return true
  end

  table.sort(moves, function(a, b) return a.from < b.from end)
  for _, op in ipairs(moves or {}) do
    local ok, err, err_op = visit(op)
    if not ok then return nil, err, err_op end
  end
  return ordered
end

local function parse_text(text)
  local level, _, indent_err = parse_leading_indent(text)
  if indent_err then
    return nil, indent_err
  end

  local body = trim(text)
  if body == "" then return nil end

  local wants_dir = has_dir_suffix(body)
  local name = normalize_slashes(strip_dir_suffix(body))
  if name == "" then return nil, "empty name" end
  if name == "." or name == ".." then return nil, "invalid name: " .. name end
  if name:find("%z") then return nil, "invalid NUL byte" end

  return {
    indent = level,
    level = level,
    name = name,
    wants_dir = wants_dir,
  }
end

local function recover_known_line_meta(view)
  local root = { abs = view.current_dir, type = "dir", level = -1 }
  local stack = {}

  for i, line in ipairs(view.doc.lines) do
    local parsed = parse_text(line_text(line))
    if parsed then
      local parent = parsed.level == 0 and root or stack[parsed.level - 1]
      if parent and parent.type == "dir" then
        local abs = system.absolute_path(path_join(parent.abs, parsed.name))
          or common.normalize_path(path_join(parent.abs, parsed.name))
        local meta = type(view.line_meta[i]) == "table" and view.line_meta[i] or nil
        local known = view.known_originals[path_key(abs)]
        local entry_type = parsed.wants_dir and "dir"
          or (meta and meta.original_type)
          or (known and known.type)
          or "file"

        if (not meta or (not meta.original_abs and not meta.force_create))
          and known and known.type == entry_type
        then
          view.line_meta[i] = {
            original_abs = known.abs,
            original_type = known.type,
            original_size = known.size,
            original_modified = known.modified,
            expanded = false,
          }
          meta = view.line_meta[i]
        end

        local entry = { abs = abs, type = entry_type, level = parsed.level }
        stack[parsed.level] = entry
        local deeper = parsed.level + 1
        while stack[deeper] do
          stack[deeper] = nil
          deeper = deeper + 1
        end
      end
    end
  end
end

local FileTreeView = DocView:extend()
FileTreeView.context = "application"

function FileTreeView:__tostring() return "FileTreeView" end

function FileTreeView:new()
  local doc = Doc()
  FileTreeView.super.new(self, doc)
  self.target_size = filetree_config.size
  self.visible = filetree_config.visible
  self.current_dir = core.root_project().path
  self.original_entries = {}
  self.original_by_name = {}
  self.known_originals = {}
  self.line_meta = {}
  self.line_hint_cache = {}
  self.line_hint_count_cache = {}
  self.line_hint_count_pending = {}
  self.line_hint_count_queue = {}
  self.line_hint_count_worker_running = false
  self.last_lines = nil
  self.status_cache = nil
  self.git_status = { files = {}, dirs = {}, stats = {}, dir_stats = {}, generation = 0 }
  self.git_status_worker_running = false
  self.git_status_refresh_requested = false
  self.git_status_last_refresh = 0
  self.has_possible_edits = false
  self.filesystem_watch = DirWatch()
  self.filesystem_watched_dirs = {}
  self.filesystem_dir_signatures = {}
  self.filesystem_watch_running = false
  self.filesystem_sync_deferred = false
  self.filesystem_watch_update_suppressed = 0
  self.filesystem_watch_update_deferred = false
  self:set_caption "File Tree"

  local view = self
  function doc:on_text_change(type, transaction)
    view.last_text_change_type = type
    view.last_text_transaction = transaction
    view.status_cache = nil
    view.has_possible_edits = true
  end

  self:refresh()
  self:start_filesystem_watch()
end

function FileTreeView:get_name()
  return "File Tree: " .. common.relative_path(core.root_project().path, self.current_dir)
end

function FileTreeView:get_gutter_width()
  return style.padding.x * 2, style.padding.x
end

function FileTreeView:git_root()
  local root = core.root_project and core.root_project()
  return root and root.path or self.current_dir
end

function FileTreeView:schedule_git_status_refresh(reason, force)
  local now = system.get_time()
  if not force and now - (self.git_status_last_refresh or 0) < GIT_STATUS_REFRESH_INTERVAL then
    return
  end
  self.git_status_last_refresh = now
  self.git_status_refresh_requested = true
  if self.git_status_worker_running then return end
  self.git_status_worker_running = true

  core.add_thread(function()
    while self.git_status_refresh_requested do
      self.git_status_refresh_requested = false
      self:refresh_git_status(reason)
    end
    self.git_status_worker_running = false
  end)
end

function FileTreeView:refresh_git_status(reason)
  local root = self:git_root()
  if not root then return end

  local files, dirs = {}, {}
  local stats, dir_stats = {}, {}
  local in_repo = false

  local git_path = git_backend.git_path()
  if not git_path then
    self.git_status = { files = files, dirs = dirs, stats = stats, dir_stats = dir_stats, generation = (self.git_status and self.git_status.generation or 0) + 1 }
    return
  end

  local code, out, err = run_process_capture(
    { git_path, "rev-parse", "--show-toplevel" }, { cwd = root }, 64 * 1024
  )
  if code == 0 and trim(out) ~= "" then
    root = common.normalize_path(trim(out))
    in_repo = true
  end
  if not in_repo then
    self.git_status = { files = files, dirs = dirs, stats = stats, dir_stats = dir_stats, generation = (self.git_status and self.git_status.generation or 0) + 1 }
    return
  end

  code, out, err = run_process_capture(
    { git_path, "status", "--porcelain=v1", "--ignored", "-uall", "-z" },
    { cwd = root }, GIT_STATUS_MAX_OUTPUT
  )
  if code ~= 0 then
    core.log_quiet("File Tree git status failed (%s): %s", tostring(reason or "refresh"), tostring(err))
    return
  end

  for _, record in ipairs(git_backend.parse_status_z(out)) do
    local rel = normalize_git_rel(record.new_path or record.path or record.old_path)
    local kind = git_status_kind(record.xy) or record.kind
    if rel and kind then
      local abs = git_abs(root, rel)
      if abs then files[path_key(abs)] = stronger_git_kind(files[path_key(abs)], kind) end
      for _, parent in ipairs(parent_rel_paths(rel)) do
        local pabs = git_abs(root, parent)
        if pabs then dirs[path_key(pabs)] = stronger_git_kind(dirs[path_key(pabs)], kind) end
      end
    end
  end

  code, out, err = run_process_capture(
    { git_path, "diff", "--numstat", "--no-renames", "-z", "HEAD", "--" },
    { cwd = root }, GIT_STATUS_MAX_OUTPUT
  )
  if code == 0 then
    for _, record in ipairs(split_nul(out)) do
      local added_text, deleted_text, rel = record:match("^([^\t]*)\t([^\t]*)\t(.+)$")
      local added, deleted = tonumber(added_text), tonumber(deleted_text)
      rel = normalize_git_rel(rel)
      if added and deleted and rel then
        local abs = git_abs(root, rel)
        if abs then stats[path_key(abs)] = { additions = added, deletions = deleted } end
        for _, parent in ipairs(parent_rel_paths(rel)) do
          local pabs = git_abs(root, parent)
          if pabs then
            local key = path_key(pabs)
            local total = dir_stats[key] or { additions = 0, deletions = 0 }
            total.additions = total.additions + added
            total.deletions = total.deletions + deleted
            dir_stats[key] = total
          end
        end
      end
    end
  else
    core.log_quiet("File Tree git numstat failed (%s): %s", tostring(reason or "refresh"), tostring(err))
  end

  self.git_status = {
    files = files,
    dirs = dirs,
    stats = stats,
    dir_stats = dir_stats,
    generation = (self.git_status and self.git_status.generation or 0) + 1,
  }
  core.redraw = true
end

function FileTreeView:get_git_info_for_entry(entry)
  if not entry or not self.git_status then return nil end
  local key = path_key(entry.abs)
  local kind = self.git_status.files[key]
  local stat = entry.type ~= "dir" and self.git_status.stats[key] or nil
  if entry.type == "dir" then
    kind = kind or self.git_status.dirs[key]
  end
  if kind or stat then return { kind = kind, stat = stat } end
end

function FileTreeView:get_git_info_for_line(line)
  local entry = self:get_line_hint_entry(line)
  return self:get_git_info_for_entry(entry)
end

function FileTreeView:git_text_color(kind)
  return filetree_render.git_text_color(kind)
end

function FileTreeView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function FileTreeView:on_scale_change(new_scale, prev_scale)
  self.target_size = self.target_size / prev_scale * new_scale
end

function FileTreeView:update()
  FileTreeView.super.update(self)
end

function FileTreeView:filesystem_reveal_paths(path)
  if not path then return nil end
  return { path }
end

function FileTreeView:queue_filesystem_sync(path, reason)
  if self.has_possible_edits then
    if not self.filesystem_sync_deferred then
      core.log_quiet("File Tree filesystem sync deferred because the editable tree has unapplied edits")
    end
    self.filesystem_sync_deferred = true
    return false
  end

  core.log_quiet("File Tree filesystem sync from %s: %s", reason or "watch", tostring(path))
  self:refresh_preserving_selection_paths(true, self:filesystem_reveal_paths(path))
  self.filesystem_sync_deferred = false
  return true
end

function FileTreeView:sync_path(path, reason)
  if type(path) ~= "string" or path == "" then return false end
  local expanded = common.home_expand(path)
  path = common.normalize_path(system.absolute_path(expanded) or expanded)
  local resolved = project_paths.resolve(path)
  if not resolved or resolved.flags.browsable == false then return false end
  return self:queue_filesystem_sync(path, reason or "notification")
end

function FileTreeView:filesystem_dir_signature(dir)
  local names = system.list_dir(dir)
  if not names then return nil end
  table.sort(names)

  local parts = {}
  for _, name in ipairs(names) do
    if filetree_config.show_hidden or name:sub(1, 1) ~= "." then
      local abs = path_join(dir, name)
      local info = system.get_file_info(abs)
      if info then
        parts[#parts + 1] = table.concat({
          name,
          info.type or "",
          tostring(info.size or ""),
          tostring(info.modified or ""),
        }, "\0")
      end
    end
  end
  return table.concat(parts, "\1")
end

function FileTreeView:update_filesystem_watches()
  if not self.filesystem_watch then return end
  if (self.filesystem_watch_update_suppressed or 0) > 0 then
    self.filesystem_watch_update_deferred = true
    return
  end
  self.filesystem_watch_update_deferred = false

  local wanted = {}
  wanted[self.current_dir] = true
  local entries = self:build_entries(false)
  for _, entry in ipairs(entries) do
    if entry.type == "dir" and type(entry.meta) == "table" and entry.meta.expanded then
      wanted[entry.abs] = true
    end
  end

  for dir in pairs(self.filesystem_watched_dirs) do
    if not wanted[dir] then
      self.filesystem_watch:unwatch(dir)
      self.filesystem_watched_dirs[dir] = nil
      self.filesystem_dir_signatures[dir] = nil
    end
  end
  for dir in pairs(wanted) do
    if system.get_file_info(dir) then
      if not self.filesystem_watched_dirs[dir] then
        self.filesystem_watch:watch(dir)
        self.filesystem_watched_dirs[dir] = true
      end
      self.filesystem_dir_signatures[dir] = self:filesystem_dir_signature(dir)
    end
  end
end

function FileTreeView:handle_filesystem_watch_change(changed_dir)
  changed_dir = changed_dir and common.normalize_path(changed_dir)
  if not changed_dir or not self.filesystem_watched_dirs[changed_dir] then return end

  local old_signature = self.filesystem_dir_signatures[changed_dir]
  local new_signature = self:filesystem_dir_signature(changed_dir)
  if old_signature == new_signature then return end

  self.filesystem_dir_signatures[changed_dir] = new_signature
  self:queue_filesystem_sync(changed_dir, "watch")
end

function FileTreeView:start_filesystem_watch()
  if self.filesystem_watch_running or not self.filesystem_watch then return end
  self.filesystem_watch_running = true
  local view = self
  core.add_thread(function()
    while true do
      local ok, err = pcall(function()
        view.filesystem_watch:check(function(changed_dir)
          view:handle_filesystem_watch_change(changed_dir)
        end)
      end)
      if not ok then
        core.log_quiet("File Tree filesystem watch failed: %s", tostring(err))
        coroutine.yield(5)
      else
        coroutine.yield(0.25)
      end
    end
  end)
end

function FileTreeView:set_caption(text)
  self.caption = text
end

function FileTreeView:snapshot_lines()
  self.last_lines = {}
  for i, line in ipairs(self.doc.lines) do
    self.last_lines[i] = line_text(line)
    if self.line_meta[i] == nil then self.line_meta[i] = NO_META end
  end
  for i = #self.doc.lines + 1, #self.line_meta do
    self.line_meta[i] = nil
  end
  self.last_change_id = self.doc:get_change_id()
  self.__line_hint_entries_change_id = nil
  self.__line_hint_entries_by_line = nil
  self.__line_hint_errors = nil
end

function FileTreeView:sync_meta()
  if self.last_lines and self.last_change_id == self.doc:get_change_id() then return end
  if not self.last_lines then
    self:snapshot_lines()
    return
  end

  local old_lines, old_meta = self.last_lines, self.line_meta
  local new_lines = {}
  for i, line in ipairs(self.doc.lines) do new_lines[i] = line_text(line) end

  local same = #old_lines == #new_lines
  if same then
    for i = 1, #old_lines do
      if old_lines[i] ~= new_lines[i] then same = false; break end
    end
  end
  if same then
    self.last_change_id = self.doc:get_change_id()
    return
  end

  local prefix = 0
  while prefix < #old_lines and prefix < #new_lines
    and old_lines[prefix + 1] == new_lines[prefix + 1]
  do
    prefix = prefix + 1
  end

  local old_tail, new_tail = #old_lines, #new_lines
  while old_tail > prefix and new_tail > prefix
    and old_lines[old_tail] == new_lines[new_tail]
  do
    old_tail = old_tail - 1
    new_tail = new_tail - 1
  end

  local new_meta = {}
  for i = 1, prefix do new_meta[i] = old_meta[i] or NO_META end

  local old_count = old_tail - prefix
  local new_count = new_tail - prefix
  local old_by_text = {}
  for i = 1, old_count do
    local idx = prefix + i
    local text = old_lines[idx]
    old_by_text[text] = old_by_text[text] or {}
    old_by_text[text][#old_by_text[text] + 1] = old_meta[idx] or NO_META
  end

  if old_count == new_count then
    local unchanged = 0
    for i = 1, new_count do
      local list = old_by_text[new_lines[prefix + i]]
      if list and #list > 0 then unchanged = unchanged + 1 end
    end
    local treat_as_reorder = unchanged == new_count
    for i = 1, new_count do
      local text = new_lines[prefix + i]
      local list = old_by_text[text]
      if treat_as_reorder and list and #list > 0 then
        new_meta[prefix + i] = table.remove(list, 1)
      else
        new_meta[prefix + i] = old_meta[prefix + i] or NO_META
      end
    end
  else
    -- Insertions/deletions can touch several disjoint ranges before we sync
    -- metadata. Preserve unchanged lines inside the changed block by matching
    -- their text in order, and use structured filetree clipboard metadata for
    -- genuinely inserted rows when available.
    local inserted_meta = filetree_clipboard_metas_for_lines(self, new_lines, prefix + 1, new_count)
    for i = 1, new_count do
      local text = new_lines[prefix + i]
      local list = old_by_text[text]
      if list and #list > 0 then
        new_meta[prefix + i] = table.remove(list, 1)
      else
        new_meta[prefix + i] = (inserted_meta and inserted_meta[i]) or NO_META
      end
    end
  end

  local suffix_count = #new_lines - new_tail
  for i = 0, suffix_count - 1 do
    new_meta[new_tail + 1 + i] = old_meta[old_tail + 1 + i] or NO_META
  end

  self.line_meta = new_meta
  recover_known_line_meta(self)
  self:snapshot_lines()
  self.status_cache = nil
end

function FileTreeView:remember_original(item)
  if item.project_path_separator or item.project_path_readonly then return end
  self.known_originals[path_key(item.abs)] = {
    abs = item.abs,
    type = item.type,
    size = item.size,
    modified = item.modified,
  }
end

function FileTreeView:capture_expanded_paths()
  if self.rendered_dir ~= self.current_dir and not common.path_equals(self.rendered_dir, self.current_dir) then return {} end

  local expanded = {}
  local entries = self:build_entries(false)
  for _, entry in ipairs(entries) do
    if entry.type == "dir" and type(entry.meta) == "table" and entry.meta.expanded then
      expanded[entry.abs] = true
    end
  end
  return expanded
end

function FileTreeView:add_reveal_paths(expanded, paths)
  for _, target in ipairs(paths or {}) do
    if target and in_project(target, self.current_dir) then
      local dir = parent_dir(target)
      while dir and not common.path_equals(dir, self.current_dir) and in_project(dir, self.current_dir) do
        expanded[dir] = true
        dir = parent_dir(dir)
      end
    elseif target then
      local resolved = project_paths.resolve(target)
      local entry = resolved and resolved.entry
      if entry and entry.role ~= "root" and resolved.flags.browsable ~= false then
        expanded[entry.path] = true
        local dir = parent_dir(target)
        while dir and not common.path_equals(dir, entry.path) and in_project(dir, entry.path) do
          expanded[dir] = true
          dir = parent_dir(dir)
        end
      end
    end
  end
end

function FileTreeView:restore_expanded_paths(expanded)
  local paths = {}
  for path in pairs(expanded or {}) do
    if not common.path_equals(path, self.current_dir) then paths[#paths + 1] = path end
  end
  table.sort(paths, function(a, b)
    local da, db = path_depth(a), path_depth(b)
    if da ~= db then return da < db end
    return #a < #b
  end)

  for _, path in ipairs(paths) do
    local entries = self:build_entries(false)
    for _, entry in ipairs(entries) do
      if common.path_equals(entry.abs, path) and entry.type == "dir" then
        local meta = self.line_meta[entry.line]
        if type(meta) == "table" and not meta.expanded and system.get_file_info(path) then
          self:expand_folder(entry.line, entry, false)
        end
        break
      end
    end
  end
end

function FileTreeView:capture_selection_paths()
  self:sync_meta()
  local entries, errors = self:build_entries(false)
  local by_line = {}
  for _, entry in ipairs(entries) do
    if not errors[entry.line] then by_line[entry.line] = entry end
  end

  local selections = {}
  for idx, line1, col1, line2, col2 in self.doc:get_selections(false) do
    local entry1 = by_line[line1]
    local entry2 = by_line[line2]
    if not entry1 or not entry2 then return nil end
    selections[idx] = {
      line1_abs = entry1.abs,
      col1 = col1,
      line2_abs = entry2.abs,
      col2 = col2,
    }
  end
  if #selections == 0 then return nil end
  return {
    selections = selections,
    last_selection = self.doc.last_selection,
  }
end

function FileTreeView:restore_selection_paths(snapshot)
  if not snapshot or not snapshot.selections then return false end

  local entries = self:build_entries(false)
  local by_abs = {}
  for _, entry in ipairs(entries) do by_abs[path_key(entry.abs)] = entry end

  local function restore(selections, last_selection)
    local restored = {}
    local primary_line, primary_col
    for idx, selection in ipairs(selections) do
      local entry1 = by_abs[path_key(selection.line1_abs)]
      local entry2 = by_abs[path_key(selection.line2_abs)]
      if not entry1 or not entry2 then return false end
      restored[#restored + 1] = entry1.line
      restored[#restored + 1] = selection.col1
      restored[#restored + 1] = entry2.line
      restored[#restored + 1] = selection.col2
      if idx == last_selection then
        primary_line, primary_col = entry1.line, selection.col1
      end
    end
    if #restored == 0 then return false end

    last_selection = common.clamp(math.floor(tonumber(last_selection) or 1), 1, #restored / 4)
    self:set_selection_state({ selections = restored, last_selection = last_selection })
    if primary_line then self:scroll_to_make_visible(primary_line, primary_col or 1) end
    return true
  end

  if restore(snapshot.selections, snapshot.last_selection) then return true end

  local primary = snapshot.selections[snapshot.last_selection or 1]
  if primary then
    return restore({ primary }, 1)
  end
  return false
end

function FileTreeView:remap_selection_paths(snapshot, path_map)
  if not snapshot or not snapshot.selections or not path_map then return snapshot end

  local function remap_path(abs)
    local direct = path_map[path_key(abs)]
    if direct then return direct end
    for _, move in ipairs(path_map.__moves or {}) do
      if common.path_belongs_to(abs, move.from) then
        local suffix = abs:sub(#move.from + 1)
        if suffix:sub(1, 1) == PATHSEP then
          return common.normalize_path(move.to .. suffix)
        end
      end
    end
    return abs
  end

  local remapped = {
    selections = {},
    last_selection = snapshot.last_selection,
  }
  for idx, selection in ipairs(snapshot.selections) do
    remapped.selections[idx] = {
      line1_abs = remap_path(selection.line1_abs),
      col1 = selection.col1,
      line2_abs = remap_path(selection.line2_abs),
      col2 = selection.col2,
    }
  end
  return remapped
end

local PROJECT_PATH_SECTION_LABELS = {
  vendored = "──────────────── Vendored Project Directories",
  external = "──────────────── External Project Directories",
}

local function project_path_role_for_abs(abs)
  local display = project_paths.display_path(abs, { kind = "filetree" })
  local flags = display and display.flags
  if flags and flags.excluded_entry then return "excluded", display end
  return display and display.root_role, display
end

local function project_path_section_item(role)
  return {
    name = PROJECT_PATH_SECTION_LABELS[role] or ("──────────────── " .. tostring(role)),
    sort_name = "",
    abs = "",
    type = "section",
    display = (PROJECT_PATH_SECTION_LABELS[role] or tostring(role)) .. "\n",
    project_path_role = role,
    project_path_separator = true,
    project_path_readonly = true,
  }
end

local function project_path_root_item(entry)
  local info = system.get_file_info(entry.path)
  local missing = not (info and info.type == "dir")
  return {
    name = entry.label,
    sort_name = (entry.label or ""):lower(),
    abs = entry.path,
    type = "dir",
    size = info and info.size,
    modified = info and info.modified,
    display = entry.label .. "/" .. "\n",
    project_path_role = entry.role,
    project_path_label = entry.label,
    project_path_id = entry.id,
    project_path_root = true,
    project_path_missing = missing,
    project_path_readonly = true,
    project_path_display = entry.label .. "/",
  }
end

function FileTreeView:append_project_path_sections(out)
  local entries_by_role = { vendored = {}, external = {} }
  for _, entry in ipairs(project_paths.entries({ include_root = false })) do
    if entries_by_role[entry.role] then
      entries_by_role[entry.role][#entries_by_role[entry.role] + 1] = entry
    end
  end

  for _, role in ipairs({ "vendored", "external" }) do
    local entries = entries_by_role[role]
    if #entries > 0 then
      if #out > 0 then
        out[#out + 1] = "\n"
        self.line_meta[#out] = NO_META
      end
      local section = project_path_section_item(role)
      out[#out + 1] = section.display
      self.line_meta[#out] = make_meta(section)
      table.sort(entries, function(a, b) return (a.label or "") < (b.label or "") end)
      for _, entry in ipairs(entries) do
        local item = project_path_root_item(entry)
        out[#out + 1] = item.display
        self.line_meta[#out] = make_meta(item)
      end
    end
  end
end

function FileTreeView:refresh_preserving_selection_paths(preserve_expansion, reveal_paths, path_map, selection_paths)
  selection_paths = selection_paths or self:capture_selection_paths()
  self:refresh(false, preserve_expansion, reveal_paths)
  selection_paths = self:remap_selection_paths(selection_paths, path_map)
  if selection_paths and not self:restore_selection_paths(selection_paths) then
    core.log_quiet("File Tree refresh could not restore selection by path")
  end
end

function FileTreeView:refresh(keep_selection, preserve_expansion, reveal_paths)
  local l, c = self.doc:get_selection()
  local expanded = preserve_expansion == false and {} or self:capture_expanded_paths()
  self:add_reveal_paths(expanded, reveal_paths)

  self.original_entries = sorted_dir(self.current_dir, filetree_config.show_hidden)
  self.original_by_name = {}
  self.known_originals = {}
  self.line_meta = {}
  self.line_hint_cache = {}
  self.line_hint_count_cache = {}
  self.line_hint_count_pending = {}
  self.line_hint_count_queue = {}

  local out = {}
  for i, item in ipairs(self.original_entries) do
    local role, display = project_path_role_for_abs(item.abs)
    item.project_path_role = role
    item.project_path_label = display and display.root_label
    item.project_path_id = display and display.root_id
    item.project_path_readonly = false
    self.original_by_name[item.name] = i
    self:remember_original(item)
    out[#out + 1] = item.display .. "\n"
    self.line_meta[i] = make_meta(item)
  end
  self:append_project_path_sections(out)
  set_doc_lines(self.doc, out)
  for i = #out + 1, #self.doc.lines do self.line_meta[i] = NO_META end
  self.rendered_dir = self.current_dir
  self:snapshot_lines()
  self.status_cache = nil
  self.filesystem_watch_update_suppressed = (self.filesystem_watch_update_suppressed or 0) + 1
  self:restore_expanded_paths(expanded)
  self.filesystem_watch_update_suppressed = math.max(0, (self.filesystem_watch_update_suppressed or 1) - 1)
  self.has_possible_edits = false

  if keep_selection then
    self.doc:set_selection(math.min(l, #self.doc.lines), c)
  end
  self:update_filesystem_watches()
  self:schedule_git_status_refresh("filetree-refresh", true)
end

function FileTreeView:get_sort_mode()
  return filetree_config.sort_mode
end

function FileTreeView:apply_sort_mode(sort_mode)
  local requested_sort_mode = sort_mode
  sort_mode = normalize_sort_mode(sort_mode)
  if not sort_mode then
    core.warn("File Tree: unknown sort mode: %s", tostring(requested_sort_mode))
    return false
  end
  if filetree_config.sort_mode == sort_mode then return true end

  if self.has_possible_edits then
    core.warn("File Tree: apply or refresh edits before changing sort")
    core.log_quiet("File Tree sort change blocked because the editable tree has unapplied edits")
    return false
  end

  local previous = filetree_config.sort_mode
  local selection_paths = self:capture_selection_paths()
  filetree_config.sort_mode = sort_mode
  save_sort_mode(sort_mode)
  core.log_quiet("File Tree sort changed from %s to %s", previous, sort_mode)

  self:refresh(false, true)
  if selection_paths and not self:restore_selection_paths(selection_paths) then
    core.log_quiet("File Tree sort changed but selection path restore did not find the prior entry")
  end
  core.log("File Tree: sorted by %s", SORT_LABELS[sort_mode] or sort_mode)
  return true
end

function FileTreeView:set_sort_mode(sort_mode)
  return self:with_selection_state(function()
    return self:apply_sort_mode(sort_mode)
  end)
end

function FileTreeView:doc_splice(at, remove, insert_lines, insert_meta)
  insert_lines = insert_lines or {}
  insert_meta = insert_meta or {}
  common.splice(self.doc.lines, at, remove, insert_lines)
  if remove > 0 then self.doc.highlighter:remove_notify(at, remove) end
  if #insert_lines > 0 then self.doc.highlighter:insert_notify(at, #insert_lines) end
  self.doc:clear_cache(at, math.max(remove, #insert_lines))
  self.doc:sanitize_selection()

  for i = 1, #insert_lines do
    if insert_meta[i] == nil then insert_meta[i] = NO_META end
  end
  common.splice(self.line_meta, at, remove, insert_meta)
  if #self.doc.lines == 0 then
    self.doc.lines[1] = "\n"
    self.line_meta[1] = NO_META
  end
  -- Expand/collapse is navigation, not filesystem editing. It rewrites the
  -- backing text buffer outside Doc's undo machinery, so stale undo entries can
  -- point at removed lines. Drop them to avoid corrupt undo history.
  self.doc:clear_undo_redo()
  self:snapshot_lines()
  self.status_cache = nil
end

function FileTreeView:copy_line_payload(slots)
  local payload = { text = "", items = {}, slots = {} }
  local chunks = {}
  for _, slot in ipairs(slots) do
    local slot_chunks, slot_items = {}, {}
    for line = slot.first, slot.last do
      local text = self.doc.lines[line] or "\n"
      local item = {
        text = line_text(text),
        meta = clone_meta(self.line_meta[line]),
      }
      chunks[#chunks + 1] = text
      payload.items[#payload.items + 1] = item
      slot_chunks[#slot_chunks + 1] = text
      slot_items[#slot_items + 1] = item
    end
    payload.slots[#payload.slots + 1] = {
      text = table.concat(slot_chunks),
      items = slot_items,
    }
  end
  payload.text = table.concat(chunks)
  return payload
end

local function merge_line_ranges(ranges)
  table.sort(ranges, function(a, b) return a.first < b.first end)
  local merged = {}
  for _, range in ipairs(ranges) do
    local prev = merged[#merged]
    if prev and range.first <= prev.last + 1 then
      prev.last = math.max(prev.last, range.last)
    else
      merged[#merged + 1] = { first = range.first, last = range.last }
    end
  end
  return merged
end

function FileTreeView:selected_whole_line_slots()
  self:sync_meta()
  local slots = {}
  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    local first, last
    if line1 == line2 and col1 == col2 then
      first, last = line1, line1
    elseif col1 == 1 then
      if line2 > line1 and col2 == 1 then
        first, last = line1, line2 - 1
      elseif col2 >= #(self.doc.lines[line2] or "") then
        first, last = line1, line2
      end
    end
    if not first or first > last then return nil end
    first = math.max(1, first)
    last = math.min(#self.doc.lines, last)
    slots[#slots + 1] = { first = first, last = last }
  end

  table.sort(slots, function(a, b) return a.first < b.first end)
  return slots
end

function FileTreeView:selected_covered_line_slots()
  self:sync_meta()
  local slots = {}
  for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
    local first, last = line1, line2
    if line1 ~= line2 and col2 <= 1 then
      last = line2 - 1
    end
    if first <= last then
      first = math.max(1, first)
      last = math.min(#self.doc.lines, last)
      slots[#slots + 1] = { first = first, last = last }
    end
  end

  table.sort(slots, function(a, b) return a.first < b.first end)
  return slots
end

function FileTreeView:remove_line_range(first, last)
  if first > last then return end
  if first == 1 and last >= #self.doc.lines then
    self.doc:remove(1, 1, #self.doc.lines, math.huge)
  elseif last < #self.doc.lines then
    self.doc:remove(first, 1, last + 1, 1)
  else
    self.doc:remove(first - 1, math.huge, last, math.huge)
  end
end

function FileTreeView:copy_or_cut_lines(delete)
  local slots = self:selected_whole_line_slots()
  if not slots or #slots == 0 then
    core.filetree_clipboard = nil
    return false
  end
  local ranges = merge_line_ranges(slots)
  local payload = self:copy_line_payload(slots)
  payload.mode = delete and "cut" or "copy"
  system.set_clipboard(payload.text)
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  core.filetree_clipboard = payload

  if delete then
    local edits = {}
    for _, range in ipairs(ranges) do
      if range.first == 1 and range.last >= #self.doc.lines then
        edits[#edits + 1] = { line1 = 1, col1 = 1, line2 = #self.doc.lines, col2 = math.huge, text = "" }
      elseif range.last < #self.doc.lines then
        edits[#edits + 1] = { line1 = range.first, col1 = 1, line2 = range.last + 1, col2 = 1, text = "" }
      else
        edits[#edits + 1] = { line1 = range.first - 1, col1 = math.huge, line2 = range.last, col2 = math.huge, text = "" }
      end
    end
    self.doc:apply_edits(edits, { type = "remove", merge_cursors = true })
    for i = #ranges, 1, -1 do
      local range = ranges[i]
      common.splice(self.line_meta, range.first, range.last - range.first + 1)
    end
    if #self.line_meta == 0 then self.line_meta[1] = NO_META end
    self:snapshot_lines()
  end
  return true
end

function FileTreeView:paste_lines_with_metadata()
  local payload = core.filetree_clipboard
  local clipboard = system.get_clipboard()
  if not payload or not payload.items or #payload.items == 0 then return false end
  if clipboard ~= payload.text then return false end

  local function cloned_metas(items)
    local metas = {}
    for i, item in ipairs(items or {}) do metas[i] = clone_meta(item.meta) end
    return metas
  end

  local lines = {}
  for idx in self.doc:get_selections() do
    local line = self.doc:get_selection_idx(idx)
    if line then lines[#lines + 1] = line end
  end
  table.sort(lines)

  local records = {}
  if payload.slots and #payload.slots == #lines then
    for i, line in ipairs(lines) do
      local slot = payload.slots[i]
      records[#records + 1] = {
        line = line,
        text = (slot.text or ""):gsub("\r", ""),
        metas = cloned_metas(slot.items),
      }
    end
  else
    for _, line in ipairs(lines) do
      records[#records + 1] = {
        line = line,
        text = (payload.text or ""):gsub("\r", ""),
        metas = cloned_metas(payload.items),
      }
    end
  end

  local edits = {}
  for _, record in ipairs(records) do
    edits[#edits + 1] = { line1 = record.line, col1 = 1, line2 = record.line, col2 = 1, text = record.text }
  end
  self.doc:apply_edits(edits, { type = "insert", merge_cursors = false })

  table.sort(records, function(a, b) return a.line > b.line end)
  for _, record in ipairs(records) do
    common.splice(self.line_meta, record.line, 0, record.metas)
  end
  self:snapshot_lines()
  self.status_cache = nil
  return true
end

function FileTreeView:parse_line(line)
  local parsed = parse_text(line_text(self.doc.lines[line]))
  return parsed
end

function FileTreeView:line_is_dir(line)
  local stats = perf_stats()
  local start = perf_call(stats, "filetree_line_is_dir_calls")
  local meta = self.line_meta[line]
  if type(meta) == "table" and meta.project_path_separator then
    perf_finish(stats, "filetree_line_is_dir_ms", start)
    return false
  end
  local parsed = self:parse_line(line)
  local result = (parsed and parsed.wants_dir) or (type(meta) == "table" and meta.original_type == "dir")
  perf_finish(stats, "filetree_line_is_dir_ms", start)
  return result
end

function FileTreeView:get_line_hint_entry(line)
  local stats = perf_stats()
  local start = perf_call(stats, "filetree_line_hint_entry_calls")
  local change_id = self.doc:get_change_id()
  if self.__line_hint_entries_change_id ~= change_id
      or self.__line_hint_entries_dir ~= self.current_dir then
    perf_add(stats, "filetree_line_hint_entry_rebuilds", 1)
    local build_start = perf_start(stats)
    local entries, errors = self:build_entries(false)
    local by_line = {}
    for _, entry in ipairs(entries) do by_line[entry.line] = entry end
    self.__line_hint_entries_change_id = change_id
    self.__line_hint_entries_dir = self.current_dir
    self.__line_hint_entries_by_line = by_line
    self.__line_hint_errors = errors
    perf_finish(stats, "filetree_line_hint_entry_build_ms", build_start)
  end
  local entry
  if not (self.__line_hint_errors and self.__line_hint_errors[line]) then
    entry = self.__line_hint_entries_by_line and self.__line_hint_entries_by_line[line]
  end
  perf_finish(stats, "filetree_line_hint_entry_ms", start)
  return entry
end

function FileTreeView:line_hint_count_key(abs, show_hidden)
  if show_hidden == nil then show_hidden = filetree_config.show_hidden end
  return (show_hidden and "1" or "0") .. "\0" .. abs
end

function FileTreeView:pop_line_hint_count_task()
  for i, task in ipairs(self.line_hint_count_queue or {}) do
    if task.priority then
      return table.remove(self.line_hint_count_queue, i)
    end
  end
  return table.remove(self.line_hint_count_queue, 1)
end

function FileTreeView:start_line_hint_count_worker()
  if self.line_hint_count_worker_running then return end
  self.line_hint_count_worker_running = true

  core.add_thread(function()
    local batch_updated = false
    local batch_start = system.get_time()

    while true do
      local task = self:pop_line_hint_count_task()
      if not task then break end

      local info = system.get_file_info(task.abs)
      if info and info.type == "dir" and info.modified == task.modified then
        local folders, files, err = count_direct_children(
          task.abs, task.show_hidden, LINE_HINT_COUNT_CHILD_BUDGET
        )
        local latest = system.get_file_info(task.abs)
        if latest and latest.type == "dir" and latest.modified == task.modified then
          self.line_hint_count_cache[task.key] = {
            modified = task.modified,
            folders = folders,
            files = files,
            error = err,
          }
          if err then
            core.log_quiet("File Tree Line Hint count failed for %s: %s", task.abs, err)
          end
          batch_updated = true
        end
      end
      if self.line_hint_count_pending[task.key] == task then
        self.line_hint_count_pending[task.key] = nil
      end

      if system.get_time() - batch_start >= LINE_HINT_COUNT_WORKER_BUDGET then
        if batch_updated then
          core.redraw = true
          batch_updated = false
        end
        coroutine.yield(0)
        batch_start = system.get_time()
      end
    end

    if batch_updated then core.redraw = true end
    self.line_hint_count_worker_running = false
  end)
end

function FileTreeView:get_folder_hint_counts(abs, modified, priority)
  self.line_hint_count_cache = self.line_hint_count_cache or {}
  self.line_hint_count_pending = self.line_hint_count_pending or {}
  self.line_hint_count_queue = self.line_hint_count_queue or {}

  local key = self:line_hint_count_key(abs)
  local cached = self.line_hint_count_cache[key]
  if cached and cached.modified == modified then return cached end

  local pending = self.line_hint_count_pending[key]
  if pending then
    pending.modified = modified
    pending.show_hidden = filetree_config.show_hidden
    pending.priority = pending.priority or priority
    return nil, true
  end

  pending = {
    key = key,
    abs = abs,
    modified = modified,
    show_hidden = filetree_config.show_hidden,
    priority = priority,
  }
  self.line_hint_count_pending[key] = pending
  table.insert(self.line_hint_count_queue, pending)
  self:start_line_hint_count_worker()
  return nil, true
end

function FileTreeView:format_line_hint_for_path(abs, info)
  local stats = perf_stats()
  local start = perf_start(stats)
  if not info or not info.type then perf_finish(stats, "filetree_line_hint_format_ms", start); return nil end

  local modified = format_modified_time(info.modified)
  if not modified then perf_finish(stats, "filetree_line_hint_format_ms", start); return nil end

  if info.type == "file" then
    self.line_hint_cache = self.line_hint_cache or {}
    local key = self:line_hint_count_key(abs)
    local cached = self.line_hint_cache[key]
    if cached and cached.type == info.type
        and cached.size == info.size
        and cached.modified == info.modified then
      perf_add(stats, "filetree_line_hint_cache_hits", 1)
      perf_finish(stats, "filetree_line_hint_format_ms", start)
      return cached.text
    end

    perf_add(stats, "filetree_line_hint_cache_misses", 1)
    local text = string.format("%s · %s", format_file_size(info.size), modified)
    self.line_hint_cache[key] = {
      type = info.type,
      size = info.size,
      modified = info.modified,
      text = text,
    }
    perf_finish(stats, "filetree_line_hint_format_ms", start)
    return text
  elseif info.type == "dir" then
    local counts = self:get_folder_hint_counts(abs, info.modified, true)
    if counts and counts.error then perf_finish(stats, "filetree_line_hint_format_ms", start); return modified end
    if counts and counts.folders and counts.files then
      perf_add(stats, "filetree_line_hint_folder_count_hits", 1)
      perf_finish(stats, "filetree_line_hint_format_ms", start)
      return string.format("%4d   · %s", counts.folders + counts.files, modified)
    end
    perf_add(stats, "filetree_line_hint_folder_count_pending", 1)
    perf_finish(stats, "filetree_line_hint_format_ms", start)
    return string.format("%s   · %s", "   …", modified)
  end
  perf_finish(stats, "filetree_line_hint_format_ms", start)
end

function FileTreeView:get_line_hint(line)
  local stats = perf_stats()
  local start = perf_call(stats, "filetree_line_hint_calls")
  local function finish(result)
    perf_finish(stats, "filetree_line_hint_ms", start)
    return result
  end

  if not filetree_config.show_line_hints then return finish(nil) end
  if self.has_possible_edits and self:get_line_status(line) == "invalid" then return finish(nil) end

  local entry = self:get_line_hint_entry(line)
  if not entry then return finish(nil) end

  local info = entry.cached_info
  if not info or info.type ~= entry.type then return finish(nil) end

  local text = self:format_line_hint_for_path(entry.abs, info)
  if not text then return finish(nil) end

  local font = self:get_font()
  local dim = style.dim
  local git_start = perf_start(stats)
  local git = self:get_git_info_for_entry(entry)
  perf_finish(stats, "filetree_line_hint_git_ms", git_start)
  local segments = filetree_render.changed_stat_segments(git and git.stat, font) or {}
  if #segments > 0 then segments[#segments + 1] = { text = "   ", font = font, color = dim } end
  if #segments == 0 and git and git.kind == "ignored" then
    segments[#segments + 1] = { text = "ignored   ", font = font, color = style.filetree_git_status_ignored }
  end
  if #segments == 0 then
    perf_add(stats, "filetree_line_hint_segments", 1)
    return finish({ text = text, font = font, color = dim })
  end
  segments[#segments + 1] = { text = text, font = font, color = dim }
  perf_add(stats, "filetree_line_hint_segments", #segments)
  return finish(segments)
end

function FileTreeView:draw_folder_row_background(line, x, y, width)
  local stats = perf_stats()
  local start = perf_call(stats, "filetree_folder_row_background_calls")
  local color = filetree_config.folder_row_background
  if not color or not self:line_is_dir(line) then
    perf_finish(stats, "filetree_folder_row_background_ms", start)
    return false
  end
  renderer.draw_rect(x, y, width, self:get_line_height(), color)
  perf_add(stats, "filetree_folder_row_background_rects", 1)
  perf_finish(stats, "filetree_folder_row_background_ms", start)
  return true
end

function FileTreeView:draw_line_body(line, x, y)
  local stats = perf_stats()
  local start = perf_call(stats, "filetree_draw_line_body_calls")
  local gw = self:get_gutter_width()
  self:draw_folder_row_background(
    line,
    x + self.scroll.x,
    y,
    math.max(0, self.size.x - gw)
  )
  local result = FileTreeView.super.draw_line_body(self, line, x, y)
  perf_finish(stats, "filetree_draw_line_body_ms", start)
  return result
end

function FileTreeView:project_path_line_color(line)
  local meta = self.line_meta[line]
  if type(meta) ~= "table" then return nil end
  if meta.project_path_missing then return style.project_path_missing end
  if meta.project_path_separator then return style.project_path_separator end
  if meta.project_path_role == "external" then return style.project_path_external end
  if meta.project_path_role == "vendored" then return style.project_path_vendored end
  if meta.project_path_role == "excluded" then return style.project_path_excluded end
  return nil
end

function FileTreeView:draw_line_text(line, x, y)
  local stats = perf_stats()
  local start = perf_call(stats, "filetree_draw_line_text_calls")
  local git_start = perf_start(stats)
  local git = self:get_git_info_for_line(line)
  perf_finish(stats, "filetree_draw_line_text_git_ms", git_start)
  local text = line_text(self.doc:get_utf8_line(line))
  local project_path_color = self:project_path_line_color(line)
  if project_path_color then
    renderer.draw_text(
      self:get_font(), text, x, y + self:get_line_text_y_offset(), project_path_color,
      { tab_offset = 0 }
    )
    perf_add(stats, "filetree_draw_line_text_colored_calls", 1)
    perf_finish(stats, "filetree_draw_line_text_ms", start)
    return self:get_line_height()
  end
  if not filetree_render.draw_row_text(self, text, x, y, git and git.kind, self:line_is_dir(line)) then
    perf_add(stats, "filetree_draw_line_text_plain_calls", 1)
    local result = FileTreeView.super.draw_line_text(self, line, x, y)
    perf_finish(stats, "filetree_draw_line_text_ms", start)
    return result
  end

  perf_add(stats, "filetree_draw_line_text_colored_calls", 1)
  perf_finish(stats, "filetree_draw_line_text_ms", start)
  return self:get_line_height()
end

function FileTreeView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  self:draw_folder_row_background(line, self.position.x, y, gw)
  local status = self:get_line_status(line)
  if status then
    local color = filetree_render.git_gutter_color(status) or style.git_change_deletion
    local w = style.gitdiff_width
    renderer.draw_rect(x + style.padding.x * 0.5, y, w, lh, color)
  end
  return lh
end

function FileTreeView:collect_draft_rows(rows, draft, base_indent, parent_line)
  if not draft then return end
  for i, rel in ipairs(draft.lines or {}) do
    local meta = (draft.meta and draft.meta[i]) or NO_META
    local text = indent_prefix(base_indent) .. line_text(rel)
    rows[#rows + 1] = {
      line = parent_line,
      text = text,
      meta = meta,
      hidden = true,
      parent_line = parent_line,
      draft = draft,
      draft_index = i,
    }
    if type(meta) == "table" and meta.draft and not meta.expanded then
      local parsed = parse_text(text)
      if parsed then
        self:collect_draft_rows(rows, meta.draft, parsed.indent + INDENT, parent_line)
      end
    end
  end
end

function FileTreeView:collect_rows(include_hidden)
  local rows = {}
  for i, line in ipairs(self.doc.lines) do
    local meta = self.line_meta[i] or NO_META
    local text = line_text(line)
    rows[#rows + 1] = { line = i, text = text, meta = meta, hidden = false }
    if include_hidden and type(meta) == "table" and meta.draft and not meta.expanded then
      local parsed = parse_text(text)
      if parsed then
        self:collect_draft_rows(rows, meta.draft, parsed.indent + INDENT, i)
      end
    end
  end
  return rows
end

function FileTreeView:build_entries(include_hidden)
  self:sync_meta()
  local rows = self:collect_rows(include_hidden)
  local entries, errors = {}, {}
  local root = { abs = self.current_dir, type = "dir", level = -1 }
  local stack = {}

  for _, row in ipairs(rows) do
    local meta = type(row.meta) == "table" and row.meta or nil
    if meta and meta.project_path_separator then goto continue end

    local parsed, err = parse_text(row.text)
    if err then
      errors[row.line] = err
      goto continue
    end
    if not parsed then goto continue end -- blank lines are ignored

    local parent = parsed.level == 0 and root or stack[parsed.level - 1]
    if not parent or parent.type ~= "dir" then
      errors[row.line] = "missing folder parent for indentation"
      goto continue
    end

    local abs
    if meta and meta.project_path_root and meta.original_abs then
      abs = meta.original_abs
    else
      abs = system.absolute_path(path_join(parent.abs, parsed.name))
        or common.normalize_path(path_join(parent.abs, parsed.name))
    end
    local resolved = project_paths.resolve(abs)
    if not (resolved and resolved.flags.browsable ~= false) then
      errors[row.line] = "path escapes Project Paths"
      goto continue
    end

    local entry_type = parsed.wants_dir and "dir" or "file"
    if meta and meta.original_type and meta.original_type ~= entry_type then
      errors[row.line] = "changing file/folder type is not supported"
    end

    local entry = {
      line = row.line,
      parent_line = row.parent_line,
      hidden = row.hidden,
      text = parsed.name,
      abs = abs,
      type = entry_type,
      level = parsed.level,
      meta = meta,
      original_abs = meta and meta.original_abs,
      original_type = meta and meta.original_type,
      original_size = meta and meta.original_size,
      original_modified = meta and meta.original_modified,
      cached_info = cached_info_from_meta(meta, abs, entry_type),
      draft = row.draft,
      draft_index = row.draft_index,
      readonly = (meta and meta.project_path_readonly) or parent.readonly or false,
      project_path_role = meta and meta.project_path_role or parent.project_path_role,
      project_path_root = meta and meta.project_path_root or false,
      project_path_missing = meta and meta.project_path_missing or false,
    }
    entries[#entries + 1] = entry

    stack[parsed.level] = entry
    local deeper = parsed.level + 1
    while stack[deeper] do
      stack[deeper] = nil
      deeper = deeper + 1
    end

    ::continue::
  end

  return entries, errors
end

function FileTreeView:plan_changes(status_only)
  local entries, errors = self:build_entries(true)
  local status = {}
  local invalid = false
  local invalid_reasons = {}
  local ambiguities = {}

  local function draw_line(e)
    return e.hidden and e.parent_line or e.line
  end

  local function mark_invalid(line_or_entry, reason)
    local line = type(line_or_entry) == "table" and draw_line(line_or_entry) or line_or_entry
    if line then status[line] = "invalid" end
    invalid = true
    if reason then
      invalid_reasons[#invalid_reasons + 1] = line and string.format("line %d: %s", line, reason) or reason
    end
  end

  for line, err in pairs(errors) do mark_invalid(line, err) end

  local mutable_entries = {}
  for _, e in ipairs(entries) do
    if e.readonly then
      if not e.original_abs
          or not common.path_equals(e.abs, e.original_abs)
          or e.original_type ~= e.type then
        mark_invalid(e, "Project Path Role sections are browse/open-only")
      end
    else
      mutable_entries[#mutable_entries + 1] = e
    end
  end
  entries = mutable_entries

  local by_abs = {}
  for _, e in ipairs(entries) do
    local key = path_key(e.abs)
    by_abs[key] = by_abs[key] or {}
    table.insert(by_abs[key], e)
  end
  for _, list in pairs(by_abs) do
    if #list > 1 then
      for _, e in ipairs(list) do mark_invalid(e, "duplicate target path: " .. op_path(e.abs)) end
    end
  end

  local explicit_sources = {}
  for _, e in ipairs(entries) do
    if e.original_abs then explicit_sources[path_key(e.original_abs)] = true end
  end

  local groups = {}
  local creates = {}
  local function add_group(src, e)
    local key = path_key(src)
    local group = groups[key]
    if not group then
      group = { src = src, entries = {} }
      groups[key] = group
    end
    group.entries[#group.entries + 1] = e
  end

  for _, e in ipairs(entries) do
    if status[draw_line(e)] ~= "invalid" then
      local src = e.original_abs
      local src_type = e.original_type

      -- If metadata was lost but the row still names a known original at the
      -- same path, treat it as that original instead of a conflicting create.
      local entry_key = path_key(e.abs)
      local known = self.known_originals[entry_key]
      if not src and known and known.type == e.type and not explicit_sources[entry_key] then
        src, src_type = known.abs, known.type
      end

      if src then
        if src_type ~= e.type then
          mark_invalid(e, "changing file/folder type is not supported: " .. op_path(e.abs))
        else
          add_group(src, e)
        end
      else
        local replaces_existing = explicit_sources[path_key(e.abs)]
        if system.get_file_info(e.abs) and not replaces_existing then
          mark_invalid(e, "target already exists: " .. op_path(e.abs))
        else
          creates[#creates + 1] = {
            path = e.abs,
            type = e.type,
            line = e.line,
            hidden = e.hidden,
            parent_line = e.parent_line,
            force_create = e.meta and e.meta.force_create,
            replaces_existing = replaces_existing,
            draft = e.draft,
            draft_index = e.draft_index,
          }
          status[draw_line(e)] = status[draw_line(e)] or "addition"
        end
      end
    end
  end

  local copies, moves, trashes = {}, {}, {}
  local seen_sources = {}
  local vacated_sources = {}
  for _, group in pairs(groups) do
    local src, list = group.src, group.entries
    if self.known_originals[path_key(src)] then
      local kept_original = false
      for _, e in ipairs(list) do
        if common.path_equals(e.abs, src) then kept_original = true; break end
      end
      if not kept_original and system.get_file_info(src) then vacated_sources[path_key(src)] = src end
    end
  end

  local function check_target(op, e, allow_vacated_target)
    if common.path_equals(op.to, op.from) then return false end
    if op.type == "dir" and common.path_belongs_to(op.to, op.from) then
      mark_invalid(e, "cannot move/copy a folder into itself: " .. op_path(op.from) .. " -> " .. op_path(op.to))
      return false
    end
    local target_vacated = vacated_sources[path_key(op.to)] ~= nil
    if allow_vacated_target and not target_vacated then
      for _, vacated in pairs(vacated_sources) do
        if common.path_belongs_to(op.to, vacated) then target_vacated = true; break end
      end
    end
    if system.get_file_info(op.to) and not (allow_vacated_target and target_vacated) then
      mark_invalid(e, "target already exists: " .. op_path(op.to))
      return false
    end
    return true
  end

  for _, group in pairs(groups) do
    local src, list = group.src, group.entries
    seen_sources[path_key(src)] = true
    table.sort(list, function(a, b) return (a.line or 0) < (b.line or 0) end)

    local orig = self.known_originals[path_key(src)]
    local source_known_here = orig ~= nil
    local source_type = (orig and orig.type) or (list[1] and list[1].original_type) or (list[1] and list[1].type)

    local kept_original
    local changed = {}
    for _, e in ipairs(list) do
      if common.path_equals(e.abs, src) then
        kept_original = e
      else
        changed[#changed + 1] = e
      end
    end
    local source_info = #changed > 0 and system.get_file_info(src) or nil

    if source_known_here and not kept_original and #changed == 0 then
      trashes[#trashes + 1] = { abs = src, type = source_type }
    elseif not source_info and #changed > 0 then
      for _, e in ipairs(changed) do mark_invalid(e, "source no longer exists: " .. op_path(src)) end
    elseif kept_original or not source_known_here then
      -- Original still exists in this editable snapshot, or the source came
      -- from stale/off-screen filetree clipboard metadata. Extra occurrences are
      -- copies; never delete/move a source that this buffer did not own.
      for _, e in ipairs(changed) do
        local op = {
          from = src,
          to = e.abs,
          type = source_type,
          line = e.line,
          hidden = e.hidden,
          parent_line = e.parent_line,
        }
        if check_target(op, e, false) then
          copies[#copies + 1] = op
          status[draw_line(e)] = status[draw_line(e)] or "addition"
        end
      end
    else
      -- The original row disappeared from this snapshot. One destination is the
      -- move; additional destinations are copies, matching Oil's convention of
      -- making the final occurrence the move.
      for i, e in ipairs(changed) do
        local op = {
          from = src,
          to = e.abs,
          type = source_type,
          line = e.line,
          hidden = e.hidden,
          parent_line = e.parent_line,
        }
        if check_target(op, e, i == #changed) then
          if i == #changed then
            moves[#moves + 1] = op
            status[draw_line(e)] = status[draw_line(e)] or "modification"
          else
            copies[#copies + 1] = op
            status[draw_line(e)] = status[draw_line(e)] or "addition"
          end
        end
      end
    end
  end

  for _, orig in pairs(self.known_originals) do
    local abs = orig.abs
    if not seen_sources[path_key(abs)] then
      trashes[#trashes + 1] = { abs = abs, type = orig.type }
    end
  end

  -- Do not emit child trashes when a containing folder is already trashed.
  table.sort(trashes, function(a, b) return #a.abs < #b.abs end)
  local filtered_trashes, trashed_dirs = {}, {}
  for _, op in ipairs(trashes) do
    local covered = false
    for dir in pairs(trashed_dirs) do
      if common.path_belongs_to(op.abs, dir) then covered = true; break end
    end
    if not covered then
      filtered_trashes[#filtered_trashes + 1] = op
      if op.type == "dir" then trashed_dirs[op.abs] = true end
    end
  end
  trashes = filtered_trashes

  -- If metadata was lost, a cut/paste can look like "create this basename" +
  -- "trash that same basename". Do not silently turn a file move/copy into
  -- destructive delete + empty create; force the user to resolve it by using
  -- filetree's metadata-preserving copy/cut/paste path.
  local creates_by_type = {}
  for _, create in ipairs(creates) do
    creates_by_type[create.type] = (creates_by_type[create.type] or 0) + 1
  end
  for _, create in ipairs(creates) do
    if not create.force_create then
      local candidates, same_type_candidates = {}, {}
      local create_name = common.basename(create.path)
      for _, trash in ipairs(trashes) do
        if trash.type == create.type then
          same_type_candidates[#same_type_candidates + 1] = { abs = trash.abs, type = trash.type }
          if common.basename(trash.abs) == create_name then
            candidates[#candidates + 1] = { abs = trash.abs, type = trash.type }
          end
        end
      end
      if #candidates == 0 and #same_type_candidates > 0 then
        candidates = same_type_candidates
      end
      if #candidates > 0 then
        local matches = {}
        for _, candidate in ipairs(candidates) do matches[#matches + 1] = op_path(candidate.abs) end
        ambiguities[#ambiguities + 1] = {
          line = create.line,
          path = create.path,
          type = create.type,
          candidates = candidates,
          draft = create.draft,
          draft_index = create.draft_index,
        }
        mark_invalid(create.line, string.format(
          "ambiguous %s '%s': create new, or move/copy from %s",
          create.type, op_path(create.path), table.concat(matches, ", ")
        ))
      end
    end
  end

  -- Parent folder moves cover unchanged child moves. If a child was also moved
  -- elsewhere, rewrite its source to the post-parent-move path.
  table.sort(moves, function(a, b) return #a.from < #b.from end)
  local filtered_moves = {}
  for _, op in ipairs(moves) do
    local skip = false
    for _, parent in ipairs(filtered_moves) do
      if parent.type == "dir" and common.path_belongs_to(op.from, parent.from) then
        local suffix = op.from:sub(#parent.from + 1)
        local mapped = parent.to .. suffix
        if common.path_equals(op.to, mapped) then
          skip = true
        else
          op.from = mapped
        end
        break
      end
    end
    if not skip then filtered_moves[#filtered_moves + 1] = op end
  end
  moves = filtered_moves

  -- If a parent folder is moved but a child row is still shown at its original
  -- path, keep the user's edited tree exact by moving that child back out of
  -- the parent's new location after the parent move.
  table.sort(moves, function(a, b) return #a.from > #b.from end)
  local move_from = {}
  for _, op in ipairs(moves) do move_from[path_key(op.from)] = true end
  for _, e in ipairs(entries) do
    if e.original_abs and common.path_equals(e.abs, e.original_abs) and not move_from[path_key(e.original_abs)] then
      for _, parent in ipairs(moves) do
        if parent.type == "dir" and common.path_belongs_to(e.original_abs, parent.from) then
          local mapped = parent.to .. e.original_abs:sub(#parent.from + 1)
          if not common.path_equals(mapped, e.abs) then
            moves[#moves + 1] = {
              from = mapped,
              to = e.abs,
              type = e.type,
              line = e.line,
              hidden = e.hidden,
              parent_line = e.parent_line,
            }
            status[draw_line(e)] = status[draw_line(e)] or "modification"
            move_from[path_key(e.original_abs)] = true
          end
          break
        end
      end
    end
  end

  local _, cycle_err, cycle_op = ordered_moves_or_cycle(moves)
  if cycle_err then mark_invalid(cycle_op or moves[1], cycle_err) end

  -- If a copied directory's subtree is represented in the editable buffer, do
  -- not recursively copy the whole source directory. Create the destination dir
  -- and let the visible/hidden child entries define the exact copied subtree;
  -- otherwise child renames/deletes would become additive surprises.
  local expanded_copy_dirs = {}
  for _, copy in ipairs(copies) do
    if copy.type == "dir" then
      for _, e in ipairs(entries) do
        local copied_child = e.original_abs
          and (common.path_equals(e.original_abs, copy.from) or common.path_belongs_to(e.original_abs, copy.from))
        if not common.path_equals(e.abs, copy.to) and common.path_belongs_to(e.abs, copy.to) and copied_child then
          expanded_copy_dirs[copy] = true
          creates[#creates + 1] = {
            path = copy.to,
            type = "dir",
            line = copy.line,
            hidden = copy.hidden,
            parent_line = copy.parent_line,
          }
          break
        end
      end
    end
  end

  -- Parent folder copies recursively include unchanged child copies.
  table.sort(copies, function(a, b) return #a.from < #b.from end)
  local filtered_copies = {}
  for _, op in ipairs(copies) do
    local skip = expanded_copy_dirs[op]
    for _, parent in ipairs(filtered_copies) do
      if parent.type == "dir" and common.path_belongs_to(op.from, parent.from) then
        local suffix = op.from:sub(#parent.from + 1)
        if common.path_equals(op.to, parent.to .. suffix) then
          skip = true
          break
        end
      end
    end
    if not skip then filtered_copies[#filtered_copies + 1] = op end
  end
  copies = filtered_copies

  -- Trashes inside moved directories should apply to the post-move path.
  table.sort(moves, function(a, b) return #a.from > #b.from end)
  for _, trash in ipairs(trashes) do
    for _, move in ipairs(moves) do
      if common.path_equals(trash.abs, move.from) or common.path_belongs_to(trash.abs, move.from) then
        trash.abs = move.to .. trash.abs:sub(#move.from + 1)
        break
      end
    end
  end

  -- If a copied source is also moved (or lives inside a moved folder), copy
  -- from the post-move path at apply time. Keep the displayed source unchanged
  -- so the preview still describes the user's intent.
  local ordered_for_mapping = ordered_moves_or_cycle(moves) or moves
  for _, copy in ipairs(copies) do
    local apply_from = copy.from
    for _, move in ipairs(ordered_for_mapping) do
      if common.path_equals(apply_from, move.from) or common.path_belongs_to(apply_from, move.from) then
        apply_from = move.to .. apply_from:sub(#move.from + 1)
      end
    end
    if apply_from ~= copy.from then copy.apply_from = apply_from end
  end

  if status_only then return { status = status, invalid = invalid } end
  if invalid then return nil, "fix invalid red-marked lines before applying", status, invalid_reasons, ambiguities end
  return { creates = creates, copies = copies, moves = moves, trashes = trashes, status = status }
end

function FileTreeView:get_line_status(line)
  self:sync_meta()
  if not self.has_possible_edits then return nil end
  if not self.status_cache then
    local plan = self:plan_changes(true)
    self.status_cache = plan.status or {}
  end
  return self.status_cache[line]
end

function FileTreeView:entry_for_line(line)
  local entries, errors = self:build_entries(false)
  if errors[line] then return nil, errors[line] end
  for _, e in ipairs(entries) do
    if e.line == line then return e end
  end
  return nil
end

function FileTreeView:read_folder_lines(abs, indent, parent_entry)
  local lines, metas = {}, {}
  for _, item in ipairs(sorted_dir(abs, filetree_config.show_hidden)) do
    local role, display = project_path_role_for_abs(item.abs)
    item.project_path_role = role or (parent_entry and parent_entry.project_path_role)
    item.project_path_label = display and display.root_label
    item.project_path_id = display and display.root_id
    item.project_path_readonly = parent_entry and parent_entry.readonly or false
    self:remember_original(item)
    lines[#lines + 1] = indent_prefix(indent) .. item.display .. "\n"
    metas[#metas + 1] = make_meta(item)
  end
  return lines, metas
end

function FileTreeView:relative_descendant_line(text, base_indent)
  local level = parse_leading_indent(text)
  if level and level >= base_indent then
    return strip_indent_levels(text, base_indent) .. "\n"
  end
  return trim(text) .. "\n"
end

function FileTreeView:descendant_range(line, indent)
  local last = line
  for i = line + 1, #self.doc.lines do
    local text = line_text(self.doc.lines[i])
    local parsed, err = parse_text(text)
    if parsed and parsed.indent <= indent then break end
    if err then
      local level = leading_indent_level(text)
      if level <= indent then break end
    end
    last = i
  end
  return line + 1, last
end

function FileTreeView:collapse_folder(line, entry)
  local meta = self.line_meta[line]
  if type(meta) ~= "table" then
    meta = { expanded = true }
    self.line_meta[line] = meta
  end

  local first, last = self:descendant_range(line, entry.level * INDENT)
  local draft = { lines = {}, meta = {} }
  for i = first, last do
    draft.lines[#draft.lines + 1] = self:relative_descendant_line(line_text(self.doc.lines[i]), entry.level * INDENT + INDENT)
    draft.meta[#draft.meta + 1] = clone_meta(self.line_meta[i])
  end
  meta.draft = draft
  meta.expanded = false

  if last >= first then
    self:doc_splice(first, last - first + 1, {}, {})
  else
    self:snapshot_lines()
    self.status_cache = nil
  end
  self:update_filesystem_watches()
end

function FileTreeView:auto_expand_single_child_folder(parent_line, seen)
  seen = seen or {}
  local parent = self:entry_for_line(parent_line)
  if not parent or parent.type ~= "dir" or seen[parent.abs] then return end
  seen[parent.abs] = true

  local child_line, child_entry, child_count = nil, nil, 0
  for i = parent_line + 1, #self.doc.lines do
    local parsed = self:parse_line(i)
    if parsed and parsed.level <= parent.level then break end
    if parsed and parsed.level == parent.level + 1 then
      child_count = child_count + 1
      child_line = i
      child_entry = self:entry_for_line(i)
      if child_count > 1 then return end
    end
  end

  if child_count == 1 and child_entry and child_entry.type == "dir" then
    local meta = self.line_meta[child_line]
    if type(meta) == "table" and not meta.expanded and system.get_file_info(child_entry.abs) then
      self:expand_folder(child_line, child_entry, true, seen)
    end
  end
end

function FileTreeView:expand_folder(line, entry, auto_single, seen)
  local meta = self.line_meta[line]
  if type(meta) ~= "table" then
    meta = { expanded = false }
    self.line_meta[line] = meta
  end

  local lines, metas = {}, {}
  local child_indent = entry.level * INDENT + INDENT
  if meta.draft then
    for i, rel in ipairs(meta.draft.lines or {}) do
      lines[#lines + 1] = indent_prefix(child_indent) .. line_text(rel) .. "\n"
      metas[#metas + 1] = clone_meta(meta.draft.meta and meta.draft.meta[i])
    end
    meta.draft = nil
  else
    lines, metas = self:read_folder_lines(entry.abs, child_indent, entry)
  end
  meta.expanded = true
  self:doc_splice(line + 1, 0, lines, metas)
  if auto_single then
    self:auto_expand_single_child_folder(line, seen)
  end
  self:update_filesystem_watches()
end

function FileTreeView:open_selected_files()
  local slots = merge_line_ranges(self:selected_covered_line_slots())
  local entries, errors = self:build_entries(false)
  local entries_by_line = {}
  for _, entry in ipairs(entries) do entries_by_line[entry.line] = entry end

  local files, seen = {}, {}
  for _, slot in ipairs(slots) do
    for line = slot.first, slot.last do
      local entry = entries_by_line[line]
      if errors[line] then
        core.error("File Tree: %s", errors[line])
        return false
      end
      if entry and entry.type == "file" and not seen[entry.abs] then
        local info = system.get_file_info(entry.abs)
        if info and info.type == "file" then
          files[#files + 1] = entry
          seen[entry.abs] = true
        end
      end
    end
  end

  if #files <= 1 then return false end
  for _, entry in ipairs(files) do
    sidepanel.open_path_in_main(entry.abs, { preserve_focus = true })
  end
  return true
end

function FileTreeView:open_item(target)
  self:sync_meta()
  if target ~= "side" and self:open_selected_files() then return end

  local line = self.doc:get_selection(true)
  local entry, err = self:entry_for_line(line)
  if not entry then
    if err then core.error("File Tree: %s", err) end
    return
  end

  local info = system.get_file_info(entry.abs)
  if entry.type == "dir" then
    -- Opening folders is a pure UI operation. It deliberately discards/reveals
    -- subtree text without applying pending filesystem edits.
    local meta = self.line_meta[line]
    if type(meta) == "table" and meta.expanded then
      self:collapse_folder(line, entry)
    else
      if (not info or info.type ~= "dir") and not (type(meta) == "table" and meta.draft) then return end
      self:expand_folder(line, entry, true)
    end
  else
    if info and info.type == "file" then
      if target == "side" then
        sidepanel.open_path_in_side(entry.abs, { focus = true, source_view = self.last_main_panel_view })
      else
        sidepanel.open_path_in_main(entry.abs, { preserve_focus = true })
      end
    end
  end
end

function FileTreeView:up_dir()
  self.current_dir = parent_dir(self.current_dir)
  if not in_project(self.current_dir, core.root_project().path) then
    self.current_dir = core.root_project().path
  end
  self.scroll.to.y, self.scroll.y = 0, 0
  self:refresh(false, false)
end

function FileTreeView:apply_plan(plan)
  local changed = false
  local selection_path_map = { __moves = {} }
  local selection_paths = self:capture_selection_paths()

  table.sort(plan.creates, function(a, b)
    if a.type ~= b.type then return a.type == "dir" end
    return path_depth(a.path) < path_depth(b.path)
  end)

  local function apply_create(op)
    local existing = system.get_file_info(op.path)
    if existing then
      if op.type == "dir" and existing.type == "dir" then return true end
      core.error("File Tree: target already exists: %s", op.path)
      return false
    end
    local ok, err, path
    if op.type == "dir" then
      ok, err, path = common.mkdirp(op.path)
      if not ok then core.error("File Tree: mkdir failed: %s: %s", path or op.path, err); return false end
    else
      local parent = parent_dir(op.path)
      if parent and not system.get_file_info(parent) then
        ok, err, path = common.mkdirp(parent)
        if not ok then core.error("File Tree: mkdir failed: %s: %s", path or parent, err); return false end
      end
      local fp
      fp, err = io.open(op.path, "wb")
      if not fp then core.error("File Tree: create failed: %s", err); return false end
      fp:close()
    end
    core.log("File Tree: created %s", op.path)
    changed = true
    return true
  end

  -- Explicitly typed parent folders must exist before copy/move/create-file
  -- operations place children inside them.
  for _, op in ipairs(plan.creates) do
    if op.type == "dir" and not op.replaces_existing and not apply_create(op) then return end
  end


  local ordered_moves, move_order_err = ordered_moves_or_cycle(plan.moves)
  if not ordered_moves then
    core.error("File Tree: %s", move_order_err)
    return
  end
  for _, op in ipairs(ordered_moves) do
    if system.get_file_info(op.to) then
      core.error("File Tree: target already exists: %s", op.to)
      return
    end
    if op.type == "dir" and common.path_belongs_to(op.to, op.from) then
      core.error("File Tree: cannot move a folder into itself: %s -> %s", op.from, op.to)
      return
    end
    local parent = parent_dir(op.to)
    if parent and not system.get_file_info(parent) then
      local ok, err, path = common.mkdirp(parent)
      if not ok then core.error("File Tree: mkdir failed: %s: %s", path or parent, err); return end
    end
    local ok, err = os.rename(op.from, op.to)
    if not ok then core.error("File Tree: move failed: %s", err); return end
    selection_path_map[path_key(op.from)] = op.to
    selection_path_map.__moves[#selection_path_map.__moves + 1] = { from = op.from, to = op.to }
    update_open_docs_after_rename(op.from, op.to, op.type)
    core.log("File Tree: moved %s -> %s", op.from, op.to)
    changed = true
  end

  for _, op in ipairs(plan.creates) do
    if op.type == "dir" and not apply_create(op) then return end
  end

  table.sort(plan.copies, function(a, b) return path_depth(a.to) < path_depth(b.to) end)
  for _, op in ipairs(plan.copies) do
    if system.get_file_info(op.to) then
      core.error("File Tree: target already exists: %s", op.to)
      return
    end
    local ok, err = copy_recursive(op.apply_from or op.from, op.to, op.type)
    if not ok then core.error("File Tree: copy failed: %s", err); return end
    core.log("File Tree: copied %s -> %s", op.from, op.to)
    changed = true
  end

  for _, op in ipairs(plan.creates) do
    if op.type ~= "dir" and not apply_create(op) then return end
  end

  table.sort(plan.trashes, function(a, b) return #a.abs > #b.abs end)
  local trash_list = {}
  for _, op in ipairs(plan.trashes) do
    if system.get_file_info(op.abs) then trash_list[#trash_list + 1] = op.abs end
  end
  if #trash_list > 0 then
    local ok, err = trash_paths(trash_list)
    if not ok then core.error("File Tree: trash/delete failed: %s", err); return end
    for _, path in ipairs(trash_list) do
      core.log("File Tree: %s %s", filetree_config.delete_to_trash and PLATFORM == "Windows" and "trashed" or "deleted", path)
    end
    changed = true
  end

  local reveal_paths = {}
  for _, op in ipairs(plan.moves) do reveal_paths[#reveal_paths + 1] = op.to end
  for _, op in ipairs(plan.copies) do reveal_paths[#reveal_paths + 1] = op.to end
  for _, op in ipairs(plan.creates) do reveal_paths[#reveal_paths + 1] = op.path end
  self:refresh_preserving_selection_paths(true, reveal_paths, selection_path_map, selection_paths)
  if changed then core.log("File Tree: applied edits") else core.log("File Tree: nothing to apply") end
end

function FileTreeView:operation_lines(plan)
  local rows = {}
  local function add_row(verb, type, from, to)
    rows[#rows + 1] = { verb = verb, type = type, from = from, to = to }
  end

  for _, op in ipairs(plan.creates) do
    if op.type == "dir" and not op.replaces_existing then
      add_row("CREATE", op.type, op_path(op.path))
    end
  end
  local ordered_moves = ordered_moves_or_cycle(plan.moves) or plan.moves
  for _, op in ipairs(ordered_moves) do
    add_row(is_rename_op(op) and "RENAME" or "MOVE", op.type, op_path(op.from), op_path(op.to))
  end
  for _, op in ipairs(plan.creates) do
    if op.type == "dir" and op.replaces_existing then
      add_row("CREATE", op.type, op_path(op.path))
    end
  end
  for _, op in ipairs(plan.copies) do
    add_row("COPY", op.type, op_path(op.from), op_path(op.to))
  end
  for _, op in ipairs(plan.creates) do
    if op.type ~= "dir" then
      add_row("CREATE", op.type, op_path(op.path))
    end
  end
  for _, op in ipairs(plan.trashes) do
    add_row("DELETE", op.type, op_path(op.abs))
  end

  local verb_w, type_w, from_w = 0, 0, 0
  for _, row in ipairs(rows) do
    verb_w = math.max(verb_w, #row.verb)
    type_w = math.max(type_w, #row.type)
    if row.to then from_w = math.max(from_w, #row.from) end
  end

  local lines = {}
  for _, row in ipairs(rows) do
    if row.to then
      lines[#lines + 1] = string.format(
        "%-" .. verb_w .. "s  %-" .. type_w .. "s  %-" .. from_w .. "s  ->  %s",
        row.verb, row.type, row.from, row.to
      )
    else
      lines[#lines + 1] = string.format(
        "%-" .. verb_w .. "s  %-" .. type_w .. "s  %s",
        row.verb, row.type, row.from
      )
    end
  end
  return lines
end

function FileTreeView:operation_count(plan)
  return #plan.creates + #plan.copies + #plan.moves + #plan.trashes
end

function FileTreeView:operation_summary(plan)
  local trash_label = filetree_config.delete_to_trash and PLATFORM == "Windows" and "Trash" or "Delete"
  return string.format(
    "Create: %d   Copy: %d   Move: %d   %s: %d",
    #plan.creates, #plan.copies, #plan.moves, trash_label, #plan.trashes
  )
end

local operation_colors = {
  CREATE = style.filetree_operation_create,
  COPY = style.filetree_operation_copy,
  MOVE = style.filetree_operation_move,
  RENAME = style.filetree_operation_rename,
  DELETE = style.filetree_operation_delete,
}

local function filetree_operation_message(lines)
  if #lines == 0 then
    return "File Tree has no filesystem operations to apply."
  end

  local message = {
    filetree_styled_nag_message = true,
    lines = {
      { { text = "File Tree will perform these filesystem operations:" } },
      {},
    }
  }

  for _, line in ipairs(lines) do
    local verb, rest = line:match("^(%S+)(.*)$")
    message.lines[#message.lines + 1] = {
      { text = verb or line, font = style.code_font, color = operation_colors[verb] or style.nagbar_text },
      { text = rest or "", font = style.code_font, color = style.nagbar_text },
    }
  end
  return message
end

function FileTreeView:confirm_apply_plan(plan)
  local lines = self:operation_lines(plan)
  local message = filetree_operation_message(lines)

  core.nag_view:show("Apply File Tree Operations", message, {
    { text = "Apply", default_yes = true },
    { text = "Cancel", default_no = true },
  }, function(item)
    if item.text == "Apply" then self:apply_plan(plan) end
  end)
end

function FileTreeView:resolve_ambiguity(ambiguity)
  local lines = {
    string.format("%s '%s' could be a new empty item or a moved item.", ambiguity.type, op_path(ambiguity.path)),
    "",
    "Choose how to interpret this row:",
    "",
  }
  for i, candidate in ipairs(ambiguity.candidates or {}) do
    lines[#lines + 1] = string.format("%d. MOVE from %s", i, op_path(candidate.abs))
  end
  lines[#lines + 1] = string.format("%d. CREATE new empty %s", #(ambiguity.candidates or {}) + 1, ambiguity.type)

  local options = {}
  for i in ipairs(ambiguity.candidates or {}) do
    options[#options + 1] = {
      text = "Move " .. i,
      candidate_index = i,
      default_yes = #(ambiguity.candidates or {}) == 1,
    }
  end
  options[#options + 1] = { text = "Create", create = true }
  options[#options + 1] = { text = "Cancel", cancel = true, default_no = true }

  local function set_ambiguity_meta(meta)
    if ambiguity.draft and ambiguity.draft_index then
      ambiguity.draft.meta = ambiguity.draft.meta or {}
      ambiguity.draft.meta[ambiguity.draft_index] = meta
    else
      self.line_meta[ambiguity.line] = meta
    end
  end

  core.nag_view:show("Resolve File Tree Ambiguity", table.concat(lines, "\n"), options, function(item)
    local candidates = ambiguity.candidates or {}
    if item.candidate_index then
      local candidate = candidates[item.candidate_index]
      set_ambiguity_meta({
        original_abs = candidate.abs,
        original_type = candidate.type,
        expanded = false,
      })
      self:snapshot_lines()
      self.status_cache = nil
      core.add_thread(function() self:apply_edits() end)
    elseif item.create then
      set_ambiguity_meta({ force_create = true })
      self:snapshot_lines()
      self.status_cache = nil
      core.add_thread(function() self:apply_edits() end)
    end
  end)
end

function FileTreeView:show_plan_errors(message, reasons, ambiguities)
  if ambiguities and #ambiguities > 0 then
    self:resolve_ambiguity(ambiguities[1])
    return
  end

  local text = "File Tree cannot apply these edits."
  if message then text = text .. "\n\n" .. message end
  if reasons and #reasons > 0 then
    text = text .. "\n\n" .. table.concat(reasons, "\n")
  end
  core.nag_view:show("File Tree Invalid Operations", text, {
    { text = "OK", default_yes = true, default_no = true },
  })
end

function FileTreeView:apply_edits()
  self:sync_meta()
  local plan, err, _, reasons, ambiguities = self:plan_changes()
  if not plan then self:show_plan_errors(err, reasons, ambiguities); return end

  if self:operation_count(plan) == 0 then
    self.doc:clean()
    self.has_possible_edits = false
    self.status_cache = nil
    core.log("File Tree: nothing to apply")
    return
  end

  self:confirm_apply_plan(plan)
end

local view = FileTreeView()
file_context.exclude_main_panel_view(view)
sidepanel.register_panel("filetree", view)
view.node = sidepanel.side_node

local function wrap_doc_command(name, filetree_handler)
  local base = command.map[name]
  command.add(function(...)
    if core.active_view == view then return true, "filetree", view end
    if not base then return false end
    local result = { base.predicate(...) }
    if table.remove(result, 1) then
      if #result > 0 then
        return true, "base", table.unpack(result)
      end
      return true, "base", ...
    end
    return false
  end, {
    [name] = function(mode, ...)
      if mode == "filetree" then
        if filetree_handler(view, ...) then return end
      else
        core.filetree_clipboard = nil
      end
      if base then base.perform(...) end
    end
  })
end

wrap_doc_command("doc:copy", function(v)
  return v:copy_or_cut_lines(false)
end)
wrap_doc_command("doc:cut", function(v)
  return v:copy_or_cut_lines(true)
end)
wrap_doc_command("doc:paste", function(v)
  return v:paste_lines_with_metadata()
end)

local function current_main_panel_view()
  return sidepanel.current_main_panel_view(view.last_main_panel_view)
end

local function current_file_path()
  return file_context.current_file_path(view.last_main_panel_view)
end

local function remember_current_main_panel_view()
  view.last_main_panel_view = current_main_panel_view() or view.last_main_panel_view
end

local function hide_and_focus_main_panel_view()
  sidepanel.focus_main(true)
end

local function show_and_focus_filetree()
  remember_current_main_panel_view()
  sidepanel.show("filetree", { focus = true })
end

local function find_entry(filename)
  local entries = view:build_entries(false)
  for _, entry in ipairs(entries) do
    if common.path_equals(entry.abs, filename) then return entry end
  end
end

local function focus_entry(entry, filename)
  local text = line_text(view.doc.lines[entry.line])
  local name = common.basename(filename)
  local start_col = text:find(name, 1, true) or 1
  view.doc:set_selection(entry.line, start_col, entry.line, start_col + #name)
  view:scroll_to_make_visible(entry.line, start_col)

  -- Bias horizontal scroll toward the start. Only scroll right if the
  -- selected filename would be completely off-screen.
  local x1 = view:get_col_x_offset(entry.line, start_col)
  local x2 = view:get_col_x_offset(entry.line, start_col + #name)
  local visible_left = view.scroll.to.x
  local visible_right = visible_left + view.size.x - view:get_gutter_width()
  if x2 < visible_left or x1 > visible_right then
    view.scroll.to.x = math.max(0, x1 - style.padding.x)
    view.scroll.x = view.scroll.to.x
  else
    view.scroll.to.x = 0
    view.scroll.x = 0
  end

  sidepanel.show("filetree", { focus = true })
  return true
end

local function focus_file(filename)
  filename = filename and common.normalize_path(filename)
  local root = core.root_project and core.root_project()
  local resolved = filename and project_paths.resolve(filename)
  if not filename or not root or not resolved or resolved.flags.browsable == false then return end

  sidepanel.show("filetree", { focus = false })
  local refreshed = false
  if resolved.entry.role == "root" and not in_project(filename, view.current_dir) then
    view.current_dir = root.path
  end
  if view.rendered_dir ~= view.current_dir and not common.path_equals(view.rendered_dir, view.current_dir) then
    view:refresh(false, true, { filename })
    refreshed = true
  else
    local expanded = {}
    view:add_reveal_paths(expanded, { filename })
    view:restore_expanded_paths(expanded)
  end

  local entry = find_entry(filename)
  if not entry and not refreshed then
    view:refresh(false, true, { filename })
    entry = find_entry(filename)
  end
  if entry then return focus_entry(entry, filename) end
end

command.add(nil, {
  ["filetree:toggle"] = function()
    if view.visible then
      hide_and_focus_main_panel_view()
    else
      show_and_focus_filetree()
    end
  end,
  ["filetree:focus"] = function()
    show_and_focus_filetree()
  end,
  ["filetree:focus-editor-and-hide"] = function()
    hide_and_focus_main_panel_view()
  end,
  ["filetree:focus-and-show"] = function()
    show_and_focus_filetree()
  end,
  ["filetree:focus-current-file"] = function()
    focus_file(current_file_path())
  end,
  ["filetree:focus-file"] = focus_file,
  ["filetree:sync-path"] = function(path)
    view:sync_path(path, "command")
  end,
  ["filetree:sort-by-name"] = function()
    view:set_sort_mode("name")
  end,
  ["filetree:sort-by-date-modified"] = function()
    view:set_sort_mode("modified")
  end,
})

command.add(function() return core.active_view:is(FileTreeView) end, {
  ["filetree:refresh"] = function()
    view:refresh_preserving_selection_paths(true)
  end,
  ["filetree:apply"] = function()
    view:apply_edits()
  end,
  ["filetree:open"] = function()
    view:open_item()
  end,
  ["filetree:open-side"] = function()
    view:open_item("side")
  end,
  ["filetree:up-dir"] = function()
    view:up_dir()
  end,
  ["filetree:project-root"] = function()
    view.current_dir = core.root_project().path
    view:refresh(false, false)
  end,
  ["filetree:select-all"] = function()
    view.doc:set_selection(1, 1, #view.doc.lines, #view.doc.lines[#view.doc.lines])
  end,
})

keymap.add {
  ["ctrl+\\"] = "filetree:toggle",
  ["alt+1"] = "sidepanel:hide",
  ["alt+2"] = "filetree:focus-and-show",
  ["alt+r"] = "filetree:open",
  ["alt+shift+r"] = "filetree:open-side",
  ["ctrl+return"] = "filetree:open-side",
  ["ctrl+s"] = "filetree:apply",
  ["f5"] = "filetree:refresh",
  ["alt+left"] = "filetree:up-dir",
  ["alt+home"] = "filetree:project-root",
}

return view
