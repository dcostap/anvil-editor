-- mod-version:3 priority:101
-- A small Telescope-like fuzzy/search overlay for Anvil.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local common = require "core.common"
local config = require "core.config"
local process = require "core.process"
local http = require "core.http"
local storage = require "core.storage"
local Doc = require "core.doc"
local DocView = require "core.docview"
local ImageView = require "core.imageview"
local file_context = require "core.file_context"
local sidepanel = require "core.sidepanel"
local Widget = require "widget"
local TextBox = require "widget.textbox"
local fuzzy_native = require "fuzzy"

local PreviewDocView = DocView:extend()

function PreviewDocView:get_gutter_width()
  local padding = style.padding.x * 2
  if config.show_line_numbers then
    return self:get_font():get_width("00000") + padding, padding
  end
  return style.padding.x, padding
end

function PreviewDocView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  if config.show_line_numbers then
    local color = style.line_number
    for _, line1, _, line2 in self.doc:get_selections(true) do
      if line >= line1 and line <= line2 then
        color = style.line_number2
        break
      end
    end
    -- Preview gutters are fixed-width and left-aligned so the label itself
    -- stays anchored when the visible range changes from 1 to 2+ digits.
    renderer.draw_text(self:get_font(), tostring(line), x + style.padding.x, y + self:get_line_text_y_offset(), color)
  end
  return lh
end

-- Older development versions of this plugin monkey-patched keymap.on_key_pressed.
-- Restore it on reload so this version uses normal Anvil commands/keymaps.
if keymap.__fuzzy_searcher_original_on_key_pressed then
  keymap.on_key_pressed = keymap.__fuzzy_searcher_original_on_key_pressed
  keymap.__fuzzy_searcher_original_on_key_pressed = nil
end

local BUNDLED_PLUGIN_DIR = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher"
local USER_PLUGIN_DIR = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher"
local RECENT_COMMANDS_FILE = USER_PLUGIN_DIR .. PATHSEP .. "recent_commands.txt"
local RECENT_PROJECT_TIMES_FILE = USER_PLUGIN_DIR .. PATHSEP .. "recent_project_times.lua"

local function bundled_tool(name)
  local bundled = BUNDLED_PLUGIN_DIR .. PATHSEP .. name
  if system.get_file_info(bundled) then return bundled end
  return USER_PLUGIN_DIR .. PATHSEP .. name
end

local fuzzy_searcher = {
  result_limit = 30,
  max_result_limit = 500,
  width = 0.90,
  height = 0.80,
  side_padding_reduce_width = 1500 * SCALE,
  min_width = 1200 * SCALE,
  min_side_padding = nil,
  min_height = 650 * SCALE,
  preview_width = 0.50,
  fd = bundled_tool("fd.exe"),
  rg = bundled_tool("rg.exe"),
  fuzzy_candidate_limit = 500,
  fuzzy_scan_limit = 10000,
  fuzzy_line_max_chars = 1200,
  fuzzy_time_slice = 0.006,
  grep_path_column_width = 0.45,
  preview_debug = false,
  preview_text_max_bytes = 2 * 1024 * 1024,
}

local FSView = Widget:extend()
local active_view
local open
local open_static_results

local modal_modkey_map = {
  ["left ctrl"] = "ctrl", ["right ctrl"] = "ctrl",
  ["left shift"] = "shift", ["right shift"] = "shift",
  ["left alt"] = "alt", ["right alt"] = "altgr",
  ["left gui"] = "super", ["right gui"] = "super",
  ["left windows"] = "super", ["right windows"] = "super",
}
local modal_modkeys = { "ctrl", "shift", "alt", "altgr", "super" }
local function modal_normalize_stroke(stroke)
  local stroke_table = {}
  for key in stroke:gmatch("[^+]+") do table.insert(stroke_table, key) end
  table.sort(stroke_table, function(a, b)
    if a == b then return false end
    for _, mod in ipairs(modal_modkeys) do
      if a == mod or b == mod then return a == mod end
    end
    return a < b
  end)
  return table.concat(stroke_table, "+")
end

local function modal_key_to_stroke(key)
  local keys = { key }
  for _, mod in ipairs(modal_modkeys) do
    if keymap.modkeys[mod] then table.insert(keys, mod) end
  end
  return modal_normalize_stroke(table.concat(keys, "+"))
end

