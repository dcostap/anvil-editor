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
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local ImageView = require "core.imageview"
local file_context = require "core.file_context"
local TitleBar = require "core.titlebar"
local poi = require "core.poi"
local project_paths = require "core.project_paths"
local project_files = require "core.project_files"
local panes = require "core.panes"
local view_icons = require "core.view_icons"
local path_tree = require "plugins.path_tree"
local Widget = require "widget"
local TextBox = require "widget.textbox"
local fuzzy_native = require "fuzzy"

local PreviewTextView = TextView:extend()

function PreviewTextView:new(buffer)
  PreviewTextView.super.new(self, buffer)
  self.interactive = false
  self.show_current_line_highlight = false
end

function PreviewTextView:set_interactive(interactive)
  self.interactive = interactive == true
  self.show_current_line_highlight = self.interactive
end

function PreviewTextView:restore_preview_search_ranges()
  if not self.preview_search_ranges or next(self.buffer.search_selections) ~= nil then return end
  for _, range in ipairs(self.preview_search_ranges) do
    self.buffer:add_search_selection(range[1], range[2], range[3], range[4])
  end
end

function PreviewTextView:get_line_number_gutter_width()
  return self:get_font():get_width("00000")
end

function PreviewTextView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  if self:line_numbers_visible() then
    local color = style.line_number
    if self.interactive then
      for _, line1, _, line2 in self.buffer:get_selections(true) do
        if line >= line1 and line <= line2 then
          color = style.line_number2
          break
        end
      end
    end
    -- Preview gutters are fixed-width and left-aligned so the label itself
    -- stays anchored when the visible range changes from 1 to 2+ digits.
    renderer.draw_text(self:get_font(), tostring(line), x + style.padding.x, y + self:get_line_text_y_offset(), color)
  end
  return lh
end

local BUNDLED_PLUGIN_DIR = DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher"
local USER_PLUGIN_DIR = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "fuzzy_searcher"
local RECENT_COMMANDS_FILE = USER_PLUGIN_DIR .. PATHSEP .. "recent_commands.txt"
local RECENT_PROJECT_TIMES_FILE = USER_PLUGIN_DIR .. PATHSEP .. "recent_project_times.lua"
local EXACT_GREP_SLICE_SECONDS = 0.002

local function bundled_tool(name)
  local bundled = BUNDLED_PLUGIN_DIR .. PATHSEP .. name
  if system.get_file_info(bundled) then return bundled end
  return USER_PLUGIN_DIR .. PATHSEP .. name
end

local fuzzy_searcher = {
  copy_feedback = require "core.copy_feedback",
  file_icons = require "core.file_icons",
  result_limit = 30,
  max_result_limit = 500,
  width = 0.90,
  height = 0.80,
  side_padding_reduce_width = 1500 * SCALE,
  min_width = 1200 * SCALE,
  min_side_padding = nil,
  min_height = 650 * SCALE,
  preview_width = 0.50,
  deep_code_results_height = 0.42,
  rg = PLATFORM == "Windows" and bundled_tool("rg.exe") or "rg",
  fuzzy_candidate_limit = 500,
  fuzzy_scan_limit = 10000,
  fuzzy_line_max_chars = 1200,
  fuzzy_time_slice = 0.006,
  grep_path_column_width = 0.45,
  preview_debug = false,
  preview_text_max_bytes = 2 * 1024 * 1024,
  loading_feedback_delay = 0.20,
}

local FSView = Widget:extend()
view_icons.register("fuzzy", view_icons.ui("L"))
local active_view

function fuzzy_searcher._perf_scope_begin(name, capture_heap)
  if not core.perf_draw_scope_active then return nil end
  local perf = package.loaded["core.perf"]
  return perf and perf.scope_begin and perf.scope_begin(name, capture_heap) or nil
end

function fuzzy_searcher._perf_scope_end(token)
  if not token then return end
  local perf = package.loaded["core.perf"]
  if perf and perf.scope_end then perf.scope_end(token) end
end

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
    local restore = file_context.current_content_view(core.active_view) or core.active_view
    if restore and restore ~= picker and restore ~= picker.input and restore ~= input_view then
      picker.prev_view = restore
    end
    core.set_active_view(input_view)
    picker.input:activate()
  end
  if reason then fuzzy_focus_log(reason, picker) end
end

local function modal_picker_command_allowed(cmd)
  if type(cmd) ~= "string" then return false end
  return cmd:match("^fuzzy:") ~= nil
      or cmd == "core:open_text_capture"
      or cmd == "core:activate_point_of_interest"
      or cmd == "core:activate_point_of_interest_split"
      or cmd == "pane:focus_local_next"
      or cmd == "pane:focus_local_previous"
end

local function modal_textbox_command_allowed(cmd)
  if type(cmd) ~= "string" then return false end
  if cmd == "editor:select_previous_camel_hump"
      or cmd == "editor:select_next_camel_hump"
      or cmd == "editor:extend_selection_smart"
      or cmd == "editor:shrink_selection_smart"
      or cmd == "editor:expand_selection_block"
      or cmd == "editor:select_to_matching"
  then
    return true
  end
  if cmd:match("^core:move_to_") or cmd:match("^core:select_to_") then return true end
  if cmd:match("^core:delete") then return true end
  return cmd == "core:backspace"
      or cmd == "core:copy"
      or cmd == "core:cut"
      or cmd == "core:paste"
      or cmd == "core:undo"
      or cmd == "core:redo"
      or cmd == "core:select_all"
      or cmd == "core:select_none"
end

local function modal_command(stroke, predicate)
  local commands = keymap.map[stroke]
  if not commands then return nil end
  for _, cmd in ipairs(commands) do
    if predicate(cmd) then return cmd end
  end
end

local function modal_picker_command(stroke, picker)
  -- Ctrl+Enter is also claimed by local IntelliJ conflict disabling. Keep the
  -- picker modal command authoritative even when the global keymap was later
  -- overwritten.
  if stroke == "ctrl+return" then return "fuzzy:confirm_side" end
  local cmd = modal_command(stroke, modal_picker_command_allowed)
  if cmd == "fuzzy:copy_selected" then
    local textview = picker and picker.input and picker.input.textview
    local state = textview and textview:get_selection_state()
    for i = 1, #(state and state.selections or {}), 4 do
      if state.selections[i] ~= state.selections[i + 2]
      or state.selections[i + 1] ~= state.selections[i + 3] then
        return nil
      end
    end
  end
  return cmd
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
fuzzy_searcher.files_cache_root = nil
fuzzy_searcher.files_cache = nil
fuzzy_searcher.files_indexing = false
fuzzy_searcher.files_generation = 0
fuzzy_searcher.files_scan_generation = 0
fuzzy_searcher.files_refresh_requested = false
fuzzy_searcher.files_scan_proc = nil
fuzzy_searcher.files_scope_generation = 0
fuzzy_searcher.files_metadata = {}
fuzzy_searcher.folders_cache = {}
fuzzy_searcher.folders_fuzzy_index = nil
fuzzy_searcher.files_fuzzy_index = nil
fuzzy_searcher.files_fuzzy_index_generation = -1
fuzzy_searcher.files_fuzzy_index_kind = nil
fuzzy_searcher.files_materialized_cache = nil
fuzzy_searcher.files_materialized_generation = -1
fuzzy_searcher.files_last_scan_diagnostics = nil
fuzzy_searcher.files_scan_reason = nil
fuzzy_searcher.files_skip_next_picker_refresh = false
fuzzy_searcher.files_cache_test_override = false
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