local function modal_modkeys_string()
  local keys = {}
  for _, mod in ipairs(modal_modkeys) do
    if keymap.modkeys[mod] then keys[#keys+1] = mod end
  end
  return #keys > 0 and table.concat(keys, "+") or "none"
end

local function scale_mouse_wheel_modkeys_pressed()
  local scale_key = PLATFORM == "Mac OS X" and "cmd" or "ctrl"
  if not keymap.modkeys[scale_key] then return false end
  for key, pressed in pairs(keymap.modkeys) do
    if pressed and key ~= scale_key and key ~= "shift" then return false end
  end
  return true
end

local function current_picker()
  if active_view and active_view:is_visible() then return active_view end
  local view = core.fuzzy_searcher_active_view
  if view and view.is_visible and view:is_visible() then
    active_view = view
    return view
  end
end

local function view_label(view)
  if not view then return "nil" end
  local label = view.type_name or view.name
  if type(view.get_name) == "function" then
    local ok, name = pcall(view.get_name, view)
    if ok and name and name ~= "" then label = label and (label .. ":" .. name) or name end
  end
  return tostring(label or view)
end

local function fuzzy_focus_log(event, picker, extra)
  picker = picker or current_picker()
  local input = picker and picker.input
  local input_textview = input and input.textview
  local visible = picker and picker.is_visible and picker:is_visible() or false
  local text_len = "nil"
  if input and type(input.get_text) == "function" then
    local ok, text = pcall(input.get_text, input)
    if ok and text then text_len = tostring(#text) end
  end
  core.log_quiet(
    "Fuzzy focus: %s active=%s child=%s input=%s textview=%s input_active=%s visible=%s text_len=%s%s",
    tostring(event),
    view_label(core.active_view),
    view_label(picker and picker.child_active),
    view_label(input),
    view_label(input_textview),
    tostring(input and input.active),
    tostring(visible),
    text_len,
    extra and (" " .. tostring(extra)) or ""
  )
end

local function ensure_input_focus(picker, reason)
  if not picker or not picker.input then return end
  picker:swap_active_child(picker.input)
  local input_view = picker.input.input_text and picker.input.textview or picker.input
  if input_view and core.active_view ~= input_view then
    local restore = file_context.current_main_panel_view(core.active_view) or core.active_view
    if restore and restore ~= picker and restore ~= picker.input and restore ~= input_view then
      picker.prev_view = restore
    end
    core.set_active_view(input_view)
    picker.input:activate()
  end
  if reason then fuzzy_focus_log(reason, picker) end
end

local function modal_fuzzy_command_allowed(cmd)
  return type(cmd) == "string" and cmd:match("^fuzzy%-searcher:") ~= nil
end

local function modal_textbox_command_allowed(cmd)
  if type(cmd) ~= "string" then return false end
  if cmd:match("^doc:move%-") or cmd:match("^doc:select%-") then return true end
  if cmd:match("^doc:delete") then return true end
  return cmd == "doc:backspace"
      or cmd == "doc:copy"
      or cmd == "doc:cut"
      or cmd == "doc:paste"
      or cmd == "doc:undo"
      or cmd == "doc:redo"
      or cmd == "doc:select-all"
      or cmd == "doc:select-none"
end

local function modal_command(stroke, predicate)
  local commands = keymap.map[stroke]
  if not commands then return nil end
  for _, cmd in ipairs(commands) do
    if predicate(cmd) then return cmd end
  end
end

local function modal_fuzzy_command(stroke)
  -- Ctrl+Enter is also claimed by local IntelliJ conflict disabling. Keep the
  -- picker modal command authoritative even when the global keymap was later
  -- overwritten.
  if stroke == "ctrl+return" then return "fuzzy-searcher:confirm-side" end
  return modal_command(stroke, modal_fuzzy_command_allowed)
end

local function modal_textbox_command(stroke)
  return modal_command(stroke, modal_textbox_command_allowed)
end

local modal_non_text_keys = {
  ["escape"] = true, ["return"] = true, ["keypad enter"] = true,
  ["tab"] = true, ["backspace"] = true, ["delete"] = true, ["insert"] = true,
  ["up"] = true, ["down"] = true, ["left"] = true, ["right"] = true,
  ["home"] = true, ["end"] = true, ["pageup"] = true, ["pagedown"] = true,
  ["capslock"] = true, ["numlock"] = true, ["scrolllock"] = true,
  ["printscreen"] = true, ["pause"] = true, ["menu"] = true,
}
for i = 1, 24 do modal_non_text_keys["f" .. i] = true end

local function modal_should_let_text_input_through(key, stroke)
  -- Printable text arrives through a later textinput event. If we consume the
  -- keypressed event for plain/shifted characters, Anvil/SDL can suppress
  -- that textinput, so normal typing appears broken. Ctrl/Alt/Super combos are
  -- shortcuts and stay modal-blocked unless explicitly allowed.
  if keymap.modkeys.super then return false end
  if keymap.modkeys.ctrl or keymap.modkeys.alt then
    -- On Windows AltGr can appear as ctrl+alt, but it is used to enter
    -- printable characters like @/# on many layouts. If the physical AltGr
    -- modifier is down, do not treat ctrl/alt as shortcut blockers.
    if not keymap.modkeys.altgr then return false end
  end
  if modal_textbox_command(stroke) or modal_non_text_keys[key] then return false end
  return type(key) == "string" and key ~= ""
end
local files_cache_root, files_cache, files_indexing, files_generation = nil, nil, false, 0
local files_fuzzy_index, files_fuzzy_index_generation = nil, -1
local command_cache
local recent_commands = {}
local recent_command_set = {}
local recent_project_times = {}
local line_count_cache = {}
local grep_proc
local grep_generation = 0
local file_search_generation = 0
local symbol_generation = 0
local fuzzy_grep_jobs = {}

local function project_dir()
  local p = core.root_project and core.root_project()
  return common.normalize_path((p and p.path) or system.absolute_path("."))
end

local function display_root(root)
  return common.home_encode and common.home_encode(root) or root
end

local function fullpath(path)
  path = tostring(path or "")
  if path == "" then return project_dir() end
  local normalized = common.normalize_path(path)
  if normalized and common.is_absolute_path(normalized) then return normalized end
  return project_dir() .. PATHSEP .. path:gsub("[/\\]", PATHSEP)
end

local function file_result_key(path)
  local normalized = common.normalize_path(fullpath(path))
  return normalized and common.path_compare_key(normalized)
end

local function compact_age(ts)
  ts = tonumber(ts)
  if not ts then return nil end
  local elapsed = math.max(0, os.time() - ts)
  local hour = 60 * 60
  local day = 24 * hour
  local week = 7 * day
  if elapsed < day then return tostring(math.floor(elapsed / hour)) .. "h" end
  if elapsed < week then return tostring(math.floor(elapsed / day)) .. "d" end
  return tostring(math.floor(elapsed / week)) .. "w"
end

local function filetime_to_time(filetime)
  if filetime == nil then return nil end
  local n = tonumber(filetime)
  if not n then return nil end
  return math.floor((n / 10000000) - 11644473600)
end

local function format_size(size)
  local n = tonumber(size)
  if not n then return "" end
  if n < 1024 then return tostring(n) .. " B" end
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  if n < 1024 * 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  return string.format("%.2f GB", n / (1024 * 1024 * 1024))
end

local function existing_absolute_dir(text)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  text = text:gsub("^\"(.-)\"$", "%1")
  local expanded = common.home_expand(text)
  local normalized = common.normalize_path(expanded)
  if not normalized or not common.is_absolute_path(normalized) then return nil end
  local abs = system.absolute_path(normalized)
  local info = abs and system.get_file_info(abs)
  if info and info.type == "dir" then return common.normalize_path(abs) end
end

local function get_recent_projects()
  local out, seen = {}, {}
  for _, path in ipairs(core.recent_projects or {}) do
    path = common.normalize_path(path)
    local key = common.path_compare_key(path)
    if path and path ~= "" and key and not seen[key] then
      out[#out+1] = path
      seen[key] = true
    end
  end
  return out
end

local function load_recent_project_times()
  local ok, t = pcall(dofile, RECENT_PROJECT_TIMES_FILE)
  if ok and type(t) == "table" then recent_project_times = t end
end

local function save_recent_project_times()
  common.mkdirp(USER_PLUGIN_DIR)
  local fp = io.open(RECENT_PROJECT_TIMES_FILE, "wb")
  if not fp then return end
  fp:write("return " .. common.serialize(recent_project_times, { pretty = true }))
  fp:close()
end

local function remember_project_open(path, when)
  if type(path) == "table" then path = path.path end
  path = common.normalize_path(path)
  if not path or path == "" then return end
  for existing in pairs(recent_project_times) do
    if existing ~= path and common.path_equals(existing, path) then
      recent_project_times[existing] = nil
    end
  end
  recent_project_times[path] = when or os.time()
  save_recent_project_times()
end

local function ensure_recent_project_times()
  local changed = false
  local now = os.time()
  for _, path in ipairs(get_recent_projects()) do
    if not recent_project_times[path] then
      recent_project_times[path] = now
      changed = true
    end
  end
  if changed then save_recent_project_times() end
end

local function wrap_project_openers()
  if core.__fuzzy_searcher_original_open_project_in_same_window then
    core.open_project_in_same_window = core.__fuzzy_searcher_original_open_project_in_same_window
  end
  if core.__fuzzy_searcher_original_open_project_in_new_window then
    core.open_project_in_new_window = core.__fuzzy_searcher_original_open_project_in_new_window
  end

  core.__fuzzy_searcher_original_open_project_in_same_window = core.open_project_in_same_window
  core.open_project_in_same_window = function(project, ...)
    remember_project_open(project)
    return core.__fuzzy_searcher_original_open_project_in_same_window(project, ...)
  end

  core.__fuzzy_searcher_original_open_project_in_new_window = core.open_project_in_new_window
  core.open_project_in_new_window = function(project, ...)
    remember_project_open(project)
    return core.__fuzzy_searcher_original_open_project_in_new_window(project, ...)
  end
end

load_recent_project_times()
ensure_recent_project_times()
wrap_project_openers()

local function open_anvil_window(path)
  core.open_project_in_new_window(path)
end

local function kill_grep()
  if grep_proc and grep_proc:running() then pcall(function() grep_proc:kill() end) end
  grep_proc = nil
end

local function kill_file_search()
  file_search_generation = file_search_generation + 1
end

local function clear_native_file_index()
  if files_fuzzy_index and files_fuzzy_index.free then
    pcall(function() files_fuzzy_index:free() end)
  end
  files_fuzzy_index = nil
  files_fuzzy_index_generation = -1
end

local function rebuild_native_file_index()
  if not files_cache then return nil end
  if files_fuzzy_index and files_fuzzy_index_generation == files_generation then return files_fuzzy_index end
  clear_native_file_index()
  local ok, idx = pcall(function()
    return fuzzy_native.index(files_cache, { mode = "path" })
  end)
  if ok then
    files_fuzzy_index = idx
    files_fuzzy_index_generation = files_generation
    return idx
  end
  return nil
end

local function native_file_index_ready()
  return files_fuzzy_index and files_fuzzy_index_generation == files_generation
end

local function ensure_file_index()
  local root = project_dir()
  if files_cache and files_cache_root == root then return end
  if files_indexing and files_cache_root == root then return end

  clear_native_file_index()
  files_cache_root = root
  files_cache = {}
  files_indexing = true
  files_generation = files_generation + 1
  local gen = files_generation

  core.add_thread(function()
    local proc, err = process.start({
      fuzzy_searcher.fd,
      "--type", "f",
      "--hidden",
      "--exclude", ".git",
      "."
    }, {
      cwd = root,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_DISCARD,
      stdin = process.REDIRECT_DISCARD,
    })

    if not proc then
      files_indexing = false
      core.error("fuzzy_searcher: fd failed: %s", err or "unknown error")
      return
    end

    local t, n = {}, 0
    while true do
      local line = proc.stdout:read("line", { scan = 1 / config.fps })
      if line and line ~= "" then
        line = line:gsub("^%.[/\\]", ""):gsub("\\", "/")
        t[#t+1] = line
        n = n + 1
        if n % 250 == 0 and gen == files_generation and files_cache_root == root then
          files_cache = t
          if active_view then active_view.dirty = true; active_view:schedule_update(true) end
        end
      elseif not proc:running() then
        break
      else
        coroutine.yield(1 / config.fps)
      end
    end
    proc:wait(process.WAIT_DEADLINE)
    if gen == files_generation and files_cache_root == root then
      table.sort(t)
      files_cache = t
      files_indexing = false
      rebuild_native_file_index()
      if active_view then active_view.dirty = true; active_view:schedule_update(true) end
    end
  end)
end

local function get_files()
  ensure_file_index()
  return files_cache or {}
end

local function get_recent_files(skip_path)
  local root = project_dir()
  local current_key = skip_path and common.path_compare_key(skip_path) or nil
  local out, seen = {}, {}

  for _, abs in ipairs(core.visited_files or {}) do
    abs = tostring(abs or "")
    if abs ~= "" then
      abs = common.normalize_path(abs)
      if abs and not common.is_absolute_path(abs) then
        abs = system.absolute_path(abs)
        abs = abs and common.normalize_path(abs)
      end
      local key = abs and common.path_compare_key(abs)
      if key and key ~= current_key and not seen[key] then
        local info = system.get_file_info(abs)
        if info and info.type == "file" then
          seen[key] = true
          if common.path_belongs_to(abs, root) then
            out[#out+1] = common.relative_path(root, abs):gsub("\\", "/")
          else
            -- Keep non-project recents visible/openable. Since they are not
            -- relative to the active project, show their absolute path.
            out[#out+1] = abs
          end
        end
      end
    end
  end

  return out
end

local function get_file_search_items()
  -- `fd` already returns a unique project-relative file list.  Avoid calling
  -- fullpath()/normalize_path() for every indexed file on each keystroke; on
  -- large projects that pre-scan allocation/normalization dominated latency.
  local files = get_files()
  local recents = get_recent_files()
  if #recents == 0 then return files end

  local out, recent_set = {}, {}
  for _, f in ipairs(recents) do recent_set[f] = true end
  for _, f in ipairs(files) do
    out[#out+1] = f
    recent_set[f] = nil
  end
  for _, f in ipairs(recents) do
    if recent_set[f] then out[#out+1] = f end
  end
  return out
end

local function get_commands()
  if command_cache then return command_cache end
  local t = {}
  for name in pairs(command.map) do t[#t+1] = name end
  table.sort(t)
  command_cache = t
  return t
end

local function save_recent_commands()
  common.mkdirp(USER_PLUGIN_DIR)
  local fp = io.open(RECENT_COMMANDS_FILE, "wb")
  if not fp then return end
  for _, name in ipairs(recent_commands) do
    fp:write(name, "\n")
  end
  fp:close()
end

local function load_recent_commands()
  local fp = io.open(RECENT_COMMANDS_FILE, "rb")
  if not fp then return end
  for line in fp:lines() do
    local name = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" and not recent_command_set[name] then
      recent_commands[#recent_commands+1] = name
      recent_command_set[name] = true
      if #recent_commands >= 10 then break end
    end
  end
  fp:close()
end

local function remember_command(name)
  name = tostring(name or "")
  if name == "" then return end

  if recent_command_set[name] then
    for i, v in ipairs(recent_commands) do
      if v == name then
        table.remove(recent_commands, i)
        break
      end
    end
  end

  table.insert(recent_commands, 1, name)
  recent_command_set[name] = true

  while #recent_commands > 10 do
    local removed = table.remove(recent_commands)
    if removed then recent_command_set[removed] = nil end
  end

  save_recent_commands()
end

load_recent_commands()

local function parse_query(s)
  local before, grep = s, nil
  local p = s:find("#", 1, true)
  if p then
    before = s:sub(1, p - 1)
    grep = s:sub(p + 1):gsub("^%s+", "")
  end

  local base, line = before, nil
  local b, n = before:match("^(.-)%s*:%s*(%d+)%s*$")
  if n then
    base = b:gsub("%s+$", "")
    line = tonumber(n)
  end
  return base:gsub("^%s+", ""):gsub("%s+$", ""), line, grep
end

local function trim_query(q)
  return tostring(q or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

fuzzy_searcher.mode_prefixes = { ["#"] = true, ["@"] = true, [">"] = true, ["$"] = true, ["$$"] = true }
fuzzy_searcher.prompt_history_loaded = false
fuzzy_searcher.prompt_history = {}

local function split_mode_prefix(text)
  text = tostring(text or "")
  if text:sub(1, 2) == "$$" then return "$$", text:sub(3) end
  local prefix = text:sub(1, 1)
  if fuzzy_searcher.mode_prefixes[prefix] then return prefix, text:sub(2) end
  return "", text
end

function fuzzy_searcher.load_prompt_history()
  if fuzzy_searcher.prompt_history_loaded then return end
  local function normalize(data)
    local normalized = {}
    if type(data) ~= "table" then return normalized end
    for mode, entries in pairs(data) do
      mode = tostring(mode or "")
      if type(entries) == "table" then
        local out, seen = {}, {}
        for _, entry in ipairs(entries) do
          entry = type(entry) == "string" and entry or nil
          if entry and trim_query(entry) ~= "" and not seen[entry] then
            out[#out + 1] = entry
            seen[entry] = true
            if #out >= 50 then break end
          end
        end
        if #out > 0 then normalized[mode] = out end
      end
    end
    return normalized
  end

  fuzzy_searcher.prompt_history = normalize(storage.load("fuzzy_searcher", "prompt_history"))
  fuzzy_searcher.prompt_history_loaded = true
end

function fuzzy_searcher.save_prompt_history()
  fuzzy_searcher.load_prompt_history()
  storage.save("fuzzy_searcher", "prompt_history", fuzzy_searcher.prompt_history)
end

function fuzzy_searcher.prompt_history_for_mode(mode)
  fuzzy_searcher.load_prompt_history()
  mode = tostring(mode or "")
  fuzzy_searcher.prompt_history[mode] = fuzzy_searcher.prompt_history[mode] or {}
  return fuzzy_searcher.prompt_history[mode]
end

function fuzzy_searcher.record_prompt_history_text(text)
  local mode, query = split_mode_prefix(text)
  query = tostring(query or "")
  if trim_query(query) == "" then return end

  local history = fuzzy_searcher.prompt_history_for_mode(mode)
  for i = #history, 1, -1 do
    if history[i] == query then table.remove(history, i) end
  end
  table.insert(history, 1, query)
  while #history > 50 do table.remove(history) end
  fuzzy_searcher.save_prompt_history()
end

function fuzzy_searcher.restored_prompt_text(text)
  local mode, query = split_mode_prefix(text)
  if query ~= "" then return text, false end
  local latest = fuzzy_searcher.prompt_history_for_mode(mode)[1]
  if latest and latest ~= "" then return mode .. latest, true end
  return text, false
end

local function split_words(q)
  local t = {}
  for w in trim_query(q):lower():gmatch("%S+") do t[#t+1] = w end
  return t
end

local SCORE_MATCH = 16
local BONUS_BOUNDARY = SCORE_MATCH / 2
local BONUS_BOUNDARY_WHITE = BONUS_BOUNDARY + 2
local BONUS_BOUNDARY_DELIMITER = BONUS_BOUNDARY + 1
local BONUS_NON_WORD = BONUS_BOUNDARY
local BONUS_CAMEL123 = BONUS_BOUNDARY - 1
local BONUS_CONSECUTIVE = 4

local function char_class_at(text, idx)
  if idx < 1 or idx > #text then return "white" end
  local ch = text:sub(idx, idx)
  local b = ch:byte()
  if ch:match("%s") then return "white" end
  if ch == "/" or ch == "\\" or ch == ":" or ch == ";" or ch == "," or ch == "|" then return "delimiter" end
  if b and b >= 48 and b <= 57 then return "number" end
  if b and b >= 97 and b <= 122 then return "lower" end
  if b and b >= 65 and b <= 90 then return "upper" end
  if ch:match("%a") then return "letter" end
  return "nonword"
end

local function bonus_for(prev_class, class)
  if class ~= "white" then
    if prev_class == "white" then return BONUS_BOUNDARY_WHITE end
    if prev_class == "delimiter" then return BONUS_BOUNDARY_DELIMITER end
    if prev_class == "nonword" then return BONUS_BOUNDARY end
  end
  if (prev_class == "lower" and class == "upper") or (prev_class ~= "number" and class == "number") then
    return BONUS_CAMEL123
  end
  if class == "nonword" or class == "delimiter" then return BONUS_NON_WORD end
  if class == "white" then return BONUS_BOUNDARY_WHITE end
  return 0
end

local function bonus_at(text, idx)
  local prev_class = idx == 1 and "white" or char_class_at(text, idx - 1)
  return bonus_for(prev_class, char_class_at(text, idx))
end

local function positions_to_spans(positions, offset)
  local spans = {}
  offset = offset or 0
  local s, e
  for _, p in ipairs(positions or {}) do
    if not s then
      s, e = p, p
    elseif p == e + 1 then
      e = p
    else
      spans[#spans+1] = { offset + s, offset + e }
      s, e = p, p
    end
  end
  if s then spans[#spans+1] = { offset + s, offset + e } end
  return spans
end

local function fuzzy_match(query, text)
  query = trim_query(query)
  text = tostring(text or "")
  if query == "" then return 0, {}, nil, nil end
  local match = fuzzy_native.match(text, query, { mode = "generic", spans = true })
  if not match then return nil end
  return match.score, match.spans or {}, match.selection_span, match.match_start
end

local function fuzzy_subsequence_too_weak(word_len, positions)
  if word_len < 4 then return false end
  if not positions or #positions == 0 then return false end
  local longest_run, current_run, max_gap = 1, 1, 0
  for i = 2, #positions do
    local gap = positions[i] - positions[i - 1] - 1
    if gap > max_gap then max_gap = gap end
    if positions[i] == positions[i - 1] + 1 then
      current_run = current_run + 1
    else
      current_run = 1
    end
    if current_run > longest_run then longest_run = current_run end
  end
  if longest_run >= math.ceil(word_len / 2) then return false end
  local span = positions[#positions] - positions[1] + 1
  if span > word_len * 2 + 4 then return true end
  return max_gap > math.max(10, word_len * 2)
end

local function fuzzy_match_file_fast_word(word, text, lower, base_start)
  word = trim_query(word):lower()
  if word == "" then return 0, {} end

  local positions = {}
  local score = 0
  local scan = 1
  local last = 0
  for i = 1, #word do
    local p = lower:find(word:sub(i, i), scan, true)
    if not p then return nil end
    positions[#positions+1] = p

    local b = bonus_at(text, p)
    score = score + SCORE_MATCH + b
    if p == last + 1 then score = score + BONUS_CONSECUTIVE end
    if p >= base_start then score = score + 8 end
    if text:sub(p, p) == word:sub(i, i) then score = score + 1 end

    last = p
    scan = p + 1
  end

  if fuzzy_subsequence_too_weak(#word, positions) then return nil end

  score = score - (positions[1] or 1)
  score = score - math.floor((positions[#positions] - positions[1]) / 3)
  return score, positions_to_spans(positions)
end

local function fuzzy_match_file_fast(query, text)
  query = trim_query(query)
  text = tostring(text or "")
  if query == "" then return 0, {} end

  local lower = text:lower()
  local base = text:match("[^/\\]+$") or text
  local base_start = #text - #base + 1
  local total, spans = 0, {}

  for _, word in ipairs(split_words(query)) do
    local exact_s, exact_e = lower:find(word:lower(), 1, true)
    local score, word_spans
    if exact_s then
      score = SCORE_MATCH * #word + 120 - exact_s - math.floor((exact_e - exact_s) / 2)
      if exact_s >= base_start then score = score + 120 end
      word_spans = { { exact_s, exact_e } }
    else
      score, word_spans = fuzzy_match_file_fast_word(word, text, lower, base_start)
      if not score then return nil end
    end
    total = total + score
    for _, span in ipairs(word_spans) do spans[#spans+1] = span end
  end

  total = total - math.floor(#text / 8)
  return total, spans
end

local line_exists

local function collect_recent_file_matches(query, line, skip_path)
  local matches, skip_keys = {}, {}
  local empty_query = trim_query(query) == ""

  for _, item in ipairs(get_recent_files(skip_path)) do
    local key = file_result_key(item)
    if key then skip_keys[key] = true end
    local score, spans = 0, {}
    if not empty_query then
      score, spans = fuzzy_match_file_fast(query, item)
    end
    if score and line_exists(item, line) then
      matches[#matches+1] = { item = item, text = item, score = score, spans = spans or {} }
    end
  end

  return matches, skip_keys
end

local function build_sectioned_file_results(recent_matches, general_matches, limit, query, line)
  local out = {}
  local shown_recent, shown_general = 0, 0
  limit = math.max(0, limit or 0)

  for _, match in ipairs(recent_matches or {}) do
    if #out >= limit then break end
    out[#out+1] = {
      kind = "file", label = match.item, file = match.item,
      line = line or 1, col = 1, query = query,
      match_spans = match.spans or {}, recent = true
    }
    shown_recent = shown_recent + 1
  end

  local general_available = #(general_matches or {}) > 0
  local separator_visible = shown_recent > 0 and general_available and #out + 1 < limit
  if separator_visible then
    out[#out+1] = { header = true, separator = true, label = "" }
  end

  if shown_recent == 0 or separator_visible then
    for _, match in ipairs(general_matches or {}) do
      if #out >= limit then break end
      out[#out+1] = {
        kind = "file", label = match.item, file = match.item,
        line = line or 1, col = 1, query = query,
        match_spans = match.spans or {}
      }
      shown_general = shown_general + 1
    end
  end

  local hidden_recent = shown_recent < #(recent_matches or {})
  local hidden_general = shown_general < #(general_matches or {})
  return out, hidden_recent or hidden_general
end

local function fuzzy_result_better(a, b)
  if a.score == b.score then return tostring(a.text) < tostring(b.text) end
  return a.score > b.score
end

local function fuzzy_insert_top(scored, candidate, limit)
  if limit <= 0 then return end
  local n = #scored
  if n >= limit and not fuzzy_result_better(candidate, scored[n]) then return end

  local insert_at = n + 1
  while insert_at > 1 and fuzzy_result_better(candidate, scored[insert_at - 1]) do
    insert_at = insert_at - 1
  end
  table.insert(scored, insert_at, candidate)
  if #scored > limit then table.remove(scored) end
end

local function fuzzy_filter(items, query, limit, make_text)
  query = trim_query(query)
  limit = math.max(0, limit or #items)
  if query == "" then
    local out = {}
    for i = 1, math.min(limit, #items) do
      local text = make_text and make_text(items[i]) or items[i]
      out[#out+1] = { item = items[i], text = text, score = 0, spans = {} }
    end
    return out
  end

  if not make_text then
    local native_results = fuzzy_native.filter(items, query, { mode = "generic", limit = limit, spans = true })
    local out = {}
    for _, match in ipairs(native_results) do
      out[#out+1] = {
        item = items[match.index],
        text = match.text,
        score = match.score or 0,
        spans = match.spans or {}
      }
    end
    return out
  end

  -- Keep only the best requested results instead of collecting and sorting every
  -- match. This fallback is only used for lists whose display text is produced
  -- by a Lua callback, which v1 of the native engine intentionally avoids in the
  -- hot loop.
  local scored = {}
  for _, item in ipairs(items) do
    local text = make_text and make_text(item) or item
    local score, spans = fuzzy_match(query, text)
    if score then
      fuzzy_insert_top(scored, { item = item, text = text, score = score, spans = spans or {} }, limit)
    end
  end
  return scored
end

local function line_count(path)
  local cached = line_count_cache[path]
  if cached then return cached end
  local fp = io.open(path, "rb")
  if not fp then line_count_cache[path] = 0; return 0 end
  local n = 0
  for _ in fp:lines() do n = n + 1 end
  fp:close()
  line_count_cache[path] = n
  return n
end

line_exists = function(relpath, nr)
  if not nr then return true end
  return line_count(fullpath(relpath)) >= nr
end

local binary_preview_extensions = {
  pdf=true,
  doc=true, docx=true, xls=true, xlsx=true, ppt=true, pptx=true,
  odt=true, ods=true, odp=true,
  zip=true, rar=true, ["7z"]=true, tar=true, gz=true, bz2=true, xz=true,
  exe=true, dll=true, pdb=true, lib=true, obj=true, so=true, dylib=true,
  class=true, jar=true, pyc=true,
  mp3=true, wav=true, flac=true, ogg=true, m4a=true,
  mp4=true, mov=true, avi=true, mkv=true, webm=true,
  ttf=true, otf=true, woff=true, woff2=true,
  sqlite=true, db=true,
}

local function file_extension(path)
  local ext = tostring(path or ""):match("%.([^%.%/%\\]+)$")
  return ext and ext:lower() or ""
end

local function detect_binary_preview(path)
  local ext = file_extension(path)
  if binary_preview_extensions[ext] then return true, ext:upper() .. " file" end

  local info = system.get_file_info(path)
  if info and info.size and info.size > (fuzzy_searcher.preview_text_max_bytes or 2097152) then
    return true, string.format("Large file (%.1f MB)", info.size / 1024 / 1024)
  end

  local fp = io.open(path, "rb")
  if not fp then return true, "Cannot open file" end
  local data = fp:read(8192) or ""
  fp:close()

  if data:sub(1, 4) == "%PDF" then return true, "PDF file" end
  if data:sub(1, 2) == "MZ" then return true, "Windows executable" end
  if data:sub(1, 4) == "PK\003\004" then return true, "ZIP container" end
  if data:sub(1, 7) == "\127ELF\002\001\001" or data:sub(1, 4) == "\127ELF" then return true, "ELF binary" end
  if data:find("%z", 1, true) then return true, "Binary file" end

  local weird = 0
  for i = 1, #data do
    local b = data:byte(i)
    if b < 32 and b ~= 9 and b ~= 10 and b ~= 13 and b ~= 12 then weird = weird + 1 end
  end
  if #data > 0 and weird / #data > 0.05 then return true, "Binary file" end
  return false, nil
end

local function tokenize_code_query(q)
  local t = {}
  for w in tostring(q or ""):lower():gmatch("%S+") do
    if #w > 1 then t[#t+1] = w end
  end
  return t
end

local function parse_code_search_terms(q)
  local terms = {}
  local i, n = 1, #q

  local function add_fuzzy_chunk(chunk)
    for _, tok in ipairs(tokenize_code_query(chunk or "")) do
      terms[#terms+1] = { text = tok, exact = false }
    end
  end

  local function add_exact_phrase(phrase)
    phrase = tostring(phrase or "")
    if phrase ~= "" then terms[#terms+1] = { text = phrase:lower(), exact = true, phrase = phrase } end
  end

  while i <= n do
    while i <= n and q:sub(i, i):match("%s") do i = i + 1 end
    if i > n then break end

    if q:sub(i, i) == '"' then
      local j = i + 1
      while j <= n do
        if q:sub(j, j) == '"' then
          local k = j
          while k + 1 <= n and q:sub(k + 1, k + 1) == '"' do k = k + 1 end
          if k == n or q:sub(k + 1, k + 1):match("%s") then
            break
          end
          j = k + 1
        else
          j = j + 1
        end
      end
      if j <= n then
        add_exact_phrase(q:sub(i + 1, j - 1))
        i = j + 1
      else
        -- While the closing quote has not been typed yet, still treat the
        -- remainder as one literal phrase instead of splitting on spaces.
        add_exact_phrase(q:sub(i + 1))
        break
      end
    else
      local j = i
      while j <= n and (not q:sub(j, j):match("%s")) and q:sub(j, j) ~= '"' do j = j + 1 end
      add_fuzzy_chunk(q:sub(i, j - 1))
      i = j
    end
  end

  return terms
end

local function quoted_exact_query(q)
  local s = trim_query(q)
  if s:sub(1, 1) ~= '"' then return nil end
  if #s > 1 and s:sub(-1) == '"' then return s:sub(2, -2) end
  return s:sub(2)
end

local function terms_to_legacy_tokens(terms)
  local tokens = {}
  for _, term in ipairs(terms or {}) do tokens[#tokens+1] = term.text end
  return tokens
end

local function terms_fuzzy_query(terms)
  local tokens = {}
  for _, term in ipairs(terms or {}) do
    if not term.exact then tokens[#tokens+1] = term.text end
  end
  return table.concat(tokens, " ")
end

local function exact_term_spans(lower_text, terms)
  local spans = {}
  for _, term in ipairs(terms or {}) do
    if term.exact then
      local start = 1
      local found = false
      while true do
        local s, e = lower_text:find(term.text, start, true)
        if not s then break end
        spans[#spans+1] = { s, e }
        found = true
        start = e + 1
      end
      if not found then return nil end
    end
  end
  return spans
end

local function yield_if_over_budget(start_time)
  local budget = fuzzy_searcher.fuzzy_time_slice or 0.006
  if system.get_time() - start_time >= budget then
    coroutine.yield(1 / config.fps)
    return system.get_time()
  end
  return start_time
end

local function parse_vimgrep(line)
  local f, l, c, txt = line:match("^(.-):(%d+):(%d+):(.*)$")
  if not f then return nil end
  return {
    kind = "grep",
    file = f:gsub("\\", "/"),
    line = tonumber(l),
    col = tonumber(c),
    text = txt,
    exact = true,
  }
end

local function scope_key(scope)
  if not scope then return "*" end
  return table.concat(scope, "\0")
end

local function fuzzy_job_key(root, scope, seed)
  return root .. "\0" .. scope_key(scope) .. "\0" .. seed:lower()
end

local function seed_for_tokens(tokens)
  local seed = tokens[1]
  for _, tok in ipairs(tokens or {}) do if #tok > #(seed or "") then seed = tok end end
  return seed
end

local function kill_fuzzy_grep_jobs()
  for _, job in pairs(fuzzy_grep_jobs) do
    if job.proc and job.proc:running() then pcall(function() job.proc:kill() end) end
    job.cancelled = true
  end
  fuzzy_grep_jobs = {}
end

local function ensure_fuzzy_grep_job(root, scope, tokens)
  if not tokens or #tokens == 0 then return nil end

  -- Prefer reusing an already-warm broader stream when the user appends tokens,
  -- e.g. #word -> #word test. Also start the most selective stream in the
  -- background if it differs, so future filtering can switch to it.
  local preferred_seed = seed_for_tokens(tokens)
  local reusable
  for _, tok in ipairs(tokens) do
    local existing = fuzzy_grep_jobs[fuzzy_job_key(root, scope, tok)]
    if existing then reusable = existing; break end
  end

  local function start_job(seed)
    local key = fuzzy_job_key(root, scope, seed)
    local job = fuzzy_grep_jobs[key]
    if job then job.last_used = system.get_time(); return job end

    job = {
      key = key,
      root = root,
      scope = scope,
      seed = seed,
      lines = {},
      seen = {},
      scanned = 0,
      version = 0,
      done = false,
      truncated = false,
      cancelled = false,
      last_used = system.get_time(),
    }
    fuzzy_grep_jobs[key] = job

    core.add_thread(function()
      local args = { fuzzy_searcher.rg, "--vimgrep", "--color", "never", "-i", "-F", "--hidden", "--glob", "!.git/**", "-e", seed }
      if scope then args[#args+1] = "--"; for _, f in ipairs(scope) do args[#args+1] = f end end
      local proc = process.start(args, { cwd = root, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_DISCARD, stdin = process.REDIRECT_DISCARD })
      job.proc = proc
      if not proc then job.done = true; job.version = job.version + 1; return end

      local max_scanned = fuzzy_searcher.fuzzy_scan_limit or 10000
      local max_line_chars = fuzzy_searcher.fuzzy_line_max_chars or 1200
      local slice_start = system.get_time()
      while not job.cancelled and job.scanned < max_scanned do
        local l = proc.stdout:read("line", { scan = 1 / config.fps })
        if l then
          job.scanned = job.scanned + 1
          local r = parse_vimgrep(l)
          if r and #(r.text or "") <= max_line_chars then
            local key = r.file .. ":" .. tostring(r.line)
            if not job.seen[key] then
              job.seen[key] = true
              job.lines[#job.lines+1] = r
              job.version = job.version + 1
            end
          end
          slice_start = yield_if_over_budget(slice_start)
        elseif not proc:running() then
          break
        else
          coroutine.yield(1 / config.fps)
          slice_start = system.get_time()
        end
      end

      job.truncated = proc:running() or job.scanned >= max_scanned
      if proc:running() then pcall(function() proc:kill() end) end
      proc:wait(process.WAIT_DEADLINE)
      job.done = true
      job.version = job.version + 1
      if active_view then active_view:schedule_update(true) end
    end)

    return job
  end

  local preferred = preferred_seed and start_job(preferred_seed) or nil
  if reusable and preferred and reusable ~= preferred then return reusable, preferred end
  return reusable or preferred, preferred
end

local function basename(path)
  return (path and path:match("[^/\\]+$")) or path or ""
end

local function truncate_text(font, text, max_width)
  text = tostring(text or "")
  if max_width <= 0 then return "" end
  if font:get_width(text) <= max_width then return text end
  local ellipsis = "..."
  if font:get_width(ellipsis) > max_width then return "" end
  local lo, hi = 0, text:ulen(nil, nil, true) or #text
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    local candidate = text:usub(1, mid) .. ellipsis
    if font:get_width(candidate) <= max_width then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return text:usub(1, lo) .. ellipsis
end

local function utf8_floor_end(text, pos)
  pos = common.clamp(math.floor(pos or 0), 0, #text)
  while pos > 0 and pos < #text and common.is_utf8_cont(text, pos + 1) do
    pos = pos - 1
  end
  return pos
end

local function utf8_ceil_start(text, pos)
  pos = common.clamp(math.floor(pos or 1), 1, #text + 1)
  while pos <= #text and common.is_utf8_cont(text, pos) do
    pos = pos + 1
  end
  return pos
end

local function utf8_safe_sub(text, first, last)
  if #text == 0 then return "" end
  first = utf8_ceil_start(text, first or 1)
  last = utf8_floor_end(text, last or #text)
  if first > last or first > #text then return "" end
  return text:sub(first, last)
end

local function fit_forward_end(font, text, first, max_width)
  first = utf8_ceil_start(text, first or 1)
  if max_width <= 0 or first > #text then return first - 1 end
  if font:get_width(utf8_safe_sub(text, first, #text)) <= max_width then return #text end

  local lo, hi = first - 1, #text
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if font:get_width(utf8_safe_sub(text, first, mid)) <= max_width then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return utf8_floor_end(text, lo)
end

local function fit_suffix_start(font, text, last, max_width)
  last = utf8_floor_end(text, last or #text)
  if max_width <= 0 or last < 1 then return last + 1 end
  if font:get_width(utf8_safe_sub(text, 1, last)) <= max_width then return 1 end

  local lo, hi = 1, last
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if font:get_width(utf8_safe_sub(text, mid, last)) <= max_width then
      hi = mid
    else
      lo = mid + 1
    end
  end
  return utf8_ceil_start(text, lo)
end

local function merge_spans(spans, max_len)
  table.sort(spans, function(a, b) return a[1] < b[1] end)
  local merged = {}
  for _, span in ipairs(spans) do
    if span[1] <= max_len and span[2] >= 1 then
      local s = common.clamp(span[1], 1, max_len)
      local e = common.clamp(span[2], 1, max_len)
      if s <= e then
        local last = merged[#merged]
        if last and s <= last[2] + 1 then
          last[2] = math.max(last[2], e)
        else
          merged[#merged+1] = {s, e}
        end
      end
    end
  end
  return merged
end

local function literal_spans(text, query, offset)
  local spans = {}
  text = tostring(text or "")
  query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return spans end
  offset = offset or 0
  local lower_text, lower_query = text:lower(), query:lower()
  local pos = 1
  while true do
    local s, e = lower_text:find(lower_query, pos, true)
    if not s then break end
    spans[#spans+1] = {offset + s, offset + e}
    pos = e + 1
  end
  return spans
end

local function offset_spans(spans, offset)
  local out = {}
  offset = offset or 0
  for _, span in ipairs(spans or {}) do out[#out+1] = { span[1] + offset, span[2] + offset } end
  return out
end

local function project_spans(spans, src_start, src_end, dst_before)
  local out = {}
  dst_before = dst_before or 0
  for _, span in ipairs(spans or {}) do
    local s = math.max(span[1], src_start)
    local e = math.min(span[2], src_end)
    if s <= e then out[#out+1] = { dst_before + (s - src_start + 1), dst_before + (e - src_start + 1) } end
  end
  return out
end

local function grep_content_spans(text, result, offset, line_nr)
  if not result or not result.grep_query or result.grep_query == "" then return {} end
  if result.content_spans and (not line_nr or line_nr == result.line) then
    return offset_spans(result.content_spans, offset)
  end
  if result.exact then
    return literal_spans(text, result.grep_query, offset)
  end
  if line_nr and line_nr ~= result.line then return {} end
  local _, spans = fuzzy_match(result.fuzzy_query or result.grep_query, text)
  return offset_spans(spans, offset)
end

local function single_span_or_leftmost(spans)
  local first
  for _, span in ipairs(spans or {}) do
    local s, e = tonumber(span[1]), tonumber(span[2])
    if s and e and s <= e then
      if not first or s < first[1] then first = { s, e } end
    end
  end
  if not first then return nil, nil end
  if #(spans or {}) == 1 then return first, first[1] end
  return nil, first[1]
end

local function grep_accept_range(result)
  if not result or result.kind ~= "grep" then return nil end
  local line = result.line or 1
  if result.content_selection_span then
    return line, result.content_selection_span[1], line, result.content_selection_span[2] + 1
  end
  if result.content_match_start then
    return line, result.content_match_start
  end
  local selection_span, match_start = single_span_or_leftmost(result.content_spans)
  if selection_span then return line, selection_span[1], line, selection_span[2] + 1 end
  if match_start then return line, match_start end
  if result.exact and result.col and result.grep_query and result.grep_query ~= "" then
    return line, result.col, line, result.col + #result.grep_query
  end
  return line, result.col or 1
end

local function color_with_alpha(color, alpha)
  color = color or style.accent
  return { color[1] or 255, color[2] or 255, color[3] or 255, alpha or color[4] or 255 }
end

function PreviewDocView:get_font()
  return style.get_small_font(DocView.get_font(self))
end

local function text_span_for_anchor(spans, text_len, anchor_pos)
  local first, best, best_distance
  anchor_pos = tonumber(anchor_pos)
  for _, span in ipairs(spans or {}) do
    local s, e = tonumber(span[1]), tonumber(span[2])
    if s and e and s <= text_len and e >= 1 then
      s, e = common.clamp(s, 1, text_len), common.clamp(e, 1, text_len)
      if s <= e then
        if not first or s < first[1] then first = { s, e } end
        if anchor_pos then
          local distance = anchor_pos < s and (s - anchor_pos) or (anchor_pos > e and (anchor_pos - e) or 0)
          if not best or distance < best_distance or (distance == best_distance and s < best[1]) then
            best, best_distance = { s, e }, distance
          end
        end
      end
    end
  end
  return best or first
end

local function prefix_clipped_highlight(font, text, width, spans, ellipsis, ellipsis_width)
  local keep = fit_forward_end(font, text, 1, width - ellipsis_width)
  return utf8_safe_sub(text, 1, keep) .. ellipsis, project_spans(spans, 1, keep, 0)
end

local function clip_highlighted_text(font, text, width, spans, anchor_to_match)
  text = tostring(text or "")
  spans = spans or {}
  if width <= 0 then return "", {} end
  if font:get_width(text) <= width then return text, merge_spans(spans, #text) end

  local ellipsis = "..."
  local ellipsis_width = font:get_width(ellipsis)
  if ellipsis_width > width then return "", {} end

  local anchor_pos = type(anchor_to_match) == "number" and anchor_to_match or nil
  local anchor = anchor_to_match and text_span_for_anchor(spans, #text, anchor_pos) or nil
  if not anchor then
    return prefix_clipped_highlight(font, text, width, spans, ellipsis, ellipsis_width)
  end

  -- If the normal left-to-right truncation still shows the full anchored
  -- match, keep it; just avoid projecting highlight spans onto the ellipsis.
  local prefix_keep = fit_forward_end(font, text, 1, width - ellipsis_width)
  if anchor[2] <= prefix_keep then
    return utf8_safe_sub(text, 1, prefix_keep) .. ellipsis, project_spans(spans, 1, prefix_keep, 0)
  end

  -- The match starts beyond the visible prefix. Slide the inline preview
  -- forward and render a window around the anchored content match, with a leading
  -- ellipsis for omitted text. The projected spans only cover real source text,
  -- so the ellipses themselves are never highlighted as matches.
  local match_start = utf8_ceil_start(text, anchor[1])
  local match_end = utf8_floor_end(text, anchor[2])
  if match_end < match_start then match_end = match_start end

  local leading = match_start > 1
  local trailing = match_end < #text
  local fixed_width = (leading and ellipsis_width or 0) + (trailing and ellipsis_width or 0)
  if fixed_width >= width then
    trailing = false
    fixed_width = leading and ellipsis_width or 0
    if fixed_width >= width then
      return prefix_clipped_highlight(font, text, width, spans, ellipsis, ellipsis_width)
    end
  end

  local text_width = width - fixed_width
  local match_width = font:get_width(utf8_safe_sub(text, match_start, match_end))
  local extra_width = math.max(0, text_width - math.min(match_width, text_width))
  local before_budget = math.min(extra_width * 0.45, text_width * 0.30)
  local first = match_start
  if before_budget > 1 and match_start > 1 then
    local before_end = utf8_floor_end(text, match_start - 1)
    if before_end >= 1 then first = fit_suffix_start(font, text, before_end, before_budget) end
  end

  first = utf8_ceil_start(text, first)
  leading = first > 1
  fixed_width = (leading and ellipsis_width or 0) + (trailing and ellipsis_width or 0)
  if fixed_width >= width then
    trailing = false
    fixed_width = leading and ellipsis_width or 0
  end
  if fixed_width >= width then
    return prefix_clipped_highlight(font, text, width, spans, ellipsis, ellipsis_width)
  end

  local last = fit_forward_end(font, text, first, width - fixed_width)
  if last < match_start then
    first = match_start
    leading = first > 1
    trailing = false
    fixed_width = leading and ellipsis_width or 0
    if fixed_width >= width then
      return prefix_clipped_highlight(font, text, width, spans, ellipsis, ellipsis_width)
    end
    last = fit_forward_end(font, text, first, width - fixed_width)
  end
  if last < match_start then
    return prefix_clipped_highlight(font, text, width, spans, ellipsis, ellipsis_width)
  end

  trailing = last < #text
  local clipped = (leading and ellipsis or "") .. utf8_safe_sub(text, first, last) .. (trailing and ellipsis or "")
  return clipped, project_spans(spans, first, last, leading and #ellipsis or 0)
end

local function draw_match_highlight_rect(x, y, w, h)
  if w <= 0 or h <= 0 then return end
  renderer.draw_rect(x, y, w, h, style.selectionhighlight)
  local outline = style.search_selection_secondary_outline
  if not outline then return end
  local t = math.max(1, SCALE or 1)
  renderer.draw_rect(x, y, w, t, outline)
  renderer.draw_rect(x, y + h - t, w, t, outline)
  renderer.draw_rect(x, y, t, h, outline)
  renderer.draw_rect(x + w - t, y, t, h, outline)
end

local function draw_highlighted_text(font, text, x, y, width, color, spans, match_color, anchor_to_match)
  local clipped
  clipped, spans = clip_highlighted_text(font, text, width, spans, anchor_to_match)
  spans = merge_spans(spans or {}, #clipped)
  local highlight_fg = match_color or style.search_selection_text or color
  local pos = 1
  local cx = x
  local line_h = font:get_height()
  for _, span in ipairs(spans) do
    if pos < span[1] then
      cx = renderer.draw_text(font, clipped:sub(pos, span[1] - 1), cx, y, color)
    end
    local chunk = clipped:sub(span[1], span[2])
    local chunk_w = font:get_width(chunk)
    draw_match_highlight_rect(cx, y, chunk_w, line_h)
    cx = renderer.draw_text(font, chunk, cx, y, highlight_fg)
    pos = span[2] + 1
  end
  if pos <= #clipped then
    cx = renderer.draw_text(font, clipped:sub(pos), cx, y, color)
  end
  return cx
end

local function draw_prefixed_highlighted_text(font, prefix, text, x, y, width, color, spans, match_color, anchor_to_match)
  prefix = prefix or ""
  if prefix == "" then
    return draw_highlighted_text(font, text, x, y, width, color, spans, match_color, anchor_to_match)
  end
  if width <= 0 then return x end

  local prefix_w = font:get_width(prefix)
  if prefix_w >= width then
    return renderer.draw_text(font, truncate_text(font, prefix, width), x, y, style.dim)
  end

  local cx = renderer.draw_text(font, prefix, x, y, style.dim)
  return draw_highlighted_text(font, text, cx, y, width - prefix_w, color, spans, match_color, anchor_to_match)
end

local function command_preview_parts(name)
  local binding = keymap.get_binding(name)
  local picker = current_picker()
  local path = picker and picker.source_file_path
  if not path then
    path = file_context.view_file_path(core.active_view)
  end

  local preview
  if name == "user:copy-absolute-filepath" then
    preview = path
  elseif name == "user:copy-absolute-filepath-with-line" then
    local picker = current_picker()
    local line = picker and picker.source_file_line or 1
    preview = path and string.format("%s:%d", path, line or 1)
  elseif name == "user:copy-relative-filepath" then
    local root = core.root_project and core.root_project()
    local root_path = root and common.normalize_path(root.path)
    if path and root_path and common.path_belongs_to(path, root_path) then
      preview = common.relative_path(root_path, path):gsub("\\", "/")
    elseif path then
      preview = "not inside project"
    end
  elseif name == "user:copy-filename" then
    preview = path and basename(path)
  end

  if binding == "" then binding = nil end
  if preview == "" then preview = nil end
  return binding, preview
end

local function command_preview_info(name)
  local binding, preview = command_preview_parts(name)
  if binding and preview then return binding .. "  ·  " .. preview end
  return preview or binding
end

local function command_status_parts(name)
  local picker = current_picker()
  local value = command.get_status(name, picker and picker.source_view)
  if value == nil or value == "" then return nil end

  local state
  if type(value) == "boolean" then
    state = value
    value = value and "ON" or "OFF"
  end
  return {
    prefix = " [Currently: ",
    value = tostring(value),
    suffix = "]",
    state = state,
  }
end

local function command_status_width(font, status)
  if not status then return 0 end
  return font:get_width(status.prefix .. status.value .. status.suffix)
end

local function draw_command_status(font, status, x, y, width)
  if not status or width <= 0 then return x end
  local prefix = status.prefix
  local value = status.value
  local suffix = status.suffix
  local total = prefix .. value .. suffix
  if font:get_width(total) > width then
    return renderer.draw_text(font, truncate_text(font, total, width), x, y, style.dim)
  end

  local value_color = status.state == true and style.good
    or status.state == false and style.error
    or style.text
  x = renderer.draw_text(font, prefix, x, y, style.dim)
  x = renderer.draw_text(font, value, x, y, value_color)
  return renderer.draw_text(font, suffix, x, y, style.dim)
end

local function result_list_label_and_spans(r)
  if r.kind == "command" then
    return r.label or r.command or "", r.match_spans or {}, "> "
  end
  if r.kind == "project" then
    local text = r.label or r.project or ""
    return display_root(text), r.match_spans or {}, "@ "
  end
  if r.kind == "symbol" then
    local text = r.label or r.name or ""
    local prefix = r.symbol_scope == "document" and "$$ " or "$ "
    return prefix .. text, offset_spans(r.match_spans or {}, #prefix)
  end
  local text = r.label or r.file or ""
  return text, r.match_spans or {}
end

local function draw_project_result_row(font, r, x, y, width)
  local label, spans, prefix = result_list_label_and_spans(r)
  local age = r.opened_at and compact_age(r.opened_at)
  local gap = style.padding.x
  local label_w = width
  if age and age ~= "" then
    local age_w = font:get_width(age)
    renderer.draw_text(font, age, x + width - age_w, y, style.dim)
    label_w = math.max(0, width - age_w - gap)
  end
  draw_prefixed_highlighted_text(font, prefix, label, x, y, label_w, style.text, spans)
end

local function draw_new_project_result_row(font, r, x, y, width)
  local prefix = "Open this new folder as project: "
  local cx = renderer.draw_text(font, prefix, x, y, style.dim)
  draw_highlighted_text(font, r.project or r.label or "", cx, y, math.max(0, x + width - cx), style.text, {})
end

local draw_file_result_row
local grep_row_columns

local function draw_symbol_result_row(font, r, x, y, width)
  local path_w, gap, text_w = grep_row_columns(width)
  local line = tonumber(r.line) or 1
  local line_suffix = line <= 9999 and string.format(":%-4d", line) or ":" .. tostring(line)
  local prefix = r.symbol_scope == "document" and "$$ " or "$ "
  draw_file_result_row(font, r.file or "", r.file_spans, prefix, x, y, path_w, line_suffix)
  if text_w <= 0 then return end

  local preview_font = style.get_small_font(font)
  local preview_y = y + math.max(0, math.floor((font:get_height() - preview_font:get_height()) / 2))
  local text_x = x + path_w + gap
  local declaration = tostring(r.declaration or "")
  if declaration ~= "" and r.declaration_name_span then
    local name_start = math.max(1, tonumber(r.declaration_name_span[1]) or 1)
    local name_end = math.min(#declaration, tonumber(r.declaration_name_span[2]) or 0)
    if name_start <= name_end then
      local before = declaration:sub(1, name_start - 1)
      local name = declaration:sub(name_start, name_end)
      local after = declaration:sub(name_end + 1)
      local right = text_x + text_w
      local cx = text_x
      local name_w = preview_font:get_width(name)
      local before_w = math.min(preview_font:get_width(before), math.max(0, text_w - name_w))
      if before_w > 0 then
        cx = renderer.draw_text(preview_font, truncate_text(preview_font, before, before_w), cx, preview_y, style.dim)
      end
      if cx < right then
        cx = draw_highlighted_text(preview_font, name, cx, preview_y, math.max(0, right - cx), style.text, r.match_spans or {})
      end
      if after ~= "" and cx < right then
        renderer.draw_text(preview_font, truncate_text(preview_font, after, right - cx), cx, preview_y, style.dim)
      end
      return
    end
  end

  local label = tostring(r.label or r.name or "")
  local signature = tostring(r.signature or "")
  local signature_text = signature ~= "" and (" " .. signature) or ""
  local signature_w = math.min(text_w * 0.55, preview_font:get_width(signature_text))
  local label_w = math.max(0, text_w - signature_w)
  local label_end = draw_highlighted_text(preview_font, label, text_x, preview_y, label_w, style.text, r.match_spans or {})
  if signature_w > 0 and label_end < text_x + text_w then
    renderer.draw_text(preview_font, truncate_text(preview_font, signature_text, text_x + text_w - label_end), label_end, preview_y, style.dim)
  end
end

local function draw_everything_result_row(font, r, x, y, width)
  local gap = style.padding.x
  local kind_w = font:get_width("folder") + gap
  local size_w = math.max(font:get_width("999.9 MB"), font:get_width(r.size_label or "")) + gap
  local date_w = font:get_width("999w") + gap
  local meta_w = kind_w + size_w + date_w
  local path_w = math.max(0, width - meta_w)
  local kind = r.is_folder and "folder" or "file"
  local kind_color = r.is_folder and (style.accent) or (style.dim)
  draw_file_result_row(font, r.path or r.label, r.match_spans, r.is_folder and "@ " or "", x, y, path_w)
  local mx = x + path_w + gap
  renderer.draw_text(font, kind, mx, y, kind_color)
  mx = mx + kind_w
  renderer.draw_text(font, truncate_text(font, r.size_label or "", size_w - gap), mx, y, style.dim)
  mx = mx + size_w
  renderer.draw_text(font, truncate_text(font, r.modified_label or "", date_w - gap), mx, y, style.dim)
end

local function draw_command_result_row(font, r, x, y, width)
  local label, spans, prefix = result_list_label_and_spans(r)
  local binding, preview = command_preview_parts(r.command)
  -- Keep command rows column-aligned even when a row has no shortcut or no
  -- preview text: empty cells still reserve their column width.
  -- Layout: command label | preview/info | shortcut binding.
  -- In narrow panes, progressively shrink the side columns to zero so the
  -- command label eventually gets the full row width.
  local scale = SCALE or 1
  local side_column_factor = common.clamp((width - 260 * scale) / (760 * scale - 260 * scale), 0, 1)
  local preview_factor = side_column_factor * side_column_factor
  local gap = style.padding.x * side_column_factor
  local preview_w = math.floor(width * 0.28 * preview_factor)
  local binding_w = math.floor(width * 0.18 * side_column_factor)
  local label_w = math.max(0, width - preview_w - binding_w - gap * 2)

  local status_w = command_status_width(font, r.status)
  local command_label_w = label_w
  if status_w > 0 and label_w > status_w + font:get_width("> …") then
    command_label_w = label_w - status_w
  else
    status_w = 0
  end
  local label_end = draw_prefixed_highlighted_text(font, prefix, label, x, y, command_label_w, style.text, spans)
  if status_w > 0 then
    draw_command_status(font, r.status, label_end, y, status_w)
  end

  local preview_x = x + label_w + gap
  local binding_x = preview_x + preview_w + gap
  if preview and preview ~= "" then
    renderer.draw_text(font, truncate_text(font, preview, preview_w), preview_x, y, style.dim)
  end
  if binding and binding ~= "" then
    renderer.draw_text(font, truncate_text(font, binding, binding_w), binding_x, y, style.dim)
  end
end

draw_file_result_row = function(font, file, spans, prefix, x, y, width, suffix)
  file = tostring(file or "")
  spans = spans or {}
  prefix = prefix or ""
  suffix = suffix or ""

  local path_font = style.get_small_font(font)
  local prefix_color = style.dim
  local dir_color = style.dim
  local suffix_color = style.dim
  local name_color = style.text
  local line_h = font:get_height()
  local path_y = y + math.max(0, math.floor((line_h - path_font:get_height()) / 2))

  local cx = renderer.draw_text(font, prefix, x, y, prefix_color)
  local right = x + width
  local available = math.max(0, right - cx)
  if available <= 0 then return cx end

  local name = basename(file)
  local dir = file:sub(1, math.max(0, #file - #name))
  local name_start = #dir + 1
  local name_spans = project_spans(spans, name_start, #file, 0)
  local suffix_width = suffix ~= "" and font:get_width(suffix) or 0

  local name_width = font:get_width(name)
  if dir ~= "" then
    local scale = SCALE or 1
    local min_name_width = math.min(name_width, math.max(48 * scale, available * 0.55))
    local dir_width = name_width + suffix_width < available
      and available - name_width - suffix_width
      or math.max(0, available - min_name_width - suffix_width)
    if dir_width > path_font:get_width("...") then
      local dir_spans = project_spans(spans, 1, #dir, 0)
      cx = draw_highlighted_text(path_font, dir, cx, path_y, dir_width, dir_color, dir_spans)
      available = math.max(0, right - cx)
    end
  end

  local name_available = suffix_width > 0 and math.max(0, available - suffix_width) or available
  cx = draw_highlighted_text(font, name, cx, y, name_available, name_color, name_spans)
  local suffix_x = cx
  if suffix ~= "" and cx < right then
    cx = renderer.draw_text(font, truncate_text(font, suffix, right - cx), cx, y, suffix_color)
  end
  return cx, suffix_x
end

grep_row_columns = function(width)
  local scale = SCALE or 1
  local gap = math.max(8 * scale, style.padding.x)
  local ratio = fuzzy_searcher.grep_path_column_width or 0.45
  local path_w = math.floor(width * ratio)
  if width > 260 * scale then
    path_w = common.clamp(path_w, 130 * scale, width - 120 * scale)
  else
    path_w = math.floor(width * 0.5)
  end
  return path_w, gap, math.max(0, width - path_w - gap)
end

local function draw_grep_result_row(font, result, x, y, width, collapse_file, collapsed_line_x)
  local path_w, gap, text_w = grep_row_columns(width)
  local line = tonumber(result.line) or 1
  local line_suffix = line <= 9999 and string.format(":%-4d", line) or ":" .. tostring(line)
  local line_x = collapsed_line_x
  if collapse_file then
    line_x = common.clamp(line_x or x, x, x + path_w)
    renderer.draw_text(font, truncate_text(font, line_suffix, math.max(0, x + path_w - line_x)), line_x, y, style.dim)
  else
    local prefix = result.exact and "# " or "~# "
    local _end_x
    _end_x, line_x = draw_file_result_row(font, result.file or "", result.file_spans, prefix, x, y, path_w, line_suffix)
  end
  if text_w <= 0 then return line_x end
  local preview_font = style.get_small_font(font)
  local preview_y = y + math.max(0, math.floor((font:get_height() - preview_font:get_height()) / 2))
  local text_x = x + path_w + gap
  local text = tostring(result.text or "")
  local spans = grep_content_spans(text, result, 0)
  local anchor = result.col or true
  local leading = #(text:match("^%s*") or "")
  if leading > 0 then
    text = text:sub(leading + 1)
    spans = project_spans(spans, leading + 1, leading + #text, 0)
    if type(anchor) == "number" then anchor = math.max(1, anchor - leading) end
  end
  draw_highlighted_text(preview_font, text, text_x, preview_y, text_w, style.text, spans, nil, anchor)
  return line_x
end

local function build_scope(base, line, max_count)
  if base:sub(1, 1) == ">" then base = "" end
  local limit = max_count or 200
  local list = {}
  if not line and native_file_index_ready() then
    local ok, matches = pcall(function()
      return files_fuzzy_index:search(base, { limit = limit, spans = false })
    end)
    if ok and matches then
      for _, match in ipairs(matches) do list[#list+1] = match.text end
      return list
    end
  end

  local matches = fuzzy_filter(get_files(), base, limit)
  for _, match in ipairs(matches) do
    local f = match.item
    if (not line) or line_exists(f, line) then list[#list+1] = f end
  end
  return list
end

local everything = {
  state = "unknown",
  probe_generation = 0,
  search_generation = 0,
  host = os.getenv("EVERYTHING_HOST") or "localhost",
  port = os.getenv("EVERYTHING_PORT") or "54367",
}

local function everything_endpoint()
  return "http://" .. everything.host .. ":" .. everything.port .. "/"
end

local function probe_everything(view)
  if everything.state == "available" or everything.state == "unavailable" or everything.state == "probing" then return end
  everything.state = "probing"
  everything.probe_generation = everything.probe_generation + 1
  local gen = everything.probe_generation
  core.log_quiet("Fuzzy Everything: probing %s", everything_endpoint())
  http.get(everything_endpoint(), { json = "1", search = "", count = "1" }, {
    timeout = 1,
    on_done = function(ok, err)
      if gen ~= everything.probe_generation then return end
      everything.state = ok and "available" or "unavailable"
      core.log_quiet("Fuzzy Everything: probe %s%s", ok and "available" or "unavailable", err and (" — " .. tostring(err)) or "")
      if ok and view and active_view == view and view:is_project_mode() then
        view.dirty = true
        view:schedule_update(true)
      end
    end
  })
end

local function everything_full_path(item)
  local path = tostring(item.path or "")
  local name = item.name
  if name and name ~= "" then
    if path == "" then return common.normalize_path(name) end
    return common.normalize_path(path .. PATHSEP .. name)
  end
  return common.normalize_path(path)
end

local function everything_project_search_query(query)
  -- Project mode is looking for folders to open. Do not set Everything's
  -- path=1 flag here: a query like "sm64" would match every descendant whose
  -- parent path contains sm64 and bury the actual project folder.
  query = trim_query(query)
  if query == "" then return query end
  if query:lower():find("folder:", 1, true) then return query end
  return "folder: " .. query
end

local function everything_project_search_params(query, count, offset)
  return {
    json = "1",
    search = everything_project_search_query(query),
    count = tostring(count),
    offset = tostring(offset or 0),
    path_column = "1",
    size_column = "1",
    date_modified_column = "1",
    sort = "path",
    ascending = "1",
  }
end

local function everything_path_depth(path)
  path = tostring(path or "")
  local depth = 0
  for part in path:gmatch("[^/\\]+") do
    if part ~= "" then depth = depth + 1 end
  end
  return depth
end

local function sort_everything_project_results(results)
  table.sort(results, function(a, b)
    local af = a and a.is_folder and 0 or 1
    local bf = b and b.is_folder and 0 or 1
    if af ~= bf then return af < bf end

    local ap = tostring((a and (a.path or a.label)) or "")
    local bp = tostring((b and (b.path or b.label)) or "")
    local ad, bd = everything_path_depth(ap), everything_path_depth(bp)
    if ad ~= bd then return ad < bd end

    local al, bl = ap:lower(), bp:lower()
    if al ~= bl then return al < bl end
    return ap < bp
  end)
end

local function everything_result_from_item(item, query)
  local path = everything_full_path(item)
  if not path or path == "" then return nil end
  local is_folder = item.type == "folder"
  local modified_time = filetime_to_time(item.date_modified)
  local _, spans = fuzzy_match(query or "", path)
  return {
    kind = "everything",
    label = path,
    path = path,
    file = is_folder and nil or path,
    project = is_folder and path or nil,
    is_folder = is_folder,
    query = query,
    match_spans = spans or {},
    size_label = is_folder and "" or format_size(item.size),
    modified_label = modified_time and compact_age(modified_time) or "",
  }
end

function FSView:new(prefix, opts)
  opts = opts or {}
  FSView.super.new(self, nil, true) -- floating widget; widget lib owns RootPanel routing
  file_context.exclude_main_panel_view(self)
  self.type_name = "plugins.fuzzy_searcher"
  self.name = "Fuzzy Searcher"
  self.background_color = style.background
  self.border.width = 0
  self.results = {}
  self.selected = 1
  self.viewport_offset = 1
  self.loaded_limit = nil
  self.has_more = false
  self.current_query_key = nil
  self.force_refresh = false
  self.pending_select_index = nil
  self.status = ""
  self.last_files_generation = -1
  self.dirty = true
  self.scrollable = false
  self.hovered_result = nil
  self.pressed_result = nil
  self.pressed_clicks = 0
  self.forward_mouse_to_child = false
  self.preview_view = nil
  self.preview_key = nil
  self.preview_target_line = nil
  self.preview_highlight_key = nil
  self.preview_blocked = nil
  self.preview_mouse_pressed = false
  self.everything_results = {}
  self.everything_total = 0
  self.everything_has_more = false
  self.everything_loading = false
  self.everything_query_key = nil
  self.everything_status = ""
  self.static_mode = opts.static == true
  self.static_results = opts.results or {}
  self.static_status = opts.status or ""

  local source_view = core.active_view
  local source_doc = source_view and source_view.doc
  self.source_view = file_context.current_main_panel_view(source_view) or source_view
  self.source_doc = source_doc
  self.source_file_path = file_context.view_file_path(source_view)
  self.source_file_line = source_doc and source_doc:get_selection(false) or 1

  self.input = TextBox(self, prefix or "", "")
  local default_input_draw_line_text = self.input.textview.draw_line_text
  function self.input.textview:draw_line_text(line, x, y)
    local text = self.doc.lines[line] or ""
    local mode_prefix, query = split_mode_prefix(text)
    if mode_prefix == "" or self.subparent.password then
      return default_input_draw_line_text(self, line, x, y)
    end

    local font = self:get_font()
    local ty = y + self:get_line_text_y_offset()
    local cx = renderer.draw_text(font, mode_prefix, x, ty, style.dim)
    renderer.draw_text(font, query, cx, ty, style.syntax["normal"] or style.text)
    return self:get_line_height()
  end
  local cursor_col = #(prefix or "") + 1
  -- When prefix is a grep mode quoted-exact query (e.g. #"text"),
  -- place the cursor before the closing quote so the user can extend the query.
  if (prefix or ""):match('^#".*"$') then cursor_col = cursor_col - 1 end
  self.input.textview.doc:set_selection(1, cursor_col, 1, cursor_col)
  self.input.border.color = style.dim
  self.input.activate = function(input)
    TextBox.activate(input)
    input.hover_border = style.dim
    input.border.color = input.hover_border
  end
  file_context.exclude_main_panel_view(self.input)
  file_context.exclude_main_panel_view(self.input.textview)
  self.input.on_change = function(_, text)
    if self.static_mode then return end
    if not self._applying_prompt_history then self._prompt_history_session = nil end
    self.dirty = true
    self:refresh(text)
    self:schedule_update(true)
  end

  if self.static_mode then
    self.input.textview.doc.readonly = true
  end

  if not self.static_mode then ensure_file_index() end
  self:show()
  self:layout()
  ensure_input_focus(self)
  fuzzy_focus_log("open", self, "prefix_len=" .. tostring(#tostring(prefix or "")))
  self:refresh(self.input:get_text())
end

function FSView:layout()
  local root = core.root_panel
  local rw, rh = root.size.x, root.size.y
  local width_ratio = fuzzy_searcher.width or 0.90
  local reduce_at = fuzzy_searcher.side_padding_reduce_width or 1500 * SCALE
  local min_width = fuzzy_searcher.min_width or 1200 * SCALE
  local min_side_padding = fuzzy_searcher.min_side_padding or style.padding.x
  local normal_side_padding = rw * (1 - width_ratio) / 2
  local side_padding = normal_side_padding
  if rw < reduce_at and reduce_at > min_width then
    local reduce_at_padding = reduce_at * (1 - width_ratio) / 2
    local t = common.clamp((rw - min_width) / (reduce_at - min_width), 0, 1)
    side_padding = min_side_padding + (reduce_at_padding - min_side_padding) * t
  end
  side_padding = common.clamp(side_padding, 0, math.max(0, rw / 2 - 1))
  local w = math.max(1, rw - side_padding * 2)
  local h = math.min(rh, math.max(rh * fuzzy_searcher.height, fuzzy_searcher.min_height or 0))
  local x = root.position.x + (rw - w) / 2
  local y = root.position.y + (rh - h) / 2
  self:set_size(w, h)
  self:set_position(x, y)
  local pad = style.padding.x
  self.input:set_position(pad, pad)
  self.input:set_size(self.size.x - pad * 2)
end

function FSView:is_command_mode()
  if self.static_mode then return false end
  local text = self.input and self.input:get_text() or ""
  return text:sub(1, 1) == ">"
end

function FSView:is_project_mode()
  if self.static_mode then return false end
  local text = self.input and self.input:get_text() or ""
  return text:sub(1, 1) == "@"
end

function FSView:is_full_width_mode()
  return self:is_command_mode() or self:is_project_mode()
end

function FSView:list_metrics(font)
  font = font or style.code_font
  local pad = style.padding.x
  local lh = font:get_height()
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  local top = y + self.input.size.y + pad * 3 + lh
  local list_w = self:is_full_width_mode() and w or w * (1 - fuzzy_searcher.preview_width)
  local total_rows = math.max(0, math.floor((h - (top - y)) / lh))
  local result_rows = math.max(1, total_rows - 2) -- first/last rows are scroll indicators
  return {
    x = x, y = y, w = w, h = h, top = top, list_w = list_w,
    lh = lh, total_rows = total_rows, result_rows = result_rows,
    results_top = top + lh,
    bottom_indicator_y = top + math.max(0, total_rows - 1) * lh,
  }
end

function FSView:reset_pagination()
  self.loaded_limit = self:list_metrics().result_rows
  self.selected = 1
  self.viewport_offset = 1
  self.pending_select_index = nil
end

function FSView:max_result_limit()
  local rows = self:list_metrics().result_rows
  return math.max(rows, fuzzy_searcher.max_result_limit or fuzzy_searcher.result_limit or rows)
end

function FSView:result_limit()
  local rows = self:list_metrics().result_rows
  self.loaded_limit = common.clamp(self.loaded_limit or rows, rows, self:max_result_limit())
  return self.loaded_limit
end

function FSView:can_load_more()
  return self.has_more and self:result_limit() < self:max_result_limit()
end

function FSView:load_more(select_next)
  if not self:can_load_more() then return false end
  local current = self:result_limit()
  local rows = self:list_metrics().result_rows
  if select_next then self.pending_select_index = current + 1 end
  self.loaded_limit = common.clamp(current + rows, rows, self:max_result_limit())
  self.loading_more = true
  self.force_refresh = true
  self.dirty = true
  self:refresh(self.input:get_text())
  return true
end

function FSView:ensure_selection_visible()
  if #self.results == 0 then self.selected, self.viewport_offset = 1, 1; return end
  local rows = self:list_metrics().result_rows
  self.viewport_offset = common.clamp(self.viewport_offset or 1, 1, math.max(1, #self.results))
  if self.selected < self.viewport_offset then
    self.viewport_offset = self.selected
  elseif self.selected > self.viewport_offset + rows - 1 then
    self.viewport_offset = self.selected - rows + 1
  end
  self.viewport_offset = common.clamp(self.viewport_offset, 1, math.max(1, #self.results - rows + 1))
end

function FSView:select_delta(delta)
  if #self.results == 0 then self.selected = 1; self.viewport_offset = 1; return end
  if delta > 0 and self.selected >= #self.results and self.has_more then
    if self:load_more(true) then return end
  end
  local i = self.selected
  repeat
    i = common.clamp(i + delta, 1, #self.results)
    if not self.results[i].header then break end
    if i == 1 or i == #self.results then break end
  until false
  self.selected = i
  self:ensure_selection_visible()
end

function FSView:selected_result()
  local r = self.results[self.selected]
  if r and not r.header then return r end
end

function FSView:preview_bounds()
  local pad = style.padding.x
  local m = self:list_metrics(style.code_font)
  local px = m.x + m.list_w + pad
  local py = m.top
  local pw = m.w - m.list_w - pad * 2
  local ph = m.h - (m.top - m.y)
  return px, py, pw, ph
end

function FSView:preview_contains(x, y)
  local px, py, pw, ph = self:preview_bounds()
  return x >= px and x <= px + pw and y >= py and y <= py + ph
end

function FSView:clear_preview_view()
  if self.preview_view and self.preview_view.doc then
    self.preview_view.doc:clear_search_selections()
  end
  self.preview_view = nil
  self.preview_key = nil
  self.preview_target_line = nil
  self.preview_highlight_key = nil
  self.preview_blocked = nil
  self.preview_mouse_pressed = false
end

local function draw_preview_debug(view, result, x, y, w, h)
  if not fuzzy_searcher.preview_debug then return end
  local font = style.code_font
  local lh = font:get_height()
  local lines = {}
  local clip = core.clip_rect_stack and core.clip_rect_stack[#core.clip_rect_stack] or {}

  if view:extends(DocView) then
    local minline, maxline = view:get_visible_line_range()
    local gw = view:get_gutter_width()
    local tx, ty = view:get_line_screen_position(minline)
    local raw = tostring(view.doc.lines[minline] or "")
    local utf8 = tostring(view.doc:get_utf8_line(minline) or "")
    local sample = raw:gsub("\t", "→"):gsub("\n", "⏎")
    local usample = utf8:gsub("\t", "→"):gsub("\n", "⏎")
    local tok = view.doc.highlighter:get_line(minline).tokens
    lines[#lines+1] = "PREVIEW DEBUG: DocView"
    lines[#lines+1] = string.format("rect=(%.0f,%.0f %.0fx%.0f) view=(%.0f,%.0f %.0fx%.0f)", x, y, w, h, view.position.x, view.position.y, view.size.x, view.size.y)
    lines[#lines+1] = string.format("clip=(%.0f,%.0f %.0fx%.0f) scroll=(%.0f,%.0f -> %.0f,%.0f)", clip[1] or -1, clip[2] or -1, clip[3] or -1, clip[4] or -1, view.scroll.x, view.scroll.y, view.scroll.to.x, view.scroll.to.y)
    lines[#lines+1] = string.format("lines=%d visible=%d..%d target=%s gutter=%.0f text_xy=(%.0f,%.0f) binary=%s", #view.doc.lines, minline, maxline, tostring(result and result.line), gw, tx, ty, tostring(view.doc.binary))
    lines[#lines+1] = string.format("raw[%d] len=%d: %s", minline, #raw, sample:sub(1, 90))
    lines[#lines+1] = string.format("utf8[%d] len=%d: %s", minline, #utf8, usample:sub(1, 90))
    lines[#lines+1] = string.format("tokens=%d first=(%s,%s)", #tok, tostring(tok[1]), tostring(tok[2] and tok[2]:sub(1, 40)))
    renderer.draw_rect(tx, ty, math.max(2, font:get_width("TEXT ORIGIN PROBE")), lh, color_with_alpha(style.accent, 90))
    renderer.draw_text(font, "TEXT ORIGIN PROBE", tx, ty, style.text)
  else
    lines[#lines+1] = "PREVIEW DEBUG: " .. tostring(view)
    lines[#lines+1] = string.format("rect=(%.0f,%.0f %.0fx%.0f) view=(%.0f,%.0f %.0fx%.0f)", x, y, w, h, view.position.x, view.position.y, view.size.x, view.size.y)
    lines[#lines+1] = string.format("clip=(%.0f,%.0f %.0fx%.0f)", clip[1] or -1, clip[2] or -1, clip[3] or -1, clip[4] or -1)
  end

  local box_h = math.min(h - 8, (#lines * lh) + 8)
  renderer.draw_rect(x + 4, y + 4, math.max(0, w - 8), box_h, style.fuzzy_searcher_preview_background)
  local yy = y + 8
  for i, line in ipairs(lines) do
    renderer.draw_text(font, truncate_text(font, line, w - 16), x + 8, yy, i == 1 and (style.accent) or style.text)
    yy = yy + lh
    if yy > y + box_h then break end
  end
end

local function draw_preview_placeholder(message, detail, x, y, w, h)
  renderer.draw_rect(x, y, w, h, style.background)
  local font = style.code_font
  local lh = font:get_height()
  local yy = y + style.padding.y
  renderer.draw_text(font, message or "Preview unavailable", x + style.padding.x, yy, style.accent)
  yy = yy + lh * 1.4
  if detail and detail ~= "" then
    draw_highlighted_text(font, detail, x + style.padding.x, yy, w - style.padding.x * 2, style.dim, {})
  end
end

local function call_preview_view_method(view, method, ...)
  if view and view.with_selection_state then
    return view:with_selection_state(method, view, ...)
  end
  return method(view, ...)
end

local function draw_view_in_rect(view, x, y, w, h, result)
  -- Embedded core views may push their own clip rects. Give them a clean local
  -- clip stack rooted at the preview pane; otherwise they can intersect with a
  -- stale parent/deferred-draw clip.
  local saved_stack = core.clip_rect_stack
  local rx, ry, rw, rh = table.unpack(saved_stack[#saved_stack])
  core.clip_rect_stack = {{ x, y, w, h }}
  renderer.set_clip_rect(x, y, w, h)
  call_preview_view_method(view, view.draw)
  draw_preview_debug(view, result, x, y, w, h)
  core.clip_rect_stack = saved_stack
  renderer.set_clip_rect(rx, ry, rw, rh)
end

function FSView:update_preview_view()
  local r = self:selected_result()
  if not r or not r.file then self:clear_preview_view(); return nil end

  local path = fullpath(r.file)
  local key = path
  local view
  if ImageView.is_supported(path) then
    key = "image:" .. path
  else
    local blocked, reason = detect_binary_preview(path)
    if blocked then
      key = "blocked:" .. path .. ":" .. tostring(reason)
      if self.preview_key ~= key then
        self:clear_preview_view()
        self.preview_key = key
        self.preview_blocked = { reason = reason or "Unsupported binary file", path = path }
      end
      return nil
    end
    key = "doc:" .. path
  end

  if self.preview_key ~= key then
    self:clear_preview_view()
    if key:sub(1, 6) == "image:" then
      view = ImageView(path, "fit")
    else
      local ok, doc = pcall(Doc)
      if ok and doc then
        doc.disable_language_services = true
        doc.disable_treesitter = true
        local filename = core.normalize_to_project_dir(path)
        ok = pcall(function()
          doc:set_filename(filename, path)
          doc:load(path)
        end)
      end
      if not ok or not doc then
        self.preview_blocked = { reason = "Cannot open file", path = path }
        return nil
      end
      view = PreviewDocView(doc)
    end
    self.preview_view = view
    self.preview_key = key
  end

  view = self.preview_view
  local px, py, pw, ph = self:preview_bounds()
  view.position.x, view.position.y = px, py
  view.size.x, view.size.y = math.max(0, pw), math.max(0, ph)

  local target = r.line or 1
  if view.doc then
    target = common.clamp(target, 1, #view.doc.lines)
    local highlight_key = table.concat({
      r.kind or "", r.grep_query or "", r.fuzzy_query or "", tostring(target),
      tostring(r.col or ""), tostring(r.line2 or ""), tostring(r.col2 or ""), r.text or "",
    }, "\0")
    if self.preview_target_line ~= target or self.preview_highlight_key ~= highlight_key then
      local reveal_col1, reveal_col2
      view:with_selection_state(function()
        view.doc:clear_search_selections()
        local selections = {}
        if r.kind == "grep" then
          for _, span in ipairs(grep_content_spans(view.doc.lines[target] or "", r, 0, target) or {}) do
            local col1, col2 = span[1], span[2] + 1
            view.doc:add_search_selection(target, col1, target, col2)
            if not reveal_col1 then reveal_col1, reveal_col2 = col1, col2 end
            table.insert(selections, target)
            table.insert(selections, col1)
            table.insert(selections, target)
            table.insert(selections, col2)
          end
        elseif r.kind == "symbol" and r.col then
          local line1 = common.clamp(tonumber(r.line) or target, 1, #view.doc.lines)
          local line2 = common.clamp(tonumber(r.line2) or line1, 1, #view.doc.lines)
          local col1 = math.max(1, tonumber(r.col) or 1)
          local col2 = math.max(col1 + 1, tonumber(r.col2) or (col1 + #(r.name or r.label or "")))
          view.doc:add_search_selection(line1, col1, line2, col2)
          reveal_col1, reveal_col2 = col1, col2
          table.insert(selections, line1)
          table.insert(selections, col1)
          table.insert(selections, line2)
          table.insert(selections, col2)
        end
        if #selections > 0 then
          view.doc:set_selection(selections[1], selections[2], selections[3], selections[4])
          for i = 5, #selections, 4 do
            view.doc:set_selections(
              math.floor((i - 1) / 4) + 1,
              selections[i], selections[i + 1], selections[i + 2], selections[i + 3],
              nil, 0
            )
          end
          view.doc.last_selection = 1
        else
          view.doc:set_selection(target, 1, target, 1)
        end
      end)
      view:scroll_to_line(target, false, true)
      if reveal_col1 then
        view:scroll_to_make_visible(target, reveal_col1, true, {
          line2 = target,
          col2 = reveal_col2,
          vertical = false,
        })
      end
      self.preview_target_line = target
      self.preview_highlight_key = highlight_key
    end
  end

  call_preview_view_method(view, view.update)
  return view
end

-- Treat the floating overlay as a modal surface for mouse routing: while it is
-- open, editor hover/click/wheel events behind it should not leak through.
function FSView:mouse_on_top(x, y)
  return self:is_visible()
end

function FSView:panel_contains(x, y)
  if not self:is_visible() then return false end
  local px = self.position.x - self.border.width
  local py = self.position.y - self.border.width
  return x >= px and x <= px + self:get_width() and y >= py and y <= py + self:get_height()
end

function FSView:result_at_point(x, y)
  if not self:panel_contains(x, y) then return nil end
  local m = self:list_metrics(style.code_font)
  if x < m.x or x > m.x + m.list_w - style.divider_size then return nil end

  if y >= m.results_top and y < m.results_top + m.result_rows * m.lh then
    local idx = self.viewport_offset + math.floor((y - m.results_top) / m.lh)
    if idx >= 1 and idx <= #self.results then return idx end
  end
  if y >= m.top and y < m.top + m.lh and self.viewport_offset > 1 then
    return "scroll-up"
  end
  if y >= m.bottom_indicator_y and y < m.bottom_indicator_y + m.lh
    and (self.viewport_offset + m.result_rows - 1 < #self.results or self:can_load_more())
  then
    return "scroll-down"
  end
  return nil
end

function FSView:on_mouse_pressed(button, x, y, clicks)
  self.mouse.x, self.mouse.y = x, y
  self.pressed_result = nil
  self.pressed_clicks = clicks or 1
  self.forward_mouse_to_child = false

  fuzzy_focus_log("mouse-pressed", self, string.format("button=%s clicks=%s input_hit=%s preview_hit=%s", tostring(button), tostring(clicks), tostring(self.input and self.input:mouse_on_top(x, y)), tostring(self:preview_contains(x, y))))

  if not self:panel_contains(x, y) then
    self:close()
    return true
  end

  if self.input and self.input:mouse_on_top(x, y) then
    self.forward_mouse_to_child = true
    return FSView.super.on_mouse_pressed(self, button, x, y, clicks)
  end

  if self:preview_contains(x, y) then
    if not self.preview_view then self:update_preview_view() end
    if not self.preview_view then return true end
    local interactive = self.preview_view:extends(ImageView) or self.preview_view:scrollbar_overlaps_point(x, y)
    if interactive then
      self.preview_mouse_pressed = true
      call_preview_view_method(self.preview_view, self.preview_view.on_mouse_pressed, button, x, y, clicks)
    end
    self:swap_active_child(self.input)
    self:schedule_update(true)
    return true
  end

  local hit = self:result_at_point(x, y)
  if hit == "scroll-up" then
    for _ = 1, self:list_metrics().result_rows do self:select_delta(-1) end
    self:schedule_update(true)
  elseif hit == "scroll-down" then
    for _ = 1, self:list_metrics().result_rows do self:select_delta(1) end
    self:schedule_update(true)
  elseif type(hit) == "number" and self.results[hit] and not self.results[hit].header then
    self.selected = hit
    self.pressed_result = hit
    self:ensure_selection_visible()
    self:schedule_update(true)
  end

  self:swap_active_child(self.input)
  return true
end

function FSView:on_mouse_released(button, x, y)
  self.mouse.x, self.mouse.y = x, y

  if self.forward_mouse_to_child then
    self.forward_mouse_to_child = false
    FSView.super.on_mouse_released(self, button, x, y)
    self:swap_active_child(self.input)
    return true
  end

  if self.preview_mouse_pressed then
    self.preview_mouse_pressed = false
    if self.preview_view then
      call_preview_view_method(self.preview_view, self.preview_view.on_mouse_released, button, x, y)
    end
    self:swap_active_child(self.input)
    self:schedule_update(true)
    return true
  end

  local hit = self:result_at_point(x, y)
  if button == "left" and type(hit) == "number" and hit == self.pressed_result then
    self.selected = hit
    self:ensure_selection_visible()
    if (self.pressed_clicks or 1) >= 2 then self:confirm() end
  end

  self.pressed_result = nil
  self.pressed_clicks = 0
  if self:is_visible() then self:swap_active_child(self.input) end
  return true
end

function FSView:on_mouse_moved(x, y, dx, dy)
  self.mouse.x, self.mouse.y = x, y

  if self.forward_mouse_to_child or (self.input and self.input.mouse_is_pressed) or (self.input and self.input:mouse_on_top(x, y)) then
    local handled = FSView.super.on_mouse_moved(self, x, y, dx, dy)
    self.hovered_result = nil
    return handled or true
  end

  if self.preview_view and (self.preview_mouse_pressed or self:preview_contains(x, y)) then
    call_preview_view_method(self.preview_view, self.preview_view.on_mouse_moved, x, y, dx, dy)
    if self.preview_view.cursor then system.set_cursor(self.preview_view.cursor) end
    self.hovered_result = nil
    self:schedule_update(true)
    return true
  end

  local hit = self:result_at_point(x, y)
  local hovered = type(hit) == "number" and self.results[hit] and not self.results[hit].header and hit or nil
  if hovered ~= self.hovered_result then
    self.hovered_result = hovered
    self:schedule_update(true)
  end
  return true
end

function FSView:on_mouse_wheel(y, x)
  if scale_mouse_wheel_modkeys_pressed() then return false end

  if self.preview_view and self:preview_contains(self.mouse.x, self.mouse.y) then
    if not call_preview_view_method(self.preview_view, self.preview_view.on_mouse_wheel, y, x) and self.preview_view.scrollable then
      self.preview_view.scroll.to.y = self.preview_view.scroll.to.y + y * -config.mouse_wheel_scroll
    end
    call_preview_view_method(self.preview_view, self.preview_view.update)
    self:schedule_update(true)
  elseif self:panel_contains(self.mouse.x, self.mouse.y) then
    self:select_delta(y < 0 and 1 or -1)
    self:schedule_update(true)
  end
  return true
end

function FSView:start_file_search(query, line, reset_selection)
  kill_file_search()
  local gen = file_search_generation
  local keep_limit = self:max_result_limit() + 1
  local root = project_dir()
  local skip_path = self.source_file_path

  self.results = {}
  self.has_more = false
  self.hovered_result = nil
  if reset_selection then
    self.selected = 1
    self.viewport_offset = 1
  end
  self.status = files_indexing
    and string.format("Indexing files… %d found — %s", #(files_cache or {}), display_root(root))
    or string.format("Searching %d files…", #(files_cache or {}))
  self:schedule_update(true)

  local function apply_results(out, has_more)
    self.results = out
    self.has_more = has_more
    if self.pending_select_index then
      self.selected = common.clamp(self.pending_select_index, 1, math.max(1, #out))
      self.pending_select_index = nil
    else
      self.selected = common.clamp(self.selected, 1, math.max(1, #out))
    end
    if self.results[self.selected] and self.results[self.selected].header then
      self:select_delta(1)
      if self.results[self.selected] and self.results[self.selected].header then self:select_delta(-1) end
    end
    self:ensure_selection_visible()
  end

  core.add_thread(function()
    local recent_matches, skip_keys = collect_recent_file_matches(query, line, skip_path)

    if not line and native_file_index_ready() then
      local ok, native_results = pcall(function()
        return files_fuzzy_index:search(query, { limit = keep_limit + #recent_matches + 32, spans = true })
      end)
      if ok and native_results and gen == file_search_generation and active_view == self then
        local general_matches = {}
        for _, match in ipairs(native_results) do
          local key = file_result_key(match.text)
          if key and not skip_keys[key] then
            general_matches[#general_matches+1] = {
              item = match.text, text = match.text, score = match.score or 0,
              spans = match.spans or {}
            }
            if #general_matches >= keep_limit then break end
          end
        end
        local out, hidden = build_sectioned_file_results(recent_matches, general_matches, self:result_limit(), query, line)
        apply_results(out, hidden or native_results.has_more)
        self.status = string.format("%d recent + %d file matches shown%s — %d files indexed — %s",
          #recent_matches, #general_matches, self.has_more and "+" or "", #(files_cache or {}), display_root(root))
        self:schedule_update(true)
        return
      end
    end

    local items = get_files()
    local general_matches = {}
    local matched_general = 0
    local scanned = 0
    local empty_query = trim_query(query) == ""
    local slice_start = system.get_time()
    local last_publish = system.get_time()

    local function publish(final)
      if gen ~= file_search_generation or active_view ~= self then return false end
      local out, hidden = build_sectioned_file_results(recent_matches, general_matches, self:result_limit(), query, line)
      apply_results(out, hidden or matched_general > #general_matches)
      if final then
        local total_matches = #recent_matches + matched_general
        self.status = files_indexing
          and string.format("%d file matches — still indexing %d files — %s", total_matches, #(files_cache or {}), display_root(root))
          or string.format("%d file matches — %d files indexed — %s", total_matches, #items, display_root(root))
      else
        self.status = string.format("%d file matches — scanning %d/%d…", #recent_matches + matched_general, scanned, #items)
      end
      self:schedule_update(true)
      last_publish = system.get_time()
      return true
    end

    for _, item in ipairs(items) do
      if gen ~= file_search_generation or active_view ~= self then return end
      scanned = scanned + 1
      local key = file_result_key(item)
      if key and not skip_keys[key] then
        local score, spans
        if empty_query then
          score, spans = 0, {}
        else
          score, spans = fuzzy_match_file_fast(query, item)
        end
        if score and line_exists(item, line) then
          matched_general = matched_general + 1
          local candidate = { item = item, text = item, score = score, spans = spans or {} }
          if empty_query then
            if #general_matches < keep_limit then general_matches[#general_matches+1] = candidate end
          else
            fuzzy_insert_top(general_matches, candidate, keep_limit)
          end
        end
      end
      if (#recent_matches > 0 or #general_matches > 0) and system.get_time() - last_publish > 0.05 then publish(false) end
      slice_start = yield_if_over_budget(slice_start)
    end

    publish(true)
  end)
end

function FSView:start_everything_project_search(query, offset, append)
  query = trim_query(query)
  if query == "" then
    self.everything_results = {}
    self.everything_total = 0
    self.everything_has_more = false
    self.everything_loading = false
    self.everything_status = ""
    return
  end
  if everything.state ~= "available" then
    core.log_quiet("Fuzzy Everything: search deferred; state=%s query=%q", tostring(everything.state), query)
    probe_everything(self)
    return
  end

  everything.search_generation = everything.search_generation + 1
  local gen = everything.search_generation
  local count = fuzzy_searcher.everything_page_size or 80
  offset = offset or 0
  self.everything_loading = true
  self.everything_status = offset > 0 and "Loading more Everything results…" or "Searching Everything…"
  local params = everything_project_search_params(query, count, offset)
  core.log_quiet("Fuzzy Everything: searching query=%q everything_search=%q offset=%d count=%d append=%s", query, params.search, offset, count, tostring(append))
  self:schedule_update(true)

  http.get(everything_endpoint(), params, {
    timeout = 2,
    on_done = function(ok, _err, data)
      if gen ~= everything.search_generation or active_view ~= self then return end
      self.everything_loading = false
      self.loading_more = false
      if not ok or type(data) ~= "table" then
        core.log_quiet("Fuzzy Everything: search failed query=%q err=%s data_type=%s", query, tostring(_err), type(data))
        everything.state = "unavailable"
        self.everything_results = {}
        self.everything_total = 0
        self.everything_has_more = false
        self.everything_status = ""
        self.dirty = true
        self:schedule_update(true)
        return
      end
      local total = tonumber(data.totalResults) or 0
      local out = append and self.everything_results or {}
      for _, item in ipairs(data.results or {}) do
        local r = everything_result_from_item(item, query)
        if r then out[#out+1] = r end
      end
      sort_everything_project_results(out)
      self.everything_results = out
      self.everything_total = total
      self.everything_has_more = #out < total
      self.everything_status = string.format("%d Everything folders%s", #out, self.everything_has_more and "+" or "")
      core.log_quiet("Fuzzy Everything: search ok query=%q shown=%d total=%d has_more=%s", query, #out, total, tostring(self.everything_has_more))
      self.dirty = true
      self:schedule_update(true)
    end
  })
end

function FSView:refresh_normal(base, line, reset_selection, force_refresh)
  local limit = self:result_limit()
  local mode = base:sub(1, 1)
  if base:sub(1, 2) == "$$" then
    mode = "$$"
    base = base:sub(3):gsub("^%s+", "")
  elseif mode == ">" or mode == "@" or mode == "$" then
    base = base:sub(2):gsub("^%s+", "")
  end

  local out = {}
  self.has_more = false

  local function add_file_results(query, max_items)
    if max_items <= 0 then self.has_more = true; return end

    if trim_query(query) == "" and not line then
      local recent_matches, skip_keys = collect_recent_file_matches(query, line, self.source_file_path)
      local general_matches = {}
      for _, item in ipairs(get_files()) do
        local key = file_result_key(item)
        if key and not skip_keys[key] then
          general_matches[#general_matches+1] = { item = item, text = item, score = 0, spans = {} }
          if #general_matches > max_items then break end
        end
      end
      local rows, hidden = build_sectioned_file_results(recent_matches, general_matches, max_items, query, line)
      out = rows
      self.has_more = hidden or #general_matches > max_items
      return
    end

    self:start_file_search(query, line, reset_selection)
    return "async"
  end

  local function add_command_results(query, max_items)
    if max_items <= 0 then self.has_more = true; return end

    if trim_query(query) == "" then
      local added_recent = 0
      for _, name in ipairs(recent_commands) do
        if command.map[name] then
          if added_recent >= max_items then self.has_more = true; return end
          out[#out+1] = { kind = "command", label = name, command = name, query = query, match_spans = {}, recent = true, info = command_preview_info(name), status = command_status_parts(name) }
          added_recent = added_recent + 1
        end
      end
      return
    end

    local matches = fuzzy_filter(get_commands(), query, max_items + 1)
    for i, match in ipairs(matches) do
      if i > max_items then self.has_more = true; break end
      local name = match.item
      out[#out+1] = { kind = "command", label = name, command = name, query = query, match_spans = match.spans, info = command_preview_info(name), status = command_status_parts(name) }
    end
  end

  local function add_project_results(query, max_items)
    if max_items <= 0 then self.has_more = true; return end
    ensure_recent_project_times()
    local projects = get_recent_projects()

    if trim_query(query) == "" then
      for i, path in ipairs(projects) do
        if i > max_items then self.has_more = true; break end
        out[#out+1] = { kind = "project", label = path, project = path, query = query, match_spans = {}, recent = true, opened_at = recent_project_times[path] }
      end
      return
    end

    local matches = fuzzy_filter(projects, query, max_items + 1, display_root)
    for i, match in ipairs(matches) do
      if i > max_items then self.has_more = true; break end
      local path = match.item
      out[#out+1] = { kind = "project", label = path, project = path, query = query, match_spans = match.spans, recent = true, opened_at = recent_project_times[path] }
    end

    if #out == 0 then
      local path = existing_absolute_dir(query)
      if path then
        out[#out+1] = { kind = "new_project", label = path, project = path, query = query }
      end
    end
  end

  local async
  if mode == ">" then
    kill_file_search()
    add_command_results(base, limit)
  elseif mode == "$" then
    kill_file_search()
    self:start_symbol_search(base, reset_selection)
    return
  elseif mode == "$$" then
    kill_file_search()
    self:start_current_document_symbol_search(base, reset_selection)
    return
  elseif mode == "@" then
    kill_file_search()
    local project_limit = limit
    local project_query = base
    if trim_query(project_query) ~= "" then
      project_limit = math.max(1, math.floor(limit * 0.35))
      if everything.state == "unknown" then probe_everything(self) end
      if everything.state == "available" then
        if self.everything_query_key ~= project_query then
          self.everything_query_key = project_query
          self:start_everything_project_search(project_query, 0, false)
        elseif force_refresh and self.loading_more and self.everything_has_more and not self.everything_loading then
          self:start_everything_project_search(project_query, #(self.everything_results or {}), true)
        end
      end
    else
      self.everything_results = {}
      self.everything_total = 0
      self.everything_has_more = false
      self.everything_status = ""
      self.everything_query_key = nil
    end
    add_project_results(project_query, project_limit)
    if trim_query(project_query) ~= "" and everything.state == "available" then
      out[#out+1] = { header = true, label = self.everything_loading and "Everything — searching…" or "Everything" }
      local remaining = math.max(0, limit - #out)
      for i = 1, math.min(remaining, #(self.everything_results or {})) do
        out[#out+1] = self.everything_results[i]
      end
      self.has_more = self.has_more or self.everything_has_more
    end
  else
    async = add_file_results(base, limit)
    if async then return end
    kill_file_search()
  end

  if mode == "@" then
    local extra = self.everything_status and self.everything_status ~= "" and (" — " .. self.everything_status) or ""
    self.status = string.format("%d recent projects%s", #get_recent_projects(), extra)
  elseif files_indexing then
    self.status = string.format("Indexing files… %d found — %s", #(files_cache or {}), display_root(project_dir()))
  else
    self.status = string.format("%d files indexed — %s", #(files_cache or {}), display_root(project_dir()))
  end

  self.results = out
  self.hovered_result = nil
  if reset_selection then
    self.selected = 1
    self.viewport_offset = 1
  elseif self.pending_select_index then
    self.selected = common.clamp(self.pending_select_index, 1, math.max(1, #out))
    self.pending_select_index = nil
  else
    self.selected = common.clamp(self.selected, 1, math.max(1, #out))
  end
  if self.results[self.selected] and self.results[self.selected].header then self:select_delta(1) end
  self:ensure_selection_visible()
end

function FSView:start_grep_fuzzy_stream(base, line, grep, terms, scope, root, gen, preserve_results)
  -- Grep results are streamed asynchronously. Do not page them by clearing and
  -- restarting the search while the user scrolls; publish a growing stable
  -- prefix and let selection stop naturally at the currently available end.
  local limit = self:max_result_limit()
  local tokens = terms_to_legacy_tokens(terms)
  local job, preferred_job = ensure_fuzzy_grep_job(root, scope, tokens)
  if not job then return end
  local jobs = { job }
  if preferred_job and preferred_job ~= job then jobs[#jobs+1] = preferred_job end
  local exact_results = #terms == 1 and not terms[1].exact and trim_query(grep):lower() == terms[1].text
  local fuzzy_query = terms_fuzzy_query(terms)
  local initial_settle_seconds = 0.10
  local initial_settle_visible_multiplier = 2
  local same_file_group_scan = 8
  local same_file_group_score_slack = 500
  local same_file_group_max_burst = 3

  local function grep_result_file_key(r)
    local file = tostring(r and r.file or "")
    if file == "" then return "" end
    return common.path_compare_key(file)
  end

  local function grep_result_key(r)
    local file_key = grep_result_file_key(r)
    if file_key == "" then return nil end
    return file_key .. "\0" .. tostring(r.line or "")
  end

  local function grep_result_better(a, b)
    local as, bs = a.fuzzy_score or 0, b.fuzzy_score or 0
    if as ~= bs then return as > bs end

    local af, bf = grep_result_file_key(a), grep_result_file_key(b)
    if af ~= bf then return af < bf end

    local al, bl = tonumber(a.line) or 0, tonumber(b.line) or 0
    if al ~= bl then return al < bl end

    local ac, bc = tonumber(a.col) or 0, tonumber(b.col) or 0
    if ac ~= bc then return ac < bc end

    return tostring(a.text or "") < tostring(b.text or "")
  end

  local function regroup_nearby_same_file_grep_results(sorted)
    local out, used = {}, {}
    for i, anchor in ipairs(sorted) do
      if not used[i] then
        out[#out+1] = anchor
        used[i] = true

        local anchor_file = grep_result_file_key(anchor)
        local anchor_score = anchor.fuzzy_score or 0
        local pulled = 1
        if anchor_file ~= "" then
          local last = math.min(#sorted, i + same_file_group_scan)
          for j = i + 1, last do
            local candidate = sorted[j]
            if not used[j]
              and grep_result_file_key(candidate) == anchor_file
              and anchor_score - (candidate.fuzzy_score or 0) <= same_file_group_score_slack then
              out[#out+1] = candidate
              used[j] = true
              pulled = pulled + 1
              if pulled >= same_file_group_max_burst then break end
            end
          end
        end
      end
    end
    return out
  end

  local function jobs_label()
    if #jobs == 1 then return jobs[1].seed end
    local names = {}
    for _, s in ipairs(jobs) do names[#names+1] = s.seed end
    return table.concat(names, "/")
  end

  if not preserve_results then
    self.results = {}
    self.selected = 1
    self.viewport_offset = 1
    self.hovered_result = nil
  end
  self.has_more = true
  self.status = exact_results and string.format("Searching '%s'…", jobs_label())
    or string.format("Expanding fuzzy text search from '%s'…", jobs_label())
  self:schedule_update(true)

  core.add_thread(function()
    local base_query = base:sub(1, 1) == ">" and "" or base
    local candidates, candidate_seen = {}, {}
    local processed = {}
    for _, s in ipairs(jobs) do processed[s.key] = 0 end
    local max_candidates = fuzzy_searcher.fuzzy_candidate_limit or 500
    local slice_start = system.get_time()
    local stream_started = system.get_time()
    local last_publish = 0
    local published_candidate_count = 0
    local first_publish_done = false
    local initial_candidate_target = math.max(
      20,
      self:list_metrics().result_rows * initial_settle_visible_multiplier
    )
    local committed_results, committed_keys = {}, {}

    local function commit_visible_prefix()
      local existing = self.results or {}
      if #existing == 0 then return end
      local metrics = self:list_metrics()
      local visible_bottom = math.min(
        #existing,
        math.max(0, (self.viewport_offset or 1) + metrics.result_rows - 1)
      )
      for i = 1, visible_bottom do
        local r = existing[i]
        local key = grep_result_key(r)
        if key and not committed_keys[key] then
          committed_keys[key] = true
          committed_results[#committed_results+1] = r
        end
      end
    end

    local function initial_publish_ready(final)
      if final or first_publish_done then return true end
      if #candidates >= initial_candidate_target then return true end
      return #candidates > 0 and system.get_time() - stream_started >= initial_settle_seconds
    end

    local function add_candidate(source)
      if line and not line_exists(source.file, line) then return end
      local key = source.file .. ":" .. tostring(source.line)
      if candidate_seen[key] then return end

      local low = (source.text or ""):lower()
      local spans = exact_term_spans(low, terms)
      if not spans then return end
      for _, term in ipairs(terms) do
        if not term.exact and not low:find(term.text, 1, true) then return end
      end

      local score, fuzzy_spans, fuzzy_selection_span, fuzzy_match_start = 0, {}, nil, nil
      if fuzzy_query ~= "" then
        score, fuzzy_spans, fuzzy_selection_span, fuzzy_match_start = fuzzy_match(fuzzy_query, source.text)
        if not score then return end
      end
      for _, span in ipairs(fuzzy_spans or {}) do spans[#spans+1] = span end
      score = score + (#spans * 4)
      local content_selection_span, content_match_start = single_span_or_leftmost(spans)
      if fuzzy_query ~= "" and fuzzy_selection_span and #(spans or {}) == 1 then
        content_selection_span = fuzzy_selection_span
      end
      content_match_start = content_match_start or fuzzy_match_start

      local r = {
        kind = "grep",
        file = source.file,
        line = source.line,
        col = source.col,
        text = source.text,
        exact = exact_results,
        grep_query = grep,
        fuzzy_query = fuzzy_query,
        fuzzy_score = score,
        content_spans = spans or {},
        content_selection_span = content_selection_span,
        content_match_start = content_match_start,
        base_query = base_query,
      }
      if base_query ~= "" then
        local _, file_spans = fuzzy_match(base_query, r.file)
        r.file_spans = file_spans or {}
      end

      candidate_seen[key] = true
      candidates[#candidates+1] = r
    end

    local function job_stats()
      local running, truncated, scanned = false, false, 0
      for _, s in ipairs(jobs) do
        running = running or not s.done
        truncated = truncated or s.truncated
        scanned = scanned + (s.scanned or 0)
      end
      return running, truncated, scanned
    end

    local function publish(final)
      if gen ~= grep_generation or active_view ~= self then return false end
      if not initial_publish_ready(final) then return true end
      if first_publish_done then commit_visible_prefix() end

      local running, truncated, scanned = job_stats()
      local tail = {}
      for _, candidate in ipairs(candidates) do
        local key = grep_result_key(candidate)
        if key and not committed_keys[key] then tail[#tail+1] = candidate end
      end
      table.sort(tail, grep_result_better)
      tail = regroup_nearby_same_file_grep_results(tail)

      local out, emitted = {}, {}
      for _, r in ipairs(committed_results) do
        local key = grep_result_key(r)
        if key and not emitted[key] then
          out[#out+1] = r
          emitted[key] = true
          if #out >= limit then break end
        end
      end
      if #out < limit then
        for _, r in ipairs(tail) do
          local key = grep_result_key(r)
          if key and not emitted[key] then
            out[#out+1] = r
            emitted[key] = true
            if #out >= limit then break end
          end
        end
      end

      self.results = out
      self.has_more = #candidates > limit or running or truncated
      if self.pending_select_index then
        self.selected = common.clamp(self.pending_select_index, 1, math.max(1, #out))
        self.pending_select_index = nil
      else
        self.selected = common.clamp(self.selected, 1, math.max(1, #out))
      end
      self.viewport_offset = common.clamp(self.viewport_offset, 1, math.max(1, #out))
      self:ensure_selection_visible()

      local fuzzy_count = #candidates
      if exact_results then
        if final then
          self.status = truncated
            and string.format("%d exact matches — limited scan from '%s'", fuzzy_count, jobs_label())
            or string.format("%d exact matches", fuzzy_count)
        else
          self.status = string.format("%d exact matches — scanning '%s'… %d lines", fuzzy_count, jobs_label(), scanned)
        end
      elseif final then
        self.status = truncated
          and string.format("%d fuzzy matches — limited scan from '%s'", fuzzy_count, jobs_label())
          or string.format("%d fuzzy matches", fuzzy_count)
      else
        self.status = string.format("%d fuzzy matches — scanning '%s'… %d lines", fuzzy_count, jobs_label(), scanned)
      end
      self:schedule_update(true)
      last_publish = system.get_time()
      published_candidate_count = #candidates
      first_publish_done = true
      commit_visible_prefix()
      return true
    end

    while gen == grep_generation and active_view == self do
      local all_done = true
      for _, s in ipairs(jobs) do
        while (processed[s.key] or 0) < #s.lines and #candidates < max_candidates do
          processed[s.key] = (processed[s.key] or 0) + 1
          add_candidate(s.lines[processed[s.key]])
          if #candidates ~= published_candidate_count
            and #candidates > 0
            and system.get_time() - last_publish > 0.04
            and initial_publish_ready(false) then
            publish(false)
          end
          slice_start = yield_if_over_budget(slice_start)
        end
        if not s.done or (processed[s.key] or 0) < #s.lines then all_done = false end
      end

      if #candidates ~= published_candidate_count
        and #candidates > 0
        and system.get_time() - last_publish > 0.08
        and initial_publish_ready(false) then
        publish(false)
      end
      if (#candidates >= max_candidates) or all_done then break end
      coroutine.yield(1 / config.fps)
      slice_start = system.get_time()
    end

    if gen ~= grep_generation or active_view ~= self then return end
    publish(true)
  end)
end

function FSView:start_grep(base, line, grep)
  grep_generation = grep_generation + 1
  local gen = grep_generation
  kill_file_search()
  kill_grep()

  local preserve_results = self.loading_more
  self.loading_more = false
  self.loaded_limit = self:max_result_limit()
  if not preserve_results then
    self.results = {}
    self.selected = 1
    self.viewport_offset = 1
    self.hovered_result = nil
  end
  self.has_more = false
  self.status = grep == "" and "Type text after # to search inside files" or "Searching exact text matches…"
  if grep == "" then return end

  local limit = self:max_result_limit()
  local root = project_dir()
  local scope = nil
  if base ~= "" or line then
    scope = build_scope(base, line, 200)
    if #scope == 0 then self.status = "No files in scope"; return end
  end

  local exact_query = quoted_exact_query(grep)
  if exact_query and exact_query ~= "" then grep = exact_query end

  local terms = parse_code_search_terms(grep)
  local single_token_exact = #terms == 1 and not terms[1].exact and trim_query(grep):lower() == terms[1].text
  if not exact_query and (#terms > 1 or single_token_exact) then
    self:start_grep_fuzzy_stream(base, line, grep, terms, scope, root, gen, preserve_results)
    return
  end

  if preserve_results then
    self.results = {}
    self.selected = 1
    self.viewport_offset = 1
    self.hovered_result = nil
  end

  core.add_thread(function()
    local function add_result(r, seen, exact)
      if gen ~= grep_generation or active_view ~= self then return false end
      if line and not line_exists(r.file, line) then return true end
      local key = r.file .. ":" .. r.line .. ":" .. r.col
      if seen[key] then return true end
      if #self.results >= limit then
        self.has_more = true
        self:schedule_update(true)
        return false
      end
      seen[key] = true
      r.exact = exact
      r.grep_query = grep
      if exact and r.col and grep and grep ~= "" then
        r.content_selection_span = { r.col, r.col + #grep - 1 }
        r.content_match_start = r.col
      end
      r.base_query = base:sub(1, 1) == ">" and "" or base
      if r.base_query ~= "" and not r.file_spans then
        local _, file_spans = fuzzy_match(r.base_query, r.file)
        r.file_spans = file_spans or {}
      end
      self.results[#self.results+1] = r
      if #self.results == 1 then self.selected = 1; self.viewport_offset = 1 end
      if self.pending_select_index and #self.results >= self.pending_select_index then
        self.selected = self.pending_select_index
        self.pending_select_index = nil
      end
      self:ensure_selection_visible()
      self:schedule_update(true)
      return true
    end

    local seen = {}
    local args = { fuzzy_searcher.rg, "--vimgrep", "--color", "never", "-i", "-F", "--hidden", "--glob", "!.git/**", "-e", grep }
    if scope then args[#args+1] = "--"; for _, f in ipairs(scope) do args[#args+1] = f end end
    local proc = process.start(args, { cwd = root, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_DISCARD, stdin = process.REDIRECT_DISCARD })
    grep_proc = proc

    if proc then
      while gen == grep_generation and active_view == self do
        local l = proc.stdout:read("line", { scan = 1 / config.fps })
        if l then
          local r = parse_vimgrep(l)
          if r and not add_result(r, seen, true) then break end
        elseif not proc:running() then break else coroutine.yield(1 / config.fps) end
      end
      if proc:running() then pcall(function() proc:kill() end) end
      proc:wait(process.WAIT_DEADLINE)
      if grep_proc == proc then grep_proc = nil end
    end

    if gen ~= grep_generation or active_view ~= self then return end
    self.status = string.format("%d exact matches", #self.results)
    self:schedule_update(true)
  end)
end

local SYMBOL_KIND_LABELS = {
  file = "file",
  module = "module",
  namespace = "namespace",
  package = "package",
  class = "class",
  method = "method",
  property = "property",
  field = "field",
  constructor = "ctor",
  enum = "enum",
  interface = "interface",
  ["function"] = "function",
  variable = "variable",
  constant = "constant",
  struct = "struct",
  enum_member = "member",
  type_parameter = "type param",
}

local function symbol_display_file(path)
  path = common.normalize_path(path or "")
  local root = project_dir()
  if path ~= "" and common.path_belongs_to(path, root) then
    return common.relative_path(root, path):gsub("\\", "/")
  end
  return path
end

local function symbol_result_from_item(item, query, opts)
  opts = opts or {}
  local path = item.path or item.file
  local file = symbol_display_file(path)
  local label = item.name or item.label or ""
  local line = item.line or (item.name_range and item.name_range.start and item.name_range.start.line) or item.start_line or 1
  local col = item.col or (item.name_range and item.name_range.start and item.name_range.start.col) or item.start_col or 1
  local line2 = item.line2 or (item.name_range and item.name_range["end"] and item.name_range["end"].line) or item.end_line
  local col2 = item.col2 or (item.name_range and item.name_range["end"] and item.name_range["end"].col) or item.end_col
  local _, name_spans = fuzzy_match(query, label)
  local _, file_spans = fuzzy_match(query, file)
  return {
    kind = "symbol",
    label = label,
    name = label,
    symbol_kind = item.kind,
    symbol_kind_label = SYMBOL_KIND_LABELS[item.kind] or item.kind or "symbol",
    detail = item.detail,
    signature = item.signature,
    declaration = item.declaration,
    declaration_name_span = item.declaration_name_span,
    file = file,
    path = path,
    doc = opts.doc,
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    query = query,
    match_spans = name_spans or {},
    file_spans = file_spans or {},
    symbol_scope = opts.scope,
  }
end

local function set_symbol_results(view, query, results, source_label, status, reason, limit, opts)
  opts = opts or {}
  local out = {}
  for i, item in ipairs(results or {}) do
    if i > limit then view.has_more = true; break end
    out[#out + 1] = symbol_result_from_item(item, query, opts)
  end
  view.results = out
  view.selected = common.clamp(view.selected or 1, 1, math.max(1, #out))
  view:ensure_selection_visible()
  if status == "fresh" or status == "stale" then
    local count = #(results or {})
    local suffix = source_label and source_label ~= "" and (" — " .. source_label) or ""
    view.status = string.format("%d symbol%s%s", count, count == 1 and "" or "s", suffix)
  elseif reason then
    view.status = tostring(reason)
  end
  view:schedule_update(true)
end

local function lsp_enabled()
  local ok, manager = pcall(require, "core.lsp.manager")
  return ok and manager and manager.is_enabled and manager.is_enabled() ~= false
end

function FSView:start_symbol_search(query, reset_selection)
  symbol_generation = symbol_generation + 1
  local gen = symbol_generation
  local limit = self:max_result_limit()
  query = trim_query(query)
  self.results = {}
  self.has_more = false
  self.hovered_result = nil
  if reset_selection then
    self.selected = 1
    self.viewport_offset = 1
  end
  self.status = query == "" and "Type after $ to find Project symbols" or "Finding Project symbols…"
  self:schedule_update(true)
  if query == "" then return end

  core.add_thread(function()
    local results, reason, status, source_label
    if lsp_enabled() then
      local lsp_provider = require "core.lsp.provider"
      local deadline = system.get_time() + ((config.lsp and config.lsp.navigation_timeout) or 10)
      results, reason, status = lsp_provider.workspace_symbols(query, { force = true })
      while status ~= "fresh" and status ~= "stale" and status ~= "unavailable" and system.get_time() < deadline do
        if gen ~= symbol_generation or active_view ~= self then return end
        coroutine.yield(0.05)
        results, reason, status = lsp_provider.workspace_symbols(query)
      end
      if status == "fresh" or status == "stale" then source_label = "LSP" end
    else
      status = "unavailable"
      reason = "LSP disabled"
    end

    if status ~= "fresh" and status ~= "stale" then
      local ts_symbols = require "core.treesitter.symbol_index"
      local deadline = system.get_time() + ((config.lsp and config.lsp.navigation_timeout) or 10)
      results, reason, status = ts_symbols.workspace_symbols(query, { force = false, limit = limit + 1, allow_stale = true })
      while status ~= "fresh" and status ~= "unavailable" and system.get_time() < deadline do
        if gen ~= symbol_generation or active_view ~= self then return end
        local index = ts_symbols.status()
        if status == "stale" then
          set_symbol_results(self, query, results, "Tree-sitter indexing", status, reason, limit, { scope = "project" })
          if not index or index.status ~= "indexing" then break end
        elseif index and index.status == "indexing" then
          self.status = string.format("Indexing Project symbols… %d found", #(index.symbols or {}))
          self:schedule_update(true)
        end
        coroutine.yield(0.05)
        results, reason, status = ts_symbols.workspace_symbols(query, { limit = limit + 1, allow_stale = true })
      end
      source_label = "Tree-sitter"
    end

    if gen ~= symbol_generation or active_view ~= self then return end
    if status == "fresh" or status == "stale" then
      set_symbol_results(self, query, results, source_label, status, reason, limit, { scope = "project" })
    else
      self.results = {}
      self.status = "Finding Project symbols timed out"
      self:schedule_update(true)
    end
    if reason and status ~= "fresh" then core.log_quiet("Fuzzy Project symbols: %s", tostring(reason)) end
  end)
end

function FSView:start_current_document_symbol_search(query, reset_selection)
  symbol_generation = symbol_generation + 1
  local gen = symbol_generation
  local limit = self:max_result_limit()
  query = trim_query(query)
  self.results = {}
  self.has_more = false
  self.hovered_result = nil
  if reset_selection then
    self.selected = 1
    self.viewport_offset = 1
  end
  self.status = "Finding current Document symbols…"
  self:schedule_update(true)

  core.add_thread(function()
    local doc = self.source_doc or (self.source_view and self.source_view.doc) or (core.active_view and core.active_view.doc)
    local treesitter = require "core.treesitter"
    if doc then treesitter.attach_or_update_doc(doc, "current-document-symbol-search") end
    local deadline = system.get_time() + 3
    while doc and doc.treesitter and doc.treesitter.status ~= "ready" and system.get_time() < deadline do
      if gen ~= symbol_generation or active_view ~= self then return end
      treesitter.poll_doc(doc)
      coroutine.yield(0.03)
    end
    if gen ~= symbol_generation or active_view ~= self then return end
    local ts_symbols = require "core.treesitter.symbol_index"
    local results, reason, status = ts_symbols.current_document_symbols(doc, query, { limit = limit + 1 })
    if status == "fresh" or status == "stale" then
      set_symbol_results(self, query, results, "current Document", status, reason, limit, { scope = "document", doc = doc })
      if #self.results == 0 and reason then self.status = "No current Document symbols: " .. tostring(reason) end
    else
      self.status = reason or "No current Document symbols"
      self:schedule_update(true)
    end
  end)
end

function FSView:refresh_static()
  self.results = self.static_results or {}
  self.has_more = false
  self.hovered_result = nil
  self.status = self.static_status or ""
  self.selected = common.clamp(self.selected or 1, 1, math.max(1, #self.results))
  self:ensure_selection_visible()
end

function FSView:set_static_results(results, status)
  if not self.static_mode then return end
  self.static_results = results or {}
  self.static_status = status or ""
  self.dirty = true
  self:refresh_static()
  self:schedule_update(true)
end

function FSView:refresh(text)
  if self.static_mode then
    self:refresh_static()
    self.dirty = false
    self.force_refresh = false
    return
  end
  text = text or self.input:get_text()
  local files_changed = self.last_files_generation ~= files_generation
  local base, line, grep = parse_query(text)
  local query_key = base .. "\0" .. tostring(line or "") .. "\0" .. tostring(grep or "")
  local query_changed = query_key ~= self.current_query_key

  if query_changed then
    self.current_query_key = query_key
    self:reset_pagination()
  end

  if not self.force_refresh and not self.dirty and not files_changed then return end
  local force_refresh = self.force_refresh
  self.force_refresh = false
  self.dirty = false
  self.last_files_generation = files_generation

  if grep ~= nil then
    if query_changed or force_refresh then self:start_grep(base, line, grep) end
  else
    kill_grep()
    kill_fuzzy_grep_jobs()
    self:refresh_normal(base, line, query_changed, force_refresh)
  end
end

function FSView:supports_text_input()
  return true
end

function FSView:on_text_input(text)
  if self.static_mode then return true end
  -- Text input is the authoritative path for all printable characters,
  -- especially layout-dependent ones like AltGr, dead keys and IME output.
  self._awaiting_textinput = nil
  fuzzy_focus_log("text-input-before", self, "bytes=" .. tostring(#tostring(text or "")) .. " text=" .. tostring(text or ""))
  ensure_input_focus(self)
  self.input:on_text_input(text)
  fuzzy_focus_log("text-input-after", self, "bytes=" .. tostring(#tostring(text or "")) .. " text=" .. tostring(text or ""))
  return true
end

function fuzzy_searcher.apply_prompt_history_query(view, mode, query, select_query)
  local text = tostring(mode or "") .. tostring(query or "")
  view._applying_prompt_history = true
  view.input:set_text(text)
  view._applying_prompt_history = false

  local doc = view.input and view.input.textview and view.input.textview.doc
  if doc then
    if select_query then
      doc:set_selection(1, #(mode or "") + 1, 1, #text + 1)
    else
      doc:set_selection(1, #text + 1, 1, #text + 1)
    end
  end
  view.dirty = true
  view.force_refresh = true
  view:refresh(text)
  view:schedule_update(true)
end

function FSView:record_prompt_history()
  if self.static_mode or self._prompt_history_recorded then return end
  self._prompt_history_recorded = true
  if self.input then fuzzy_searcher.record_prompt_history_text(self.input:get_text()) end
end

function FSView:prompt_history_session()
  local mode, query = split_mode_prefix(self.input and self.input:get_text() or "")
  local session = self._prompt_history_session
  if session and session.mode == mode then return session end

  local entries = { query }
  for _, entry in ipairs(fuzzy_searcher.prompt_history_for_mode(mode)) do
    if entry ~= query then entries[#entries + 1] = entry end
  end
  session = { mode = mode, entries = entries, index = 1 }
  self._prompt_history_session = session
  return session
end

function FSView:navigate_prompt_history(delta)
  if self.static_mode or not self.input then return false end
  local session = self:prompt_history_session()
  local index = common.clamp(session.index + delta, 1, #session.entries)
  if index == session.index then return false end
  session.index = index
  fuzzy_searcher.apply_prompt_history_query(self, session.mode, session.entries[index], false)
  return true
end

function FSView:close()
  fuzzy_focus_log("close", self)
  self:record_prompt_history()
  kill_file_search()
  kill_grep()
  kill_fuzzy_grep_jobs()
  self:clear_preview_view()
  self:swap_active_child(nil)
  self:hide()
  self:destroy()
  if active_view == self then active_view = nil end
  if core.fuzzy_searcher_active_view == self then core.fuzzy_searcher_active_view = nil end
end

function FSView:selected_file_path()
  local r = self:selected_result()
  if not r or not r.file then return end
  return common.normalize_path(fullpath(r.file))
end

function FSView:focus_selected_in_tree()
  local path = self:selected_file_path()
  if not path then return end

  local root = core.root_project and core.root_project()
  if not root or not common.path_belongs_to(path, root.path) then return end

  -- Close first so filetree remains the active view; otherwise its update() sees
  -- the fuzzy input as active and collapses itself again.
  self:close()
  command.perform("filetree:focus-file", path)
end

function FSView:reveal_selected_in_explorer()
  local path = self:selected_file_path()
  if not path then return end

  self:close()
  command.perform("user:reveal-active-file-in-explorer", path)
end

function FSView:confirm(target_side)
  local r = self:selected_result()
  if not r then return end
  if r.kind == "command" then
    local cmd = r.command
    remember_command(cmd)
    self:close()
    command.perform(cmd)
    return
  end
  if (r.kind == "project" or r.kind == "new_project" or (r.kind == "everything" and r.is_folder)) and r.project then
    local path = r.project
    self:close()
    if target_side or r.kind == "new_project" then
      open_anvil_window(path)
    else
      core.open_project_in_same_window(path)
    end
    return
  end
  if r.doc and r.line then
    local doc = r.doc
    local source_view = self.source_view
    self:close()
    if source_view and source_view.doc == doc then
      if r.line2 and r.col2 then doc:set_selection(r.line, r.col, r.line2, r.col2) else doc:set_selection(r.line, r.col) end
    end
    return
  end
  if r.file then
    local path = fullpath(r.file)
    local line, col, line2, col2 = r.line or 1, r.col or 1, nil, nil
    if r.kind == "grep" then
      line, col, line2, col2 = grep_accept_range(r)
    end
    local source_view = self.source_view
    self:close()
    if target_side then
      sidepanel.open_path_in_side(path, {
        line = line,
        col = col,
        line2 = line2,
        col2 = col2,
        focus = true,
        restore_focus = source_view,
      })
    else
      local v = core.open_file(path)
      if v and v.doc then
        if v.with_selection_state then
          v:with_selection_state(function()
            if line2 and col2 then v.doc:set_selection(line, col, line2, col2) else v.doc:set_selection(line, col) end
          end)
        else
          if line2 and col2 then v.doc:set_selection(line, col, line2, col2) else v.doc:set_selection(line, col) end
        end
      end
    end
  end
end

function FSView:update()
  self:layout()
  FSView.super.update(self)
  if self.input then
    self.input.border.color = style.dim
  end
  if self._awaiting_textinput and not self._awaiting_textinput.logged and system.get_time() - self._awaiting_textinput.time > 0.25 then
    local a = self._awaiting_textinput
    a.logged = true
    fuzzy_focus_log("textinput-missing-after-key", self,
      "key=" .. tostring(a.key) ..
      " stroke=" .. tostring(a.stroke) ..
      " before_len=" .. tostring(a.text_len) ..
      " mods=" .. modal_modkeys_string())
  end
  if self.input and core.active_view ~= self.input.textview then
    local state = view_label(core.active_view) .. "|" .. view_label(self.child_active)
    if state ~= self._last_unexpected_focus_state then
      self._last_unexpected_focus_state = state
      fuzzy_focus_log("update-unexpected-active", self)
    end
  else
    self._last_unexpected_focus_state = nil
  end
  self:refresh(self.input:get_text())
end

function FSView:draw()
  if not self:is_visible() then return false end
  local root = core.root_panel
  renderer.draw_rect(root.position.x, root.position.y, root.size.x, root.size.y, style.fuzzy_searcher_overlay_background)

  if not FSView.super.draw(self) then return false end

  local pad = style.padding.x
  local font = style.code_font
  local m = self:list_metrics(font)
  local x, y, w, h = m.x, m.y, m.w, m.h
  local top, list_w, lh = m.top, m.list_w, m.lh
  self:ensure_selection_visible()

  renderer.draw_text(font, self.status or "", x + pad, y + self.input.size.y + pad * 1.5, style.dim)
  local full_width_mode = self:is_full_width_mode()
  local command_mode = self:is_command_mode()
  local divider_w = full_width_mode and 0 or style.divider_size
  if not full_width_mode then
    renderer.draw_rect(x + list_w, top, style.divider_size, h - (top - y), style.divider)
  end

  core.push_clip_rect(x, top, list_w - divider_w, h - (top - y))
  local row_text_w = list_w - (pad * 2) - divider_w
  local arrow_color = style.dim
  local up_arrow, down_arrow = "▲", "▼"
  if self.viewport_offset > 1 then
    renderer.draw_text(font, up_arrow, x + (list_w - font:get_width(up_arrow)) / 2, top, arrow_color)
  end
  if self.viewport_offset + m.result_rows - 1 < #self.results or self:can_load_more() then
    renderer.draw_text(font, down_arrow, x + (list_w - font:get_width(down_arrow)) / 2, m.bottom_indicator_y, arrow_color)
  end

  local last = math.min(#self.results, self.viewport_offset + m.result_rows - 1)
  local has_visible_grep = false
  for idx = self.viewport_offset, last do
    local r = self.results[idx]
    if r and r.kind == "grep" then has_visible_grep = true; break end
  end
  local previous_rendered_grep_file = nil
  local previous_rendered_grep_line_x = nil
  local previous_rendered_was_grep = false
  for idx = self.viewport_offset, last do
    local r = self.results[idx]
    local yy = m.results_top + (idx - self.viewport_offset) * lh
    if r.header then
      previous_rendered_grep_file = nil
      previous_rendered_grep_line_x = nil
      previous_rendered_was_grep = false
      if r.separator then
        renderer.draw_rect(x + pad, yy + math.floor(lh / 2), math.max(0, row_text_w), style.divider_size, style.divider)
      else
        renderer.draw_text(font, truncate_text(font, r.label, row_text_w), x + pad, yy, style.accent)
      end
    else
      if idx == self.selected then
        renderer.draw_rect(x, yy, list_w, lh, style.line_highlight)
      elseif idx == self.hovered_result then
        renderer.draw_rect(x, yy, list_w, lh, style.background3 or color_with_alpha(style.text, 24))
      end
      if r.kind == "grep" then
        local file = tostring(r.file or "")
        local collapse_file = file ~= "" and previous_rendered_was_grep and file == previous_rendered_grep_file
        previous_rendered_grep_line_x = draw_grep_result_row(font, r, x + pad, yy, row_text_w, collapse_file, previous_rendered_grep_line_x)
        previous_rendered_grep_file = file
        previous_rendered_was_grep = true
      elseif r.kind == "file" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_file_result_row(font, r.file or r.label, r.match_spans, "", x + pad, yy, row_text_w)
      elseif r.kind == "symbol" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_symbol_result_row(font, r, x + pad, yy, row_text_w)
      elseif r.kind == "command" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_command_result_row(font, r, x + pad, yy, row_text_w)
      elseif r.kind == "project" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_project_result_row(font, r, x + pad, yy, row_text_w)
      elseif r.kind == "everything" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_everything_result_row(font, r, x + pad, yy, row_text_w)
      elseif r.kind == "new_project" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_new_project_result_row(font, r, x + pad, yy, row_text_w)
      else
        local label, spans, prefix = result_list_label_and_spans(r)
        draw_prefixed_highlighted_text(font, prefix, label, x + pad, yy, row_text_w, style.text, spans)
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
      end
    end
  end
  if has_visible_grep then
    local path_w, gap = grep_row_columns(row_text_w)
    local sx = x + pad + path_w + gap / 2
    renderer.draw_rect(sx, m.results_top, style.divider_size, math.max(0, last - self.viewport_offset + 1) * lh, style.divider)
  end
  core.pop_clip_rect()

  local r = self:selected_result()
  local px, py, preview_w, preview_h = self:preview_bounds()
  if full_width_mode then
    self:clear_preview_view()
  elseif r and r.kind == "command" then
    self:clear_preview_view()
    core.push_clip_rect(px, py, preview_w, preview_h)
    renderer.draw_text(font, "Command", px, py, style.accent)
    draw_highlighted_text(font, r.command, px, py + lh, preview_w, style.text, r.match_spans or {})
    local info = r.info or command_preview_info(r.command)
    if info and info ~= "" then
      renderer.draw_text(font, info, px, py + lh * 2, style.dim)
    end
    core.pop_clip_rect()
  elseif r and r.kind == "project" then
    self:clear_preview_view()
    core.push_clip_rect(px, py, preview_w, preview_h)
    renderer.draw_text(font, "Project", px, py, style.accent)
    draw_highlighted_text(font, display_root(r.project), px, py + lh, preview_w, style.text, r.match_spans or {})
    renderer.draw_text(font, "Enter: open here", px, py + lh * 3, style.dim)
    renderer.draw_text(font, "Ctrl+Enter: open in new Anvil window", px, py + lh * 4, style.dim)
    core.pop_clip_rect()
  else
    local preview = self:update_preview_view()
    if preview then
      draw_view_in_rect(preview, px, py, preview_w, preview_h, r)
    elseif self.preview_blocked then
      core.push_clip_rect(px, py, preview_w, preview_h)
      draw_preview_placeholder("Preview unavailable", self.preview_blocked.reason .. " — " .. basename(self.preview_blocked.path), px, py, preview_w, preview_h)
      core.pop_clip_rect()
    end
  end
  return true
end


local function picker_active()
  return current_picker() ~= nil
end

local function picker_close()
  local view = current_picker()
  if view then view:close() end
end

local function picker_confirm()
  local view = current_picker()
  if view then view:confirm(false) end
end

local function picker_confirm_side()
  local view = current_picker()
  if view then view:confirm(true) end
end

local function picker_focus_selected_in_tree()
  local view = current_picker()
  if view then view:focus_selected_in_tree() end
end

local function picker_reveal_selected_in_explorer()
  local view = current_picker()
  if view then view:reveal_selected_in_explorer() end
end

local function picker_next()
  local view = current_picker()
  if view then view:select_delta(1); view:schedule_update(true) end
end

local function picker_previous()
  local view = current_picker()
  if view then view:select_delta(-1); view:schedule_update(true) end
end

local function selected_text_for_search()
  local view = core.active_view
  local doc = view and view.doc
  if not doc then return "" end
  local text = doc:get_text(table.unpack({ doc:get_selection() })) or ""
  return text
end

local function quote_exact_query(text)
  text = tostring(text or "")
  return '"' .. text:gsub('"', '""') .. '"'
end

local function switch_picker_prefix(view, prefix)
  prefix = prefix or ""
  local old_text = view.input and view.input:get_text() or ""
  local old_prefix, query = split_mode_prefix(old_text)
  fuzzy_searcher.record_prompt_history_text(old_text)

  local new_text, select_query
  if query == "" then
    new_text, select_query = fuzzy_searcher.restored_prompt_text(prefix)
  else
    new_text = prefix .. query
    select_query = false
  end

  local new_prefix, new_query = split_mode_prefix(new_text)
  local doc = view.input and view.input.textview and view.input.textview.doc
  local col = #new_text + 1
  if doc and not select_query then
    local _line
    _line, col = doc:get_selection(false)
    local old_prefix_len = old_prefix ~= "" and #old_prefix or 0
    local new_prefix_len = new_prefix ~= "" and #new_prefix or 0
    col = (col or 1) - old_prefix_len + new_prefix_len
    col = common.clamp(col, new_prefix_len + 1, #new_text + 1)
  end

  fuzzy_searcher.apply_prompt_history_query(view, new_prefix, new_query, select_query)
  if doc and not select_query then doc:set_selection(1, col, 1, col) end
  ensure_input_focus(view, "switch-prefix")
end

function open(prefix)
  prefix = prefix or ""
  local view = current_picker()
  if view then
    switch_picker_prefix(view, prefix)
    return
  end
  if prefix == "#" then
    local selection = selected_text_for_search()
    if selection ~= "" then prefix = "#" .. quote_exact_query(selection) end
  end
  local initial_text, select_restored_query = fuzzy_searcher.restored_prompt_text(prefix)
  active_view = FSView(initial_text)
  core.fuzzy_searcher_active_view = active_view
  if select_restored_query then
    local mode = split_mode_prefix(initial_text)
    fuzzy_searcher.apply_prompt_history_query(active_view, mode, initial_text:sub(#mode + 1), true)
  end
end

function open_static_results(title, results, opts)
  opts = opts or {}
  title = title or "Results"
  local view = current_picker()
  if view then view:close() end
  active_view = FSView(title, {
    static = true,
    results = results or {},
    status = opts.status or title,
  })
  core.fuzzy_searcher_active_view = active_view
  return active_view
end

command.add(nil, {
  ["fuzzy-searcher:open"] = function() open("") end,
  ["fuzzy-searcher:open-files"] = function() open("") end,
  ["fuzzy-searcher:open-projects"] = function() open("@") end,
  ["fuzzy-searcher:open-grep"] = function() open("#") end,
  ["fuzzy-searcher:open-symbols"] = function() open("$") end,
  ["fuzzy-searcher:open-current-document-symbols"] = function() open("$$") end,
  ["fuzzy-searcher:open-commands"] = function() open(">") end,
})

command.add(picker_active, {
  ["fuzzy-searcher:close"] = picker_close,
  ["fuzzy-searcher:confirm"] = picker_confirm,
  ["fuzzy-searcher:confirm-side"] = picker_confirm_side,
  ["fuzzy-searcher:focus-selected-in-tree"] = picker_focus_selected_in_tree,
  ["fuzzy-searcher:reveal-selected-in-explorer"] = picker_reveal_selected_in_explorer,
  ["fuzzy-searcher:next"] = picker_next,
  ["fuzzy-searcher:previous"] = picker_previous,
  ["fuzzy-searcher:prompt-history-previous"] = function()
    local view = current_picker()
    if view then view:navigate_prompt_history(1) end
  end,
  ["fuzzy-searcher:prompt-history-next"] = function()
    local view = current_picker()
    if view then view:navigate_prompt_history(-1) end
  end,
})

-- Global open shortcuts intentionally override conflicting defaults.
core.fuzzy_searcher_install_global_keymaps = function()
  keymap.add({
    ["ctrl+shift+e"] = "fuzzy-searcher:open-projects",
    ["ctrl+e"] = "fuzzy-searcher:open-files",
    ["ctrl+shift+j"] = "fuzzy-searcher:open-symbols",
    ["ctrl+j"] = "fuzzy-searcher:open-current-document-symbols",
    ["ctrl+shift+f"] = "fuzzy-searcher:open-grep",
    ["ctrl+shift+a"] = "fuzzy-searcher:open-commands",
    ["ctrl+shift+p"] = "fuzzy-searcher:open-commands",
  }, true)
  keymap.unbind("ctrl+shift+f", "project-search:find")
end
core.fuzzy_searcher_install_global_keymaps()

-- Picker-local navigation. These are prepended, not overwritten: when the
-- picker predicate is false, Anvil falls through to the normal bindings.
core.fuzzy_searcher_install_picker_keymaps = function()
  keymap.add({
    ["escape"] = "fuzzy-searcher:close",
    ["return"] = "fuzzy-searcher:confirm",
    ["keypad enter"] = "fuzzy-searcher:confirm",
    ["alt+r"] = "fuzzy-searcher:confirm",
    ["ctrl+return"] = "fuzzy-searcher:confirm-side",
    ["alt+shift+r"] = "fuzzy-searcher:confirm-side",
    ["ctrl+l"] = "fuzzy-searcher:focus-selected-in-tree",
    ["ctrl+shift+l"] = "fuzzy-searcher:reveal-selected-in-explorer",
    ["up"] = "fuzzy-searcher:previous",
    ["down"] = "fuzzy-searcher:next",
    ["alt+left"] = "fuzzy-searcher:prompt-history-previous",
    ["alt+right"] = "fuzzy-searcher:prompt-history-next",
  })
end
core.fuzzy_searcher_install_picker_keymaps()

keymap.__fuzzy_searcher_original_on_key_pressed = keymap.on_key_pressed
keymap.on_key_pressed = function(key, ...)
  if modal_modkey_map[key] or not current_picker() then
    return keymap.__fuzzy_searcher_original_on_key_pressed(key, ...)
  end

  local picker = current_picker()
  local stroke = modal_key_to_stroke(key)
  if key:match("^wheel") and scale_mouse_wheel_modkeys_pressed() then
    return keymap.__fuzzy_searcher_original_on_key_pressed(key, ...)
  end
  local fuzzy_cmd = modal_fuzzy_command(stroke)
  local textbox_cmd = not fuzzy_cmd and modal_textbox_command(stroke)
  if fuzzy_cmd then
    ensure_input_focus(picker)
    fuzzy_focus_log("key-fuzzy-command", picker, "key=" .. tostring(key) .. " stroke=" .. tostring(stroke) .. " cmd=" .. tostring(fuzzy_cmd))
    command.perform(fuzzy_cmd, ...)
  elseif textbox_cmd and not picker.static_mode then
    ensure_input_focus(picker)
    fuzzy_focus_log("key-textbox-command", picker, "key=" .. tostring(key) .. " stroke=" .. tostring(stroke) .. " cmd=" .. tostring(textbox_cmd))
    command.perform(textbox_cmd, ...)
  elseif modal_should_let_text_input_through(key, stroke) and not picker.static_mode then
    -- Printable keys must be handled by SDL textinput, not by key-name
    -- fallbacks; this preserves keyboard layout, AltGr, dead keys and IME.
    ensure_input_focus(picker)
    picker._awaiting_textinput = {
      time = system.get_time(),
      key = key,
      stroke = stroke,
      text_len = picker.input and #(picker.input:get_text() or "") or nil,
    }
    fuzzy_focus_log("key-let-textinput-through", picker, "key=" .. tostring(key) .. " stroke=" .. tostring(stroke) .. " mods=" .. modal_modkeys_string())
    return false
  else
    fuzzy_focus_log("key-consumed", picker, "key=" .. tostring(key) .. " stroke=" .. tostring(stroke))
  end
  -- The picker is modal: every non-modifier keypress is consumed while it is
  -- open, even when it is not one of the picker/input shortcuts above.
  return true
end

return {
  open = open,
  open_static_results = open_static_results,
  _test = {
    everything_project_search_params = everything_project_search_params,
    everything_project_search_query = everything_project_search_query,
    everything_path_depth = everything_path_depth,
    sort_everything_project_results = sort_everything_project_results,
    split_mode_prefix = split_mode_prefix,
    clear_prompt_history = function()
      fuzzy_searcher.prompt_history_loaded = true
      fuzzy_searcher.prompt_history = {}
      storage.save("fuzzy_searcher", "prompt_history", fuzzy_searcher.prompt_history)
    end,
    prompt_history = function(mode)
      local history = fuzzy_searcher.prompt_history_for_mode(mode)
      return { table.unpack(history) }
    end,
    recent_files = get_recent_files,
    file_search_rows = function(query, files, skip_path, limit)
      local recent_matches, skip_keys = collect_recent_file_matches(query or "", nil, skip_path)
      local general_matches = {}
      local empty_query = trim_query(query or "") == ""
      for _, item in ipairs(files or {}) do
        local key = file_result_key(item)
        if key and not skip_keys[key] then
          local score, spans = 0, {}
          if not empty_query then score, spans = fuzzy_match_file_fast(query, item) end
          if score then
            general_matches[#general_matches+1] = { item = item, text = item, score = score, spans = spans or {} }
          end
        end
      end
      if not empty_query then
        table.sort(general_matches, function(a, b) return fuzzy_result_better(a, b) end)
      end
      return build_sectioned_file_results(recent_matches, general_matches, limit or 30, query or "", nil)
    end,
  },
}