function fuzzy_searcher.project_roots_label(roots)
  roots = roots or project_paths.search_roots("files")
  if #roots <= 1 then
    local root = roots[1] and roots[1].path or project_dir()
    return common.home_encode and common.home_encode(root) or root
  end
  return string.format("%d Project path roots", #roots)
end

function fuzzy_searcher.remember_file_metadata(meta, metadata)
  if not (meta and meta.text and meta.abs_path) then return nil end
  metadata = metadata or fuzzy_searcher.files_metadata
  local text = meta.text
  local existing = metadata[text]
  if existing and not common.path_equals(existing.abs_path, meta.abs_path) then
    if system.get_file_info(existing.abs_path) then
      text = string.format("%s  —  %s", text, display_root(meta.abs_path))
      meta = common.merge(meta, { text = text, disambiguated = true })
    else
      metadata[text] = nil
    end
  end
  metadata[text] = meta
  return text
end

function fuzzy_searcher.file_display_item(abs_path, metadata)
  local display = project_paths.display_path(abs_path, { kind = "files" })
  if not display then return nil end
  return fuzzy_searcher.remember_file_metadata(display, metadata)
end

local function fullpath(path)
  if type(path) == "table" then
    if path.abs_path then return common.normalize_path(path.abs_path) end
    if path.root_path and path.relative_path then
      return common.normalize_path(path.root_path .. PATHSEP .. path.relative_path)
    end
    return fullpath(path.path or path.file or path.text or "")
  end
  path = tostring(path or "")
  if path == "" then return project_dir() end
  local meta = fuzzy_searcher.files_metadata[path]
  if meta and meta.abs_path then return common.normalize_path(meta.abs_path) end
  local resolved = project_paths.absolute_path(path)
  if resolved then return common.normalize_path(resolved) end
  local normalized = common.normalize_path(path)
  if normalized and common.is_absolute_path(normalized) then return normalized end
  return project_dir() .. PATHSEP .. path:gsub("[/\\]", PATHSEP)
end

---Return the File Tree Git status kind for a file result when available.
---@param file string
---@return string?
function fuzzy_searcher.git_kind_for_file(file)
  local filetree = package.loaded["plugins.filetree"]
  if not (filetree and filetree.instances) then return nil end
  local abs = fullpath(file)
  if not abs then return nil end
  for _, view in ipairs(filetree.instances()) do
    local info = view:get_git_info_for_entry({ abs = abs, type = "file" })
    if info then return info.kind end
  end
end

function fuzzy_searcher.current_file_pane_markers(max_width)
  local font = TitleBar.pane_marker_font()
  local numbers_by_path = {}
  for number, pane in ipairs(panes.ordered()) do
    local path = file_context.view_file_path(pane.current_view)
    local key = path and common.path_compare_key(path)
    if key then
      local numbers = numbers_by_path[key] or {}
      numbers_by_path[key] = numbers
      numbers[#numbers+1] = number
    end
  end

  local markers = {}
  for key, numbers in pairs(numbers_by_path) do
    local text = table.concat(numbers, "·")
    if font:get_width(text) > max_width and #numbers > 1 then
      text = tostring(numbers[1]) .. "+"
    end
    if font:get_width(text) > max_width then text = tostring(numbers[1]) end
    markers[key] = { text = text, font = font }
  end
  return markers
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

function fuzzy_searcher.format_recent_file_age(ts, now)
  ts = tonumber(ts)
  if not ts then return nil end
  local elapsed = math.max(0, (tonumber(now) or os.time()) - ts)
  local minute = 60
  local hour = 60 * minute
  local day = 24 * hour
  local year = 365 * day
  if elapsed < hour then return tostring(math.floor(elapsed / minute)) .. " min" end
  if elapsed < day then return tostring(math.floor(elapsed / hour)) .. " h" end
  if elapsed < year then return tostring(math.floor(elapsed / day)) .. " d" end
  return tostring(math.floor(elapsed / year)) .. " yr"
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

local function kill_grep()
  if grep_proc then
    local proc = grep_proc
    if proc:running() then pcall(function() proc:kill() end) end
    if proc.stdout then pcall(function() proc.stdout:close() end) end
    pcall(function() proc:wait(250, 0.001) end)
  end
  grep_proc = nil
end

local function kill_file_search()
  file_search_generation = file_search_generation + 1
end

local function clear_native_file_index()
  if fuzzy_searcher.files_fuzzy_index and fuzzy_searcher.files_fuzzy_index.free then
    pcall(function() fuzzy_searcher.files_fuzzy_index:free() end)
  end
  fuzzy_searcher.files_fuzzy_index = nil
  fuzzy_searcher.files_fuzzy_index_generation = -1
  fuzzy_searcher.files_fuzzy_index_kind = nil
  fuzzy_searcher.files_materialized_cache = nil
  fuzzy_searcher.files_materialized_generation = -1
  fuzzy_searcher.folders_cache = {}
  if fuzzy_searcher.folders_fuzzy_index and fuzzy_searcher.folders_fuzzy_index.free then
    pcall(function() fuzzy_searcher.folders_fuzzy_index:free() end)
  end
  fuzzy_searcher.folders_fuzzy_index = nil
end

local function native_file_index_ready()
  return fuzzy_searcher.files_fuzzy_index and fuzzy_searcher.files_fuzzy_index_generation == fuzzy_searcher.files_generation
end

function fuzzy_searcher.file_roots_signature(roots, include_ignored)
  local parts = {}
  for _, root in ipairs(roots or {}) do
    parts[#parts + 1] = root.id or root.path
    parts[#parts + 1] = root.path
  end
  parts[#parts + 1] = include_ignored and "ignored" or "default"
  return table.concat(parts, "\0")
end

-- Remove subscriptions left by an older plugin load.
core.__fuzzy_file_watch_service_token = (core.__fuzzy_file_watch_service_token or 0) + 1
if core.__fuzzy_project_file_watch then
  for path, id in pairs(core.__fuzzy_project_file_watch) do
    project_files.unsubscribe(path, id)
  end
end
local fuzzy_file_watch_id = {}
local fuzzy_file_watch_roots = {}
core.__fuzzy_project_file_watch = fuzzy_file_watch_roots
if core.__fuzzy_file_scan_proc then
  pcall(function()
    if core.__fuzzy_file_scan_proc:running() then core.__fuzzy_file_scan_proc:kill() end
  end)
  core.__fuzzy_file_scan_proc = nil
end

local function cancel_file_index_scan()
  fuzzy_searcher.files_scan_generation = fuzzy_searcher.files_scan_generation + 1
  local proc = fuzzy_searcher.files_scan_proc
  if proc then
    pcall(function() if proc:running() then proc:kill() end end)
    if core.__fuzzy_file_scan_proc == proc then core.__fuzzy_file_scan_proc = nil end
    fuzzy_searcher.files_scan_proc = nil
  end
  fuzzy_searcher.files_indexing = false
  fuzzy_searcher.files_refresh_requested = false
  fuzzy_searcher.files_scan_reason = nil
end

local function native_file_index_root_specs(roots)
  local entries = project_paths.entries()
  local specs = {}
  for _, root in ipairs(roots or {}) do
    local spec = {
      path = root.path,
      label = root.label or common.basename(root.path),
      role = root.role or "root",
      id = tostring(root.id or root.path),
      rank_penalty = math.floor(tonumber(root.rank_penalty) or 0),
      mappings = {},
    }
    for _, entry in ipairs(entries) do
      if not common.path_equals(entry.path, root.path)
        and common.path_belongs_to(entry.path, root.path)
      then
        spec.mappings[#spec.mappings + 1] = {
          relative_prefix = common.relative_path(root.path, entry.path),
          label = entry.label or common.basename(entry.path),
          role = entry.role or "external",
          id = tostring(entry.id or entry.path),
          rank_penalty = math.floor(tonumber(entry.rank_penalty) or 0),
        }
      end
    end
    specs[#specs + 1] = spec
  end
  return specs
end

local function native_project_file_index_ready()
  return native_file_index_ready() and fuzzy_searcher.files_fuzzy_index_kind == "project"
end

local function file_index_count()
  if native_file_index_ready() then return #fuzzy_searcher.files_fuzzy_index end
  return #(fuzzy_searcher.files_cache or {})
end

local function file_scan_command(_, include_ignored)
  return project_files.scan_command(include_ignored)
end

local function folder_index_count()
  return #(fuzzy_searcher.folders_cache or {})
end

local function sync_project_file_subscriptions(roots)
  local wanted = {}
  for _, root in ipairs(roots or {}) do
    local path = common.normalize_path(root.path)
    wanted[path] = true
    if not fuzzy_file_watch_roots[path] then
      fuzzy_file_watch_roots[path] = fuzzy_file_watch_id
      project_files.subscribe(path, fuzzy_file_watch_id, function(_, event)
        if not (event and event.refreshed) then return end
        fuzzy_searcher.files_skip_next_picker_refresh = false
        fuzzy_searcher.files_materialized_cache = nil
        fuzzy_searcher.files_materialized_generation = -1
        fuzzy_searcher.files_generation = fuzzy_searcher.files_generation + 1
        fuzzy_searcher.files_cache = nil
        clear_native_file_index()
        if fuzzy_searcher.files_indexing then
          fuzzy_searcher.files_refresh_requested = true
        elseif active_view and fuzzy_searcher.refresh_file_index_for_picker_open then
          fuzzy_searcher.refresh_file_index_for_picker_open()
        end
      end)
    end
  end
  for path, id in pairs(fuzzy_file_watch_roots) do
    if not wanted[path] then
      project_files.unsubscribe(path, id)
      fuzzy_file_watch_roots[path] = nil
    end
  end
end

local function start_file_index(roots, signature, reason, include_ignored)
  if fuzzy_searcher.files_indexing then return false end

  local builder_ok, native_builder = pcall(
    fuzzy_native.file_index_builder,
    native_file_index_root_specs(roots)
  )
  if not builder_ok or not native_builder then
    core.log_quiet("Fuzzy native file index builder could not start: %s", tostring(native_builder))
    return false
  end

  fuzzy_searcher.files_indexing = true
  fuzzy_searcher.files_scan_reason = reason or "picker-open"
  if reason ~= "project-prewarm" then fuzzy_searcher.files_skip_next_picker_refresh = false end
  fuzzy_searcher.files_refresh_requested = false
  fuzzy_searcher.files_scan_generation = fuzzy_searcher.files_scan_generation + 1
  local scan_generation = fuzzy_searcher.files_scan_generation
  core.log_quiet("Fuzzy file index scan started (%s)", tostring(reason or "picker-open"))
  core.add_thread(function()
    coroutine.yield(0.05)
    local scan_failed = false
    local scan_started = system.get_time()
    local native_feed_seconds = 0
    local scanned_directories = {}
    local scanned_directory_keys = {}

    for root_index, root in ipairs(roots) do
      if scan_generation ~= fuzzy_searcher.files_scan_generation
        or fuzzy_searcher.files_cache_root ~= signature
      then
        pcall(native_builder.free, native_builder)
        return
      end

      local files, scan_error, directories = project_files.list(root.path, {
        refresh = include_ignored or reason == "picker-open" or project_files.cached(root.path, {
          include_ignored = include_ignored,
        }) == nil,
        include_ignored = include_ignored,
      })
      if not files then
        scan_failed = true
        core.log_quiet(
          "Fuzzy file index could not start scanner for %s: %s",
          tostring(root.path), tostring(scan_error or "unknown error")
        )
        break
      end
      for _, directory in ipairs(directories or project_files.directories(root.path, {
        include_ignored = include_ignored,
      }) or {}) do
        local key = common.path_compare_key(directory)
        if key and not scanned_directory_keys[key] then
          scanned_directory_keys[key] = true
          scanned_directories[#scanned_directories + 1] = directory
        end
      end
      local chunk, chunk_bytes = {}, 0
      for _, file in ipairs(files) do
        local value = file.relative .. "\0"
        chunk[#chunk + 1] = value
        chunk_bytes = chunk_bytes + #value
        if chunk_bytes >= 256 * 1024 then
          if scan_generation ~= fuzzy_searcher.files_scan_generation
            or fuzzy_searcher.files_cache_root ~= signature
          then
            pcall(native_builder.free, native_builder)
            return
          end
          local feed_started = system.get_time()
          native_builder:feed(root_index, table.concat(chunk))
          native_feed_seconds = native_feed_seconds + (system.get_time() - feed_started)
          chunk, chunk_bytes = {}, 0
          coroutine.yield(0)
        end
      end
      if #chunk > 0 then
        local feed_started = system.get_time()
        native_builder:feed(root_index, table.concat(chunk))
        native_feed_seconds = native_feed_seconds + (system.get_time() - feed_started)
      end
    end

    if scan_generation ~= fuzzy_searcher.files_scan_generation
      or fuzzy_searcher.files_cache_root ~= signature
    then
      pcall(native_builder.free, native_builder)
      return
    end

    local completed_reason = fuzzy_searcher.files_scan_reason
    if scan_failed then
      pcall(native_builder.free, native_builder)
      core.log_quiet("Fuzzy file index retained its previous snapshot after scanning failed")
    else
      local finish_started = system.get_time()
      local task_started, finish_task = pcall(native_builder.finish_async, native_builder)
      local finished, native_index, native_stats = task_started, nil, nil
      if task_started then
        repeat
          finished, native_index, native_stats = pcall(finish_task.poll, finish_task)
          if finished and not native_index then coroutine.yield(0.005) end
        until not finished or native_index
      end
      local finish_seconds = system.get_time() - finish_started
      if not finished or not native_index then
        scan_failed = true
        core.log_quiet("Fuzzy native file index finalization failed: %s",
          tostring(task_started and native_index or finish_task))
      else
        if scan_generation ~= fuzzy_searcher.files_scan_generation
          or fuzzy_searcher.files_cache_root ~= signature
        then
          pcall(native_index.free, native_index)
          return
        end
        local previous_index = fuzzy_searcher.files_fuzzy_index
        fuzzy_searcher.files_generation = fuzzy_searcher.files_generation + 1
        fuzzy_searcher.files_cache = nil
        fuzzy_searcher.files_metadata = {}
        fuzzy_searcher.folders_cache = {}
        local folder_texts = {}
        for _, directory in ipairs(scanned_directories) do
          local meta = project_paths.display_path(directory, { kind = "files" })
          if meta then
            if meta.relpath == "" then
              meta.text = meta.root_label or common.basename(directory)
            end
            meta.is_folder = true
            local text = fuzzy_searcher.remember_file_metadata(meta)
            if text then
              meta.text = text
              fuzzy_searcher.folders_cache[#fuzzy_searcher.folders_cache + 1] = meta
              folder_texts[#folder_texts + 1] = text
            end
          end
        end
        if fuzzy_searcher.folders_fuzzy_index and fuzzy_searcher.folders_fuzzy_index.free then
          pcall(function() fuzzy_searcher.folders_fuzzy_index:free() end)
        end
        local folder_index_ok, folder_index = pcall(
          fuzzy_native.index, folder_texts, { mode = "path" }
        )
        fuzzy_searcher.folders_fuzzy_index = folder_index_ok and folder_index or nil
        fuzzy_searcher.files_materialized_cache = nil
        fuzzy_searcher.files_materialized_generation = -1
        fuzzy_searcher.files_fuzzy_index = native_index
        fuzzy_searcher.files_fuzzy_index_generation = fuzzy_searcher.files_generation
        fuzzy_searcher.files_fuzzy_index_kind = "project"
        fuzzy_searcher.files_scope_generation = fuzzy_searcher.files_scope_generation + 1
        fuzzy_searcher.files_last_scan_diagnostics = {
          files = #native_index,
          folders = folder_index_count(),
          candidates = tonumber(native_stats and native_stats.candidates) or #native_index,
          duplicates = tonumber(native_stats and native_stats.duplicates) or 0,
          input_bytes = tonumber(native_stats and native_stats.input_bytes) or 0,
          total_ms = (system.get_time() - scan_started) * 1000,
          native_feed_ms = native_feed_seconds * 1000,
          native_finish_ms = finish_seconds * 1000,
        }
        fuzzy_searcher.files_skip_next_picker_refresh = completed_reason == "project-prewarm"
          and active_view == nil
        if previous_index and previous_index ~= native_index and previous_index.free then
          pcall(previous_index.free, previous_index)
        end
        core.log_quiet(
          "Fuzzy native file index scan finished files=%d folders=%d candidates=%d duplicates=%d bytes=%d scan_ms=%.3f feed_ms=%.3f finish_ms=%.3f",
          #native_index,
          folder_index_count(),
          tonumber(native_stats and native_stats.candidates) or #native_index,
          tonumber(native_stats and native_stats.duplicates) or 0,
          tonumber(native_stats and native_stats.input_bytes) or 0,
          (system.get_time() - scan_started) * 1000,
          native_feed_seconds * 1000,
          finish_seconds * 1000
        )
      end
    end
    local refresh_requested = fuzzy_searcher.files_refresh_requested
    fuzzy_searcher.files_indexing = false
    fuzzy_searcher.files_refresh_requested = false
    fuzzy_searcher.files_scan_reason = nil
    if active_view then active_view.dirty = true; active_view:schedule_update(true) end
    if refresh_requested then fuzzy_searcher.refresh_file_index_for_picker_open() end
  end)
  return true
end

local function prepare_file_index_roots(roots, signature)
  sync_project_file_subscriptions(roots)
  if fuzzy_searcher.files_cache_root == signature then return end
  cancel_file_index_scan()
  fuzzy_searcher.files_cache_test_override = false
  fuzzy_searcher.files_cache_root = signature
  fuzzy_searcher.files_cache = nil
  fuzzy_searcher.files_metadata = {}
  fuzzy_searcher.files_generation = fuzzy_searcher.files_generation + 1
  clear_native_file_index()
  fuzzy_searcher.files_skip_next_picker_refresh = false
end

local function ensure_file_index()
  local roots = project_paths.search_roots("files")
  local include_ignored = active_view and active_view.include_ignored == true
  local signature = fuzzy_searcher.file_roots_signature(roots, include_ignored)
  if fuzzy_searcher.files_cache_test_override and fuzzy_searcher.files_cache_root == signature then return end
  prepare_file_index_roots(roots, signature)
  if native_file_index_ready() or fuzzy_searcher.files_cache or fuzzy_searcher.files_indexing then return end
  start_file_index(roots, signature, "initial-picker-open", include_ignored)
end

local function prewarm_file_index()
  local roots = project_paths.search_roots("files")
  if #roots == 0 then return false end
  local signature = fuzzy_searcher.file_roots_signature(roots, false)
  prepare_file_index_roots(roots, signature)
  if native_file_index_ready() or fuzzy_searcher.files_cache or fuzzy_searcher.files_indexing then return false end
  return start_file_index(roots, signature, "project-prewarm", false)
end

function fuzzy_searcher.refresh_file_index_for_picker_open()
  local roots = project_paths.search_roots("files")
  local include_ignored = active_view and active_view.include_ignored == true
  local signature = fuzzy_searcher.file_roots_signature(roots, include_ignored)
  if fuzzy_searcher.files_cache_test_override and fuzzy_searcher.files_cache_root == signature then return end
  prepare_file_index_roots(roots, signature)
  if fuzzy_searcher.files_skip_next_picker_refresh and native_file_index_ready() then
    fuzzy_searcher.files_skip_next_picker_refresh = false
    core.log_quiet("Fuzzy native file index: first picker open is using the prewarmed snapshot")
    return false
  end
  if fuzzy_searcher.files_indexing then
    if fuzzy_searcher.files_scan_reason ~= "project-prewarm" then
      fuzzy_searcher.files_refresh_requested = true
    else
      core.log_quiet("Fuzzy native file index: picker joined the in-progress Project prewarm")
    end
    return
  end
  start_file_index(roots, signature, "picker-open", include_ignored)
end

local function get_files()
  ensure_file_index()
  if native_project_file_index_ready() then
    if fuzzy_searcher.files_materialized_generation ~= fuzzy_searcher.files_generation then
      local files = {}
      for i = 1, #fuzzy_searcher.files_fuzzy_index do
        local item = fuzzy_searcher.files_fuzzy_index:entry(i)
        if item then
          item.abs_path = common.normalize_path(item.root_path .. PATHSEP .. item.relative_path)
          files[#files + 1] = fuzzy_searcher.remember_file_metadata(item) or item.text
        end
      end
      fuzzy_searcher.files_materialized_cache = files
      fuzzy_searcher.files_materialized_generation = fuzzy_searcher.files_generation
      core.log_quiet("Fuzzy native file index materialized %d Lua paths for fallback processing", #files)
    end
    return fuzzy_searcher.files_materialized_cache or {}
  end
  return fuzzy_searcher.files_cache or {}
end

local function adopt_native_file_match(item)
  if type(item) ~= "table" or not item.text then return item end
  if not item.root_path or not item.relative_path then return item.text end
  item.abs_path = item.abs_path
    or common.normalize_path(item.root_path .. PATHSEP .. item.relative_path)
  return fuzzy_searcher.remember_file_metadata(item) or item.text
end

function fuzzy_searcher.get_recent_file_entries()
  local out, seen = {}, {}

  local recent_files = core.visited_files or {}
  for _, recent in ipairs(recent_files) do
    local abs = core.recent_file_path and core.recent_file_path(recent) or recent
    abs = tostring(abs or "")
    if abs ~= "" then
      abs = common.normalize_path(abs)
      if abs and not common.is_absolute_path(abs) then
        abs = system.absolute_path(abs)
        abs = abs and common.normalize_path(abs)
      end
      local key = abs and common.path_compare_key(abs)
      if key and not seen[key] then
        local info = system.get_file_info(abs)
        local include_ignored = active_view and active_view.include_ignored == true
        local included = true
        if not include_ignored then
          for _, root in ipairs(project_paths.search_roots("files")) do
            if common.path_equals(abs, root.path) or common.path_belongs_to(abs, root.path) then
              local listed = project_files.contains(root.path, abs, "file")
              if listed ~= nil then included = listed end
              break
            end
          end
        end
        if info and info.type == "file" and included then
          seen[key] = true
          out[#out+1] = {
            text = fuzzy_searcher.file_display_item(abs) or abs,
            abs_path = abs,
            last_viewed = type(recent) == "table" and recent.last_viewed or nil,
            last_edited = type(recent) == "table" and recent.last_edited or tonumber(info.modified),
          }
        end
      end
    end
  end

  return out
end

local function get_commands(picker)
  return picker and picker.palette_commands or {}
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
  local before, grep, symbol = s, nil, nil
  local grep_pos = s:find("#", 1, true)
  local symbol_pos = s:find("$", 1, true)
  if symbol_pos == 1 and s:sub(1, 2) == "$$" then symbol_pos = nil end

  if grep_pos and (not symbol_pos or grep_pos < symbol_pos) then
    before = s:sub(1, grep_pos - 1)
    grep = s:sub(grep_pos + 1):gsub("^%s+", "")
  elseif symbol_pos then
    before = s:sub(1, symbol_pos - 1)
    symbol = s:sub(symbol_pos + 1):gsub("^%s+", "")
  end

  local base, line, col = before, nil, nil
  local b, n, c = before:match("^(.-)%s*:%s*(%d+)%s*[:,]%s*(%d+)%s*$")
  if not n then b, n = before:match("^(.-)%s*:%s*(%d+)%s*$") end
  if n then
    base = b:gsub("%s+$", "")
    line = tonumber(n)
    col = tonumber(c)
  end
  return base:gsub("^%s+", ""):gsub("%s+$", ""), line, col, grep, symbol
end

local function trim_query(q)
  return tostring(q or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function fuzzy_searcher.path_match_query(query)
  query = trim_query(query)
  local without_trailing_separator = query:gsub("[/\\]+$", "")
  return without_trailing_separator ~= "" and without_trailing_separator or query
end

fuzzy_searcher.mode_prefixes = {
  ["#"] = true, ["@"] = true, [">"] = true, ["!"] = true,
  ["$"] = true, ["$$"] = true,
}
fuzzy_searcher.prompt_history_loaded = false
fuzzy_searcher.prompt_history = {}

local function split_mode_prefix(text)
  text = tostring(text or "")
  local two = text:sub(1, 2)
  if two == "$$" then return two, text:sub(3) end
  local prefix = text:sub(1, 1)
  if fuzzy_searcher.mode_prefixes[prefix] then return prefix, text:sub(2) end
  return "", text
end

function fuzzy_searcher.split_prompt_mode_marker(text)
  text = tostring(text or "")
  local prefix, after = split_mode_prefix(text)
  if prefix ~= "" then return "", prefix, after end

  local grep_pos = text:find("#", 1, true)
  local symbol_pos = text:find("$", 1, true)
  local marker_pos = grep_pos
  local marker = "#"
  if symbol_pos and (not marker_pos or symbol_pos < marker_pos) then
    marker_pos, marker = symbol_pos, "$"
  end
  if marker_pos then
    return text:sub(1, marker_pos - 1), marker, text:sub(marker_pos + 1)
  end
  return text, "", ""
end

function fuzzy_searcher.prompt_mode(text)
  local _, marker = fuzzy_searcher.split_prompt_mode_marker(text)
  return marker
end

local function prompt_uses_file_index(text)
  return fuzzy_searcher.prompt_mode(text) == ""
end

function fuzzy_searcher.prompt_query_start(text)
  local before, marker = fuzzy_searcher.split_prompt_mode_marker(text)
  return marker ~= "" and (#before + #marker + 1) or 1
end

function fuzzy_searcher.normalize_prompt_history(data)
  local normalized, seen = {}, {}
  if type(data) ~= "table" then return normalized, false end
  local version2 = data.version == 2 and type(data.modes) == "table"
  local modes = version2 and data.modes or data
  local changed = not version2

  for stored_mode, entries in pairs(modes) do
    stored_mode = tostring(stored_mode or "")
    if type(entries) == "table" then
      for _, entry in ipairs(entries) do
        if type(entry) == "string" then
          local text = version2 and entry or (stored_mode .. entry)
          local mode = fuzzy_searcher.prompt_mode(text)
          seen[mode] = seen[mode] or {}
          normalized[mode] = normalized[mode] or {}
          if not seen[mode][text] and #normalized[mode] < 50 then
            normalized[mode][#normalized[mode] + 1] = text
            seen[mode][text] = true
          end
        end
      end
    end
  end
  return normalized, changed
end

function fuzzy_searcher.load_prompt_history()
  if fuzzy_searcher.prompt_history_loaded then return end
  local stored = storage.load("fuzzy_searcher", "prompt_history")
  local history, migrated = fuzzy_searcher.normalize_prompt_history(stored)
  fuzzy_searcher.prompt_history = history
  fuzzy_searcher.prompt_history_loaded = true
  if migrated and type(stored) == "table" then
    core.log_quiet("Fuzzy Searcher: normalized prompt history")
    storage.save("fuzzy_searcher", "prompt_history", { version = 2, modes = history })
  end
end

function fuzzy_searcher.save_prompt_history()
  fuzzy_searcher.load_prompt_history()
  storage.save("fuzzy_searcher", "prompt_history", {
    version = 2,
    modes = fuzzy_searcher.prompt_history,
  })
end

function fuzzy_searcher.prompt_history_for_mode(mode)
  fuzzy_searcher.load_prompt_history()
  mode = tostring(mode or "")
  fuzzy_searcher.prompt_history[mode] = fuzzy_searcher.prompt_history[mode] or {}
  return fuzzy_searcher.prompt_history[mode]
end

function fuzzy_searcher.record_prompt_history_text(text)
  text = tostring(text or "")

  local mode = fuzzy_searcher.prompt_mode(text)
  if mode == "!" then return end
  local history = fuzzy_searcher.prompt_history_for_mode(mode)
  for i = #history, 1, -1 do
    if history[i] == text then table.remove(history, i) end
  end
  table.insert(history, 1, text)
  while #history > 50 do table.remove(history) end
  fuzzy_searcher.save_prompt_history()
end

function fuzzy_searcher.restored_prompt_text(text)
  local leading_mode, query = split_mode_prefix(text)
  if query ~= "" then return text, false end
  local mode = leading_mode ~= "" and leading_mode or fuzzy_searcher.prompt_mode(text)
  if mode == "" then return "", false end
  if mode == "@" then return "@", false end
  if mode == "!" then return "!", false end
  local latest = fuzzy_searcher.prompt_history_for_mode(mode)[1]
  if latest ~= nil then return latest, true end
  return text, false
end

local function fuzzy_match(query, text)
  query = trim_query(query)
  text = tostring(text or "")
  if query == "" then return 0, {}, nil, nil end
  local match = fuzzy_native.match(text, query, { mode = "generic", spans = true })
  if not match then return nil end
  return match.score, match.spans or {}, match.selection_span, match.match_start
end

local function fuzzy_match_file_fast(query, text)
  query = trim_query(query)
  text = tostring(text or "")
  if query == "" then return 0, {} end
  local match = fuzzy_native.match(text, query, { mode = "path", spans = true })
  if not match then return nil end
  return match.score, match.spans or {}
end

local line_exists

local function collect_recent_file_matches(query, line)
  local matches, skip_keys = {}, {}
  local empty_query = trim_query(query) == ""

  for _, recent in ipairs(fuzzy_searcher.get_recent_file_entries()) do
    local item = recent.text
    local key = file_result_key(item)
    if key then skip_keys[key] = true end
    local score, spans = 0, {}
    if not empty_query then
      score, spans = fuzzy_match_file_fast(query, item)
    end
    if score and line_exists(item, line) then
      matches[#matches+1] = {
        item = item, text = item, score = score, spans = spans or {},
        last_viewed = recent.last_viewed,
        last_edited = recent.last_edited,
      }
    end
  end

  return matches, skip_keys
end

function fuzzy_searcher.file_match_row(match, query, line, recent)
  local item = match.item
  local file = type(item) == "table" and (item.text or item.file or item.path) or item
  local meta = fuzzy_searcher.files_metadata[file] or (type(item) == "table" and item) or {}
  if meta.is_folder then
    return {
      kind = "folder", label = file, path = meta.abs_path, abs_path = meta.abs_path,
      is_folder = true,
      root_label = meta.root_label,
      root_role = meta.root_role,
      root_id = meta.root_id,
      prefix_span = meta.prefix_span,
      rank_penalty = meta.rank_penalty,
      query = query,
      match_spans = match.spans or {},
    }
  end
  return {
    kind = "file", label = file, file = file,
    abs_path = meta.abs_path,
    root_label = meta.root_label,
    root_role = meta.root_role,
    root_id = meta.root_id,
    prefix_span = meta.prefix_span,
    rank_penalty = meta.rank_penalty,
    line = line or 1, col = 1, query = query,
    match_spans = match.spans or {}, recent = recent or nil,
    last_viewed = match.last_viewed,
    last_edited = match.last_edited,
  }
end

local function build_sectioned_file_results(recent_matches, general_matches, limit, query, line)
  local out = {}
  local shown_recent, shown_general = 0, 0
  limit = math.max(0, limit or 0)

  for _, match in ipairs(recent_matches or {}) do
    if #out >= limit then break end
    out[#out+1] = fuzzy_searcher.file_match_row(match, query, line, true)
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
      out[#out+1] = fuzzy_searcher.file_match_row(match, query, line, false)
      shown_general = shown_general + 1
    end
  end

  local hidden_recent = shown_recent < #(recent_matches or {})
  local hidden_general = shown_general < #(general_matches or {})
  return out, hidden_recent or hidden_general
end

function fuzzy_searcher.file_rank_penalty(item)
  if type(item) == "table" and item.rank_penalty ~= nil then
    return tonumber(item.rank_penalty) or 0
  end
  local text = type(item) == "table" and item.text or item
  local meta = text and fuzzy_searcher.files_metadata[text]
  return tonumber(meta and meta.rank_penalty) or 0
end

function fuzzy_searcher.adjusted_file_score(score, item)
  return (tonumber(score) or 0) - fuzzy_searcher.file_rank_penalty(item)
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
  buffer=true, docx=true, xls=true, xlsx=true, ppt=true, pptx=true,
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

local function decorate_grep_result(result, root)
  if not result then return nil end
  local filename = common.normalize_path(result.file)
  local abs = filename and common.is_absolute_path(filename)
    and filename
    or common.normalize_path(root .. PATHSEP .. tostring(result.file or ""))
  if not abs then return nil end
  local display = project_paths.display_path(abs, { kind = "grep" })
  if display then
    if display.rank_penalty == math.huge then return nil end
    result.file = display.text
    result.abs_path = display.abs_path
    result.root_label = display.root_label
    result.root_role = display.root_role
    result.root_id = display.root_id
    result.prefix_span = display.prefix_span
    result.rank_penalty = display.rank_penalty
  else
    result.file = abs
    result.abs_path = abs
  end
  return result
end

local function scope_for_root(scope, root)
  if not scope then return nil end
  local out = {}
  for _, filename in ipairs(scope) do
    local abs = fullpath(filename)
    if abs and (common.path_equals(abs, root) or common.path_belongs_to(abs, root)) then
      out[#out + 1] = common.relative_path(root, abs)
    end
  end
  return out
end

local function scope_key(scope)
  if not scope then return "*" end
  return table.concat(scope, "\0")
end

local function fuzzy_job_key(root, scope, seed, include_ignored)
  return root .. "\0" .. scope_key(scope) .. "\0"
    .. (include_ignored and "ignored" or "default") .. "\0" .. seed:lower()
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

local function ensure_fuzzy_grep_job(root, scope, tokens, include_ignored)
  if not tokens or #tokens == 0 then return nil end

  -- Prefer reusing an already-warm broader stream when the user appends tokens,
  -- e.g. #word -> #word test. Also start the most selective stream in the
  -- background if it differs, so future filtering can switch to it.
  local preferred_seed = seed_for_tokens(tokens)
  local reusable
  for _, tok in ipairs(tokens) do
    local existing = fuzzy_grep_jobs[fuzzy_job_key(root, scope, tok, include_ignored)]
    if existing then reusable = existing; break end
  end

  local function start_job(seed)
    local key = fuzzy_job_key(root, scope, seed, include_ignored)
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

    job.thread_key = core.add_thread(function()
      core.log_quiet(
        "Fuzzy grep batch started seed=%s files=%s",
        tostring(seed), scope and tostring(#scope) or "all"
      )
      local args = { fuzzy_searcher.rg, "--vimgrep", "--color", "never", "-i", "-F" }
      project_files.add_filter_arguments(args, include_ignored)
      args[#args + 1], args[#args + 2] = "-e", seed
      if scope then
        args[#args+1] = "--"
        for _, f in ipairs(scope) do args[#args+1] = f end
      else
        args[#args + 1] = "."
      end
      local proc = process.start(args, { cwd = root, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_DISCARD, stdin = process.REDIRECT_DISCARD })
      job.proc = proc
      if not proc then
        job.done = true
        job.version = job.version + 1
        for thread_key in pairs(job.wake_threads or {}) do core.wake_thread(thread_key) end
        return
      end

      local max_scanned = fuzzy_searcher.fuzzy_scan_limit or 10000
      local max_line_chars = fuzzy_searcher.fuzzy_line_max_chars or 1200
      local slice_start = system.get_time()
      while not job.cancelled and job.scanned < max_scanned do
        local ok, line_or_error = pcall(
          proc.stdout.read, proc.stdout, "line", { scan = 0.001, timeout = 0.1 }
        )
        if ok and line_or_error then
          job.scanned = job.scanned + 1
          local r = decorate_grep_result(parse_vimgrep(line_or_error), root)
          if r and #(r.text or "") <= max_line_chars then
            local key = r.file .. ":" .. tostring(r.line)
            if not job.seen[key] then
              job.seen[key] = true
              job.lines[#job.lines+1] = r
              job.version = job.version + 1
              for thread_key in pairs(job.wake_threads or {}) do core.wake_thread(thread_key) end
            end
          end
          slice_start = yield_if_over_budget(slice_start)
        elseif not ok and not tostring(line_or_error):find("timeout expired", 1, true) then
          core.log_quiet("Fuzzy grep read failed under %s: %s", tostring(root), tostring(line_or_error))
          break
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
      for thread_key in pairs(job.wake_threads or {}) do core.wake_thread(thread_key) end
      core.log_quiet(
        "Fuzzy grep batch finished seed=%s files=%s lines=%d truncated=%s",
        tostring(seed), scope and tostring(#scope) or "all", job.scanned, tostring(job.truncated)
      )
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

function PreviewTextView:get_font()
  return style.get_small_font(TextView.get_font(self))
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
  renderer.draw_rect(x, y, w, h, style.search_selection_secondary)
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
  local target = picker and {
    path = picker.source_file_path,
    line = picker.source_file_line,
  } or file_context.view_path_target(core.active_view)
  local path = target and target.path

  local preview
  if name == "editor:copy_absolute_filepath" then
    preview = path
  elseif name == "editor:copy_absolute_filepath_with_line" then
    local line = target and target.line or 1
    preview = path and string.format("%s:%d", path, line or 1)
  elseif name == "editor:copy_relative_filepath" then
    local root = core.root_project and core.root_project()
    local root_path = root and common.normalize_path(root.path)
    if path and root_path and common.path_belongs_to(path, root_path) then
      preview = common.relative_path(root_path, path):gsub("\\", "/")
    elseif path then
      preview = "not inside project"
    end
  elseif name == "editor:copy_project_path" then
    local project = core.root_project and core.root_project()
    preview = project and project.path
  elseif name == "editor:copy_filename" then
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

local function command_status_parts(name, picker)
  picker = picker or current_picker()
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
    return r.label or r.command or "", r.match_spans or {}, ""
  end
  if r.kind == "shell_command" then
    return r.label or "Run shell command", {}, "! "
  end
  if r.kind == "project" then
    local text = r.label or r.project or ""
    return display_root(text), r.match_spans or {}, "@ "
  end
  if r.kind == "symbol" then
    local text = r.label or r.name or ""
    local prefix = r.symbol_scope == "buffer" and "$$ " or "$ "
    return prefix .. text, offset_spans(r.match_spans or {}, #prefix)
  end
  local text = r.label or r.file or ""
  return text, r.match_spans or {}
end

function fuzzy_searcher.result_main_text(r)
  if not r then return nil end
  local text
  if r.kind == "grep" then
    text = r.text or r.label or r.file
  elseif r.kind == "command" then
    text = r.label or r.command
  elseif r.kind == "symbol" then
    text = r.label or r.name
  elseif r.kind == "project" or r.kind == "new_project" then
    text = r.project or r.label
  elseif r.kind == "path" or r.kind == "create_path" then
    text = r.path or r.project or r.file or r.label
  elseif r.kind == "file" then
    text = r.file or r.label
  else
    text = r.label or r.text or r.file or r.path or r.project or r.name or r.command
  end
  text = text and tostring(text) or nil
  if text == "" then return nil end
  return text
end

function fuzzy_searcher.project_result_font(font)
  return style.prose_font:get_size() == font:get_size()
    and style.prose_font or style.get_scaled_font(style.prose_font, font:get_size())
end

local function merge_folder_matches(matches, query, line, limit)
  if line then return matches, 0 end
  query = fuzzy_searcher.path_match_query(query)
  local index = fuzzy_searcher.folders_fuzzy_index
  if not index then
    local matched = 0
    for _, folder in ipairs(fuzzy_searcher.folders_cache or {}) do
      local score, spans = fuzzy_match_file_fast(query, folder.text)
      if score then
        matched = matched + 1
        fuzzy_insert_top(matches, {
          item = folder,
          text = folder.text,
          score = fuzzy_searcher.adjusted_file_score(score, folder),
          spans = spans or {},
        }, limit)
      end
    end
    return matches, matched, matched > limit
  end
  local search_limit = math.min(
    #(fuzzy_searcher.folders_cache or {}), math.max(limit + 64, limit)
  )
  local results = index:search(query, { limit = search_limit, spans = true })
  for _, result in ipairs(results) do
    local folder = fuzzy_searcher.files_metadata[result.text]
    if folder and folder.is_folder then
      fuzzy_insert_top(matches, {
        item = folder,
        text = folder.text,
        score = fuzzy_searcher.adjusted_file_score(result.score or 0, folder),
        spans = result.spans or {},
      }, limit)
    end
  end
  return matches, #results, results.has_more == true
end

function fuzzy_searcher.command_search_text(name)
  local metadata = command.get_metadata(name)
  local parts = { name }
  for _, keyword in ipairs(metadata and metadata.keywords or {}) do
    parts[#parts + 1] = keyword
  end
  return table.concat(parts, " ")
end

local function draw_project_result_row(font, r, x, y, width)
  local label, spans, prefix = result_list_label_and_spans(r)
  local project_font = fuzzy_searcher.project_result_font(font)
  local age = r.opened_at and compact_age(r.opened_at)
  local gap = style.padding.x
  local label_w = width
  if age and age ~= "" then
    local age_w = font:get_width(age)
    renderer.draw_text(font, age, x + width - age_w, y, style.dim)
    label_w = math.max(0, width - age_w - gap)
  end
  local cx = renderer.draw_text(font, prefix, x, y, style.dim)
  local project_y = y + math.max(0, math.floor((font:get_height() - project_font:get_height()) / 2))
  draw_highlighted_text(project_font, label, cx, project_y, math.max(0, x + label_w - cx), style.text, spans)
end

function fuzzy_searcher.draw_recent_file_metadata(font, r, x, y, width)
  local recent_file_icons = require "core.recent_file_icons"
  local metadata_font = style.get_small_font(font)
  local metadata_y = y + math.max(0, math.floor((font:get_height() - metadata_font:get_height()) / 2))
  local parts = {}
  local edited = fuzzy_searcher.format_recent_file_age(r.last_edited)
  local viewed = fuzzy_searcher.format_recent_file_age(r.last_viewed)
  if edited then parts[#parts+1] = { icon = "pencil", text = edited } end
  if viewed then parts[#parts+1] = { icon = "eye", text = viewed } end
  if #parts == 0 then return width end

  local row_height = metadata_font:get_height()
  local icon_size = recent_file_icons.size_for_row(row_height)
  local icon_gap = math.max(2 * (SCALE or 1), style.padding.x / 4)
  local separator = "  ·  "
  local separator_w = metadata_font:get_width(separator)
  local metadata_w = (#parts - 1) * separator_w
  for _, part in ipairs(parts) do
    part.cell_width = metadata_font:get_width(part.text)
    metadata_w = metadata_w + icon_size + icon_gap + part.cell_width
  end

  local outer_gap = style.padding.x
  if metadata_w + outer_gap >= width then return width end
  local cx = x + width - metadata_w
  for index, part in ipairs(parts) do
    if index > 1 then cx = renderer.draw_text(metadata_font, separator, cx, metadata_y, style.dim) end
    recent_file_icons.draw(part.icon, cx, metadata_y, row_height, icon_size)
    cx = cx + icon_size + icon_gap
    renderer.draw_text(metadata_font, part.text, cx, metadata_y, style.dim)
    cx = cx + part.cell_width
  end
  return math.max(0, width - metadata_w - outer_gap)
end

local function draw_new_project_result_row(font, r, x, y, width)
  local prefix = "Open this new folder as project: "
  local cx = renderer.draw_text(font, prefix, x, y, style.dim)
  local project_font = fuzzy_searcher.project_result_font(font)
  local project_y = y + math.max(0, math.floor((font:get_height() - project_font:get_height()) / 2))
  draw_highlighted_text(project_font, r.project or r.label or "", cx, project_y, math.max(0, x + width - cx), style.text, {})
end

local draw_file_result_row
local grep_row_columns

function fuzzy_searcher.grep_enclosing_symbol(result)
  if not result or not result.abs_path then return nil end
  if result.enclosing_symbol_checked then return result.enclosing_symbol end
  local line = tonumber(result.line) or 1
  local col = tonumber(result.col or result.content_match_start) or 1
  local symbol_index = require "core.treesitter.symbol_index"
  local symbol, reason = symbol_index.enclosing_symbol(result.abs_path, line, col, {
    kinds = { "function", "method" },
  })
  if reason ~= "indexing" and reason ~= "overlay-indexing" and reason ~= "index-unavailable" then
    result.enclosing_symbol_checked = true
    result.enclosing_symbol = symbol
  end
  if symbol and symbol.name and symbol.name ~= "" then return symbol end
end

function fuzzy_searcher.symbol_declaration_text(symbol, include_suffix)
  if include_suffix == nil then include_suffix = true end
  local declaration = tostring(symbol and symbol.declaration or "")
  if declaration ~= "" and symbol.declaration_name_span then
    if include_suffix then return declaration end
    local name_end = math.min(#declaration, tonumber(symbol.declaration_name_span[2]) or 0)
    if name_end > 0 then return declaration:sub(1, name_end) end
  end
  local label = tostring(symbol and (symbol.label or symbol.name) or "")
  local signature = tostring(symbol and symbol.signature or "")
  return include_suffix and signature ~= "" and (label .. " " .. signature) or label
end

function fuzzy_searcher.draw_symbol_declaration(font, symbol, x, y, width, name_spans, include_suffix)
  if include_suffix == nil then include_suffix = true end
  local declaration = tostring(symbol and symbol.declaration or "")
  if declaration ~= "" and symbol.declaration_name_span then
    local name_start = math.max(1, tonumber(symbol.declaration_name_span[1]) or 1)
    local name_end = math.min(#declaration, tonumber(symbol.declaration_name_span[2]) or 0)
    if name_start <= name_end then
      local before = declaration:sub(1, name_start - 1)
      local name = declaration:sub(name_start, name_end)
      local after = include_suffix and declaration:sub(name_end + 1) or ""
      local right = x + width
      local cx = x
      local name_width = font:get_width(name)
      local before_width = math.min(font:get_width(before), math.max(0, width - name_width))
      if before_width > 0 then
        cx = renderer.draw_text(font, truncate_text(font, before, before_width), cx, y, style.dim)
      end
      if cx < right then
        cx = draw_highlighted_text(font, name, cx, y, math.max(0, right - cx), style.text, name_spans or {})
      end
      if after ~= "" and cx < right then
        cx = renderer.draw_text(font, truncate_text(font, after, right - cx), cx, y, style.dim)
      end
      return cx
    end
  end

  local label = tostring(symbol and (symbol.label or symbol.name) or "")
  local signature = include_suffix and tostring(symbol and symbol.signature or "") or ""
  local signature_text = signature ~= "" and (" " .. signature) or ""
  local signature_width = math.min(width * 0.55, font:get_width(signature_text))
  local label_width = math.max(0, width - signature_width)
  local cx = draw_highlighted_text(font, label, x, y, label_width, style.text, name_spans or {})
  if signature_width > 0 and cx < x + width then
    cx = renderer.draw_text(font, truncate_text(font, signature_text, x + width - cx), cx, y, style.dim)
  end
  return cx
end

function fuzzy_searcher.draw_grep_symbol_context(font, symbol, x, y, width, row_height)
  if not symbol or width <= 0 then return 0 end
  local symbol_icons = require "core.symbol_icons"
  local context_font = style.get_small_font(font)
  local context_y = y + math.max(0, math.floor((row_height - context_font:get_height()) / 2))
  local icon_size = symbol_icons.size_for_row(row_height)
  local icon_gap = math.max(3 * (SCALE or 1), style.padding.x / 3)
  local declaration = fuzzy_searcher.symbol_declaration_text(symbol, false)
  local icon_width = symbol_icons.resolve_kind(symbol.kind or "symbol") and icon_size or 0
  local content_gap = icon_width > 0 and icon_gap or 0
  local declaration_width = math.min(
    context_font:get_width(declaration), math.max(0, width - icon_width - content_gap)
  )
  local content_width = icon_width + content_gap + declaration_width
  local cx = x + math.max(0, width - content_width)
  if icon_width > 0 then
    symbol_icons.draw(symbol.kind or "symbol", cx, y, row_height, icon_size)
    cx = cx + icon_width + content_gap
  end
  fuzzy_searcher.draw_symbol_declaration(
    context_font, symbol, cx, context_y, declaration_width, {}, false
  )
  return content_width
end

function fuzzy_searcher.file_result_filename_width(font, file, prefix, suffix, show_file_icon)
  file = tostring(file or "")
  prefix = tostring(prefix or "")
  suffix = tostring(suffix or "")
  local row_height = font:get_height()
  local marker_width = math.max(1, style.gitdiff_width or (2 * (SCALE or 1)))
  local marker_gap = math.max(2 * (SCALE or 1), style.padding.x / 4)
  local icon_width = show_file_icon and fuzzy_searcher.file_icons.column_width(row_height) or 0
  local file_font = style.prose_font:get_size() == font:get_size()
    and style.prose_font or style.get_scaled_font(style.prose_font, font:get_size())
  local name = basename(file)
  local directory_gap = #file > #name and (SCALE or 1) or 0
  return marker_width + marker_gap + icon_width + font:get_width(prefix)
    + file_font:get_width(name) + font:get_width(suffix) + directory_gap
end

local function draw_symbol_result_row(font, r, x, y, width, row_height)
  local symbol_icons = require "core.symbol_icons"
  local icon_size = symbol_icons.size_for_row(row_height)
  local icon_column_width = 0
  if symbol_icons.resolve_kind(r.symbol_kind or "symbol") then
    icon_column_width = icon_size + math.max(4 * (SCALE or 1), style.padding.x / 2)
    symbol_icons.draw(r.symbol_kind or "symbol", x, y, row_height, icon_size)
  end

  x = x + icon_column_width
  width = math.max(0, width - icon_column_width)
  local path_w, gap, text_w = grep_row_columns(width)
  local line = tonumber(r.line) or 1
  local line_suffix = line <= 9999 and string.format(":%-4d", line) or ":" .. tostring(line)
  local prefix = r.symbol_scope == "buffer" and "$$ " or "$ "
  draw_file_result_row(font, r.file or "", r.file_spans, prefix, x, y, path_w, line_suffix, r.prefix_span, r.root_role)
  if text_w <= 0 then return end

  local preview_font = style.get_small_font(font)
  local preview_y = y + math.max(0, math.floor((font:get_height() - preview_font:get_height()) / 2))
  local text_x = x + path_w + gap
  fuzzy_searcher.draw_symbol_declaration(
    preview_font, r, text_x, preview_y, text_w, r.match_spans or {}
  )
end

local function draw_path_result_row(font, r, x, y, width)
  local gap = style.padding.x
  local metadata_font = style.get_small_font(font)
  local metadata_y = y + math.max(0, math.floor((font:get_height() - metadata_font:get_height()) / 2))
  local icon_column_width = fuzzy_searcher.file_icons.column_width(font:get_height())
  if r.create_path then
    renderer.draw_text(style.icon_font, "]", x, y, style.good)
  elseif r.is_folder then
    local icon_color = r.path_search and style.fuzzy_searcher_recent_project_icon or style.accent
    renderer.draw_text(style.icon_font, r.path_search and "B" or "d", x, y, icon_color)
  else
    fuzzy_searcher.file_icons.draw(r.path or r.label, x, y, font:get_height())
  end
  local path_x = x + icon_column_width
  local path_end = draw_file_result_row(
    font, r.label or r.path, r.match_spans, "",
    path_x, y, math.max(0, width - icon_column_width), nil, nil, nil, false
  )
  path_end = math.min(x + width, path_end or path_x)

  local marker_width = math.max(1, style.gitdiff_width or (2 * (SCALE or 1)))
    + math.max(2 * (SCALE or 1), style.padding.x / 4)
  r._path_copy_x = path_x + marker_width
  r._path_copy_width = math.max(0, path_end - r._path_copy_x)

  local available = math.max(0, x + width - path_end - gap)
  if available <= 0 then return end

  local details = {}
  if r.size_label and r.size_label ~= "" then details[#details+1] = r.size_label end
  if r.modified_label and r.modified_label ~= "" then details[#details+1] = r.modified_label end
  local detail_text = #details > 0 and table.concat(details, "  ") or ""
  local detail_display = truncate_text(metadata_font, detail_text, available)
  local metadata_width = metadata_font:get_width(detail_display)
  local mx = x + width - metadata_width
  if detail_display ~= "" then
    renderer.draw_text(metadata_font, detail_display, mx, metadata_y, style.dim)
  end
end

local function draw_command_result_row(font, r, x, y, width)
  local label, spans, prefix = result_list_label_and_spans(r)
  local binding, preview = command_preview_parts(r.command)
  local row_height = font:get_height()
  local icon_column_width = row_height + math.max(2 * (SCALE or 1), style.padding.x / 3)
  local command_prefix = r.command and r.command:match("^([a-z][a-z0-9_]*):")
  local icon = view_icons.get(command_prefix)
  if icon then
    local icon_width = view_icons.width(icon, row_height)
    local icon_x = x + math.floor((row_height - icon_width) / 2)
    view_icons.draw(icon, icon_x, y, row_height)
    local metadata = command.get_metadata(r.command)
    if metadata and metadata.opens_view then
      view_icons.draw_opener_badge(icon_x, y, icon_width, row_height)
    end
  end
  x = x + icon_column_width
  width = math.max(0, width - icon_column_width)
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

local function project_path_prefix_color(role)
  if role == "external" then return style.project_path_external end
  if role == "vendored" then return style.project_path_vendored end
  return style.project_path_external
end

draw_file_result_row = function(font, file, spans, prefix, x, y, width, suffix, prefix_span, root_role, show_file_icon, git_kind)
  file = tostring(file or "")
  spans = spans or {}
  prefix = prefix or ""
  suffix = suffix or ""

  local row_height = font:get_height()
  local marker_width = math.max(1, style.gitdiff_width or (2 * (SCALE or 1)))
  local marker_gap = math.max(2 * (SCALE or 1), style.padding.x / 4)
  local marker_column_width = marker_width + marker_gap
  local marker_color = path_tree.git_gutter_color(git_kind or fuzzy_searcher.git_kind_for_file(file))
  if marker_color then renderer.draw_rect(x, y, marker_width, row_height, marker_color) end
  x = x + marker_column_width
  width = math.max(0, width - marker_column_width)

  if show_file_icon then
    local icon_column_width = fuzzy_searcher.file_icons.column_width(row_height)
    fuzzy_searcher.file_icons.draw(file, x, y, row_height)
    x = x + icon_column_width
    width = math.max(0, width - icon_column_width)
  end

  local file_font = style.prose_font:get_size() == font:get_size()
    and style.prose_font or style.get_scaled_font(style.prose_font, font:get_size())
  local path_font = style.get_small_font(file_font)
  local prefix_color = style.dim
  local dir_color = style.dim
  local suffix_color = style.dim
  local name_color = style.text
  local line_h = font:get_height()
  local name_y = y + math.max(0, math.floor((line_h - file_font:get_height()) / 2))
  local path_y = y + math.max(0, math.floor((line_h - path_font:get_height()) / 2))

  local cx = renderer.draw_text(font, prefix, x, y, prefix_color)
  local right = x + width
  local available = math.max(0, right - cx)
  if available <= 0 then return cx end

  local name = basename(file)
  local dir = file:sub(1, math.max(0, #file - #name))
  local name_start = #dir + 1
  local name_spans = project_spans(spans, name_start, #file, 0)
  local project_prefix = nil
  local project_rest = dir
  if type(prefix_span) == "table" and prefix_span[1] == 1 and prefix_span[2] and prefix_span[2] <= #dir then
    project_prefix = dir:sub(prefix_span[1], prefix_span[2])
    project_rest = dir:sub(prefix_span[2] + 1)
  end
  local suffix_width = suffix ~= "" and font:get_width(suffix) or 0

  local name_width = file_font:get_width(name)
  if dir ~= "" then
    local scale = SCALE or 1
    local min_name_width = math.min(name_width, math.max(48 * scale, available * 0.55))
    local dir_width = name_width + suffix_width < available
      and available - name_width - suffix_width
      or math.max(0, available - min_name_width - suffix_width)
    if dir_width > path_font:get_width("...") then
      if project_prefix then
        local prefix_w = path_font:get_width(project_prefix)
        if prefix_w < dir_width then
          local prefix_spans = project_spans(spans, 1, #project_prefix, 0)
          cx = draw_highlighted_text(path_font, project_prefix, cx, path_y, prefix_w, project_path_prefix_color(root_role), prefix_spans)
          local rest_spans = project_spans(spans, #project_prefix + 1, #dir, 0)
          cx = draw_highlighted_text(path_font, project_rest, cx, path_y, math.max(0, dir_width - prefix_w), dir_color, rest_spans)
        else
          local dir_spans = project_spans(spans, 1, #dir, 0)
          cx = draw_highlighted_text(path_font, dir, cx, path_y, dir_width, dir_color, dir_spans)
        end
      else
        local dir_spans = project_spans(spans, 1, #dir, 0)
        cx = draw_highlighted_text(path_font, dir, cx, path_y, dir_width, dir_color, dir_spans)
      end
      available = math.max(0, right - cx)
    end
  end

  local name_available = suffix_width > 0 and math.max(0, available - suffix_width) or available
  cx = draw_highlighted_text(file_font, name, cx, name_y, name_available, name_color, name_spans)
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
  local symbol = fuzzy_searcher.grep_enclosing_symbol(result)
  local context_width = 0
  local context_gap = math.max(8 * (SCALE or 1), style.padding.x * 2)
  local prefix = result.exact and "# " or "~# "
  local line = tonumber(result.line) or 1
  local line_suffix = line <= 9999 and string.format(":%-4d", line) or ":" .. tostring(line)
  if symbol then
    local context_font = style.get_small_font(font)
    local symbol_icons = require "core.symbol_icons"
    local icon_width = symbol_icons.resolve_kind(symbol.kind or "symbol")
      and symbol_icons.size_for_row(font:get_height()) or 0
    local icon_gap = icon_width > 0 and math.max(3 * (SCALE or 1), style.padding.x / 3) or 0
    local desired = icon_width + icon_gap
      + context_font:get_width(fuzzy_searcher.symbol_declaration_text(symbol, false))
    local file_width = fuzzy_searcher.file_result_filename_width(
      font, result.file, prefix, line_suffix, true
    )
    local max_context = math.max(0, path_w - file_width - context_gap)
    local min_context = icon_width + icon_gap
      + context_font:get_width(tostring(symbol.name or ""))
    context_width = math.min(desired, max_context)
    if context_width < min_context then symbol = nil; context_width = 0 end
  end
  local file_width = math.max(0, path_w - (symbol and context_width + context_gap or 0))
  local line_x = collapsed_line_x
  if collapse_file then
    line_x = common.clamp(line_x or x, x, x + file_width)
    renderer.draw_text(font, truncate_text(font, line_suffix, math.max(0, x + file_width - line_x)), line_x, y, style.dim)
  else
    local _end_x
    _end_x, line_x = draw_file_result_row(
      font, result.file or "", result.file_spans, prefix, x, y, file_width,
      line_suffix, result.prefix_span, result.root_role, true
    )
  end
  if symbol then
    fuzzy_searcher.draw_grep_symbol_context(
      font, symbol, x + path_w - context_width, y, context_width, font:get_height()
    )
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

fuzzy_searcher.grep_order = {
  PATH_NONE = 0,
  PATH_LOOSE = 1,
  PATH_COMPACT = 2,
  PATH_CONTIGUOUS = 3,
  SAME_FILE_SCORE_SLACK = 500,
  SAME_FILE_MAX_BURST = 6,
}

function fuzzy_searcher.grep_order.path_match_class(query, text)
  query = trim_query(query)
  if query == "" then return fuzzy_searcher.grep_order.PATH_NONE end
  text = tostring(text or "")
  local match = fuzzy_native.match(text, query, { mode = "path" })
  if not match or match.match_class == "loose" then return fuzzy_searcher.grep_order.PATH_LOOSE end
  if match.match_class == "contiguous" then return fuzzy_searcher.grep_order.PATH_CONTIGUOUS end
  return fuzzy_searcher.grep_order.PATH_COMPACT
end

local function build_scope(base, line, max_count)
  if base:sub(1, 1) == ">" then base = "" end
  local limit = max_count or 200
  local list = {}
  local meta = {
    by_path = {},
    has_more = false,
    indexing = fuzzy_searcher.files_indexing,
    query = base,
    limit = limit,
  }
  local function add_match(item, score)
    local text = type(item) == "table" and item.text or item
    if type(item) == "table" then adopt_native_file_match(item) end
    local abs = fullpath(item)
    local key = abs and common.path_compare_key(abs)
    if not key then return end
    local rank_penalty = fuzzy_searcher.file_rank_penalty(item)
    if rank_penalty == math.huge then return end
    list[#list+1] = abs
    meta.by_path[key] = {
      score = (tonumber(score) or 0) - rank_penalty,
      match_class = fuzzy_searcher.grep_order.path_match_class(base, text),
      text = text,
    }
  end
  if native_file_index_ready() then
    local ok, matches = pcall(function()
      return fuzzy_searcher.files_fuzzy_index:search(base, {
        limit = line and math.max(limit * 10, 1000) or limit,
        spans = false,
      })
    end)
    if ok and matches then
      for _, match in ipairs(matches) do
        if not line or line_exists(match, line) then add_match(match, match.score) end
        if #list >= limit then break end
      end
      meta.has_more = matches.has_more == true
      meta.count = #list
      if meta.has_more then
        core.log_quiet("Fuzzy grep scope: query_len=%d limited to %d files", #tostring(base), #list)
      end
      return list, meta
    end
  end

  local matches = fuzzy_filter(get_files(), base, limit + 1)
  if #matches > limit then
    meta.has_more = true
    matches[#matches] = nil
  end
  for _, match in ipairs(matches) do
    local f = match.item
    if (not line) or line_exists(f, line) then add_match(f, match.score) end
  end
  meta.count = #list
  if meta.has_more then
    core.log_quiet("Fuzzy grep scope: query_len=%d limited to %d files", #tostring(base), #list)
  end
  return list, meta
end

function fuzzy_searcher.new_grep_scope_plan(base, line)
  return {
    base = base,
    line = line,
    files = {},
    meta = nil,
    request_limit = 0,
    next_index = 1,
    searched = 0,
    complete = false,
  }
end

function fuzzy_searcher.next_grep_scope_batch(plan)
  while plan.next_index > #plan.files and not plan.complete do
    plan.request_limit = plan.request_limit == 0
      and 400
      or plan.request_limit * 2
    plan.files, plan.meta = build_scope(plan.base, plan.line, plan.request_limit)
    plan.complete = not (plan.meta and plan.meta.has_more)
  end

  if plan.next_index > #plan.files then return nil end

  local batch = {}
  while plan.next_index <= #plan.files and #batch < 400 do
    local path = plan.files[plan.next_index]
    batch[#batch+1] = path
    plan.next_index = plan.next_index + 1
  end
  return batch
end

function fuzzy_searcher.grep_argument_batches(paths)
  local batches, batch, argument_chars = {}, {}, 0
  for _, path in ipairs(paths or {}) do
    local path_chars = #tostring(path) + 3
    if #batch > 0 and argument_chars + path_chars > 7000 then
      batches[#batches+1] = batch
      batch, argument_chars = {}, 0
    end
    batch[#batch+1] = path
    argument_chars = argument_chars + path_chars
  end
  if #batch > 0 then batches[#batches+1] = batch end
  return batches
end

local everything = {
  state = "unknown",
  probe_generation = 0,
  search_generation = 0,
  host = os.getenv("EVERYTHING_HOST") or "localhost",
  port = os.getenv("EVERYTHING_PORT") or "5777",
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
      if view and active_view == view
          and (view:is_path_search() or view.include_ignored) then
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

local function everything_folder_search_query(query)
  query = trim_query(query)
  if query == "" then return query end
  if query:lower():find("folder:", 1, true) then return query end
  return "folder: " .. query
end

local path_search = {}

function path_search.everything_scope_term(scope)
  scope = trim_query(scope)
  if scope == "" then return nil end
  return 'ancestor:"' .. scope:gsub('"', '""') .. '"'
end

function fuzzy_searcher.draw_shell_command_result_row(font, r, x, y, width)
  local label, spans, prefix = result_list_label_and_spans(r)
  local cwd = "Working directory: " .. tostring(r.cwd or "")
  local metadata_w = math.min(width * 0.55, font:get_width(cwd))
  local gap = style.padding.x
  local label_w = math.max(0, width - metadata_w - gap)
  draw_prefixed_highlighted_text(font, prefix, label, x, y, label_w, style.text, spans)
  renderer.draw_text(font, truncate_text(font, cwd, metadata_w), x + label_w + gap, y, style.dim)
end

function path_search.everything_scoped_query(query, scope)
  local scope_term = path_search.everything_scope_term(scope)
  if not scope_term then return query end
  return trim_query(query) == "" and scope_term or (scope_term .. " " .. query)
end

local function everything_folder_search_params(query, count, offset, scope)
  return {
    json = "1",
    search = everything_folder_search_query(path_search.everything_scoped_query(query, scope)),
    count = tostring(count),
    offset = tostring(offset or 0),
    path = "1",
    path_column = "1",
    size_column = "1",
    date_modified_column = "1",
    sort = "path",
    ascending = "1",
  }
end

local function everything_file_search_query(query)
  query = trim_query(query)
  if query == "" then return query end
  if query:lower():find("file:", 1, true) then return query end
  return "file: " .. query
end

local function everything_file_search_params(query, count, offset, scope)
  return {
    json = "1",
    search = everything_file_search_query(path_search.everything_scoped_query(query, scope)),
    count = tostring(count),
    offset = tostring(offset or 0),
    path = "1",
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

local function sort_path_results(results)
  table.sort(results, function(a, b)
    local af = a and a.is_folder and 0 or 1
    local bf = b and b.is_folder and 0 or 1
    if af ~= bf then return af < bf end

    local as = a and tonumber(a.match_score)
    local bs = b and tonumber(b.match_score)
    if as and bs and as ~= bs then return as > bs end
    if as ~= nil and bs == nil then return true end
    if as == nil and bs ~= nil then return false end

    local ap = tostring((a and (a.path or a.label)) or "")
    local bp = tostring((b and (b.path or b.label)) or "")
    local ad, bd = everything_path_depth(ap), everything_path_depth(bp)
    if ad ~= bd then return ad < bd end

    local al, bl = ap:lower(), bp:lower()
    if al ~= bl then return al < bl end
    return ap < bp
  end)
end

function path_search.parent_path(path)
  path = tostring(path or "")
  local trimmed = path:gsub("[/\\]+$", "")
  if PLATFORM == "Windows" and trimmed:match("^%a:$") then
    return trimmed .. PATHSEP
  end
  local parent = trimmed:match("^(.*)[/\\][^/\\]+$")
  if PLATFORM == "Windows" and parent and parent:match("^%a:$") then
    parent = parent .. PATHSEP
  end
  return parent
end

function path_search.relative_to_scope(path, scope)
  if not path or not scope then return path end
  if common.path_equals(path, scope) then return "" end
  if not common.path_belongs_to(path, scope) then return path end
  local start = #scope + 1
  local separator = path:sub(start, start)
  if separator == "/" or separator == "\\" then start = start + 1 end
  return path:sub(start)
end

function path_search.external_path_parts(path)
  local ok, normalized = pcall(common.normalize_path, trim_query(path))
  if not ok or not normalized or not common.is_absolute_path(normalized) then return nil end

  local info = system.get_file_info(normalized)
  if info and info.type == "dir" then
    return { scope = normalized, query = "" }
  end
  if info and info.type == "file" then
    local scope = path_search.parent_path(normalized)
    return { scope = scope, query = common.basename(normalized), exact_file = normalized }
  end

  for index = #normalized, 1, -1 do
    if normalized:sub(index, index):match("%s") then
      local candidate = trim_query(normalized:sub(1, index - 1))
      local candidate_info = common.is_absolute_path(candidate) and system.get_file_info(candidate)
      if candidate_info and candidate_info.type == "dir" then
        return {
          scope = candidate,
          query = trim_query(normalized:sub(index + 1)),
          search_terms = true,
        }
      end
    end
  end

  local scope = path_search.parent_path(normalized)
  while scope and common.is_absolute_path(scope) do
    local scope_info = system.get_file_info(scope)
    if scope_info and scope_info.type == "dir" then
      return { scope = scope, query = path_search.relative_to_scope(normalized, scope) }
    end
    if scope_info then return { blocked = true, query = normalized } end
    local parent = path_search.parent_path(scope)
    if not parent or common.path_equals(parent, scope) then break end
    scope = parent
  end
  return { scope = nil, query = normalized }
end

function path_search.ignored_project_path_parts(query)
  local roots = project_paths.search_roots("files")
  if #roots ~= 1 then return nil end
  local root = common.normalize_path(roots[1].path)
  if not query:find("[/\\]") then
    if everything.state == "unavailable" then return nil end
    return {
      scope = root,
      query = query,
      external = false,
      project_scope = true,
    }
  end
  local ok, path = pcall(common.normalize_path, root .. PATHSEP .. query)
  if not ok or not path or not common.path_belongs_to(path, root) then return nil end
  local parts = path_search.external_path_parts(path)
  if not parts or parts.blocked or not parts.scope then return nil end
  parts.external = false
  parts.project_scope = true
  return parts
end

function path_search.plan(text, options)
  text = tostring(text or "")
  local mode, query = split_mode_prefix(text)
  if mode ~= "" and mode ~= "@" then return { external = false, query = query, mode = mode } end

  query = trim_query(query)
  local explicit = mode == "@"
  if query == "~" or query:match("^~[/\\]") then
    query = common.home_expand(query)
  end
  if not common.is_absolute_path(query) then
    if not explicit then
      while query:match("^%.[/\\]") do query = query:sub(3) end
      query = trim_query(query)
    end
    if options and options.include_ignored and not explicit then
      local parts = path_search.ignored_project_path_parts(query)
      if parts then
        parts.mode = mode
        return parts
      end
    end
    return { external = explicit, explicit = explicit, query = query, mode = mode }
  end

  local display = not explicit and project_paths.display_path(query, { home_encode = false }) or nil
  if display and display.root_role then
    local project_query = display.text == "." and "" or display.text
    return { external = false, query = project_query, project_path = true, mode = mode }
  end

  local parts = path_search.external_path_parts(query) or { query = query }
  if not explicit and parts.scope then
    local scoped_display = project_paths.display_path(parts.scope, { home_encode = false })
    if scoped_display and scoped_display.root_role then
      local prefix = scoped_display.text == "." and "" or scoped_display.text
      local project_query = trim_query(parts.query)
      if prefix ~= "" and project_query ~= "" then project_query = prefix .. " " .. project_query
      elseif prefix ~= "" then project_query = prefix end
      return { external = false, query = project_query, project_path = true, mode = mode }
    end
  end
  parts.external = true
  parts.explicit = explicit
  parts.mode = mode
  parts.input_path = query
  return parts
end

function path_search.direct_result(text, line, col)
  local mode, query = split_mode_prefix(tostring(text or ""))
  if mode ~= "" and mode ~= "@" then return nil end
  query = common.sanitize_prompt_path(query)
  if query == "" then return nil end

  local trailing_separator = query:match("[/\\]$") ~= nil
  local home_relative = query == "~" or query:match("^~[/\\]") ~= nil
  local expanded = home_relative and common.home_expand(query) or query
  local absolute = common.is_absolute_path(expanded)
  local explicit = absolute or home_relative
    or query:match("^%.[/\\]") ~= nil
    or query:match("^%.%.[/\\]") ~= nil
    or query:find("[/\\]", 1) ~= nil
  local ok, path = pcall(common.normalize_path,
    absolute and expanded or (project_dir() .. PATHSEP .. expanded))
  if not ok or not path then return nil end

  local info = system.get_file_info(path)
  if info then
    ensure_recent_project_times()
    local recent, opened_at
    if info.type == "dir" then
      for _, project in ipairs(get_recent_projects()) do
        if common.path_equals(project, path) then
          recent, opened_at = true, recent_project_times[project]
          break
        end
      end
    end
    local label = common.home_encode(path)
    local score, spans = fuzzy_match(query, label)
    return {
      kind = recent and "project" or "path",
      label = label,
      path = path,
      abs_path = path,
      file = info.type == "file" and path or nil,
      project = info.type == "dir" and path or nil,
      is_folder = info.type == "dir",
      exact_path = true,
      path_search = recent or nil,
      opened_at = opened_at,
      query = query,
      line = line,
      col = col,
      match_score = score,
      match_spans = spans or {},
      size_label = info.type == "file" and format_size(info.size) or "",
      modified_label = (recent and compact_age(opened_at))
        or (info.modified and compact_age(info.modified)) or "",
    }
  end

  if not explicit then return nil end
  local parts = path_search.external_path_parts(path)
  if not parts or parts.blocked or parts.search_terms or not parts.scope then return nil end
  return {
    kind = "create_path",
    label = common.home_encode(path),
    path = path,
    abs_path = path,
    is_folder = trailing_separator,
    create_path = true,
    create_type = trailing_separator and "folder" or "file",
    query = query,
    line = line,
    match_spans = {},
    size_label = "",
    modified_label = "",
  }
end

function path_search.prepend_direct(results, direct)
  if not direct then return results end
  local direct_key = common.path_compare_key(direct.abs_path or direct.path)
  local filtered = {}
  for _, result in ipairs(results or {}) do
    local key = common.path_compare_key(result.abs_path or result.path or result.project or result.file)
    if result.header or not direct_key or key ~= direct_key then filtered[#filtered+1] = result end
  end
  local cleaned = { direct }
  for index, result in ipairs(filtered) do
    if not result.header or (filtered[index + 1] and not filtered[index + 1].header) then
      cleaned[#cleaned+1] = result
    end
  end
  return cleaned
end

function path_search.creation_error_label(err)
  local text = tostring(err or ""):lower()
  if text:find("permission", 1, true) or text:find("access is denied", 1, true) then
    return "permission denied"
  end
  if text:find("not a directory", 1, true) or text:find("not a folder", 1, true) then
    return "a parent is not a folder"
  end
  if text:find("no such", 1, true) or text:find("cannot find", 1, true) then
    return "a parent path is unavailable"
  end
  return "filesystem operation failed"
end

local function everything_result_from_item(item, query)
  local path = everything_full_path(item)
  if not path or path == "" then return nil end
  local is_folder = item.type == "folder"
  local modified_time = filetime_to_time(item.date_modified)
  local score, spans = fuzzy_match(query or "", path)
  return {
    kind = "path",
    label = path,
    path = path,
    file = is_folder and nil or path,
    project = is_folder and path or nil,
    is_folder = is_folder,
    query = query,
    match_score = score,
    match_spans = spans or {},
    size_label = is_folder and "" or format_size(item.size),
    modified_label = modified_time and compact_age(modified_time) or "",
  }
end

function FSView:new(prefix, opts)
  opts = opts or {}
  FSView.super.new(self, nil, true) -- floating widget; widget lib owns RootPanel routing
  file_context.exclude_content_view(self)
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
  self.last_files_scope_generation = -1
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
  self.everything_folder_results = {}
  self.everything_file_results = {}
  self.everything_folder_total = 0
  self.everything_file_total = 0
  self.everything_folder_offset = 0
  self.everything_file_offset = 0
  self.everything_folder_has_more = false
  self.everything_file_has_more = false
  self.everything_loading = false
  self.path_search_query_key = nil
  self.everything_status = ""
  self.static_mode = opts.static == true
  self.static_results = opts.results or {}
  self.static_status = opts.status or ""
  self.file_picker = opts.file_picker
  self.loading_feedback_generation = 0
  self.loading_feedback_pending = false
  self.loading_feedback_status = nil
  self.everything_loading_feedback_generation = 0
  self.everything_loading_pending = false
  self.everything_loading_status = nil
  self.include_ignored = false

  local source_view = opts.source_view or core.active_view
  local source_buffer = source_view and source_view.buffer
  local source_target = file_context.view_path_target(source_view)
  self.source_view = file_context.current_content_view(source_view) or source_view
  self.source_pane = opts.source_pane or panes.pane_for_view(source_view) or panes.active()
  self.source_buffer = source_buffer
  self.source_file_path = source_target and source_target.path
  self.source_context_path = file_context.view_context_path(source_view)
  self.source_file_line = source_target and source_target.line
    or source_buffer and source_buffer:get_selection(false)
    or 1
  self.palette_commands = {}
  self.palette_command_set = {}
  for _, name in ipairs(command.get_all_valid()) do
    local metadata = command.get_metadata(name)
    if metadata and metadata.palette == true then
      self.palette_commands[#self.palette_commands + 1] = name
      self.palette_command_set[name] = true
    end
  end
  table.sort(self.palette_commands)

  self.input = TextBox(self, prefix or "", "")
  self.input:set_trailing_text(function()
    return self:search_modifier_text()
  end)
  -- The picker query is a single-line field.  TextView defaults to the global
  -- editor wrapping setting, which can otherwise make long queries wrap in
  -- the input widget instead of scrolling horizontally.
  self.input.textview:set_wrapping_enabled(false)
  local default_input_draw_line_text = self.input.textview.draw_line_text
  function self.input.textview:draw_line_text(line, x, y)
    local text = self.buffer.lines[line] or ""
    local before, mode_marker, after = fuzzy_searcher.split_prompt_mode_marker(text)
    if mode_marker == "" or self.subparent.password then
      return default_input_draw_line_text(self, line, x, y)
    end

    local font = self:get_font()
    local ty = y + self:get_line_text_y_offset()
    local normal_color = style.syntax["normal"] or style.text
    local cx = x
    if before ~= "" then cx = renderer.draw_text(font, before, cx, ty, normal_color) end
    cx = renderer.draw_text(font, mode_marker, cx, ty, style.dim)
    renderer.draw_text(font, after, cx, ty, normal_color)
    return self:get_line_height()
  end
  local cursor_col = #(prefix or "") + 1
  -- When prefix is a grep mode quoted-exact query (e.g. #"text"),
  -- place the cursor before the closing quote so the user can extend the query.
  if (prefix or ""):match('^#".*"$') then cursor_col = cursor_col - 1 end
  self.input.textview.buffer:set_selection(1, cursor_col, 1, cursor_col)
  self.input.border.color = style.dim
  self.input.activate = function(input)
    TextBox.activate(input)
    input.hover_border = style.dim
    input.border.color = input.hover_border
  end
  file_context.exclude_content_view(self.input)
  file_context.exclude_content_view(self.input.textview)
  self.input.on_change = function(_, text)
    if self.static_mode then return end
    if self._applying_prompt_history then return end
    self._prompt_history_session = nil
    self.dirty = true
    self:refresh(text)
    self:schedule_update(true)
  end

  if self.static_mode then
    self.input.textview.buffer.readonly = true
  end

  if not self.static_mode and not self.file_picker and prompt_uses_file_index(prefix) then
    fuzzy_searcher.refresh_file_index_for_picker_open()
  end
  self:show()
  core.root_panel:push_modal_input(self, { label = "fuzzy-searcher" })
  core.root_panel:show_app_overlay(self, "fuzzy_searcher_overlay_background")
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

function FSView:is_path_search()
  if self.static_mode then return false end
  if self.file_picker then return true end
  if self.path_search_active ~= nil then return self.path_search_active end
  local text = self.input and self.input:get_text() or ""
  local mode, query = split_mode_prefix(text)
  if mode == "@" then return true end
  return mode == "" and common.is_absolute_path(trim_query(query))
    and not project_paths.resolve(trim_query(query))
end

function FSView:is_shell_mode()
  if self.static_mode then return false end
  local text = self.input and self.input:get_text() or ""
  return text:sub(1, 1) == "!"
end

function FSView:is_deep_code_mode()
  if self.static_mode then
    local r = self:selected_result()
    return r and (r.kind == "grep" or r.kind == "symbol")
  end
  local mode = fuzzy_searcher.prompt_mode(self.input and self.input:get_text() or "")
  return mode == "#" or mode == "$" or mode == "$$"
end

function FSView:is_full_width_mode()
  return self:is_command_mode() or self:is_shell_mode()
end

function FSView:list_metrics(font)
  font = font or style.code_font
  local pad = style.padding.x
  local row_padding = style.fuzzy_searcher_result_row_padding
  local lh = font:get_height() + row_padding * 2
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  local top = y + self.input.size.y + pad * 3 + lh
  local vertical_preview = self:is_deep_code_mode()
  local list_w = (self:is_full_width_mode() or vertical_preview) and w or w * (1 - fuzzy_searcher.preview_width)
  local available_h = math.max(0, h - (top - y))
  local list_h = available_h
  if vertical_preview then
    list_h = math.max(lh * 5, math.floor(available_h * (fuzzy_searcher.deep_code_results_height or 0.42)))
  end
  local total_rows = math.max(0, math.floor(list_h / lh))
  local result_rows = math.max(1, total_rows - 2) -- first/last rows are scroll indicators
  return {
    x = x, y = y, w = w, h = h, top = top, list_w = list_w, list_h = list_h,
    vertical_preview = vertical_preview,
    lh = lh, row_padding = row_padding, total_rows = total_rows, result_rows = result_rows,
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

function FSView:cancel_deferred_loading_feedback()
  self.loading_feedback_generation = (self.loading_feedback_generation or 0) + 1
  self.loading_feedback_pending = false
  self.loading_feedback_status = nil
end

function FSView:defer_loading_feedback(status, opts)
  opts = opts or {}
  self.loading_feedback_generation = (self.loading_feedback_generation or 0) + 1
  local gen = self.loading_feedback_generation
  self.loading_feedback_pending = true
  self.loading_feedback_status = status

  core.add_thread(function()
    local delay = fuzzy_searcher.loading_feedback_delay or 0.20
    local deadline = system.get_time() + math.max(0, delay)
    while system.get_time() < deadline do
      if gen ~= self.loading_feedback_generation or active_view ~= self then return end
      coroutine.yield(math.min(0.02, math.max(0, deadline - system.get_time())))
    end
    if gen ~= self.loading_feedback_generation or active_view ~= self then return end

    self.loading_feedback_pending = false
    if opts.clear_results ~= false then
      self.results = {}
      self.hovered_result = nil
      if opts.reset_selection then
        self.selected = 1
        self.viewport_offset = 1
      else
        self.selected = common.clamp(self.selected or 1, 1, math.max(1, #(self.results or {})))
        self.viewport_offset = common.clamp(self.viewport_offset or 1, 1, math.max(1, #(self.results or {})))
      end
    end
    if opts.has_more ~= nil then self.has_more = opts.has_more end
    self.status = self.loading_feedback_status or status or self.status
    self.loading_feedback_status = nil
    self:schedule_update(true)
  end)
end

function FSView:set_pending_status(status)
  if self.loading_feedback_pending then
    self.loading_feedback_status = status
  else
    self.status = status
    self:schedule_update(true)
  end
end

function FSView:cancel_deferred_everything_loading()
  self.everything_loading_feedback_generation = (self.everything_loading_feedback_generation or 0) + 1
  self.everything_loading_pending = false
  self.everything_loading_status = nil
end

function FSView:defer_everything_loading(status)
  self.everything_loading_feedback_generation = (self.everything_loading_feedback_generation or 0) + 1
  local gen = self.everything_loading_feedback_generation
  self.everything_loading_pending = true
  self.everything_loading_status = status

  core.add_thread(function()
    local delay = fuzzy_searcher.loading_feedback_delay or 0.20
    local deadline = system.get_time() + math.max(0, delay)
    while system.get_time() < deadline do
      if gen ~= self.everything_loading_feedback_generation or active_view ~= self then return end
      coroutine.yield(math.min(0.02, math.max(0, deadline - system.get_time())))
    end
    if gen ~= self.everything_loading_feedback_generation or active_view ~= self then return end
    self.everything_loading_pending = false
    self.everything_loading = true
    self.everything_status = self.everything_loading_status or status or self.everything_status
    self.everything_loading_status = nil
    self.dirty = true
    self:schedule_update(true)
  end)
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

function FSView:fill_prompt_from_selected()
  if self.static_mode or not self.input then return false end
  local result = self:selected_result()
  local text = fuzzy_searcher.result_main_text(result)
  if not text then return false end

  local before, marker = fuzzy_searcher.split_prompt_mode_marker(self.input:get_text())
  local prefix = marker ~= "" and (before .. marker) or ""
  local prompt = prefix .. text
  self.input:set_text(prompt, false)
  self.input.textview.buffer:set_selection(1, #prefix + 1, 1, #prompt + 1)
  ensure_input_focus(self, "fill-prompt-from-selected")
  core.log_quiet(
    "Fuzzy Searcher: filled prompt from selected %s result (%d bytes)",
    tostring(result.kind or "unknown"),
    #text
  )
  return true
end

function FSView:copy_selected()
  local r = self:selected_result()
  local text = fuzzy_searcher.result_main_text(r)
  if not text then return false end

  system.set_clipboard(text)
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  self.copy_flash = fuzzy_searcher.copy_feedback.start {
    result = r,
    index = self.selected,
    text = text,
  }
  core.log_quiet("Fuzzy Searcher: copied selected %s result text (%d bytes)", tostring(r.kind or "unknown"), #text)
  self:schedule_update(true)
  core.redraw = true
  return true
end

function FSView:text_capture()
  return require("plugins.fuzzy_searcher.text_capture").build(self, {
    result_main_text = fuzzy_searcher.result_main_text,
    format_recent_file_age = fuzzy_searcher.format_recent_file_age,
    prompt_mode = fuzzy_searcher.prompt_mode,
  })
end

function FSView:open_text_capture()
  local capture = self:text_capture()
  local source_pane = self.source_pane or panes.active()
  local result_count = #(self.results or {})
  local query_bytes = #(self.input and self.input:get_text() or "")
  self:close("text-capture")
  local view, err = require("core.text_capture").open(capture, {
    pane = source_pane,
    reason = "fuzzy-searcher-text-capture",
  })
  if not view then
    core.error("Could not open Fuzzy Searcher text: %s", tostring(err or "unknown error"))
    return false
  end
  core.log_quiet(
    "Fuzzy Searcher text capture opened: results=%d query_bytes=%d",
    result_count, query_bytes
  )
  return true
end

function FSView:copy_flash_color(idx)
  local flash = self.copy_flash
  if not flash then return nil end
  local color = fuzzy_searcher.copy_feedback.color(flash, style.fuzzy_searcher_copy_feedback)
  if not color then
    self.copy_flash = nil
    return nil
  end
  if flash.index ~= idx or flash.result ~= self.results[idx] then return nil end
  core.redraw = true
  return color
end

function FSView:copy_flash_bounds(font, r, row_x, row_text_w)
  local flash = self.copy_flash
  local text = flash and flash.text or ""
  local text_font = font
  local x = row_x
  local width = row_text_w

  if r.kind == "grep" or r.kind == "symbol" then
    local path_w, gap = grep_row_columns(row_text_w)
    x = row_x + path_w + gap
    width = math.max(0, row_text_w - path_w - gap)
  elseif r.kind == "command" then
    local icon_column_width = font:get_height()
      + math.max(2 * (SCALE or 1), style.padding.x / 3)
    x = row_x + icon_column_width
    width = math.max(0, row_text_w - icon_column_width)
  elseif r.kind == "folder" or r.kind == "path" or r.kind == "create_path" or r.path_search then
    if r._path_copy_x and r._path_copy_width then
      x = r._path_copy_x
      width = r._path_copy_width
    else
      local icon_w = fuzzy_searcher.file_icons.column_width(font:get_height())
      local marker_w = math.max(1, style.gitdiff_width or (2 * (SCALE or 1)))
        + math.max(2 * (SCALE or 1), style.padding.x / 4)
      x = row_x + icon_w + marker_w
      width = math.max(0, row_text_w - icon_w - marker_w)
    end
    text = r.label or r.path or r.project or r.file or ""
    text_font = fuzzy_searcher.project_result_font(font)
  elseif r.kind == "project" then
    local label, _, prefix = result_list_label_and_spans(r)
    local prefix_w = font:get_width(prefix)
    text = label
    text_font = fuzzy_searcher.project_result_font(font)
    x = row_x + prefix_w
    width = math.max(0, row_text_w - prefix_w)
    local age = r.opened_at and compact_age(r.opened_at)
    if age and age ~= "" then
      width = math.max(0, width - font:get_width(age) - style.padding.x)
    end
  elseif r.kind == "new_project" then
    local prefix = "Open this new folder as project: "
    x = row_x + font:get_width(prefix)
    width = math.max(0, row_text_w - font:get_width(prefix))
    text = r.project or r.label or ""
    text_font = fuzzy_searcher.project_result_font(font)
  end

  local text_w = text_font:get_width(text)
  if text_w > 0 then width = math.min(width, text_w) end
  return x, math.max(0, width)
end

function FSView:preview_bounds()
  local pad = style.padding.x
  local m = self:list_metrics(style.code_font)
  if m.vertical_preview then
    local py = m.top + m.list_h + pad
    return m.x + pad, py, math.max(0, m.w - pad * 2), math.max(0, m.y + m.h - py - pad)
  end
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
  if self:is_preview_focused() then
    self:set_preview_interactive(false)
  end
  if self.preview_view and self.preview_view.buffer then
    if self.preview_view.cancel_horizontal_extent_scan then
      self.preview_view:cancel_horizontal_extent_scan()
    end
    self.preview_view.buffer:clear_search_selections()
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

  if view:extends(TextView) then
    local minline, maxline = view:get_visible_line_range()
    local gw = view:get_gutter_width()
    local tx, ty = view:get_line_screen_position(minline)
    local raw = tostring(view.buffer.lines[minline] or "")
    local utf8 = tostring(view.buffer:get_utf8_line(minline) or "")
    local sample = raw:gsub("\t", "→"):gsub("\n", "⏎")
    local usample = utf8:gsub("\t", "→"):gsub("\n", "⏎")
    local tok = view.buffer.highlighter:get_line(minline).tokens
    lines[#lines+1] = "PREVIEW DEBUG: TextView"
    lines[#lines+1] = string.format("rect=(%.0f,%.0f %.0fx%.0f) view=(%.0f,%.0f %.0fx%.0f)", x, y, w, h, view.position.x, view.position.y, view.size.x, view.size.y)
    lines[#lines+1] = string.format("clip=(%.0f,%.0f %.0fx%.0f) scroll=(%.0f,%.0f -> %.0f,%.0f)", clip[1] or -1, clip[2] or -1, clip[3] or -1, clip[4] or -1, view.scroll.x, view.scroll.y, view.scroll.to.x, view.scroll.to.y)
    lines[#lines+1] = string.format("lines=%d visible=%d..%d target=%s gutter=%.0f text_xy=(%.0f,%.0f) binary=%s", #view.buffer.lines, minline, maxline, tostring(result and result.line), gw, tx, ty, tostring(view.buffer.binary))
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

  local path = fullpath(r)
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
    key = "text:" .. path
  end

  if self.preview_key ~= key then
    self:clear_preview_view()
    if key:sub(1, 6) == "image:" then
      view = ImageView(path, "fit")
    else
      local ok, buffer = pcall(Buffer)
      if ok and buffer then
        buffer.disable_language_services = true
        buffer.disable_treesitter = true
        buffer.disable_gitdiff_highlight = true
        local filename = core.normalize_to_project_dir(path)
        ok = pcall(function()
          buffer:set_filename(filename, path)
          buffer:load(path)
        end)
      end
      if not ok or not buffer then
        self.preview_blocked = { reason = "Cannot open file", path = path }
        return nil
      end
      buffer.read_only = true
      buffer.read_only_reason = "Fuzzy Searcher previews are read-only"
      view = PreviewTextView(buffer)
      view:set_wrapping_enabled(false)
    end
    self.preview_view = view
    self.preview_key = key
  end

  view = self.preview_view
  local px, py, pw, ph = self:preview_bounds()
  view.position.x, view.position.y = px, py
  view.size.x, view.size.y = math.max(0, pw), math.max(0, ph)

  local target = r.line or 1
  if view.buffer then
    target = common.clamp(target, 1, #view.buffer.lines)
    local highlight_key = table.concat({
      r.kind or "", r.grep_query or "", r.fuzzy_query or "", tostring(target),
      tostring(r.col or ""), tostring(r.line2 or ""), tostring(r.col2 or ""), r.text or "",
    }, "\0")
    if self.preview_target_line ~= target or self.preview_highlight_key ~= highlight_key then
      local reveal_col1, reveal_col2
      view:with_selection_state(function()
        view.buffer:clear_search_selections()
        local selections = {}
        local search_ranges = {}
        if r.kind == "grep" then
          for _, span in ipairs(grep_content_spans(view.buffer.lines[target] or "", r, 0, target) or {}) do
            local col1, col2 = span[1], span[2] + 1
            view.buffer:add_search_selection(target, col1, target, col2)
            search_ranges[#search_ranges + 1] = { target, col1, target, col2 }
            if not reveal_col1 then reveal_col1, reveal_col2 = col1, col2 end
            table.insert(selections, target)
            table.insert(selections, col1)
            table.insert(selections, target)
            table.insert(selections, col2)
          end
        elseif r.kind == "symbol" and r.col then
          local line1 = common.clamp(tonumber(r.line) or target, 1, #view.buffer.lines)
          local line2 = common.clamp(tonumber(r.line2) or line1, 1, #view.buffer.lines)
          local col1 = math.max(1, tonumber(r.col) or 1)
          local col2 = math.max(col1 + 1, tonumber(r.col2) or (col1 + #(r.name or r.label or "")))
          view.buffer:add_search_selection(line1, col1, line2, col2)
          search_ranges[#search_ranges + 1] = { line1, col1, line2, col2 }
          reveal_col1, reveal_col2 = col1, col2
          table.insert(selections, line1)
          table.insert(selections, col1)
          table.insert(selections, line2)
          table.insert(selections, col2)
        end
        if #selections > 0 then
          view.buffer:set_selection(selections[1], selections[2], selections[3], selections[4])
          for i = 5, #selections, 4 do
            view.buffer:set_selections(
              math.floor((i - 1) / 4) + 1,
              selections[i], selections[i + 1], selections[i + 2], selections[i + 3],
              nil, 0
            )
          end
          view.buffer.last_selection = 1
        else
          view.buffer:set_selection(target, 1, target, 1)
        end
        view.preview_search_ranges = search_ranges
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
    view:restore_preview_search_ranges()
  end

  call_preview_view_method(view, view.update)
  return view
end

function FSView:update_selected_preview()
  if not self:is_visible() then return nil end
  local result = self:selected_result()
  if (self:is_full_width_mode() and not self:is_deep_code_mode())
    or (result and (result.kind == "command" or result.kind == "project"))
  then
    self:clear_preview_view()
    return nil
  end
  return self:update_preview_view()
end

function FSView:set_preview_interactive(interactive)
  local preview = self.preview_view
  if not (preview and preview:extends(TextView)) then return false end

  interactive = interactive == true
  preview:set_interactive(interactive)
  if interactive then
    self:swap_active_child(nil)
    core.set_active_view(preview)
    preview:restore_preview_search_ranges()
    core.blink_reset()
    core.log_quiet("Fuzzy Searcher preview focused: file=%s",
      tostring(preview.buffer and preview.buffer.abs_filename or "unknown"))
  else
    self.prev_view = self.source_view or self.prev_view
    ensure_input_focus(self, "preview-focus-input")
  end
  self:schedule_update(true)
  return true
end

function FSView:is_preview_focused()
  return self.preview_view ~= nil and core.active_view == self.preview_view
end

function FSView:cycle_local_focus(step)
  if not (self.preview_view and self.preview_view:extends(TextView)) then
    self:update_selected_preview()
  end
  if not (self.preview_view and self.preview_view:extends(TextView)) then return false end
  return self:set_preview_interactive(not self:is_preview_focused())
end

-- Treat the floating overlay as a modal surface for mouse routing: while it is
-- open, editor hover/click/wheel events behind it should not leak through.
function FSView:mouse_on_top(x, y)
  return self:is_visible()
end

function FSView:on_modal_key_pressed(key, ...)
  if modal_modkey_map[key] then return "keymap" end

  local stroke = modal_key_to_stroke(key)
  local picker_cmd = modal_picker_command(stroke, self)
  local textbox_cmd = not picker_cmd and modal_textbox_command(stroke)
  if picker_cmd == "pane:focus_local_next" then
    self:cycle_local_focus(1)
  elseif picker_cmd == "pane:focus_local_previous" then
    self:cycle_local_focus(-1)
  elseif self:is_preview_focused() then
    if picker_cmd == "fuzzy:close" then
      command.perform(picker_cmd, ...)
    else
      return "keymap"
    end
  elseif picker_cmd then
    ensure_input_focus(self)
    fuzzy_focus_log("key-picker-command", self,
      "key=" .. tostring(key) .. " stroke=" .. tostring(stroke)
        .. " cmd=" .. tostring(picker_cmd))
    command.perform(picker_cmd, ...)
  elseif textbox_cmd and (not self.static_mode or textbox_cmd == "core:copy") then
    ensure_input_focus(self)
    fuzzy_focus_log("key-textbox-command", self,
      "key=" .. tostring(key) .. " stroke=" .. tostring(stroke)
        .. " cmd=" .. tostring(textbox_cmd))
    command.perform(textbox_cmd, ...)
  elseif modal_should_let_text_input_through(key, stroke) and not self.static_mode then
    ensure_input_focus(self)
    self._awaiting_textinput = {
      time = system.get_time(),
      key = key,
      stroke = stroke,
      text_len = self.input and #(self.input:get_text() or "") or nil,
    }
    return "target"
  else
    fuzzy_focus_log("key-consumed", self,
      "key=" .. tostring(key) .. " stroke=" .. tostring(stroke))
  end
  return true
end

function FSView:on_modal_text_input()
  return "target"
end

function FSView:on_modal_ime_text_editing()
  return "target"
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
    if self:is_preview_focused() then self:set_preview_interactive(false) end
    self.forward_mouse_to_child = true
    return FSView.super.on_mouse_pressed(self, button, x, y, clicks)
  end

  if self:preview_contains(x, y) then
    if not self.preview_view then self:update_preview_view() end
    if not self.preview_view then return true end
    if self.preview_view:extends(TextView) then
      self:set_preview_interactive(true)
      self.preview_mouse_pressed = true
      local handled = call_preview_view_method(
        self.preview_view, self.preview_view.on_mouse_pressed, button, x, y, clicks
      )
      if not handled then keymap.on_mouse_pressed(button, x, y, clicks) end
    elseif self.preview_view:extends(ImageView)
        or self.preview_view:scrollbar_overlaps_point(x, y)
    then
      self.preview_mouse_pressed = true
      call_preview_view_method(
        self.preview_view, self.preview_view.on_mouse_pressed, button, x, y, clicks
      )
    end
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

  if self:is_preview_focused() then
    self:set_preview_interactive(false)
  else
    self:swap_active_child(self.input)
  end
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
    if not self:is_preview_focused() then self:swap_active_child(self.input) end
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
  if self:is_visible() then
    if self:is_preview_focused() then
      self:set_preview_interactive(false)
    else
      self:swap_active_child(self.input)
    end
  end
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
  self.cursor = hovered and "hand" or "arrow"
  core.request_cursor(self.cursor)
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

function FSView:on_modal_mouse_wheel(y, x)
  if scale_mouse_wheel_modkeys_pressed() then return "keymap" end
  return self:on_mouse_wheel(y, x)
end

function FSView:start_file_search(query, line, reset_selection)
  kill_file_search()
  local gen = file_search_generation
  local direct = self.direct_path_result
  local keep_limit = self:max_result_limit() + 1
  local roots_label = fuzzy_searcher.project_roots_label()
  local loading_status = fuzzy_searcher.files_indexing
    and string.format("Indexing files… %d available — %s", file_index_count(), roots_label)
    or string.format("Searching %d files…", file_index_count())
  self:defer_loading_feedback(loading_status, {
    clear_results = not direct and not self.loading_more,
    reset_selection = reset_selection,
    has_more = false,
  })
  if direct then
    self.results = { direct }
    self.has_more = false
    self.selected = 1
    self.viewport_offset = 1
    self:schedule_update(true)
  end

  local function apply_results(out, has_more)
    self:cancel_deferred_loading_feedback()
    out = path_search.prepend_direct(out, direct)
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
    local recent_matches, skip_keys = collect_recent_file_matches(query, line)

    if native_file_index_ready() then
      local ok, native_results = pcall(function()
        return fuzzy_searcher.files_fuzzy_index:search(query, {
          limit = line and math.max(keep_limit * 10, 1000)
            or (keep_limit + #recent_matches + 32),
          spans = true,
        })
      end)
      if ok and native_results and gen == file_search_generation and active_view == self then
        local general_matches = {}
        for _, match in ipairs(native_results) do
          local item = adopt_native_file_match(match)
          local key = file_result_key(match)
          if key and not skip_keys[key] and (not line or line_exists(match, line)) then
            general_matches[#general_matches+1] = {
              item = match, text = item, score = fuzzy_searcher.adjusted_file_score(match.score or 0, match),
              spans = match.spans or {}
            }
            if #general_matches >= keep_limit then break end
          end
        end
        local folder_match_count, folder_has_more
        general_matches, folder_match_count, folder_has_more = merge_folder_matches(
          general_matches, query, line, keep_limit
        )
        table.sort(general_matches, function(a, b) return fuzzy_result_better(a, b) end)
        local out, hidden = build_sectioned_file_results(recent_matches, general_matches, self:result_limit(), query, line)
        local has_more = hidden or native_results.has_more or folder_has_more
        local status
        if #recent_matches + #general_matches == 0 then
          status = fuzzy_searcher.files_indexing
            and string.format("Searching files… refreshing with %d files available — %s",
              file_index_count(), roots_label)
            or string.format("No matching files — %d files + %d folders indexed — %s",
              file_index_count(), folder_index_count(), roots_label)
        else
          status = string.format("%d%s matches found — %d files + %d folders indexed — %s",
            #recent_matches + #general_matches, has_more and "+" or "",
            file_index_count(), folder_index_count(), roots_label)
        end
        if self.loading_feedback_pending and #out == 0 and not has_more and not direct then
          self.loading_feedback_status = status
          return
        end
        apply_results(out, has_more)
        self.status = status
        self:schedule_update(true)
        return
      end
    end

    local items = get_files()
    local general_matches = {}
    local matched_general = 0
    local matched_folders = 0
    local folder_has_more = false
    local scanned = 0
    local empty_query = trim_query(query) == ""
    local slice_start = system.get_time()
    local last_publish = system.get_time()

    local function publish(final)
      if gen ~= file_search_generation or active_view ~= self then return false end
      local out, hidden = build_sectioned_file_results(recent_matches, general_matches, self:result_limit(), query, line)
      local has_more = hidden or folder_has_more
        or matched_general + matched_folders > #general_matches
      local status
      if final then
        local total_matches = #recent_matches + matched_general + matched_folders
        if total_matches == 0 then
          status = fuzzy_searcher.files_indexing
            and string.format("Searching files… refreshing with %d files available — %s",
              file_index_count(), roots_label)
            or string.format("No matching files — %d files + %d folders indexed — %s",
              #items, folder_index_count(), roots_label)
        else
          status = fuzzy_searcher.files_indexing
            and string.format("%d matches — refreshing with %d files available — %s", total_matches, file_index_count(), roots_label)
            or string.format("%d matches — %d files + %d folders indexed — %s",
              total_matches, #items, folder_index_count(), roots_label)
        end
      elseif #recent_matches + matched_general == 0 then
        status = string.format("Searching files… scanning %d/%d files…", scanned, #items)
      else
        status = string.format("%d matches — scanning %d/%d files…", #recent_matches + matched_general, scanned, #items)
      end
      if final and self.loading_feedback_pending and #out == 0 and not has_more and not direct then
        self.loading_feedback_status = status
        last_publish = system.get_time()
        return true
      end
      apply_results(out, has_more)
      self.status = status
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
          local candidate = { item = item, text = item, score = fuzzy_searcher.adjusted_file_score(score, item), spans = spans or {} }
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

    general_matches, matched_folders, folder_has_more = merge_folder_matches(
      general_matches, query, line, keep_limit
    )

    publish(true)
  end)
end

function FSView:start_everything_path_search(query, scope, append)
  query = trim_query(query)
  if everything.state ~= "available" then
    core.log_quiet("Fuzzy Path Search: Everything search deferred; state=%s query_len=%d scoped=%s",
      tostring(everything.state), #query, tostring(scope ~= nil))
    probe_everything(self)
    return
  end

  everything.search_generation = everything.search_generation + 1
  local gen = everything.search_generation
  local count = fuzzy_searcher.everything_page_size or 80
  local folder_only = self.file_picker and self.file_picker.select == "folder"
  self.everything_loading = false
  self.everything_pending = folder_only and 1 or 2
  if folder_only then
    self.everything_file_results = {}
    self.everything_file_total = 0
    self.everything_file_offset = 0
    self.everything_file_has_more = false
  end
  self:defer_everything_loading(append and "Loading more Path Search results…" or "Searching Everything…")

  local function request_is_cancelled()
    return gen ~= everything.search_generation or active_view ~= self
  end

  local function finish_request(kind, ok, err, data, info)
    if request_is_cancelled() then return false end
    if not ok or type(data) ~= "table" then
      core.log_quiet("Fuzzy Path Search: Everything %s search failed query_len=%d error=%s status=%s data_type=%s",
        kind, #query, tostring(err), tostring(info and info.status or "unknown"), type(data))
      everything.state = "unavailable"
      everything.search_generation = everything.search_generation + 1
      self.everything_folder_results = {}
      self.everything_file_results = {}
      self.everything_folder_total = 0
      self.everything_file_total = 0
      self.everything_folder_offset = 0
      self.everything_file_offset = 0
      self.everything_folder_has_more = false
      self.everything_file_has_more = false
      self.everything_pending = 0
      self:cancel_deferred_everything_loading()
      self.everything_loading = false
      self.loading_more = false
      self.everything_status = "Everything is unavailable. Showing direct folder contents."
      self.dirty = true
      self:schedule_update(true)
      return false
    end

    local total = tonumber(data.totalResults) or 0
    local out = append and (kind == "folder" and self.everything_folder_results or self.everything_file_results) or {}
    for _, item in ipairs(data.results or {}) do
      local r = everything_result_from_item(item, query)
      local wanted = r and ((kind == "folder" and r.is_folder) or (kind == "file" and not r.is_folder))
      if wanted then out[#out+1] = r end
    end
    sort_path_results(out)
    if kind == "folder" then
      self.everything_folder_results = out
      self.everything_folder_total = total
      self.everything_folder_offset = (append and self.everything_folder_offset or 0) + #(data.results or {})
      self.everything_folder_has_more = self.everything_folder_offset < total
    else
      self.everything_file_results = out
      self.everything_file_total = total
      self.everything_file_offset = (append and self.everything_file_offset or 0) + #(data.results or {})
      self.everything_file_has_more = self.everything_file_offset < total
    end
    self.everything_pending = math.max(0, (self.everything_pending or 1) - 1)
    if self.everything_pending == 0 then
      self:cancel_deferred_everything_loading()
      self.everything_loading = false
      self.loading_more = false
    end
    if folder_only then
      self.everything_status = string.format("%d folders%s",
        #(self.everything_folder_results or {}), self.everything_folder_has_more and "+" or "")
    else
      self.everything_status = string.format("%d folders%s — %d files%s",
        #(self.everything_folder_results or {}), self.everything_folder_has_more and "+" or "",
        #(self.everything_file_results or {}), self.everything_file_has_more and "+" or "")
    end
    core.log_quiet("Fuzzy Path Search: Everything %s search ok query_len=%d shown=%d total=%d",
      kind, #query, #out, total)
    self.dirty = true
    self:schedule_update(true)
    return true
  end

  local function request(kind, params, on_success)
    http.get(everything_endpoint(), params, {
      timeout = 2,
      is_cancelled = request_is_cancelled,
      on_done = function(ok, err, data, info)
        if finish_request(kind, ok, err, data, info) and on_success then on_success() end
      end,
    })
  end

  local folder_offset = append and (self.everything_folder_offset or 0) or 0
  local file_offset = append and (self.everything_file_offset or 0) or 0
  core.log_quiet("Fuzzy Path Search: Everything searching query_len=%d scoped=%s append=%s",
    #query, tostring(scope ~= nil), tostring(append))
  request("folder", everything_folder_search_params(query, count, folder_offset, scope), function()
    if not folder_only then
      local file_query = query
      if self.file_picker and self.file_picker.extension_query then
        file_query = trim_query(file_query .. " " .. self.file_picker.extension_query)
      end
      request("file", everything_file_search_params(file_query, count, file_offset, scope))
    end
  end)
end

function FSView:clear_path_search_results(cancel_request)
  if cancel_request then everything.search_generation = everything.search_generation + 1 end
  self:cancel_deferred_everything_loading()
  self.everything_folder_results = {}
  self.everything_file_results = {}
  self.everything_folder_total = 0
  self.everything_file_total = 0
  self.everything_folder_offset = 0
  self.everything_file_offset = 0
  self.everything_folder_has_more = false
  self.everything_file_has_more = false
  self.everything_loading = false
  self.everything_pending = 0
  self.everything_status = ""
  self.path_search_query_key = nil
end

function path_search.native_results(scope, query, limit, picker)
  if not scope or not system.list_dir_info then return {}, {} end
  query = trim_query(query)
  if query:find("[/\\]", 1) then return {}, {} end
  limit = math.max(1, limit or 30)
  local scan_limit = math.max(limit, fuzzy_searcher.fuzzy_scan_limit or 10000)
  local folders, files = {}, {}
  local function matched_entries(entry_type)
    local is_folder = entry_type == "dir"
    local needs_scan = query ~= "" or (not is_folder and picker and picker.extensions)
    local entries = system.list_dir_info(scope, needs_scan and scan_limit or limit, entry_type)
    if type(entries) ~= "table" then return {} end

    local candidates, names = {}, {}
    for _, entry in ipairs(entries) do
      local extension = not is_folder and entry.name:match("%.([^./\\]+)$")
      if is_folder or not (picker and picker.extensions)
          or picker.extensions[tostring(extension or ""):lower()] then
        candidates[#candidates+1] = entry
        names[#names+1] = entry.name
      end
    end

    if query == "" then
      local matches = {}
      for index = 1, math.min(limit, #candidates) do
        matches[#matches+1] = { entry = candidates[index], score = 0, spans = {} }
      end
      return matches
    end

    local matches = {}
    for _, match in ipairs(fuzzy_native.filter(names, query, {
      mode = "path", limit = limit, spans = true,
    })) do
      matches[#matches+1] = {
        entry = candidates[match.index],
        score = match.score or 0,
        spans = match.spans or {},
      }
    end
    return matches
  end

  local function append_matches(matches, is_folder, target)
    for _, match in ipairs(matches) do
      local entry = match.entry
      local path = common.normalize_path(scope .. PATHSEP .. entry.name)
      local info = not is_folder and system.get_file_info(path) or nil
      target[#target+1] = {
        kind = "path",
        label = path,
        path = path,
        file = is_folder and nil or path,
        project = is_folder and path or nil,
        is_folder = is_folder,
        source = "filesystem",
        query = query,
        match_score = match.score,
        match_spans = offset_spans(match.spans, #path - #entry.name),
        size_label = is_folder and "" or format_size(info and info.size),
        modified_label = info and info.modified and compact_age(info.modified) or "",
      }
    end
  end
  append_matches(matched_entries("dir"), true, folders)
  if not (picker and picker.select == "folder") then
    append_matches(matched_entries("file"), false, files)
  end
  sort_path_results(folders)
  sort_path_results(files)
  return folders, files
end

function path_search.recent_project_results(query, scope, limit)
  ensure_recent_project_times()
  local candidates = {}
  for _, path in ipairs(get_recent_projects()) do
    if not scope or common.path_equals(path, scope) or common.path_belongs_to(path, scope) then
      candidates[#candidates+1] = path
    end
  end

  local matches = trim_query(query) == "" and nil or fuzzy_filter(candidates, query, limit + 1, display_root)
  local out = {}
  local hidden = false
  if matches then
    for i, match in ipairs(matches) do
      if i > limit then hidden = true break end
      local path = match.item
      out[#out+1] = {
        kind = "project", label = display_root(path), project = path, path = path,
        query = query, match_spans = match.spans, recent = true,
        opened_at = recent_project_times[path], modified_label = compact_age(recent_project_times[path]),
        is_folder = true, path_search = true,
      }
    end
  else
    for i, path in ipairs(candidates) do
      if i > limit then hidden = true break end
      out[#out+1] = {
        kind = "project", label = display_root(path), project = path, path = path,
        query = query, match_spans = {}, recent = true,
        opened_at = recent_project_times[path], modified_label = compact_age(recent_project_times[path]),
        is_folder = true, path_search = true,
      }
    end
  end
  return out, hidden
end

function path_search.append_sections(out, projects, folders, files, limit)
  local project_keys = {}
  for _, project in ipairs(projects) do
    local key = common.path_compare_key(project.path or project.project)
    if key then project_keys[key] = true end
  end
  local unique_folders = {}
  for _, folder in ipairs(folders) do
    local key = common.path_compare_key(folder.path or folder.project)
    if not key or not project_keys[key] then unique_folders[#unique_folders+1] = folder end
  end
  folders = unique_folders
  local folder_budget = #files == 0 and limit or math.max(1, math.floor(limit * 0.4))
  if #projects > 0 and #folders > 0 and limit >= 2 then folder_budget = math.max(2, folder_budget) end
  local folder_count = 0
  local hidden = false
  if #projects > 0 or #folders > 0 then
    out[#out+1] = { header = true, label = "Folders" }
    local project_budget = #folders > 0 and math.max(0, folder_budget - 1) or folder_budget
    for _, result in ipairs(projects) do
      if folder_count >= project_budget then hidden = true break end
      out[#out+1] = result
      folder_count = folder_count + 1
    end
    for _, result in ipairs(folders) do
      if folder_count >= folder_budget then hidden = true break end
      out[#out+1] = result
      folder_count = folder_count + 1
    end
  end

  local file_budget = math.max(1, limit - folder_count)
  if #files > 0 then
    out[#out+1] = { header = true, label = "Files" }
    for i = 1, math.min(file_budget, #files) do out[#out+1] = files[i] end
    if #files > file_budget then hidden = true end
  end
  return hidden
end

function path_search.file_picker_candidate(picker, result)
  if not picker or not result or result.header or result.create_path then return nil end
  local path = result.path or result.project or result.abs_path or result.file
  if not path then return nil end
  local is_folder = result.is_folder == true
    or result.kind == "folder" or result.kind == "project"
  if not is_folder and picker.select == "folder" then return nil end
  if not is_folder and picker.extensions then
    local extension = tostring(path):match("%.([^./\\]+)$")
    if not picker.extensions[tostring(extension or ""):lower()] then return nil end
  end
  return { path = path, type = is_folder and "folder" or "file" }
end

function path_search.file_picker_accepts(picker, candidate)
  return candidate and (picker.select == "any" or picker.select == candidate.type)
end

function path_search.filter_file_picker_results(results, picker)
  if not picker then return results end
  local out, pending_header = {}, nil
  for _, result in ipairs(results or {}) do
    if result.header then
      pending_header = result
    elseif path_search.file_picker_candidate(picker, result) then
      if pending_header then
        out[#out + 1] = pending_header
        pending_header = nil
      end
      out[#out + 1] = result
    end
  end
  return out
end

function FSView:refresh_normal(base, line, col, reset_selection, force_refresh)
  local limit = self:result_limit()
  local direct = path_search.direct_result(base, line, col)
  self.direct_path_result = direct
  local path_plan = path_search.plan(base, { include_ignored = self.include_ignored })
  if direct and direct.exact_path and direct.is_folder and not path_plan.external then
    direct.kind = "folder"
    direct.project = nil
    direct.path_search = nil
  end
  self.path_search_active = path_plan.external == true
  local mode = path_plan.mode
  base = path_plan.query or ""

  local out = {}
  self.has_more = false
  local bare_path_search = false
  if not path_plan.external and not path_plan.project_scope and self.path_search_query_key then
    self:clear_path_search_results(true)
  end

  local function add_file_results(query, max_items)
    if max_items <= 0 then self.has_more = true; return end

    if trim_query(query) == "" and not line and not native_file_index_ready() then
      local recent_matches, skip_keys = collect_recent_file_matches(query, line)
      local general_matches = {}
      for _, item in ipairs(get_files()) do
        local key = file_result_key(item)
        if key and not skip_keys[key] then
          general_matches[#general_matches+1] = { item = item, text = item, score = 0, spans = {} }
          if #general_matches > max_items then break end
        end
      end
      local folder_match_count, folder_has_more
      general_matches, folder_match_count, folder_has_more = merge_folder_matches(
        general_matches, query, line, max_items + 1
      )
      table.sort(general_matches, function(a, b) return fuzzy_result_better(a, b) end)
      local rows, hidden = build_sectioned_file_results(recent_matches, general_matches, max_items, query, line)
      out = rows
      self.has_more = hidden or folder_has_more or #general_matches > max_items
      return
    end

    self:start_file_search(query, line, reset_selection)
    return "async"
  end

  local function add_command_results(query, max_items)
    if max_items <= 0 then self.has_more = true; return end

    if trim_query(query) == "" then
      local candidates = {}
      for recent_index, name in ipairs(recent_commands) do
        if command.map[name] and self.palette_command_set[name] then
          candidates[#candidates + 1] = {
            name = name,
            recent_index = recent_index,
            opens_view = command.get_metadata(name).opens_view == true,
          }
        end
      end
      table.sort(candidates, function(a, b)
        if a.opens_view ~= b.opens_view then return a.opens_view end
        return a.recent_index < b.recent_index
      end)
      for index, candidate in ipairs(candidates) do
        if index > max_items then self.has_more = true; break end
        local name = candidate.name
        out[#out+1] = { kind = "command", label = name, command = name, query = query, match_spans = {}, recent = true, info = command_preview_info(name), status = command_status_parts(name, self) }
      end
      return
    end

    local commands = get_commands(self)
    local matches = fuzzy_filter(commands, query, #commands, fuzzy_searcher.command_search_text)
    table.sort(matches, function(a, b)
      local a_opens = command.get_metadata(a.item).opens_view == true
      local b_opens = command.get_metadata(b.item).opens_view == true
      if a_opens ~= b_opens then return a_opens end
      -- Use match quality, then identifier order. Command and keyword length
      -- must not break an otherwise equal match.
      local a_score = a.score + math.floor(#a.text / 8)
      local b_score = b.score + math.floor(#b.text / 8)
      if a_score == b_score then return a.item < b.item end
      return a_score > b_score
    end)
    for i, match in ipairs(matches) do
      if i > max_items then self.has_more = true; break end
      local name = match.item
      local identifier = name
      local _, identifier_spans = fuzzy_match(query, identifier)
      out[#out+1] = { kind = "command", label = identifier, command = name, query = query, match_spans = identifier_spans or {}, info = command_preview_info(name), status = command_status_parts(name, self) }
    end
  end

  local async
  if mode == ">" then
    kill_file_search()
    add_command_results(base, limit)
  elseif mode == "!" then
    kill_file_search()
    local shell_text = trim_query(base)
    if shell_text ~= "" then
      out[1] = {
        kind = "shell_command",
        label = "Run shell command",
        shell_command = shell_text,
        cwd = file_context.source_directory(self.source_view) or system.getcwd(),
        match_spans = {},
      }
    end
  elseif mode == "$" then
    kill_file_search()
    self:start_symbol_search(base, reset_selection)
    return
  elseif mode == "$$" then
    kill_file_search()
    self:start_current_buffer_symbol_search(base, reset_selection)
    return
  elseif path_plan.external or path_plan.project_scope then
    kill_file_search()
    local query = fuzzy_searcher.path_match_query(base)
    local scope = path_plan.scope
    bare_path_search = path_plan.explicit and query == "" and not scope
    local projects, projects_hidden = {}, false
    if not path_plan.project_scope then
      projects, projects_hidden = path_search.recent_project_results(query, scope, limit)
    end

    if bare_path_search then
      if self.path_search_query_key then self:clear_path_search_results(true) end
      for i = 1, math.min(limit, #projects) do out[#out+1] = projects[i] end
      self.has_more = projects_hidden
      self.everything_status = ""
    else
      if everything.state == "unknown" then probe_everything(self) end
      if everything.state == "available" then
        local everything_key = table.concat({ "paths", scope or "", query }, "\0")
        if self.path_search_query_key ~= everything_key then
          self:clear_path_search_results(false)
          self.path_search_query_key = everything_key
          self:start_everything_path_search(query, scope, false)
        elseif force_refresh and self.loading_more
        and (self.everything_folder_has_more or self.everything_file_has_more)
        and not self.everything_loading then
          self:start_everything_path_search(query, scope, true)
        elseif self.loading_more then
          self.loading_more = false
        end
      else
        if self.path_search_query_key then self:clear_path_search_results(true) end
        self.loading_more = false
        self.everything_status = everything.state == "probing"
          and "Checking Everything HTTP server…"
          or (scope and "Everything is unavailable. Showing direct folder contents."
            or "Everything is unavailable. Type an absolute path to browse files and folders.")
      end

      local folders = self.everything_folder_results or {}
      local files = self.everything_file_results or {}
      if everything.state ~= "available" then
        folders, files = path_search.native_results(scope, query, limit, self.file_picker)
      end
      if path_plan.project_scope then
        for _, result in ipairs(folders) do
          result.kind = "folder"
          result.project = nil
          result.path_search = nil
        end
        for _, result in ipairs(files) do
          result.abs_path = result.path or result.file
        end
      end
      if line then
        for _, result in ipairs(files) do result.line = line end
      end
      local sections_hidden = path_search.append_sections(out, projects, folders, files, limit)
      self.has_more = projects_hidden or sections_hidden
        or self.everything_folder_has_more or self.everything_file_has_more
    end
  else
    async = add_file_results(base, limit)
    if async then return end
    kill_file_search()
  end

  self:cancel_deferred_loading_feedback()

  out = path_search.prepend_direct(out, direct)
  out = path_search.filter_file_picker_results(out, self.file_picker)

  if mode == "!" then
    local cwd = file_context.source_directory(self.source_view) or system.getcwd()
    self.status = "Shell Command — Working directory: " .. cwd .. " — Output: new Command Output View"
  elseif path_plan.external then
    if bare_path_search then
      self.status = string.format("%d recent Projects", #get_recent_projects())
    else
      local scope_label = path_plan.scope and (" — " .. path_plan.scope) or ""
      self.status = (self.everything_status or "") .. scope_label
    end
  elseif path_plan.project_scope then
    local scope_label = path_plan.scope and (" — " .. path_plan.scope) or ""
    self.status = (self.everything_status or "") .. scope_label
  elseif fuzzy_searcher.files_indexing then
    self.status = string.format("Indexing files… %d available — %s", file_index_count(), fuzzy_searcher.project_roots_label())
  else
    self.status = string.format("%d files + %d folders indexed — %s",
      file_index_count(), folder_index_count(), fuzzy_searcher.project_roots_label())
  end
  if self.file_picker then
    local labels = { any = "Select a file or folder", file = "Select a file", folder = "Select a folder" }
    local label = self.file_picker.label or labels[self.file_picker.select]
    self.status = label .. (self.status ~= "" and (" — " .. self.status) or "")
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

function fuzzy_searcher.grep_order.file_key(r)
  local file = tostring(r and (r.abs_path or r.file) or "")
  if file == "" then return "" end
  return common.path_compare_key(file)
end

function fuzzy_searcher.grep_order.result_key(r)
  local file_key = fuzzy_searcher.grep_order.file_key(r)
  if file_key == "" then return nil end
  return file_key .. "\0" .. tostring(r.line or "")
end

function fuzzy_searcher.grep_order.better(a, b)
  local ap, bp = a.path_match_class or 0, b.path_match_class or 0
  if ap ~= bp then return ap > bp end

  local as, bs = a.fuzzy_score or 0, b.fuzzy_score or 0
  if as ~= bs then return as > bs end

  local aps, bps = a.path_score or 0, b.path_score or 0
  if aps ~= bps then return aps > bps end

  local af, bf = fuzzy_searcher.grep_order.file_key(a), fuzzy_searcher.grep_order.file_key(b)
  if af ~= bf then return af < bf end

  local al, bl = tonumber(a.line) or 0, tonumber(b.line) or 0
  if al ~= bl then return al < bl end

  local ac, bc = tonumber(a.col) or 0, tonumber(b.col) or 0
  if ac ~= bc then return ac < bc end

  return tostring(a.text or "") < tostring(b.text or "")
end

function fuzzy_searcher.grep_order.regroup(sorted)
  local out, used = {}, {}
  local buckets, bucket_positions = {}, {}
  -- Index each file group once. The old full-tail scan made completion work
  -- quadratic and caused a visible UI stall on broad searches.
  for i, result in ipairs(sorted) do
    local file = fuzzy_searcher.grep_order.file_key(result)
    if file ~= "" then
      local key = file .. "\0" .. tostring(result.path_match_class or 0)
      local bucket = buckets[key] or {}
      buckets[key] = bucket
      bucket[#bucket+1] = i
      bucket_positions[i] = #bucket
    end
  end

  for i, anchor in ipairs(sorted) do
    if not used[i] then
      out[#out+1] = anchor
      used[i] = true

      local anchor_file = fuzzy_searcher.grep_order.file_key(anchor)
      local anchor_score = anchor.fuzzy_score or 0
      local anchor_path_class = anchor.path_match_class or 0
      local pulled = 1
      if anchor_file ~= "" then
        local key = anchor_file .. "\0" .. tostring(anchor_path_class)
        local bucket = buckets[key] or {}
        for bucket_index = (bucket_positions[i] or #bucket) + 1, #bucket do
          local j = bucket[bucket_index]
          local candidate = sorted[j]
          if anchor_score - (candidate.fuzzy_score or 0) > fuzzy_searcher.grep_order.SAME_FILE_SCORE_SLACK then
            break
          end
          if not used[j] then
            out[#out+1] = candidate
            used[j] = true
            pulled = pulled + 1
            if pulled >= fuzzy_searcher.grep_order.SAME_FILE_MAX_BURST then break end
          end
        end
      end
    end
  end
  return out
end

function fuzzy_searcher.grep_order.results(results)
  local out = {}
  for i, result in ipairs(results or {}) do out[i] = result end
  table.sort(out, fuzzy_searcher.grep_order.better)
  return fuzzy_searcher.grep_order.regroup(out)
end

function fuzzy_searcher.grep_order.worse(a, b)
  return fuzzy_searcher.grep_order.better(b, a)
end

function fuzzy_searcher.grep_order.retain_top(heap, candidate, limit)
  limit = math.max(1, math.floor(tonumber(limit) or 1))
  if #heap < limit then
    local pos = #heap + 1
    while pos > 1 do
      local parent = math.floor(pos / 2)
      if not fuzzy_searcher.grep_order.worse(candidate, heap[parent]) then break end
      heap[pos] = heap[parent]
      pos = parent
    end
    heap[pos] = candidate
    return true
  end

  if not fuzzy_searcher.grep_order.better(candidate, heap[1]) then return false end
  local pos, count = 1, #heap
  while pos * 2 <= count do
    local child = pos * 2
    if child < count and fuzzy_searcher.grep_order.worse(heap[child + 1], heap[child]) then child = child + 1 end
    if not fuzzy_searcher.grep_order.worse(heap[child], candidate) then break end
    heap[pos] = heap[child]
    pos = child
  end
  heap[pos] = candidate
  return true
end

function FSView:start_grep_fuzzy_stream(base, line, grep, terms, scope, root, gen, preserve_results, scope_meta, scope_plan)
  -- Grep results are streamed asynchronously. Do not page them by clearing and
  -- restarting the search while the user scrolls; publish a growing stable
  -- prefix and let selection stop naturally at the currently available end.
  local limit = self:max_result_limit()
  local tokens = terms_to_legacy_tokens(terms)
  local roots = type(root) == "table" and root or { { path = root } }
  local jobs, added_jobs = {}, {}
  local processed
  local stream_thread_key
  local function add_job(job)
    if job and not added_jobs[job.key] then
      jobs[#jobs + 1] = job
      added_jobs[job.key] = true
      if processed then processed[job.key] = processed[job.key] or 0 end
      if stream_thread_key then
        job.wake_threads = job.wake_threads or {}
        job.wake_threads[stream_thread_key] = true
        if job.done then core.wake_thread(stream_thread_key) end
      end
    end
  end
  local function add_scope_jobs(batch)
    for _, root_entry in ipairs(roots) do
      local root_scope = scope_for_root(batch, root_entry.path)
      if not batch or #root_scope > 0 then
        local argument_batches = batch and fuzzy_searcher.grep_argument_batches(root_scope)
          or { false }
        for _, argument_scope in ipairs(argument_batches) do
          if argument_scope == false then argument_scope = nil end
          local job, preferred_job = ensure_fuzzy_grep_job(
            root_entry.path, argument_scope, tokens, self.include_ignored == true
          )
          add_job(job)
          add_job(preferred_job)
        end
      end
    end
  end
  add_scope_jobs(scope)
  if #jobs == 0 then return end

  -- A job is useful only while it contributes to the active query. Retaining
  -- every prefix typed into the prompt otherwise leaves multiple rg processes
  -- and their line caches alive until the picker closes.
  for key, job in pairs(fuzzy_grep_jobs) do
    if not added_jobs[key] then
      job.cancelled = true
      if job.proc and job.proc:running() then pcall(function() job.proc:kill() end) end
      fuzzy_grep_jobs[key] = nil
      core.log_quiet("Fuzzy grep: retired obsolete job %s", tostring(job.seed))
    end
  end
  local exact_results = #terms == 1 and not terms[1].exact and trim_query(grep):lower() == terms[1].text
  local fuzzy_query = terms_fuzzy_query(terms)
  local initial_settle_seconds = 0.10
  local initial_settle_visible_multiplier = 2

  local function jobs_label()
    local names, seen = {}, {}
    for _, s in ipairs(jobs) do
      if not seen[s.seed] then
        names[#names+1] = s.seed
        seen[s.seed] = true
      end
    end
    return table.concat(names, "/")
  end

  local loading_status = exact_results and string.format("Searching '%s'…", jobs_label())
    or string.format("Expanding fuzzy text search from '%s'…", jobs_label())
  self:defer_loading_feedback(loading_status, {
    clear_results = not preserve_results,
    reset_selection = not preserve_results,
    has_more = true,
  })

  stream_thread_key = core.add_thread(function()
    core.log_quiet("Fuzzy grep stream started generation=%d jobs=%d", gen, #jobs)
    local base_query = base:sub(1, 1) == ">" and "" or base
    local candidates, candidate_seen = {}, {}
    processed = {}
    for _, s in ipairs(jobs) do processed[s.key] = 0 end
    local max_candidates = fuzzy_searcher.fuzzy_candidate_limit or 500
    max_candidates = math.max(1, max_candidates, limit)
    local matched_candidate_count = 0
    local candidate_version = 0
    local slice_start = system.get_time()
    local stream_started = system.get_time()
    local last_publish = 0
    local published_candidate_version = 0
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
        local key = fuzzy_searcher.grep_order.result_key(r)
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
      local key = tostring(source.abs_path or source.file) .. ":" .. tostring(source.line)
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
        abs_path = source.abs_path,
        root_label = source.root_label,
        root_role = source.root_role,
        root_id = source.root_id,
        prefix_span = source.prefix_span,
        rank_penalty = source.rank_penalty,
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
      local current_scope_meta = scope_plan and scope_plan.meta or scope_meta
      local scope_key = source.abs_path and common.path_compare_key(source.abs_path)
      local path_info = scope_key and current_scope_meta and current_scope_meta.by_path
        and current_scope_meta.by_path[scope_key]
      if path_info then
        r.path_match_class = path_info.match_class
        r.path_score = path_info.score
      elseif base_query ~= "" then
        local path_score = fuzzy_match_file_fast(base_query, r.file)
        r.path_match_class = fuzzy_searcher.grep_order.path_match_class(base_query, r.file)
        r.path_score = path_score or 0
      else
        r.path_match_class = fuzzy_searcher.grep_order.PATH_NONE
        r.path_score = 0
      end
      if base_query ~= "" then
        local _, file_spans = fuzzy_match(base_query, r.file)
        r.file_spans = file_spans or {}
      end

      candidate_seen[key] = true
      matched_candidate_count = matched_candidate_count + 1
      if fuzzy_searcher.grep_order.retain_top(candidates, r, max_candidates) then
        candidate_version = candidate_version + 1
      end
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

      local selected_key = fuzzy_searcher.grep_order.result_key(self.results and self.results[self.selected])

      local running, truncated, scanned = job_stats()
      local tail = {}
      for _, candidate in ipairs(candidates) do
        local key = fuzzy_searcher.grep_order.result_key(candidate)
        if key and not committed_keys[key] then tail[#tail+1] = candidate end
      end
      tail = fuzzy_searcher.grep_order.results(tail)

      local out, emitted = {}, {}
      for _, r in ipairs(committed_results) do
        local key = fuzzy_searcher.grep_order.result_key(r)
        if key and not emitted[key] then
          out[#out+1] = r
          emitted[key] = true
          if #out >= limit then break end
        end
      end
      if #out < limit then
        for _, r in ipairs(tail) do
          local key = fuzzy_searcher.grep_order.result_key(r)
          if key and not emitted[key] then
            out[#out+1] = r
            emitted[key] = true
            if #out >= limit then break end
          end
        end
      end

      local scope_pending = scope_plan and (
        not scope_plan.complete or scope_plan.searched < #scope_plan.files
      )
      local has_more = matched_candidate_count > limit or running or truncated or scope_pending
      local fuzzy_count = matched_candidate_count
      local status
      if exact_results then
        if final then
          status = fuzzy_count == 0 and "No exact matches" or truncated
            and string.format("%d exact matches — limited scan from '%s'", fuzzy_count, jobs_label())
            or string.format("%d exact matches", fuzzy_count)
        elseif fuzzy_count == 0 then
          status = string.format("Searching exact text matches… scanning '%s'… %d lines", jobs_label(), scanned)
        else
          status = string.format("%d exact matches — scanning '%s'… %d lines", fuzzy_count, jobs_label(), scanned)
        end
      elseif final then
        status = fuzzy_count == 0 and "No fuzzy matches" or truncated
          and string.format("%d fuzzy matches — limited scan from '%s'", fuzzy_count, jobs_label())
          or string.format("%d fuzzy matches", fuzzy_count)
      elseif fuzzy_count == 0 then
        status = string.format("Searching fuzzy text matches… scanning '%s'… %d lines", jobs_label(), scanned)
      else
        status = string.format("%d fuzzy matches — scanning '%s'… %d lines", fuzzy_count, jobs_label(), scanned)
      end
      if scope_plan and not final then
        if scope_plan.complete then
          status = status .. string.format(
            " — searched %d of %d files", scope_plan.searched, #scope_plan.files
          )
        else
          status = status .. string.format(" — searched %d+ files", scope_plan.searched)
        end
      end
      if final and self.loading_feedback_pending and #out == 0 and not has_more then
        self.loading_feedback_status = status
        return true
      end

      self:cancel_deferred_loading_feedback()
      self.results = out
      self.has_more = has_more
      if self.pending_select_index then
        self.selected = common.clamp(self.pending_select_index, 1, math.max(1, #out))
        self.pending_select_index = nil
      elseif selected_key then
        local selected_index
        for i, result in ipairs(out) do
          if fuzzy_searcher.grep_order.result_key(result) == selected_key then selected_index = i; break end
        end
        self.selected = selected_index or common.clamp(self.selected, 1, math.max(1, #out))
      else
        self.selected = common.clamp(self.selected, 1, math.max(1, #out))
      end
      self.viewport_offset = common.clamp(self.viewport_offset, 1, math.max(1, #out))
      self:ensure_selection_visible()
      self.status = status
      if final and matched_candidate_count > #candidates then
        core.log_quiet("Fuzzy grep: ranked best %d of %d matching lines", #candidates, matched_candidate_count)
      end
      if final then
        core.log_quiet(
          "Fuzzy grep: finalized stable prefix=%d shown=%d",
          #committed_results, #out
        )
      end
      self:schedule_update(true)
      last_publish = system.get_time()
      published_candidate_version = candidate_version
      first_publish_done = true
      commit_visible_prefix()
      return true
    end

    while gen == grep_generation and active_view == self do
      local all_done = true
      for _, s in ipairs(jobs) do
        while (processed[s.key] or 0) < #s.lines do
          processed[s.key] = (processed[s.key] or 0) + 1
          add_candidate(s.lines[processed[s.key]])
          if candidate_version ~= published_candidate_version
            and #candidates > 0
            and system.get_time() - last_publish > 0.04
            and initial_publish_ready(false) then
            publish(false)
          end
          slice_start = yield_if_over_budget(slice_start)
        end
        if not s.done and s.thread_key then core.wake_thread(s.thread_key) end
        if not s.done or (processed[s.key] or 0) < #s.lines then all_done = false end
      end

      if candidate_version ~= published_candidate_version
        and #candidates > 0
        and system.get_time() - last_publish > 0.08
        and initial_publish_ready(false) then
        publish(false)
      end
      if all_done and scope_plan then
        scope_plan.searched = scope_plan.next_index - 1
        local next_scope = fuzzy_searcher.next_grep_scope_batch(scope_plan)
        scope_meta = scope_plan.meta
        if next_scope then
          core.log_quiet(
            "Fuzzy grep stream continuing generation=%d searched=%d next=%d",
            gen, scope_plan.searched, #next_scope
          )
          add_scope_jobs(next_scope)
          all_done = false
        end
      end
      if all_done then break end
      coroutine.yield(1 / config.fps)
      slice_start = system.get_time()
    end

    if gen ~= grep_generation or active_view ~= self then
      core.log_quiet(
        "Fuzzy grep stream stopped generation=%d current=%d active=%s",
        gen, grep_generation, tostring(active_view == self)
      )
      for _, job in ipairs(jobs) do
        if job.wake_threads then job.wake_threads[stream_thread_key] = nil end
      end
      return
    end
    core.log_quiet("Fuzzy grep stream finished generation=%d matches=%d", gen, matched_candidate_count)
    publish(true)
    for _, job in ipairs(jobs) do
      if job.wake_threads then job.wake_threads[stream_thread_key] = nil end
    end
  end)
  for _, job in ipairs(jobs) do
    job.wake_threads = job.wake_threads or {}
    job.wake_threads[stream_thread_key] = true
    if job.done then core.wake_thread(stream_thread_key) end
  end
end

function FSView:start_grep(base, line, grep)
  grep_generation = grep_generation + 1
  local gen = grep_generation
  kill_file_search()
  kill_grep()

  local preserve_results = self.loading_more
  self.loading_more = false
  self.loaded_limit = self:max_result_limit()
  if grep == "" then
    self:cancel_deferred_loading_feedback()
    self.results = {}
    self.selected = 1
    self.viewport_offset = 1
    self.hovered_result = nil
    self.has_more = false
    self.status = "Type text after # to search inside files"
    self:schedule_update(true)
    return
  end
  self:defer_loading_feedback("Searching exact text matches…", {
    clear_results = not preserve_results,
    reset_selection = not preserve_results,
    has_more = false,
  })

  local limit = self:max_result_limit()
  local roots = project_paths.search_roots("grep")
  local scope, scope_meta, scope_plan = nil, nil, nil
  if base ~= "" or line then
    scope_plan = fuzzy_searcher.new_grep_scope_plan(base, line)
    scope = fuzzy_searcher.next_grep_scope_batch(scope_plan)
    scope_meta = scope_plan.meta
    if not scope then
      self:cancel_deferred_loading_feedback()
      self.results = {}
      self.selected = 1
      self.viewport_offset = 1
      self.hovered_result = nil
      self.has_more = scope_meta and scope_meta.indexing or false
      self.status = self.has_more and "Indexing files for path scope…" or "No files in scope"
      self:schedule_update(true)
      return
    end
  end

  local exact_query = quoted_exact_query(grep)
  if exact_query and exact_query ~= "" then grep = exact_query end

  local terms = parse_code_search_terms(grep)
  if not exact_query and #terms > 1 then
    self:start_grep_fuzzy_stream(
      base, line, grep, terms, scope, roots, gen, preserve_results, scope_meta, scope_plan
    )
    return
  end

  core.add_thread(function()
    local results_started = false
    local candidates = {}
    local matched_count = 0
    local slice_started = system.get_time()
    local slice_yields = 0
    local last_progress_status = 0
    local stable_prefix_count = 0
    local function remember_visible_prefix()
      if #self.results == 0 then return end
      local visible_bottom = math.min(
        #self.results,
        (self.viewport_offset or 1) + self:list_metrics().result_rows - 1
      )
      stable_prefix_count = math.max(stable_prefix_count, visible_bottom)
    end
    local function yield_if_due()
      local now = system.get_time()
      if now - slice_started < EXACT_GREP_SLICE_SECONDS then return end
      slice_yields = slice_yields + 1
      if results_started and now - last_progress_status >= 0.05 then
        self.status = string.format("%d exact matches — searching…", matched_count)
        self.has_more = matched_count > #self.results
        self:schedule_update(true)
        last_progress_status = now
      end
      coroutine.yield(0)
      slice_started = system.get_time()
    end
    local function begin_results()
      if results_started then return end
      results_started = true
      self:cancel_deferred_loading_feedback()
      self.results = {}
      self.selected = 1
      self.viewport_offset = 1
      self.hovered_result = nil
      self.has_more = false
      self.status = "Searching exact text matches…"
    end

    local function add_result(r, seen, exact)
      if gen ~= grep_generation or active_view ~= self then return false end
      if line and not line_exists(r.file, line) then return true end
      local key = tostring(r.abs_path or r.file) .. ":" .. r.line .. ":" .. r.col
      if seen[key] then return true end
      seen[key] = true
      r.exact = exact
      r.grep_query = grep
      if exact and r.col and grep and grep ~= "" then
        r.content_selection_span = { r.col, r.col + #grep - 1 }
        r.content_match_start = r.col
      end
      r.base_query = base:sub(1, 1) == ">" and "" or base
      local path_key = r.abs_path and common.path_compare_key(r.abs_path)
      local path_info = path_key and scope_meta and scope_meta.by_path and scope_meta.by_path[path_key]
      if path_info then
        r.path_match_class = path_info.match_class
        r.path_score = path_info.score
      else
        r.path_match_class = r.base_query ~= ""
          and fuzzy_searcher.grep_order.path_match_class(r.base_query, r.file)
          or fuzzy_searcher.grep_order.PATH_NONE
        r.path_score = 0
      end
      r.fuzzy_score = fuzzy_match(grep, r.text) or 0
      if r.base_query ~= "" and not r.file_spans then
        local _, file_spans = fuzzy_match(r.base_query, r.file)
        r.file_spans = file_spans or {}
      end
      begin_results()
      matched_count = matched_count + 1
      fuzzy_searcher.grep_order.retain_top(candidates, r, limit)
      if #self.results < limit then
        self.results[#self.results+1] = r
        if #self.results == 1 then self.selected = 1; self.viewport_offset = 1 end
        if self.pending_select_index and #self.results >= self.pending_select_index then
          self.selected = self.pending_select_index
          self.pending_select_index = nil
        end
        self:ensure_selection_visible()
        remember_visible_prefix()
        self:schedule_update(true)
      else
        self.has_more = true
      end
      return true
    end

    local seen = {}
    local function search_root(root, root_scope)
      if gen ~= grep_generation or active_view ~= self then return false end
      if not root_scope or #root_scope > 0 then
        core.log_quiet(
          "Exact grep batch started files=%s", root_scope and tostring(#root_scope) or "all"
        )
        local args = {
          fuzzy_searcher.rg,
          "--line-number", "--column", "--no-heading", "--with-filename",
          "--color", "never", "-i", "-F",
        }
        project_files.add_filter_arguments(args, self.include_ignored == true)
        args[#args + 1], args[#args + 2] = "-e", grep
        if root_scope then
          args[#args+1] = "--"
          for _, f in ipairs(root_scope) do args[#args+1] = f end
        else
          args[#args + 1] = "."
        end
        local proc = process.start(args, { cwd = root.path, stdout = process.REDIRECT_PIPE, stderr = process.REDIRECT_DISCARD, stdin = process.REDIRECT_DISCARD })
        grep_proc = proc

        if proc then
          while gen == grep_generation and active_view == self do
            local ok, line_or_error = pcall(
              proc.stdout.read, proc.stdout, "line", { scan = 0.001, timeout = 0.1 }
            )
            if ok and line_or_error then
              local result = decorate_grep_result(parse_vimgrep(line_or_error), root.path)
              if result then add_result(result, seen, true) end
              yield_if_due()
            elseif not ok and not tostring(line_or_error):find("timeout expired", 1, true) then
              core.log_quiet("Fuzzy grep read failed under %s: %s", tostring(root.path), tostring(line_or_error))
              break
            elseif not proc:running() then
              break
            else
              coroutine.yield(1 / config.fps)
            end
          end
          if proc:running() then pcall(function() proc:kill() end) end
          proc:wait(process.WAIT_DEADLINE)
          if grep_proc == proc then grep_proc = nil end
        end
        core.log_quiet(
          "Exact grep batch finished files=%s matches=%d yields=%d",
          root_scope and tostring(#root_scope) or "all", matched_count, slice_yields
        )
      end
      return gen == grep_generation and active_view == self
    end

    local batch = scope
    repeat
      for _, root in ipairs(roots) do
        if batch then
          local root_scope = scope_for_root(batch, root.path)
          for _, argument_scope in ipairs(fuzzy_searcher.grep_argument_batches(root_scope)) do
            if not search_root(root, argument_scope) then return end
          end
        elseif not search_root(root, nil) then
          return
        end
      end
      if scope_plan then
        scope_plan.searched = scope_plan.searched + #batch
        local progress_status
        if scope_plan.complete then
          progress_status = matched_count == 0
            and string.format("Searching exact text matches… searched %d of %d files",
              scope_plan.searched, #scope_plan.files)
            or string.format("%d exact matches — searched %d of %d files",
              matched_count, scope_plan.searched, #scope_plan.files)
        else
          progress_status = matched_count == 0
            and string.format("Searching exact text matches… searched %d+ files", scope_plan.searched)
            or string.format("%d exact matches — searched %d+ files", matched_count, scope_plan.searched)
        end
        if results_started then
          self.status = progress_status
          self.has_more = matched_count > limit or scope_plan.searched < #scope_plan.files
          self:schedule_update(true)
        elseif self.loading_feedback_pending then
          self.loading_feedback_status = progress_status
        end
        batch = fuzzy_searcher.next_grep_scope_batch(scope_plan)
        scope_meta = scope_plan.meta
      else
        batch = nil
      end
    until not batch

    if gen ~= grep_generation or active_view ~= self then return end
    if not results_started and self.loading_feedback_pending then
      self.loading_feedback_status = "No exact matches"
      return
    end
    if not results_started then begin_results() end
    -- Preserve every row that the user could have seen. Rank only the unseen
    -- tail so completion improves later results without moving visible rows.
    remember_visible_prefix()
    local out, committed = {}, {}
    for i = 1, stable_prefix_count do
      local result = self.results[i]
      local key = fuzzy_searcher.grep_order.result_key(result)
      out[#out+1] = result
      if key then committed[key] = true end
    end
    local ranked_tail = {}
    for _, result in ipairs(candidates) do
      local key = fuzzy_searcher.grep_order.result_key(result)
      if not key or not committed[key] then ranked_tail[#ranked_tail+1] = result end
    end
    ranked_tail = fuzzy_searcher.grep_order.results(ranked_tail)
    for _, result in ipairs(ranked_tail) do
      if #out >= limit then break end
      out[#out+1] = result
    end
    self.results = out
    self.has_more = matched_count > #self.results
    self.status = matched_count == 0 and "No exact matches"
      or string.format("%d exact matches", matched_count)
    core.log_quiet(
      "Exact grep: finalized stable prefix=%d shown=%d matches=%d",
      stable_prefix_count, #self.results, matched_count
    )
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
  local path = item.path or item.abs_path or item.file
  local display = path and project_paths.display_path(path, { kind = "symbols" }) or nil
  local file = display and display.text or item.display_file or item.relpath
  if not file or file == "" then
    if item.path and item.file and item.file ~= item.path then
      file = item.file
    else
      file = symbol_display_file(path)
    end
  end
  local label = item.name or item.label or ""
  local line = item.line or (item.name_range and item.name_range.start and item.name_range.start.line) or item.start_line or 1
  local col = item.col or (item.name_range and item.name_range.start and item.name_range.start.col) or item.start_col or 1
  local line2 = item.line2 or (item.name_range and item.name_range["end"] and item.name_range["end"].line) or item.end_line
  local col2 = item.col2 or (item.name_range and item.name_range["end"] and item.name_range["end"].col) or item.end_col
  local _, name_spans = fuzzy_match(query, label)
  local path_query = trim_query(opts.path_query)
  local path_score, file_spans = fuzzy_match_file_fast(path_query, file)
  if path_query ~= "" and not path_score then return nil end
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
    abs_path = display and display.abs_path or item.abs_path,
    root_label = display and display.root_label or item.root_label,
    root_role = display and display.root_role or item.root_role,
    root_id = display and display.root_id or item.root_id,
    prefix_span = display and display.prefix_span or item.prefix_span,
    buffer = opts.buffer,
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    query = query,
    match_spans = name_spans or {},
    file_spans = file_spans or {},
    path_score = path_score or 0,
    path_query = path_query,
    symbol_scope = opts.scope,
  }
end

local function set_symbol_results(view, query, results, source_label, status, reason, limit, opts)
  opts = opts or {}
  view:cancel_deferred_loading_feedback()
  view.has_more = false
  local out = {}
  for _, item in ipairs(results or {}) do
    local result = symbol_result_from_item(item, query, opts)
    if result then
      if #out >= limit then view.has_more = true; break end
      out[#out + 1] = result
    end
  end
  view.results = out
  view.selected = common.clamp(view.selected or 1, 1, math.max(1, #out))
  view:ensure_selection_visible()
  if status == "fresh" or status == "stale" then
    local count = #out
    local suffix = source_label and source_label ~= "" and (" — " .. source_label) or ""
    view.status = string.format("%d symbol%s%s", count, count == 1 and "" or "s", suffix)
  elseif reason then
    view.status = tostring(reason)
  end
  view:schedule_update(true)
end

local function project_symbol_pending_status(reason, meta)
  if reason == "aggregate-dirty" or reason == "query-artifact-not-ready" then
    return "Finishing Project symbol index…"
  end
  if reason == "indexing" then
    local files_scanned = 0
    local seen = {}
    for _, root in ipairs((meta and meta.roots) or {}) do
      local index = root and root.index
      if index and not seen[index] then
        seen[index] = true
        files_scanned = files_scanned + (tonumber(index.files_scanned) or 0)
      end
    end
    local index = meta and meta.index
    if index and not seen[index] then
      files_scanned = files_scanned + (tonumber(index.files_scanned) or 0)
    end
    if files_scanned > 0 then
      return string.format("Indexing Project symbols… %d files scanned", files_scanned)
    end
    return "Indexing Project symbols…"
  end
  return tostring(reason or "Indexing Project symbols…")
end

function fuzzy_searcher.cancel_symbol_search()
  symbol_generation = symbol_generation + 1
  local request = active_view and active_view.symbol_search_request
  if request and request.cancel then request:cancel() end
  if active_view then active_view.symbol_search_request = nil end
end

function FSView:start_symbol_search(query, reset_selection, path_query)
  fuzzy_searcher.cancel_symbol_search()
  local gen = symbol_generation
  local limit = self:max_result_limit()
  query = trim_query(query)
  path_query = trim_query(path_query)
  local candidate_limit = path_query ~= ""
    and math.max(limit + 1, fuzzy_searcher.fuzzy_candidate_limit or 500)
    or (limit + 1)
  if query == "" then
    self:cancel_deferred_loading_feedback()
    self.results = {}
    self.has_more = false
    self.hovered_result = nil
    if reset_selection then
      self.selected = 1
      self.viewport_offset = 1
    end
    self.status = "Type after $ to find Project symbols"
    self:schedule_update(true)
    return
  end
  self:defer_loading_feedback("Finding Project symbols…", {
    clear_results = true,
    reset_selection = reset_selection,
    has_more = false,
  })

  core.add_thread(function()
    local results, reason, status, source_label

    -- Project-symbol search should be local and predictable.  Tree-sitter is
    -- the first-party project index, while LSP workspace/symbol providers can
    -- stay pending for seconds or return an authoritative empty result.  Use
    -- Tree-sitter first so an already-indexed project produces results without
    -- waiting on LSP.
    do
      local ts_symbols = require "core.treesitter.symbol_index"
      local deadline = math.huge
      while system.get_time() < deadline do
        if gen ~= symbol_generation or active_view ~= self then return end
        local async_request, meta
        if ts_symbols.workspace_symbols_async then
          async_request, reason, status, meta = ts_symbols.workspace_symbols_async(query, {
            force = false,
            limit = candidate_limit,
            allow_stale = false,
          })
        else
          results, reason, status, meta = ts_symbols.workspace_symbols(query, { force = false, limit = candidate_limit, allow_stale = false })
        end
        if async_request then
          self.symbol_search_request = async_request
          self:set_pending_status("Searching Project symbols…")
          while not async_request.done and system.get_time() < deadline do
            if gen ~= symbol_generation or active_view ~= self then
              async_request:cancel()
              return
            end
            coroutine.yield(0.03)
          end
          if gen ~= symbol_generation or active_view ~= self then
            async_request:cancel()
            return
          end
          if self.symbol_search_request == async_request then
            self.symbol_search_request = nil
          end
          if async_request.done and async_request.status == "fresh" then
            results = async_request.results
            reason = async_request.reason
            status = async_request.status
            break
          else
            reason = async_request.reason or reason
            status = async_request.status or status
          end
          if async_request.cancel then async_request:cancel() end
          if status == "unavailable" then break end
        elseif status == "fresh" then
          break
        elseif status == "unavailable" then
          break
        end
        self:set_pending_status(project_symbol_pending_status(reason, meta))
        coroutine.yield(0.05)
      end
      source_label = "Tree-sitter"
    end

    if gen ~= symbol_generation or active_view ~= self then return end
    if status == "fresh" or status == "stale" then
      set_symbol_results(self, query, results, source_label, status, reason, limit, {
        scope = "project",
        path_query = path_query,
      })
    else
      self:cancel_deferred_loading_feedback()
      self.results = {}
      self.status = reason and ("Project symbols unavailable: " .. tostring(reason)) or "Project symbols unavailable"
      self:schedule_update(true)
    end
    if reason and status ~= "fresh" then core.log_quiet("Fuzzy Project symbols: %s", tostring(reason)) end
  end)
end

function FSView:start_current_buffer_symbol_search(query, reset_selection)
  symbol_generation = symbol_generation + 1
  local gen = symbol_generation
  local limit = self:max_result_limit()
  query = trim_query(query)
  self:defer_loading_feedback("Finding current Buffer symbols…", {
    clear_results = true,
    reset_selection = reset_selection,
    has_more = false,
  })

  core.add_thread(function()
    local buffer = self.source_buffer or (self.source_view and self.source_view.buffer) or (core.active_view and core.active_view.buffer)
    local treesitter = require "core.treesitter"
    if buffer then treesitter.attach_or_update_buffer(buffer, "current-buffer-symbol-search") end
    local deadline = system.get_time() + 3
    while buffer and buffer.treesitter and buffer.treesitter.status ~= "ready" and system.get_time() < deadline do
      if gen ~= symbol_generation or active_view ~= self then return end
      treesitter.poll_buffer(buffer)
      coroutine.yield(0.03)
    end
    if gen ~= symbol_generation or active_view ~= self then return end
    local ts_symbols = require "core.treesitter.symbol_index"
    local results, reason, status = ts_symbols.current_buffer_symbols(buffer, query, { limit = limit + 1 })
    if status == "fresh" or status == "stale" then
      set_symbol_results(self, query, results, "current Buffer", status, reason, limit, { scope = "buffer", buffer = buffer })
      if #self.results == 0 and reason then self.status = "No current Buffer symbols: " .. tostring(reason) end
    else
      self:cancel_deferred_loading_feedback()
      self.results = {}
      self.status = reason or "No current Buffer symbols"
      self:schedule_update(true)
    end
  end)
end

function FSView:refresh_static()
  self:cancel_deferred_loading_feedback()
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
  local files_changed = self.last_files_generation ~= fuzzy_searcher.files_generation
  local files_scope_changed = self.last_files_scope_generation ~= fuzzy_searcher.files_scope_generation
  local base, line, col, grep, symbol
  if self.file_picker then
    -- A File Picker has one fixed mode. Its input is only a path query.
    base = "@" .. tostring(text or "")
  else
    base, line, col, grep, symbol = parse_query(text)
  end
  local query_key = table.concat({ base, tostring(line or ""), tostring(col or ""), tostring(grep or ""), tostring(symbol or "") }, "\0")
  local query_changed = query_key ~= self.current_query_key

  if query_changed then
    self.current_query_key = query_key
    self:reset_pagination()
  end

  if not self.force_refresh and not self.dirty and not files_changed and not files_scope_changed then return end
  local force_refresh = self.force_refresh
  self.force_refresh = false
  self.dirty = false
  self.last_files_generation = fuzzy_searcher.files_generation
  self.last_files_scope_generation = fuzzy_searcher.files_scope_generation

  if grep ~= nil then
    self.path_search_active = false
    if self.path_search_query_key then self:clear_path_search_results(true) end
    fuzzy_searcher.cancel_symbol_search()
    local scoped_index_changed = (base ~= "" or line ~= nil) and files_scope_changed
    if query_changed or force_refresh or scoped_index_changed then self:start_grep(base, line, grep) end
  elseif symbol ~= nil then
    self.path_search_active = false
    if self.path_search_query_key then self:clear_path_search_results(true) end
    if fuzzy_searcher.files_indexing
    and fuzzy_searcher.files_scan_reason ~= "project-prewarm" then
      core.log_quiet("Fuzzy file index scan cancelled after switching to Project Symbol Search")
      cancel_file_index_scan()
    end
    kill_file_search()
    kill_grep()
    kill_fuzzy_grep_jobs()
    if query_changed or force_refresh then self:start_symbol_search(symbol, query_changed, base) end
  else
    fuzzy_searcher.cancel_symbol_search()
    kill_grep()
    kill_fuzzy_grep_jobs()
    self:refresh_normal(base, line, col, query_changed, force_refresh)
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
  fuzzy_focus_log("text-input-before", self, "bytes=" .. tostring(#tostring(text or "")))
  ensure_input_focus(self)
  self.input:on_text_input(text)
  fuzzy_focus_log("text-input-after", self, "bytes=" .. tostring(#tostring(text or "")))
  return true
end

function fuzzy_searcher.apply_prompt_history_text(view, text, select_query)
  text = tostring(text or "")
  view._applying_prompt_history = true
  view.input:set_text(text)
  view._applying_prompt_history = false

  local buffer = view.input and view.input.textview and view.input.textview.buffer
  if buffer then
    local col = select_query and fuzzy_searcher.prompt_query_start(text) or (#text + 1)
    buffer:set_selection(1, col, 1, #text + 1)
  end
  view.dirty = true
  view.force_refresh = true
  view:refresh(text)
  view:schedule_update(true)
end

function FSView:record_prompt_history()
  if self.static_mode or self.file_picker or self._prompt_history_recorded then return end
  self._prompt_history_recorded = true
  if self.input then fuzzy_searcher.record_prompt_history_text(self.input:get_text()) end
end

function FSView:prompt_history_session()
  local text = self.input and self.input:get_text() or ""
  local mode = fuzzy_searcher.prompt_mode(text)
  local session = self._prompt_history_session
  if session and session.mode == mode then return session end

  local entries = { text }
  for _, entry in ipairs(fuzzy_searcher.prompt_history_for_mode(mode)) do
    if entry ~= text then entries[#entries + 1] = entry end
  end
  session = { mode = mode, entries = entries, index = 1 }
  self._prompt_history_session = session
  return session
end

function FSView:navigate_prompt_history(delta)
  if self.static_mode or self.file_picker or not self.input then return false end
  local session = self:prompt_history_session()
  local index = common.clamp(session.index + delta, 1, #session.entries)
  if index == session.index then return false end
  session.index = index
  fuzzy_searcher.apply_prompt_history_text(self, session.entries[index], false)
  return true
end

function FSView:close(reason)
  if self.closed then return end
  self.closed = true
  if self:is_preview_focused() then self:set_preview_interactive(false) end
  local cancel
  if self.file_picker and not self.file_picker_finished then
    self.file_picker_finished = true
    cancel = self.file_picker.cancel
  end
  fuzzy_focus_log("close", self)
  local input_view = self.input and self.input.textview
  core.root_panel:pop_modal_input(self)
  core.root_panel:hide_app_overlay(self)
  self:record_prompt_history()
  self:cancel_deferred_loading_feedback()
  self:cancel_deferred_everything_loading()
  kill_file_search()
  kill_grep()
  kill_fuzzy_grep_jobs()
  self:clear_preview_view()
  self:swap_active_child(nil)
  self:hide()
  self:destroy()
  if active_view == self then active_view = nil end
  if core.fuzzy_searcher_active_view == self then core.fuzzy_searcher_active_view = nil end
  if not panes.contains(self.source_pane)
      and (core.active_view == self or core.active_view == input_view) then
    core.clear_active_view(core.active_view)
  end
  if cancel then
    core.log_quiet("File Picker: cancelled reason=%s", tostring(reason or "cancelled"))
    cancel(reason or "cancelled")
  end
end

function FSView:can_toggle_ignored_files()
  if self.static_mode or self.file_picker then return false end
  local mode = fuzzy_searcher.prompt_mode(self.input and self.input:get_text() or "")
  return mode == "#" or (mode == "" and not self:is_path_search())
end

function FSView:active_search_modifiers()
  local modifiers = {}
  if self.include_ignored and self:can_toggle_ignored_files() then
    modifiers[#modifiers + 1] = "Ignored files included"
  end
  return modifiers
end

function FSView:search_modifier_text()
  return table.concat(self:active_search_modifiers(), "  ·  ")
end

function FSView:toggle_ignored_files()
  if not self:can_toggle_ignored_files() then return false end
  self.include_ignored = not self.include_ignored
  kill_grep()
  kill_fuzzy_grep_jobs()
  local text = self.input and self.input:get_text() or ""
  local base, _, _, grep = parse_query(text)
  local path_plan = path_search.plan(base, { include_ignored = self.include_ignored })
  if (grep == nil or base ~= "") and not path_plan.project_scope then
    cancel_file_index_scan()
    fuzzy_searcher.files_cache_root = nil
    fuzzy_searcher.refresh_file_index_for_picker_open()
  end
  self.current_query_key = nil
  self.force_refresh = true
  self.dirty = true
  self:schedule_update(true)
  core.log_quiet("Fuzzy Searcher: %s ignored files for this search",
    self.include_ignored and "included" or "excluded")
  return true
end

function FSView:selected_file_path()
  local r = self:selected_result()
  if not r then return end

  if r.file or r.abs_path then
    return common.normalize_path(fullpath(r))
  end

  local path = r.buffer and r.buffer.abs_filename
  if path and path ~= "" then return common.normalize_path(path) end
end

function FSView:reveal_selected_in_explorer()
  local path = self:selected_file_path()
  if not path then return end

  self:close()
  command.perform("editor:reveal_active_file_in_explorer", path)
end

function FSView:open_file_result(r, target_side)
  local path = fullpath(r)
  local line, col, line2, col2 = r.line or 1, r.col or 1, nil, nil
  if r.kind == "grep" then
    line, col, line2, col2 = grep_accept_range(r)
  end
  local source_view = self.source_view
  local source_pane = self.source_pane
  self:close()
  local view = core.open_file(path, {
    pane = source_pane,
    placement = target_side and "split" or "current",
    direction = target_side and "right" or nil,
    line = line,
    col = col,
    line2 = line2,
    col2 = col2,
    focus = true,
  })
  if view and view.buffer then
    local function apply_selection()
      view.buffer:set_selection(line, col, line2 or line, col2 or col)
    end
    if view.with_selection_state then
      view:with_selection_state(apply_selection)
    else
      apply_selection()
    end
    if view.scroll_to_line then view:scroll_to_line(line, false, true) end
    if view.scroll_to_make_visible then
      view:scroll_to_make_visible(line, col, true, {
        line2 = line2 or line,
        col2 = col2 or col,
        vertical = false,
      })
    end
  end
  return view
end

function FSView:activate_create_path(r, target_side)
  local path = common.normalize_path(r.abs_path or r.path)
  local info = path and system.get_file_info(path)
  if info then
    if info.type == "dir" then
      self:close()
      if target_side then core.open_project_in_new_window(path)
      else core.open_project_in_same_window(path) end
      return
    end
    return self:open_file_result({ kind = "path", file = path, abs_path = path, line = r.line }, target_side)
  end

  if r.is_folder then
    local created, err = common.mkdirp(path)
    if not created then
      core.error("Cannot create selected folder: %s", path_search.creation_error_label(err))
      return
    end
    core.log_quiet("Fuzzy Path Search: created folder path_len=%d", #path)
    self.force_refresh = true
    self.dirty = true
    self:refresh(self.input:get_text())
    self:schedule_update(true)
    return
  end

  local parent = common.dirname(path)
  local parent_info = parent and system.get_file_info(parent)
  if not parent_info then
    local created, err = common.mkdirp(parent)
    if not created then
      core.error("Cannot create parent folders: %s", path_search.creation_error_label(err))
      return
    end
  elseif parent_info.type ~= "dir" then
    core.error("Cannot create file because its parent is not a folder")
    return
  end

  local fp, err = io.open(path, "ab")
  if not fp then
    core.error("Cannot create selected file: %s", path_search.creation_error_label(err))
    return
  end
  fp:close()
  core.log_quiet("Fuzzy Path Search: created file path_len=%d", #path)
  return self:open_file_result({ kind = "path", file = path, abs_path = path, line = r.line }, target_side)
end

function FSView:confirm_folder_open(r, target_side)
  local path = common.normalize_path(r.abs_path or r.path or r.project)
  if not path then return false end
  local default_action = r.kind == "folder" and "filetree"
    or ((target_side or r.kind == "new_project") and "project_new" or "project_here")
  local context = {
    source_view = self.source_view,
    source_pane = panes.find(self.source_pane) or panes.active(),
    placement = target_side and "split" or "current",
    direction = target_side and "right" or nil,
  }
  local options = {
    { text = "Open File Tree", action = "filetree", default_yes = default_action == "filetree" },
    { text = "Open Project in This Window", action = "project_here", default_yes = default_action == "project_here" },
    { text = "Open Project in New Window", action = "project_new", default_yes = default_action == "project_new" },
    { text = "Cancel", action = "cancel", default_no = true },
  }

  core.nag_view:show(
    "Open Folder",
    string.format("How do you want to open \"%s\"?", common.home_encode(path)),
    options,
    function(option)
      if option.action == "cancel" then return end
      if self.closed then return end
      self:close()
      core.add_thread(function()
        core.log_quiet("Fuzzy Searcher: selected folder action=%s", tostring(option.action))
        if option.action == "filetree" then
          command.perform_with_context("filetree:open_at_choose_path", context, path)
        elseif option.action == "project_here" then
          core.open_project_in_same_window(path)
        elseif option.action == "project_new" then
          core.open_project_in_new_window(path)
        end
      end)
    end
  )
  return true
end

function FSView:confirm(target_side)
  local r = self:selected_result()
  if not r then return end
  if r.kind == "shell_command" then
    local text = trim_query(r.shell_command)
    if text == "" then return end
    local cwd = r.cwd or file_context.source_directory(self.source_view) or system.getcwd()
    self:close()
    require("plugins.command_slots").run_once(text, { cwd = cwd, focus = true })
    return
  end
  if r.kind == "command" then
    local cmd = r.command
    local metadata = command.get_metadata(cmd) or {}
    local placement = target_side and metadata.supports_placement and "split" or "current"
    local context = {
      source_view = self.source_view,
      source_pane = panes.find(self.source_pane) or panes.active(),
      placement = placement,
      direction = placement == "split" and "right" or nil,
    }
    remember_command(cmd)
    self:close()
    command.perform_with_context(cmd, context)
    return
  end
  if self.file_picker then
    local candidate = path_search.file_picker_candidate(self.file_picker, r)
    if not candidate then return end
    local path = candidate.path
    local info = system.get_file_info(path)
    if not info or (candidate.type == "folder" and info.type ~= "dir")
        or (candidate.type == "file" and info.type ~= "file") then
      self.force_refresh = true
      self.dirty = true
      self:refresh(self.input:get_text())
      self:schedule_update(true)
      return
    end
    if not path_search.file_picker_accepts(self.file_picker, candidate) then
      if candidate.type == "folder" and self.file_picker.select == "file" then
        self.input:set_text(common.normalize_path(path) .. PATHSEP)
        ensure_input_focus(self, "file-picker-browse-folder")
      end
      return
    end
    local picker = self.file_picker
    local context = {
      source_view = self.source_view,
      source_pane = panes.find(self.source_pane) or panes.active(),
      placement = target_side and "split" or "current",
      direction = target_side and "right" or nil,
    }
    self.file_picker_finished = true
    self:close()
    core.log_quiet("File Picker: selected type=%s", candidate.type)
    picker.submit(common.normalize_path(path), context)
    return
  end
  if r.kind == "create_path" then
    return self:activate_create_path(r, target_side)
  end
  if r.kind == "folder" or r.kind == "project" or r.kind == "new_project"
      or (r.kind == "path" and r.is_folder and r.project) then
    return self:confirm_folder_open(r, target_side)
  end
  if r.buffer and r.line then
    local buffer = r.buffer
    local source_view = self.source_view
    local source_pane = self.source_pane
    self:close()
    local view = source_view
    if not (view and view.buffer == buffer) then
      local Editor = require "core.editor"
      view = panes.place(function() return Editor(buffer) end, {
        pane = source_pane,
        placement = target_side and "split" or "current",
        direction = target_side and "right" or nil,
        focus = true,
      })
    end
    if r.line2 and r.col2 then buffer:set_selection(r.line, r.col, r.line2, r.col2) else buffer:set_selection(r.line, r.col) end
    return
  end
  if r.file then
    return self:open_file_result(r, target_side)
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
  local expected_preview_focus = self:is_preview_focused()
  if self.input and core.active_view ~= self.input.textview and not expected_preview_focus then
    local state = view_label(core.active_view) .. "|" .. view_label(self.child_active)
    if state ~= self._last_unexpected_focus_state then
      self._last_unexpected_focus_state = state
      fuzzy_focus_log("update-unexpected-active", self)
    end
    if core.root_panel:modal_input_owner() == self then
      ensure_input_focus(self, "update-restore-input")
    end
  else
    self._last_unexpected_focus_state = nil
  end
  self:refresh(self.input:get_text())
  self:update_selected_preview()

  local hit = self:result_at_point(self.mouse.x, self.mouse.y)
  self.hovered_result = type(hit) == "number"
    and self.results[hit] and not self.results[hit].header and hit or nil
  if self.hovered_result then
    self.cursor = "hand"
    core.request_cursor(self.cursor)
  end
end

function FSView:draw()
  if not self:is_visible() then return false end
  local draw_scope = fuzzy_searcher._perf_scope_begin("fuzzy_searcher", true)

  local phase_scope = fuzzy_searcher._perf_scope_begin("widget_chrome")
  local widget_drawn = FSView.super.draw(self)
  fuzzy_searcher._perf_scope_end(phase_scope)
  if not widget_drawn then
    fuzzy_searcher._perf_scope_end(draw_scope)
    return false
  end

  phase_scope = fuzzy_searcher._perf_scope_begin("list_setup")
  local pad = style.padding.x
  local font = style.code_font
  local m = self:list_metrics(font)
  local x, y, w, h = m.x, m.y, m.w, m.h
  local top, list_w, lh = m.top, m.list_w, m.lh
  local row_padding = m.row_padding
  self:ensure_selection_visible()

  renderer.draw_text(font, self.status or "", x + pad, y + self.input.size.y + pad * 1.5, style.dim)
  local full_width_mode = self:is_full_width_mode()
  local vertical_preview = m.vertical_preview
  local command_mode = self:is_command_mode()
  local divider_w = (full_width_mode or vertical_preview) and 0 or style.divider_size
  if vertical_preview then
    renderer.draw_rect(x, top + m.list_h, w, style.divider_size, style.divider)
  elseif not full_width_mode then
    renderer.draw_rect(x + list_w, top, style.divider_size, h - (top - y), style.divider)
  end

  core.push_clip_rect(x, top, list_w - divider_w, m.list_h)
  local row_text_w = list_w - (pad * 2) - divider_w
  local pane_markers = fuzzy_searcher.current_file_pane_markers(pad)
  local arrow_color = style.dim
  local up_arrow, down_arrow = "▲", "▼"
  if self.viewport_offset > 1 then
    renderer.draw_text(font, up_arrow, x + (list_w - font:get_width(up_arrow)) / 2, top + row_padding, arrow_color)
  end
  if self.viewport_offset + m.result_rows - 1 < #self.results or self:can_load_more() then
    renderer.draw_text(font, down_arrow, x + (list_w - font:get_width(down_arrow)) / 2, m.bottom_indicator_y + row_padding, arrow_color)
  end
  fuzzy_searcher._perf_scope_end(phase_scope)

  phase_scope = fuzzy_searcher._perf_scope_begin("result_scan")
  local last = math.min(#self.results, self.viewport_offset + m.result_rows - 1)
  local has_visible_grep = false
  for idx = self.viewport_offset, last do
    local r = self.results[idx]
    if r and r.kind == "grep" then has_visible_grep = true; break end
  end
  fuzzy_searcher._perf_scope_end(phase_scope)

  local results_scope = fuzzy_searcher._perf_scope_begin("result_rows")
  local previous_rendered_grep_file = nil
  local previous_rendered_grep_line_x = nil
  local previous_rendered_was_grep = false
  for idx = self.viewport_offset, last do
    local r = self.results[idx]
    local yy = m.results_top + (idx - self.viewport_offset) * lh
    local row_y = yy + row_padding
    local row_scope
    if core.perf_draw_scope_active then
      row_scope = fuzzy_searcher._perf_scope_begin(
        r.header and "header" or ("kind:" .. tostring(r.kind or "default"))
      )
    end
    if r.header then
      previous_rendered_grep_file = nil
      previous_rendered_grep_line_x = nil
      previous_rendered_was_grep = false
      if r.separator then
        renderer.draw_rect(x + pad, yy + math.floor(lh / 2), math.max(0, row_text_w), style.divider_size, style.divider)
      else
        renderer.draw_text(font, truncate_text(font, r.label, row_text_w), x + pad, row_y, style.accent)
      end
    else
      if idx == self.selected then
        renderer.draw_rect(x, yy, list_w, lh, style.fuzzy_searcher_result_selection_background)
      elseif idx == self.hovered_result then
        renderer.draw_rect(x, yy, list_w, lh, style.fuzzy_searcher_result_hover_background)
      end
      if r.kind == "file" or (r.kind == "path" and r.file) then
        local path = fullpath(r)
        local marker = path and pane_markers[common.path_compare_key(path)]
        if marker then
          local marker_width = marker.font:get_width(marker.text)
          renderer.draw_text(
            marker.font, marker.text,
            x + pad - marker_width,
            yy + math.floor((lh - marker.font:get_height()) / 2),
            style.titlebar_pane_number
          )
        end
      end
      if r.kind == "grep" then
        local file = tostring(r.file or "")
        local collapse_file = file ~= "" and previous_rendered_was_grep and file == previous_rendered_grep_file
        previous_rendered_grep_line_x = draw_grep_result_row(font, r, x + pad, row_y, row_text_w, collapse_file, previous_rendered_grep_line_x)
        previous_rendered_grep_file = file
        previous_rendered_was_grep = true
      elseif r.kind == "file" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        local file_text_w = r.recent and fuzzy_searcher.draw_recent_file_metadata(font, r, x + pad, row_y, row_text_w) or row_text_w
        draw_file_result_row(
          font, r.file or r.label, r.match_spans, "", x + pad, row_y,
          file_text_w, nil, r.prefix_span, r.root_role, true
        )
      elseif r.kind == "folder" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_path_result_row(font, r, x + pad, row_y, row_text_w)
      elseif r.kind == "symbol" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_symbol_result_row(font, r, x + pad, row_y, row_text_w, lh)
      elseif r.kind == "command" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_command_result_row(font, r, x + pad, row_y, row_text_w)
      elseif r.kind == "shell_command" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        fuzzy_searcher.draw_shell_command_result_row(font, r, x + pad, row_y, row_text_w)
      elseif r.kind == "project" and r.path_search then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_path_result_row(font, r, x + pad, row_y, row_text_w)
      elseif r.kind == "project" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_project_result_row(font, r, x + pad, row_y, row_text_w)
      elseif r.kind == "path" or r.kind == "create_path" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_path_result_row(font, r, x + pad, row_y, row_text_w)
      elseif r.kind == "new_project" then
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
        draw_new_project_result_row(font, r, x + pad, row_y, row_text_w)
      else
        local label, spans, prefix = result_list_label_and_spans(r)
        draw_prefixed_highlighted_text(font, prefix, label, x + pad, row_y, row_text_w, style.text, spans)
        previous_rendered_grep_file = nil
        previous_rendered_grep_line_x = nil
        previous_rendered_was_grep = false
      end
      -- Draw after the row so copied-result feedback takes precedence over
      -- fuzzy-match backgrounds as well as the selected-row background.
      local flash_color = self:copy_flash_color(idx)
      if flash_color then
        local flash_x, flash_w = self:copy_flash_bounds(font, r, x + pad, row_text_w)
        if flash_w > 0 then
          renderer.draw_rect(flash_x, yy + 1, flash_w, math.max(1, lh - 2), flash_color)
        end
      end
    end
    fuzzy_searcher._perf_scope_end(row_scope)
  end
  if has_visible_grep then
    local path_w, gap = grep_row_columns(row_text_w)
    local sx = x + pad + path_w + gap / 2
    renderer.draw_rect(sx, m.results_top, style.divider_size, math.max(0, last - self.viewport_offset + 1) * lh, style.divider)
  end
  core.pop_clip_rect()
  fuzzy_searcher._perf_scope_end(results_scope)

  phase_scope = fuzzy_searcher._perf_scope_begin("preview")
  local r = self:selected_result()
  local px, py, preview_w, preview_h = self:preview_bounds()
  if not (full_width_mode and not vertical_preview) then
    if r and r.kind == "command" then
      core.push_clip_rect(px, py, preview_w, preview_h)
      renderer.draw_text(font, "Command", px, py, style.accent)
      draw_highlighted_text(font, r.command, px, py + lh, preview_w, style.text, r.match_spans or {})
      local info = r.info or command_preview_info(r.command)
      if info and info ~= "" then
        renderer.draw_text(font, info, px, py + lh * 2, style.dim)
      end
      core.pop_clip_rect()
    elseif r and r.kind == "shell_command" then
      core.push_clip_rect(px, py, preview_w, preview_h)
      renderer.draw_text(font, "Shell Command", px, py, style.accent)
      renderer.draw_text(font, "Working directory: " .. tostring(r.cwd or ""), px, py + lh, style.dim)
      renderer.draw_text(font, "Output opens in a new Command Output View.", px, py + lh * 2, style.dim)
      core.pop_clip_rect()
    elseif r and r.kind == "create_path" then
      core.push_clip_rect(px, py, preview_w, preview_h)
      local title = r.is_folder and "Create Folder" or "Create File"
      renderer.draw_text(font, title, px, py, style.good)
      draw_highlighted_text(font, display_root(r.path), px, py + lh, preview_w, style.text, {})
      renderer.draw_text(font, "Enter: create", px, py + lh * 3, style.dim)
      if not r.is_folder then
        renderer.draw_text(font, "Ctrl+Enter: create and open in a split", px, py + lh * 4, style.dim)
      end
      core.pop_clip_rect()
    elseif r and (r.kind == "project" or (r.kind == "path" and r.is_folder)) then
      core.push_clip_rect(px, py, preview_w, preview_h)
      renderer.draw_text(font, r.kind == "project" and "Recent Project" or "Folder", px, py, style.accent)
      draw_highlighted_text(font, display_root(r.project or r.path), px, py + lh, preview_w, style.text, r.match_spans or {})
      renderer.draw_text(font, "Enter: open here", px, py + lh * 3, style.dim)
      renderer.draw_text(font, "Ctrl+Enter: open in new Anvil window", px, py + lh * 4, style.dim)
      core.pop_clip_rect()
    else
      local preview = self.preview_view
      local preview_phase_scope
      if preview then
        preview_phase_scope = fuzzy_searcher._perf_scope_begin("preview_draw")
        draw_view_in_rect(preview, px, py, preview_w, preview_h, r)
        fuzzy_searcher._perf_scope_end(preview_phase_scope)
      elseif self.preview_blocked then
        preview_phase_scope = fuzzy_searcher._perf_scope_begin("preview_placeholder")
        core.push_clip_rect(px, py, preview_w, preview_h)
        draw_preview_placeholder("Preview unavailable", self.preview_blocked.reason .. " — " .. basename(self.preview_blocked.path), px, py, preview_w, preview_h)
        core.pop_clip_rect()
        fuzzy_searcher._perf_scope_end(preview_phase_scope)
      end
    end
  end
  fuzzy_searcher._perf_scope_end(phase_scope)
  fuzzy_searcher._perf_scope_end(draw_scope)
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

poi.add_activation_provider("fuzzy-searcher-result", {
  priority = 300,
  point_at_caret = function()
    local view = current_picker()
    if not view or view:is_preview_focused() then return nil end
    return {
      kind = "fuzzy-search-result",
      line = 1,
      col = 1,
      line2 = 1,
      col2 = 2,
      text_bounds = true,
      activate = function(_, _, opts)
        view:confirm(opts and opts.placement == "split")
        return true
      end,
    }
  end,
})

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
  local buffer = view and view.buffer
  if not buffer then return "" end
  local text = buffer:get_text(table.unpack({ buffer:get_selection() })) or ""
  return text
end

local function quote_exact_query(text)
  text = tostring(text or "")
  return '"' .. text:gsub('"', '""') .. '"'
end

local function switch_picker_prefix(view, prefix)
  prefix = prefix or ""
  if view.file_picker then
    ensure_input_focus(view, "file-picker-fixed-mode")
    return false
  end
  local old_text = view.input and view.input:get_text() or ""
  local _, query = split_mode_prefix(old_text)
  if prefix == "" then
    fuzzy_searcher.record_prompt_history_text(old_text)
    fuzzy_searcher.apply_prompt_history_text(view, "", false)
    ensure_input_focus(view, "switch-prefix-files-empty")
    return
  end
  if fuzzy_searcher.prompt_mode(old_text) == prefix then
    ensure_input_focus(view, "switch-prefix-same-mode")
    return
  end
  fuzzy_searcher.record_prompt_history_text(old_text)

  local new_text, select_query
  if query == "" then
    new_text, select_query = fuzzy_searcher.restored_prompt_text(prefix)
  else
    new_text = prefix .. query
    select_query = true
  end

  fuzzy_searcher.apply_prompt_history_text(view, new_text, select_query)
  ensure_input_focus(view, "switch-prefix")
end

local function current_file_query(path)
  path = path and common.normalize_path(path)
  if not path then return "" end
  local resolved = project_paths.resolve(path)
  if resolved and resolved.entry and resolved.entry.role == "root" then
    return resolved.relpath
  end
  return path
end

local function open_current_file()
  local view = current_picker()
  local path = view and view.source_context_path or file_context.current_context_path()
  if view and view.static_mode then
    view:close()
    view = nil
  end
  if view then switch_picker_prefix(view, "")
  else open(""); view = current_picker() end
  if not view then return nil end

  local query = current_file_query(path)
  view.input:set_text(query, false)
  local info = path and system.get_file_info(path)
  if info and info.type == "file" then
    local name = common.basename(query)
    local start_col = #query - #name + 1
    view.input.textview.buffer:set_selection(1, #query + 1, 1, start_col)
  end
  view.current_query_key = nil
  view.force_refresh = true
  view.dirty = true
  view:schedule_update(true)
  ensure_input_focus(view, "open-current-file")
  return view
end

function open(prefix, opts)
  prefix = prefix or ""
  opts = opts or {}
  local view = current_picker()
  if view and view.file_picker then
    view:close("replaced")
    view = nil
  end
  if view then
    switch_picker_prefix(view, prefix)
    return view
  end
  if prefix == "#" then
    local selection = selected_text_for_search()
    if selection ~= "" then prefix = "#" .. quote_exact_query(selection) end
  end
  local initial_text, select_restored_query
  if prefix == "" or prefix == "@" then
    initial_text, select_restored_query = prefix, false
  else
    initial_text, select_restored_query = fuzzy_searcher.restored_prompt_text(prefix)
  end
  active_view = FSView(initial_text, opts)
  core.fuzzy_searcher_active_view = active_view
  if select_restored_query then
    fuzzy_searcher.apply_prompt_history_text(active_view, initial_text, true)
  end
  return active_view
end

function fuzzy_searcher.normalize_file_picker_options(opts)
  opts = opts or {}
  local select_type = opts.select or "any"
  assert(select_type == "any" or select_type == "file" or select_type == "folder",
    "File Picker select must be 'any', 'file', or 'folder'")
  assert(type(opts.submit) == "function", "File Picker requires submit")
  assert(opts.cancel == nil or type(opts.cancel) == "function", "File Picker cancel must be a function")

  local extensions, extension_list
  if opts.extensions ~= nil then
    assert(select_type ~= "folder", "a folder File Picker cannot filter file extensions")
    assert(type(opts.extensions) == "table", "File Picker extensions must be a list")
    extensions, extension_list = {}, {}
    for _, value in ipairs(opts.extensions) do
      local extension = tostring(value):lower():gsub("^%.", "")
      assert(extension ~= "" and not extension:find("[/\\]", 1),
        "File Picker extensions must contain extension names")
      if not extensions[extension] then
        extensions[extension] = true
        extension_list[#extension_list + 1] = extension
      end
    end
    assert(#extension_list > 0, "File Picker extensions must not be empty")
  end

  return {
    select = select_type,
    submit = opts.submit,
    cancel = opts.cancel,
    label = opts.label,
    extensions = extensions,
    extension_query = extension_list and ("ext:" .. table.concat(extension_list, ";")) or nil,
  }
end

function fuzzy_searcher.open_file_picker(opts)
  opts = opts or {}
  local picker = fuzzy_searcher.normalize_file_picker_options(opts)
  local view = current_picker()
  if view then view:close("replaced") end
  core.log_quiet("File Picker: open select=%s extensions=%s", picker.select,
    tostring(picker.extension_query or "none"))
  active_view = FSView(tostring(opts.query or ""), {
    source_view = opts.source_view,
    source_pane = opts.source_pane,
    file_picker = picker,
  })
  core.fuzzy_searcher_active_view = active_view
  return active_view
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
  ["fuzzy:open"] = function() open("") end,
  ["fuzzy:open_files"] = command.palette(function() open("") end, { opens_view = true }),
  ["fuzzy:open_current_file"] = command.palette(open_current_file, { opens_view = true }),
  ["fuzzy:open_paths"] = command.palette(function() open("@") end, { opens_view = true }),
  ["fuzzy:open_grep"] = command.palette(function() open("#") end, { opens_view = true }),
  ["fuzzy:open_symbols"] = command.palette(function() open("$") end, { opens_view = true }),
  ["fuzzy:open_current_buffer_symbols"] = command.palette(function() open("$$") end, { opens_view = true }),
  ["fuzzy:open_commands"] = function() open(">") end,
  ["command_output:run_shell_command"] = command.palette(function()
    local context = command.get_invocation_context() or {}
    return open("!", {
      source_view = context.source_view,
      source_pane = context.source_pane,
    })
  end, {
    keywords = { "command output", "process", "terminal" },
    opens_view = true,
  }),
})

command.add(picker_active, {
  ["fuzzy:close"] = picker_close,
})

command.add(function()
  local view = current_picker()
  return view ~= nil and not view:is_preview_focused()
end, {
  ["fuzzy:confirm"] = picker_confirm,
  ["fuzzy:confirm_side"] = picker_confirm_side,
  ["fuzzy:reveal_selected_in_explorer"] = picker_reveal_selected_in_explorer,
  ["fuzzy:fill_prompt_from_selected"] = function()
    local view = current_picker()
    if view then return view:fill_prompt_from_selected() end
  end,
  ["fuzzy:copy_selected"] = function()
    local view = current_picker()
    if view then view:copy_selected() end
  end,
  ["fuzzy:next"] = picker_next,
  ["fuzzy:previous"] = picker_previous,
  ["fuzzy:prompt_history_previous"] = function()
    local view = current_picker()
    if view then view:navigate_prompt_history(1) end
  end,
  ["fuzzy:prompt_history_next"] = function()
    local view = current_picker()
    if view then view:navigate_prompt_history(-1) end
  end,
})

command.add(function()
  local view = current_picker()
  return view and not view:is_preview_focused() and view:can_toggle_ignored_files()
end, {
  ["fuzzy:toggle_ignored_files"] = function()
    local view = current_picker()
    if view then view:toggle_ignored_files() end
  end,
})

-- Global open shortcuts intentionally override conflicting defaults.
core.fuzzy_searcher_install_global_keymaps = function()
  keymap.add({
    ["ctrl+shift+e"] = "fuzzy:open_paths",
    ["ctrl+e"] = "fuzzy:open_files",
    ["ctrl+l"] = "fuzzy:open_current_file",
    ["ctrl+shift+j"] = "fuzzy:open_symbols",
    ["ctrl+j"] = "fuzzy:open_current_buffer_symbols",
    ["ctrl+shift+f"] = "fuzzy:open_grep",
    ["ctrl+shift+a"] = "fuzzy:open_commands",
  }, true)
end
core.fuzzy_searcher_install_global_keymaps()

-- Picker-local navigation. These are prepended, not overwritten: when the
-- picker predicate is false, Anvil falls through to the normal bindings.
core.fuzzy_searcher_install_picker_keymaps = function()
  keymap.add({
    ["escape"] = "fuzzy:close",
    ["return"] = "fuzzy:confirm",
    ["keypad enter"] = "fuzzy:confirm",
    ["ctrl+return"] = "fuzzy:confirm_side",
    ["ctrl+l"] = "fuzzy:open_current_file",
    ["ctrl+shift+l"] = "fuzzy:reveal_selected_in_explorer",
    ["ctrl+c"] = "fuzzy:copy_selected",
    ["ctrl+i"] = "fuzzy:toggle_ignored_files",
    ["tab"] = "fuzzy:fill_prompt_from_selected",
    ["up"] = "fuzzy:previous",
    ["down"] = "fuzzy:next",
    ["alt+left"] = "fuzzy:prompt_history_previous",
    ["alt+right"] = "fuzzy:prompt_history_next",
  })
end
core.fuzzy_searcher_install_picker_keymaps()

local cli = package.loaded["core.cli"]
if not ((cli and cli.last_command == "test")
  or (type(ARGS) == "table" and ARGS[2] == "test"))
then
  core.add_thread(function()
    -- Workspace Project Paths are restored just after plugins load. Let that
    -- settle, then build the first immutable file snapshot before the picker
    -- is needed.
    coroutine.yield(0.5)
    if core.projects and core.projects[1] then prewarm_file_index() end
  end)
end

return {
  open = open,
  open_file_picker = fuzzy_searcher.open_file_picker,
  open_static_results = open_static_results,
  _test = {
    everything_folder_search_params = everything_folder_search_params,
    everything_folder_search_query = everything_folder_search_query,
    everything_file_search_params = everything_file_search_params,
    everything_file_search_query = everything_file_search_query,
    everything_endpoint = everything_endpoint,
    everything_path_depth = everything_path_depth,
    sort_path_results = sort_path_results,
    everything_result_from_item = everything_result_from_item,
    everything_state = function() return everything.state end,
    set_everything_state = function(state)
      everything.state = state
      everything.search_generation = everything.search_generation + 1
    end,
    format_recent_file_age = fuzzy_searcher.format_recent_file_age,
    git_kind_for_file = fuzzy_searcher.git_kind_for_file,
    draw_recent_file_metadata = fuzzy_searcher.draw_recent_file_metadata,
    draw_file_result_row = draw_file_result_row,
    draw_grep_result_row = draw_grep_result_row,
    split_mode_prefix = split_mode_prefix,
    prompt_uses_file_index = prompt_uses_file_index,
    normalize_prompt_history = fuzzy_searcher.normalize_prompt_history,
    clear_prompt_history = function()
      fuzzy_searcher.prompt_history_loaded = true
      fuzzy_searcher.prompt_history = {}
      storage.save("fuzzy_searcher", "prompt_history", {
        version = 2,
        modes = fuzzy_searcher.prompt_history,
      })
    end,
    prompt_history = function(mode)
      local history = fuzzy_searcher.prompt_history_for_mode(mode)
      return { table.unpack(history) }
    end,
    file_display_item = fuzzy_searcher.file_display_item,
    fullpath = fullpath,
    file_result_key = file_result_key,
    file_scan_command = file_scan_command,
    file_index_status = function()
      return {
        indexing = fuzzy_searcher.files_indexing,
        files = fuzzy_searcher.files_cache,
        count = file_index_count(),
        folder_count = folder_index_count(),
        native = native_project_file_index_ready(),
        materialized = fuzzy_searcher.files_materialized_generation == fuzzy_searcher.files_generation,
        diagnostics = fuzzy_searcher.files_last_scan_diagnostics,
        root_signature = fuzzy_searcher.files_cache_root,
        generation = fuzzy_searcher.files_generation,
      }
    end,
    refresh_file_index_for_test = function()
      fuzzy_searcher.files_cache_test_override = false
      return fuzzy_searcher.refresh_file_index_for_picker_open()
    end,
    prewarm_file_index_for_test = function()
      fuzzy_searcher.files_cache_test_override = false
      return prewarm_file_index()
    end,
    cancel_file_index_for_test = cancel_file_index_scan,
    build_scope = build_scope,
    decorate_grep_result = decorate_grep_result,
    grep_path_match_class = fuzzy_searcher.grep_order.path_match_class,
    order_grep_results = fuzzy_searcher.grep_order.results,
    retain_top_grep_result = fuzzy_searcher.grep_order.retain_top,
    symbol_result_from_item = symbol_result_from_item,
    result_main_text = fuzzy_searcher.result_main_text,
    set_file_cache_for_test = function(files)
      -- Invalidate any filesystem scan started by an earlier test before publishing
      -- the deterministic fixture cache.
      cancel_file_index_scan()
      fuzzy_searcher.files_generation = fuzzy_searcher.files_generation + 1
      clear_native_file_index()
      fuzzy_searcher.files_cache_root = fuzzy_searcher.file_roots_signature(project_paths.search_roots("files"))
      fuzzy_searcher.files_cache = files or {}
      fuzzy_searcher.files_cache_test_override = true
      fuzzy_searcher.files_scope_generation = fuzzy_searcher.files_scope_generation + 1
    end,
    file_search_rows = function(query, files, limit)
      local recent_matches, skip_keys = collect_recent_file_matches(query or "", nil)
      local general_matches = {}
      local empty_query = trim_query(query or "") == ""
      for _, item in ipairs(files or {}) do
        local key = file_result_key(item)
        if key and not skip_keys[key] then
          local score, spans = 0, {}
          if not empty_query then score, spans = fuzzy_match_file_fast(query, item) end
          if score then
            general_matches[#general_matches+1] = { item = item, text = item, score = fuzzy_searcher.adjusted_file_score(score, item), spans = spans or {} }
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
