-- mod-version:3 priority:250
-- Project-scoped PowerShell command slots with read-only Right Pane output.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local json = require "core.json"
local process = require "core.process"
local storage = require "core.storage"
local style = require "core.style"
local Tabs = require "core.tabs"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local file_context = require "core.file_context"
local panes = require "core.panes"

local M = core.command_slots or {}
core.command_slots = M

local SLOT_DEFS = {
  { index = 1, key = "a", label = "A" },
  { index = 2, key = "s", label = "S" },
  { index = 3, key = "d", label = "D" },
  { index = 4, key = "f", label = "F" },
}

local STORAGE_MODULE = "command-slots"
local DONE_PREFIX = "__ANVIL_COMMAND_SLOT_DONE__"
local MARKER_TAIL_BYTES = 512
local READ_CHUNK_BYTES = 8192
local COMMAND_OUTPUT_PANEL_VERSION = 2

M.slots = M.slots or {}
M.project_state_cache = M.project_state_cache or {}
M.token_counter = M.token_counter or 0

local function running_lua_tests()
  for _, arg in ipairs(ARGS or {}) do
    if arg == "test" then return true end
  end
  return false
end

local function root_project_path()
  local project = core.root_project and core.root_project()
  return project and project.path or system.getcwd()
end

local function is_uri_like_path(path)
  path = tostring(path or "")
  if path:match("^%a[%w+.-]*://") then return true end
  if path:match("^%a[%w+.-]*:") and not path:match("^%a:[/\\]") then return true end
  return false
end

local function clean_candidate_path(path)
  path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
  path = path:gsub("^[\"']", ""):gsub("[\"']$", "")
  path = path:gsub("^[%-%>:%s]+", "")
  path = path:gsub("[%s,;]+$", "")
  while #path > 1 and path:match("[%.%)]$") do
    path = path:sub(1, -2)
  end
  return path
end

local function existing_file(path)
  local info = path and system.get_file_info(path)
  return info and info.type ~= "dir"
end

local function resolve_output_path(path, root)
  path = clean_candidate_path(path)
  if path == "" or is_uri_like_path(path) then return nil end
  local candidate
  if common.is_absolute_path(path) then
    candidate = common.normalize_path(path)
  else
    candidate = common.normalize_path((root or root_project_path()) .. PATHSEP .. path)
  end
  if existing_file(candidate) then return candidate end
end

local function resolve_output_candidate(candidate, root)
  local resolved = resolve_output_path(candidate and candidate.source_path, root)
  if not resolved then return nil end
  return {
    line = candidate.line,
    col = candidate.col,
    line2 = candidate.line2,
    col2 = candidate.col2,
    kind = "command-output-location",
    label = candidate.label or resolved,
    path = resolved,
    target_line = candidate.target_line,
    target_col = candidate.target_col,
    text_bounds = true,
  }
end

local function add_output_poi(list, seen, root, line_no, col1, col2, path, target_line, target_col, label)
  path = clean_candidate_path(path)
  if path == "" or is_uri_like_path(path) then return end
  target_line = math.max(1, math.floor(tonumber(target_line) or 1))
  target_col = math.max(1, math.floor(tonumber(target_col) or 1))
  col1 = math.max(1, math.floor(tonumber(col1) or 1))
  col2 = math.max(col1 + 1, math.floor(tonumber(col2) or col1 + 1))
  local key = table.concat({ line_no, col1, col2, path, target_line, target_col }, "\0")
  if seen[key] then return end
  seen[key] = true
  list[#list + 1] = {
    line = line_no,
    col = col1,
    line2 = line_no,
    col2 = col2,
    source_path = path,
    label = label or path,
    target_line = target_line,
    target_col = target_col,
  }
end

local function candidate_starts_in_uri(line, col1)
  local prefix = line:sub(1, math.max(0, (col1 or 1) - 1))
  local token_prefix = prefix:match("([^%s\"']*)$") or ""
  token_prefix = token_prefix:gsub("^[%(%[%{%<]+", "")
  return token_prefix:match("%a[%w+.-]*:") ~= nil
end

local function add_line_matches(pois, seen, root, line, line_no)
  local function add(col1, col2, path, target_line, target_col, label)
    if candidate_starts_in_uri(line, col1) then return end
    return add_output_poi(pois, seen, root, line_no, col1, col2, path, target_line, target_col, label)
  end

  local init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("File%s+\"([^\"]+)\"%,%s+line%s+(%d+)", init)
    if not s then break end
    if not line:sub(e + 1):match("^,%s*column") then
      add(s, e + 1, path, target_line, 1, line:sub(s, e))
    end
    init = e + 1
  end

  init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("\"([^\"]+)\"%,%s+line%s+(%d+)%,%s+column%s+(%d+)", init)
    if not s then break end
    if line:sub(math.max(1, s - 5), s - 1) ~= "File " then
      add(s, e + 1, path, target_line, target_col, line:sub(s, e))
    end
    init = e + 1
  end

  init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("File%s+\"([^\"]+)\"%,%s+line%s+(%d+)%,%s+column%s+(%d+)", init)
    if not s then break end
    add(s, e + 1, path, target_line, target_col, line:sub(s, e))
    init = e + 1
  end

  init = 1
  while true do
    local s, e, path, target_line, target_col = line:find("%-%-%>%s*([^:%s][^:\r\n]-):(%d+):(%d+)", init)
    if not s then break end
    local path_offset = line:find(path, s, true) or s
    add(path_offset, e + 1, path, target_line, target_col, line:sub(path_offset, e))
    init = e + 1
  end

  for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+):(%d+)()") do
    add(s, e, path, target_line, target_col)
  end
  for s, path, target_line, e in line:gmatch("()([A-Za-z]:[/\\][^:\r\n]-):(%d+)()") do
    if not line:sub(e):match("^:%d") then
      add(s, e, path, target_line, 1)
    end
  end
  for s, path, target_line, target_col, e in line:gmatch("()([^%s:\"'()<>|]+):(%d+):(%d+)()") do
    add(s, e, path, target_line, target_col)
  end
  for s, path, target_line, e in line:gmatch("()([^%s:\"'()<>|]+):(%d+)()") do
    if not line:sub(e):match("^:%d") then
      add(s, e, path, target_line, 1)
    end
  end

  for s, path, target_line, target_col, e in line:gmatch("()([A-Za-z]:[/\\][^%(%)\r\n]-)%((%d+)%,(%d+)%)()") do
    add(s, e, path, target_line, target_col)
  end
  for s, path, target_line, e in line:gmatch("()([A-Za-z]:[/\\][^%(%)\r\n]-)%((%d+)%)()") do
    if line:sub(e, e) ~= "," then
      add(s, e, path, target_line, 1)
    end
  end
  for s, path, target_line, target_col, e in line:gmatch("()([^%s:\"'<>|]+)%((%d+)%,(%d+)%)()") do
    add(s, e, path, target_line, target_col)
  end
  for s, path, target_line, e in line:gmatch("()([^%s:\"'<>|]+)%((%d+)%)()") do
    if line:sub(e, e) ~= "," then
      add(s, e, path, target_line, 1)
    end
  end
end

local function sort_output_points(points)
  table.sort(points, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.col < b.col
  end)
  return points
end

local function extract_output_location_candidates(text)
  local candidates, seen = {}, {}
  local line_no = 1
  text = tostring(text or "")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    add_line_matches(candidates, seen, nil, line, line_no)
    line_no = line_no + 1
  end
  return sort_output_points(candidates)
end

local function resolve_output_candidates(candidates, root)
  local points = {}
  for _, candidate in ipairs(candidates or {}) do
    local poi = resolve_output_candidate(candidate, root)
    if poi then points[#points + 1] = poi end
  end
  return sort_output_points(points)
end

local function extract_output_location_pois(text, opts)
  opts = opts or {}
  return resolve_output_candidates(extract_output_location_candidates(text), opts.root or root_project_path())
end

M.extract_output_location_pois = extract_output_location_pois

local function slot_for_index(index)
  return M.slots[index]
end

local function is_blank(text)
  return not text or text:match("^%s*$") ~= nil
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function single_line(text)
  return trim(text):gsub("%s+", " ")
end

local function output_history_limit()
  return math.max(1, math.floor(tonumber(config.plugins.command_slots.max_output_history) or 100))
end

local function current_output_entry(slot)
  local history = slot and slot.output_history or nil
  if not history or #history == 0 then return nil end
  local index = common.clamp(math.floor(tonumber(slot.output_history_index) or #history), 1, #history)
  slot.output_history_index = index
  return history[index]
end

local function output_tab_title(slot)
  local label = slot and slot.label or "?"
  local entry = current_output_entry(slot)
  local command_text = entry and entry.command_text or slot and slot.last_command_text or ""
  local snippet = single_line(command_text)
  if snippet == "" then snippet = "No commands" end
  if snippet:ulen() > 48 then
    snippet = snippet:usub(1, 47) .. "…"
  end
  return string.format("%s: %s", label, snippet)
end

local function push_output_entry(slot, command_text, cwd, text)
  slot.output_history = slot.output_history or {}
  local entry = {
    command_text = command_text or "",
    cwd = cwd or "",
    text = text or "",
    started_at = system.get_time(),
  }
  table.insert(slot.output_history, entry)
  while #slot.output_history > output_history_limit() do
    table.remove(slot.output_history, 1)
  end
  slot.output_history_index = #slot.output_history
  slot.current_output_entry = entry
  return entry
end

local function normalize_history(history)
  local result, seen = {}, {}
  if type(history) == "table" then
    for _, value in ipairs(history) do
      if type(value) == "string" and not is_blank(value) and not seen[value] then
        seen[value] = true
        result[#result + 1] = value
      end
    end
  end
  return result
end

local function project_state(project_path)
  project_path = project_path or root_project_path()
  local state = M.project_state_cache[project_path]
  if not state then
    local loaded = storage.load(STORAGE_MODULE, project_path)
    state = { commands = {}, history = {} }
    if type(loaded) == "table" then
      local loaded_commands = type(loaded.commands) == "table" and loaded.commands or loaded
      for i = 1, #SLOT_DEFS do
        local value = loaded_commands[i]
        state.commands[i] = type(value) == "string" and value or ""
      end
      state.history = normalize_history(loaded.history)
    end
    M.project_state_cache[project_path] = state
  end
  return state, project_path
end

local function project_commands(project_path)
  local state, key = project_state(project_path)
  return state.commands, key, state
end

local function save_project_state(project_path, state)
  storage.save(STORAGE_MODULE, project_path, {
    commands = state.commands,
    history = state.history,
  })
end

function M.get_command(index, project_path)
  local commands = project_commands(project_path)
  return commands[index] or ""
end

function M.set_command(index, text, project_path)
  local commands, key, state = project_commands(project_path)
  commands[index] = text or ""
  save_project_state(key, state)
  core.log_quiet("Command Slot %d: stored command for project %s", index, tostring(key))
end

function M.record_history(command_text, project_path)
  if is_blank(command_text) then return end
  local state, key = project_state(project_path)
  local history = normalize_history(state.history)
  for i = #history, 1, -1 do
    if history[i] == command_text then table.remove(history, i) end
  end
  table.insert(history, 1, command_text)
  local max_history = math.max(1, tonumber(config.plugins.command_slots.max_history) or 100)
  while #history > max_history do table.remove(history) end
  state.history = history
  save_project_state(key, state)
end

local function suggestion_matches(text, candidate)
  if is_blank(text) then return true end
  text = text:lower()
  return tostring(candidate or ""):lower():find(text, 1, true) ~= nil
end

function M.suggest_commands(text, project_path)
  local state = project_state(project_path)
  local result, seen = {}, {}
  local function add(value)
    if type(value) ~= "string" or is_blank(value) or seen[value] or not suggestion_matches(text, value) then return end
    seen[value] = true
    result[#result + 1] = { text = value }
  end
  for _, value in ipairs(state.history or {}) do add(value) end
  for i = 1, #SLOT_DEFS do add(state.commands[i]) end
  return result
end

function M._build_powershell_controller()
  return table.concat({
    "$global:LASTEXITCODE = $null",
    "$__anvil_token = 'unknown'",
    "$__anvil_exit = 1",
    "try {",
    "  [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)",
    "  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)",
    "  $OutputEncoding = [Console]::OutputEncoding",
    "  if (Get-Variable -Name PSStyle -Scope Global -ErrorAction SilentlyContinue) { $PSStyle.OutputRendering = 'PlainText' }",
    "  $env:NO_COLOR = '1'",
    "  $env:CLICOLOR = '0'",
    "  $env:TERM = 'dumb'",
    "  $__anvil_payload_text = [Console]::In.ReadToEnd()",
    "  $__anvil_payload = $__anvil_payload_text | ConvertFrom-Json",
    "  $__anvil_token = [string]$__anvil_payload.token",
    "  Set-Location -LiteralPath ([string]$__anvil_payload.cwd)",
    "  $__anvil_script = [scriptblock]::Create([string]$__anvil_payload.command)",
    "  & $__anvil_script",
    "  $__anvil_success = $?",
    "  $__anvil_native_exit = $global:LASTEXITCODE",
    "  if ($null -ne $__anvil_native_exit) { $__anvil_exit = [int]$__anvil_native_exit } elseif ($__anvil_success) { $__anvil_exit = 0 } else { $__anvil_exit = 1 }",
    "} catch {",
    "  Write-Error $_",
    "  $__anvil_exit = 1",
    "}",
    "[Console]::Out.WriteLine('" .. DONE_PREFIX .. "' + $__anvil_token + ':' + $__anvil_exit)",
    "exit $__anvil_exit",
  }, "\n")
end

function M._build_powershell_payload(command_text, cwd, token)
  return json.encode({
    command = command_text or "",
    cwd = cwd or root_project_path(),
    token = tostring(token or "unknown"),
  })
end

local CommandOutputDoc = Doc:extend()

function CommandOutputDoc:__tostring() return "CommandOutputDoc" end

function CommandOutputDoc:new()
  CommandOutputDoc.super.new(self)
  self.output_text = ""
  self:clean()
end

function CommandOutputDoc:is_dirty()
  return false
end

function CommandOutputDoc:save()
  return true
end

function CommandOutputDoc:reload()
end

function CommandOutputDoc:_with_internal_mutation(fn)
  self.__command_output_mutating = true
  local ok, a, b, c = pcall(fn)
  self.__command_output_mutating = false
  if not ok then error(a, 2) end
  return a, b, c
end

function CommandOutputDoc:insert(line, col, text)
  if not self.__command_output_mutating then return end
  return CommandOutputDoc.super.insert(self, line, col, text)
end

function CommandOutputDoc:remove(line1, col1, line2, col2)
  if not self.__command_output_mutating then return end
  return CommandOutputDoc.super.remove(self, line1, col1, line2, col2)
end

function CommandOutputDoc:can_apply_edits(edits, opts)
  return self.__command_output_mutating == true
end

function CommandOutputDoc:text_input()
end

function CommandOutputDoc:ime_text_editing()
end

function CommandOutputDoc:undo()
end

function CommandOutputDoc:redo()
end

function CommandOutputDoc:delete_to_cursor()
end

function CommandOutputDoc:delete_to()
end

function CommandOutputDoc:replace()
end

function CommandOutputDoc:indent_text()
end

function CommandOutputDoc:_display_text()
  local text = self.output_text or ""
  if text == "" or text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  return text
end

function CommandOutputDoc:_replace_display_text(selection_mode)
  local old_last_line = #self.lines
  local old_selections = { table.unpack(self.selections or {}) }
  local old_last_selection = self.last_selection or 1

  self.lines = { "\n" }
  self.clean_lines = {}
  self.cache = {
    col_x = {},
    ulen = {},
  }
  self.highlighter:soft_reset()
  CommandOutputDoc.super.insert(self, 1, 1, self:_display_text())

  if selection_mode == "preserve" and #old_selections >= 4 then
    self.selections = {}
    for i = 1, #old_selections, 4 do
      local function adjusted_position(line, col)
        if line == old_last_line then line = #self.lines end
        return self:sanitize_position(line, col)
      end
      local line1, col1 = adjusted_position(old_selections[i], old_selections[i + 1])
      local line2, col2 = adjusted_position(old_selections[i + 2], old_selections[i + 3])
      self:set_selections((i - 1) / 4 + 1, line1, col1, line2, col2)
    end
    self.last_selection = common.clamp(old_last_selection, 1, math.max(1, #self.selections / 4))
  else
    self:set_selection(#self.lines, 1)
  end

  self:clear_undo_redo()
  self:clean()
end

function CommandOutputDoc:set_text(text)
  self.output_text = tostring(text or "")
  self:_with_internal_mutation(function()
    self:_replace_display_text("end")
  end)
end

function CommandOutputDoc:append(text)
  if not text or text == "" then return end
  self.output_text = (self.output_text or "") .. text
  self:_with_internal_mutation(function()
    self:_replace_display_text("preserve")
  end)
end

local CommandOutputView = DocView:extend()

function CommandOutputView:__tostring() return "CommandOutputView" end

function CommandOutputView:new(slot)
  CommandOutputView.super.new(self, CommandOutputDoc())
  self.slot = slot
  self.command_output_view = true
  self.poi_cache = nil
  file_context.exclude_content_view(self)
end

function CommandOutputView:get_name()
  return output_tab_title(self.slot)
end

function CommandOutputView:get_filename()
  return nil
end

function CommandOutputView:supports_text_input()
  return false
end

function CommandOutputView:on_text_input()
end

function CommandOutputView:try_close(do_close)
  if self.slot and self.slot.running then
    M.kill_slot(self.slot.index, "closed")
  end
  do_close()
end

function CommandOutputView:save_displayed_entry_state()
  local entry = self.displayed_entry
  if not entry then return end
  entry.selection_state = self:get_selection_state()
  entry.scroll_x, entry.scroll_to_x = self.scroll.x or 0, self.scroll.to.x or self.scroll.x or 0
  entry.scroll_y, entry.scroll_to_y = self.scroll.y or 0, self.scroll.to.y or self.scroll.y or 0
end

function CommandOutputView:show_entry(entry, opts)
  opts = opts or {}
  if self.displayed_entry and self.displayed_entry ~= entry then
    self:save_displayed_entry_state()
  end

  self.displayed_entry = entry
  self.poi_cache = nil
  self.doc:set_text(entry and entry.text or "")

  if entry and entry.selection_state then
    self:set_selection_state(entry.selection_state)
    self.scroll.x = entry.scroll_x or entry.scroll_to_x or 0
    self.scroll.to.x = entry.scroll_to_x or entry.scroll_x or 0
    self.scroll.y = entry.scroll_y or entry.scroll_to_y or 0
    self.scroll.to.y = entry.scroll_to_y or entry.scroll_y or 0
  elseif opts.follow_end then
    self.doc:set_selection(#self.doc.lines, 1)
    self:scroll_to_make_visible(#self.doc.lines, math.huge, true)
  else
    self.doc:set_selection(1, 1)
    self.scroll.x, self.scroll.to.x = 0, 0
    self.scroll.y, self.scroll.to.y = 0, 0
  end
  core.redraw = true
end

function CommandOutputView:clear_for_run(command_text, cwd)
  local header = string.format("PS %s> %s\n\n", tostring(cwd or ""), tostring(command_text or ""))
  self.displayed_entry = nil
  self.poi_cache = nil
  self.doc:set_text(header)
  self:scroll_to_make_visible(#self.doc.lines, math.huge, true)
end

function CommandOutputView:append_text(text)
  local old_scroll_x, old_scroll_to_x = self.scroll.x, self.scroll.to.x
  local old_scroll_y, old_scroll_to_y = self.scroll.y, self.scroll.to.y
  local old_last_line = #self.doc.lines
  local line1, col1, line2, col2 = self.doc:get_selection()
  local follow_output = line1 == old_last_line and line2 == old_last_line

  self.doc:append(text)
  self.poi_cache = nil

  if follow_output then
    self:scroll_to_make_visible(#self.doc.lines, col1, false)
    self.scroll.x, self.scroll.to.x = old_scroll_x, old_scroll_to_x
  else
    self.scroll.x, self.scroll.to.x = old_scroll_x, old_scroll_to_x
    self.scroll.y, self.scroll.to.y = old_scroll_y, old_scroll_to_y
  end
  core.redraw = true
end

function CommandOutputView:cache_key_for_pois()
  local entry = self.displayed_entry
  return entry or self.doc.output_text or ""
end

local function build_poi_line_index(points)
  local by_line = {}
  for _, poi in ipairs(points) do
    local line_points = by_line[poi.line]
    if not line_points then
      line_points = {}
      by_line[poi.line] = line_points
    end
    line_points[#line_points + 1] = poi
  end
  return by_line
end

function CommandOutputView:get_points_of_interest(opts)
  local text = self.doc.output_text or ""
  local key = self:cache_key_for_pois()
  local root = root_project_path()
  local cache = self.poi_cache
  if not (cache and cache.key == key and cache.text == text and cache.root == root) then
    cache = {
      key = key,
      text = text,
      root = root,
      candidates = extract_output_location_candidates(text),
    }
    self.poi_cache = cache
  end

  opts = opts or {}
  local now = system.get_time()
  local should_revalidate = opts.force_revalidate == true
    or not cache.points
    or now - (cache.validated_at or 0) >= 1
  if should_revalidate then
    cache.points = resolve_output_candidates(cache.candidates, root)
    cache.by_line = build_poi_line_index(cache.points)
    cache.validated_at = now
  end
  return cache.points
end

function CommandOutputView:get_point_of_interest_at(line, col, opts)
  opts = opts or {}
  opts.force_revalidate = true
  local points = self:get_points_of_interest(opts)
  for _, poi in ipairs(points) do
    if poi.line == line and col >= poi.col and col < (poi.col2 or poi.col) then
      return poi
    end
  end
end

function CommandOutputView:activate_point_of_interest(poi, opts)
  if not poi or not poi.path or not existing_file(poi.path) then return false end
  opts = opts or {}
  local preserve_focus = opts.preserve_focus
  if preserve_focus == nil then preserve_focus = true end
  return panes.open_path(poi.path, {
    pane = opts.pane or "left",
    line = poi.target_line or poi.line,
    col = poi.target_col or 1,
    focus = opts.pane == "right" and true or nil,
    preserve_focus = preserve_focus,
    restore_focus = preserve_focus and core.active_view or nil,
  })
end

function CommandOutputView:draw_poi_underlines(line, x, y)
  self:get_points_of_interest({ silent = true })
  local cache = self.poi_cache
  local points = cache and cache.by_line and cache.by_line[line]
  if not points or #points == 0 then return end
  local lh = self:get_line_height()
  local thickness = math.max(1, math.floor(SCALE))
  local underline_y = y + lh - thickness * 2
  local min_x = self.position.x
  local max_x = self.position.x + self.size.x
  for _, poi in ipairs(points) do
    if poi.text_bounds and poi.line == line and (poi.line2 or poi.line) == line then
      local x1 = x + self:get_col_x_offset(line, poi.col)
      local x2 = x + self:get_col_x_offset(line, poi.col2 or poi.col)
      if x2 > min_x and x1 < max_x and x2 > x1 then
        x1 = math.max(x1, min_x)
        x2 = math.min(x2, max_x)
        renderer.draw_rect(x1, underline_y, x2 - x1, thickness, style.accent or style.text)
      end
    end
  end
end

function CommandOutputView:draw_line_body(line, x, y)
  local height = CommandOutputView.super.draw_line_body(self, line, x, y)
  self:draw_poi_underlines(line, x, y)
  return height
end

local CommandOutputPanel = View:extend()

local function new_command_output_tab_bar(owner)
  return Tabs(owner, {
    should_show = function() return true end,
    log_prefix = "Command Output tabs",
  })
end

function CommandOutputPanel:__tostring() return "CommandOutputPanel" end

function CommandOutputPanel:new()
  CommandOutputPanel.super.new(self)
  self.command_output_panel = true
  self.command_output_panel_version = COMMAND_OUTPUT_PANEL_VERSION
  self.active_slot_index = self.active_slot_index or 1
  self.views = self.views or {}
  self.tab_offset = self.tab_offset or 1
  self.tab_shift = self.tab_shift or 0
  self.hovered_tab = nil
  self.hovered_scroll_button = 0
  self.tab_bar = new_command_output_tab_bar(self)
  self.cursor = "arrow"
  file_context.exclude_content_view(self)
end

function CommandOutputPanel:get_name()
  return "Command Output"
end

function CommandOutputPanel:get_tab_bar()
  if not self.tab_bar or self.tab_bar.owner ~= self then
    self.tab_bar = new_command_output_tab_bar(self)
  end
  return self.tab_bar
end

function CommandOutputPanel:tab_bar_height()
  return self:get_tab_bar():get_height()
end

function CommandOutputPanel:slot_view(slot)
  if not slot then return nil end
  if not slot.view then
    slot.view = CommandOutputView(slot)
  end
  slot.view.__pane_focus_owner = self
  self.views = self.views or {}
  if slot.index then self.views[slot.index] = slot.view end
  return slot.view
end

function CommandOutputPanel:sync_slot_views()
  self.views = self.views or {}
  for _, slot in ipairs(M.slots) do
    self.views[slot.index] = self:slot_view(slot)
  end
  for i = #SLOT_DEFS + 1, #self.views do
    self.views[i] = nil
  end
  self.active_slot_index = common.clamp(math.floor(tonumber(self.active_slot_index) or 1), 1, #SLOT_DEFS)
  self.active_view = self.views[self.active_slot_index] or self.views[1]
  return self.views
end

function CommandOutputPanel:active_slot()
  return M.slots[self.active_slot_index] or M.slots[1]
end

function CommandOutputPanel:active_output_view()
  self:sync_slot_views()
  return self.active_view
end

function CommandOutputPanel:get_focus_view()
  return self:active_output_view()
end

function CommandOutputPanel:layout_active_view()
  local view = self:active_output_view()
  if not view then return end
  local th = self:tab_bar_height()
  view.position.x = self.position.x
  view.position.y = self.position.y + th
  view.size.x = self.size.x
  view.size.y = math.max(0, self.size.y - th)
end

function CommandOutputPanel:select_slot(index, opts)
  opts = opts or {}
  self:sync_slot_views()
  index = common.clamp(math.floor(tonumber(index) or 1), 1, #SLOT_DEFS)
  local old_view = self.active_view
  if old_view then old_view:save_displayed_entry_state() end

  self.active_slot_index = index
  self.active_view = self:slot_view(self:active_slot())
  panes.remember_focus(self, self.active_view)
  self.manual_tab_scroll = nil
  local view = self.active_view
  if old_view and old_view ~= view and old_view.on_mouse_left then
    old_view:on_mouse_left()
  end
  if view then
    view:show_entry(current_output_entry(self:active_slot()), { follow_end = opts.follow_end == true })
  end
  self:layout_active_view()
  self:get_tab_bar():scroll_to_visible(index)

  if opts.focus == true and view then
    core.set_active_view(view)
  end
  core.redraw = true
  return view
end

function CommandOutputPanel:switch_tab(delta)
  return self:select_slot(((self.active_slot_index - 1 + delta) % #SLOT_DEFS) + 1, { focus = true })
end

function CommandOutputPanel:switch_history(delta)
  local slot = self:active_slot()
  local history = slot and slot.output_history or nil
  if not history or #history == 0 then return nil end
  local view = self:active_output_view()
  if view then view:save_displayed_entry_state() end
  slot.output_history_index = common.clamp((slot.output_history_index or #history) + delta, 1, #history)
  local entry = current_output_entry(slot)
  if view then view:show_entry(entry) end
  core.log_quiet("Command Slot %d: selected output history entry %d/%d", slot.index, slot.output_history_index or 0, #history)
  core.redraw = true
  return entry
end

function CommandOutputPanel:tab_at_point(x, y)
  self:sync_slot_views()
  return self:get_tab_bar():get_tab_overlapping_point(x, y)
end

function CommandOutputPanel:draw_tabs()
  self:sync_slot_views()
  return self:get_tab_bar():draw_tabs()
end

function CommandOutputPanel:update()
  self:sync_slot_views()
  self:layout_active_view()
  local view = self.active_view
  if view then view:update() end
  local mouse = core.root_panel and core.root_panel.mouse
  if mouse then
    self:get_tab_bar():update(mouse.x, mouse.y)
  else
    self:get_tab_bar():scroll_to_visible()
    self:get_tab_bar():update_animation()
  end
end

function CommandOutputPanel:draw()
  self:draw_background(style.background)
  self:draw_tabs()
  self:layout_active_view()
  local view = self.active_view
  if view then
    core.push_clip_rect(view.position.x, view.position.y, view.size.x, view.size.y)
    view:draw()
    core.pop_clip_rect()
  end
end

function CommandOutputPanel:on_mouse_pressed(button, x, y, clicks)
  local tab_bar = self:get_tab_bar()
  local scroll_button = tab_bar:get_scroll_button_index(x, y)
  if scroll_button then
    tab_bar:scroll_tabs(scroll_button)
    return true
  end
  local tab = self:tab_at_point(x, y)
  if tab then
    self:select_slot(tab, { focus = true })
    return true
  end
  local view = self:active_output_view()
  if view then
    core.set_active_view(view)
    return view:on_mouse_pressed(button, x, y, clicks)
  end
  return true
end

function CommandOutputPanel:on_mouse_released(button, x, y, ...)
  if self:get_tab_bar():is_in_tab_area(x, y) then return true end
  local view = self:active_output_view()
  if view then return view:on_mouse_released(button, x, y, ...) end
end

function CommandOutputPanel:on_mouse_moved(x, y, dx, dy)
  local tab_bar = self:get_tab_bar()
  tab_bar:update_hover(x, y)
  local view = self:active_output_view()
  if view and not tab_bar:is_in_tab_area(x, y) then
    local result = view:on_mouse_moved(x, y, dx, dy)
    self.cursor = view.cursor or "ibeam"
    return result
  end
  self.cursor = "arrow"
end

function CommandOutputPanel:on_mouse_left()
  self.hovered_tab = nil
  self.hovered_scroll_button = 0
  local view = self:active_output_view()
  if view then view:on_mouse_left() end
end

function CommandOutputPanel:on_mouse_wheel(delta_y, delta_x, ...)
  local mouse = core.root_panel and core.root_panel.mouse
  local tab_bar = self:get_tab_bar()
  if mouse and tab_bar:is_in_tab_area(mouse.x, mouse.y) then
    local dir
    if math.abs(delta_x or 0) > math.abs(delta_y or 0) then
      dir = delta_x > 0 and 1 or 2
    elseif delta_y ~= 0 then
      dir = delta_y > 0 and 1 or 2
    end
    if dir and tab_bar:can_scroll_tabs(dir) then
      tab_bar:scroll_tabs(dir)
    end
    return true
  end
  local view = self:active_output_view()
  if view then return view:on_mouse_wheel(delta_y, delta_x, ...) end
end

function CommandOutputPanel:try_close(do_close)
  for _, slot in ipairs(M.slots) do
    if slot.running then M.kill_slot(slot.index, "closed") end
  end
  do_close()
end

M.CommandOutputDoc = CommandOutputDoc
M.CommandOutputView = CommandOutputView
M.CommandOutputPanel = CommandOutputPanel

local function ensure_output_panel()
  if not M.output_panel or not M.output_panel.command_output_panel or M.output_panel.command_output_panel_version ~= COMMAND_OUTPUT_PANEL_VERSION then
    if M.output_panel then panes.remove_view(M.output_panel, { force = true, focus_left = false }) end
    M.output_panel = CommandOutputPanel()
  end
  if not panes.contains_view("right", M.output_panel) then
    panes.register_view("right", "command-output", M.output_panel)
  end
  return M.output_panel
end

local function ensure_output_view(slot, focus)
  local panel = ensure_output_panel()
  panes.show("right", { view = panel, focus = focus == true })
  return panel:select_slot(slot.index, { focus = focus == true, follow_end = true })
end

local function strip_ansi(text)
  text = tostring(text or "")
  -- PowerShell 7 emits ANSI SGR color by default when stdout is a pipe, and
  -- many native tools do the same. Command Output Views are plain text, not a
  -- terminal emulator, so remove common ANSI control sequences before display.
  text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%][^\7]*\7", "")
  text = text:gsub("\27%][^\27]*\27\\", "")
  text = text:gsub("\27%([A-Za-z0-9]", "")
  return text
end

M._strip_ansi = strip_ansi

local function append_output_text(slot, text)
  if not text or text == "" then return end
  local entry = slot.current_output_entry or current_output_entry(slot)
  local view = slot.view
  if entry then
    entry.text = (entry.text or "") .. text
    if view and view.displayed_entry == entry then
      view:append_text(text)
    end
  elseif view then
    -- Tests and compatibility paths may inject a lightweight fake view without
    -- using Command Output History. Keep those paths append-only as before.
    view:append_text(text)
  end
end

local function append_to_output(slot, text, force)
  if not text or text == "" then return end
  if config.plugins.command_slots.strip_ansi ~= false then
    text = strip_ansi(text)
    if text == "" then return end
  end

  if force then
    append_output_text(slot, text)
    return
  end

  local max_bytes = tonumber(config.plugins.command_slots.max_output_bytes)
  if slot.truncated or slot.output_bytes >= max_bytes then
    slot.truncated = true
    return
  end

  local allowed = max_bytes - slot.output_bytes
  if #text > allowed then
    if allowed > 0 then
      append_output_text(slot, text:sub(1, allowed))
      slot.output_bytes = slot.output_bytes + allowed
    end
    slot.truncated = true
    append_to_output(
      slot,
      string.format("\n--- output truncated after %.1f MB; command is still being drained ---\n", max_bytes / (1024 * 1024)),
      true
    )
  else
    append_output_text(slot, text)
    slot.output_bytes = slot.output_bytes + #text
  end
end

local function flush_pending(slot)
  if slot.pending_output and slot.pending_output ~= "" then
    append_to_output(slot, slot.pending_output)
    slot.pending_output = ""
  end
end

local function finish_run(slot, kind, exit_code, detail)
  if not slot.running then return end
  flush_pending(slot)

  local elapsed = math.max(0, system.get_time() - (slot.start_time or system.get_time()))
  local footer
  if kind == "exited" then
    footer = string.format("\n--- exited with code %s in %.1fs ---\n", tostring(exit_code), elapsed)
  elseif kind == "killed" then
    footer = string.format("\n--- killed after %.1fs ---\n", elapsed)
  elseif kind == "start-error" then
    footer = string.format("\n--- could not start PowerShell: %s ---\n", tostring(detail or "unknown error"))
  elseif kind == "write-error" then
    footer = string.format("\n--- could not send command to PowerShell: %s ---\n", tostring(detail or "unknown error"))
  else
    footer = string.format("\n--- PowerShell worker exited before the command completed%s in %.1fs ---\n", exit_code and (" with code " .. tostring(exit_code)) or "", elapsed)
  end

  append_to_output(slot, footer, true)
  core.log_quiet(
    "Command Slot %d: run finished kind=%s exit=%s detail=%s elapsed=%.1fs",
    slot.index,
    tostring(kind),
    tostring(exit_code),
    tostring(detail),
    elapsed
  )

  slot.running = false
  slot.token = nil
  slot.start_time = nil
  slot.pending_output = ""
end

function M._process_worker_output(slot, chunk)
  if not chunk or chunk == "" then return false end
  if not slot.running or not slot.token then
    core.log_quiet("Command Slot %d: dropping idle PowerShell output (%d bytes)", slot.index, #chunk)
    return false
  end

  local pending = (slot.pending_output or "") .. chunk
  local marker = DONE_PREFIX .. tostring(slot.token) .. ":"
  local marker_start, marker_end = pending:find(marker, 1, true)
  if marker_start then
    local after_marker = pending:sub(marker_end + 1)
    local exit_text = after_marker:match("^(-?%d+)")
    if not exit_text then
      if marker_start > 1 then
        append_to_output(slot, pending:sub(1, marker_start - 1))
      end
      slot.pending_output = pending:sub(marker_start)
      return false
    end

    append_to_output(slot, pending:sub(1, marker_start - 1))
    slot.pending_output = ""
    finish_run(slot, "exited", tonumber(exit_text) or 0)
    return true
  end

  if #pending > MARKER_TAIL_BYTES then
    local flush_len = #pending - MARKER_TAIL_BYTES
    append_to_output(slot, pending:sub(1, flush_len))
    pending = pending:sub(flush_len + 1)
  end
  slot.pending_output = pending
  return false
end

local function powershell_args(exe)
  return { exe, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", M._build_powershell_controller() }
end

local function start_worker(slot)
  local cwd = root_project_path()
  local errors = {}
  for _, exe in ipairs(config.plugins.command_slots.powershell_candidates or {}) do
    local proc, err = process.start(powershell_args(exe), {
      cwd = cwd,
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_STDOUT,
      env = {
        NO_COLOR = "1",
        CLICOLOR = "0",
        TERM = "dumb",
      },
    })
    if proc then
      slot.proc = proc
      slot.worker_consumed = false
      slot.worker_exe = exe
      slot.worker_generation = (slot.worker_generation or 0) + 1
      local generation = slot.worker_generation
      core.log_quiet("Command Slot %d: started disposable PowerShell worker %s", slot.index, exe)

      core.add_thread(function()
        while slot.proc == proc and slot.worker_generation == generation do
          local chunk, read_err = proc:read_stdout(READ_CHUNK_BYTES)
          if chunk and #chunk > 0 then
            M._process_worker_output(slot, chunk)
          elseif chunk == "" then
            coroutine.yield(1 / config.fps)
          else
            if read_err then
              core.log_quiet("Command Slot %d: PowerShell read ended: %s", slot.index, tostring(read_err))
            end
            break
          end
        end

        if slot.proc == proc and slot.worker_generation == generation then
          local exit_code = proc:returncode()
          slot.proc = nil
          slot.worker_consumed = false
          core.log_quiet("Command Slot %d: PowerShell worker exited code=%s", slot.index, tostring(exit_code))
          if slot.running then
            finish_run(slot, "worker-exited", exit_code)
          elseif config.plugins.command_slots.prewarm ~= false then
            start_worker(slot)
          end
        end
      end)

      return proc
    end
    errors[#errors + 1] = string.format("%s: %s", tostring(exe), tostring(err or "start failed"))
    core.log_quiet("Command Slot %d: failed to start %s: %s", slot.index, tostring(exe), tostring(err))
  end
  return nil, table.concat(errors, "; ")
end

local function kill_worker(slot)
  local proc = slot.proc
  slot.proc = nil
  slot.worker_consumed = false
  slot.worker_generation = (slot.worker_generation or 0) + 1
  if proc then
    pcall(proc.kill, proc)
  end
end

local function ensure_worker(slot)
  if slot.proc and slot.proc:running() and not slot.worker_consumed then return slot.proc end
  if slot.proc and slot.proc:running() and slot.worker_consumed then kill_worker(slot) end
  slot.proc = nil
  slot.worker_consumed = false
  return start_worker(slot)
end

function M.kill_slot(index, reason)
  local slot = slot_for_index(index)
  if not slot then return false end
  local was_running = slot.running
  if was_running then
    finish_run(slot, "killed")
  end
  slot.run_generation = (slot.run_generation or 0) + 1
  kill_worker(slot)
  core.log_quiet("Command Slot %d: killed worker reason=%s", index, tostring(reason or "manual"))
  return was_running
end

local function next_token(slot)
  M.token_counter = M.token_counter + 1
  return string.format("%d_%d_%d", slot.index, math.floor(system.get_time() * 1000000), M.token_counter)
end

local function default_run_command(slot, command_text)
  local active_before = core.active_view
  local focus_output = panes.pane_for_view(active_before) == "right"

  if slot.running then
    M.kill_slot(slot.index, "rerun")
  end

  local cwd = root_project_path()
  local header = string.format("PS %s> %s\n\n", tostring(cwd or ""), tostring(command_text or ""))
  local entry = push_output_entry(slot, command_text, cwd, header)
  local view = ensure_output_view(slot, focus_output)
  if view and view.displayed_entry ~= entry then
    view:show_entry(entry, { follow_end = true })
  end

  slot.running = true
  slot.token = next_token(slot)
  slot.run_generation = (slot.run_generation or 0) + 1
  local run_generation = slot.run_generation
  local run_token = slot.token
  slot.start_time = system.get_time()
  slot.pending_output = ""
  slot.output_bytes = 0
  slot.truncated = false
  slot.last_command_text = command_text
  slot.last_cwd = cwd

  M.record_history(command_text, cwd)
  core.log_quiet("Command Slot %d: running command in %s: %s", slot.index, cwd, command_text)

  core.add_thread(function()
    local function current_run()
      return slot.running and slot.run_generation == run_generation and slot.token == run_token
    end

    if not current_run() then return end
    local proc, start_err = ensure_worker(slot)
    if not proc then
      if current_run() then finish_run(slot, "start-error", nil, start_err) end
      return
    end

    if not current_run() then return end
    local payload = M._build_powershell_payload(command_text, cwd, run_token)
    local written, write_err = proc.stdin:write(payload)
    if written and written >= #payload then
      if current_run() then slot.worker_consumed = true end
      proc.stdin:close()
      return
    end

    if not current_run() then return end
    core.log_quiet("Command Slot %d: PowerShell write failed; restarting worker: %s", slot.index, tostring(write_err))
    kill_worker(slot)
    proc, start_err = ensure_worker(slot)
    if not proc then
      if current_run() then finish_run(slot, "start-error", nil, start_err) end
      return
    end

    if not current_run() then return end
    written, write_err = proc.stdin:write(payload)
    if written and written >= #payload then
      if current_run() then slot.worker_consumed = true end
      proc.stdin:close()
      return
    end

    if current_run() then
      finish_run(slot, "write-error", nil, write_err)
      kill_worker(slot)
    end
  end)

  return view
end

M._default_run_command = default_run_command
M._run_command_impl = M._run_command_impl or default_run_command

function M.run_command(index, command_text)
  local slot = slot_for_index(index)
  if not slot or is_blank(command_text) then return nil end
  return M._run_command_impl(slot, command_text)
end

function M.run_slot(index)
  local text = M.get_command(index)
  if is_blank(text) then
    return M.prompt_slot(index, false)
  end
  return M.run_command(index, text)
end

function M.prompt_slot(index, select_existing)
  local slot = slot_for_index(index)
  if not slot then return end
  local text = M.get_command(index)
  core.global_prompt_bar:enter("Command Slot " .. slot.label, {
    text = text,
    select_text = select_existing == true and not is_blank(text),
    suggest = function(input)
      return M.suggest_commands(input)
    end,
    show_suggestions = true,
    typeahead = false,
    submit = function(input)
      if is_blank(input) then
        core.log_quiet("Command Slot %d: blank prompt submit ignored", index)
        return
      end
      M.set_command(index, input)
      M.run_command(index, input)
    end,
  })
end

local function active_output_panel()
  local view = core.active_view
  if view and view.command_output_panel then return view end
  local owner = view and view.__pane_focus_owner
  if owner and owner.command_output_panel then return owner end
end

local function active_output_slot()
  local view = core.active_view
  if view and view.command_output_view and view.slot then return view.slot end
  local panel = active_output_panel()
  return panel and panel:active_slot()
end

function M.navigate_output_history(delta)
  local panel = active_output_panel()
  if not panel then
    local slot = active_output_slot()
    panel = slot and slot.view and slot.view.__pane_focus_owner
  end
  if panel and panel.switch_history then
    return panel:switch_history(delta)
  end
end

local function install_commands()
  local map = {}
  for _, def in ipairs(SLOT_DEFS) do
    local index = def.index
    map["command-slots:run-" .. def.key] = function()
      return M.run_slot(index)
    end
    map["command-slots:edit-" .. def.key] = function()
      return M.prompt_slot(index, true)
    end
  end
  map["command-slots:kill-active"] = function()
    local slot = active_output_slot()
    if slot then return M.kill_slot(slot.index, "command") end
    return false
  end
  map["command-slots:focus-output"] = function()
    local panel = ensure_output_panel()
    panes.show("right", { view = panel, focus = true })
    local slot = panel:active_slot()
    if slot then
      panel:select_slot(slot.index, { focus = true, follow_end = true })
    end
  end
  map["command-slots:switch-next"] = function()
    local panel = ensure_output_panel()
    panes.show("right", { view = panel, focus = true })
    return panel:switch_tab(1)
  end
  map["command-slots:switch-previous"] = function()
    local panel = ensure_output_panel()
    panes.show("right", { view = panel, focus = true })
    return panel:switch_tab(-1)
  end
  command.add(nil, map)

  command.add(function()
    local slot = active_output_slot()
    return slot ~= nil, slot
  end, {
    ["command-slots:history-previous"] = function()
      M.navigate_output_history(-1)
    end,
    ["command-slots:history-next"] = function()
      M.navigate_output_history(1)
    end,
  })
end

local function install_keymaps()
  keymap.add_direct({
    ["alt+3"] = "command-slots:focus-output",
  })

  local map = {}
  for _, def in ipairs(SLOT_DEFS) do
    map["alt+" .. def.key] = "command-slots:run-" .. def.key
    map["alt+shift+" .. def.key] = "command-slots:edit-" .. def.key
  end
  keymap.add_direct(map)
end

local function output_view_active()
  local view = core.active_view
  return view and (view.command_output_view == true or view.command_output_panel == true)
end

local function wrap_command_to_block_output_view(name)
  local base = command.map[name]
  if not base or base.__command_slots_blocks_output_view then return end
  command.add(function(...)
    if output_view_active() then return false end
    return base.predicate(...)
  end, {
    [name] = function(...)
      return base.perform(...)
    end,
  })
  command.map[name].__command_slots_blocks_output_view = true
end

local function install_readonly_command_guards()
  local blocked = {
    "doc:cut",
    "doc:undo",
    "doc:redo",
    "doc:paste",
    "doc:paste-primary-selection",
    "doc:newline",
    "doc:newline-below",
    "doc:newline-above",
    "doc:delete",
    "doc:backspace",
    "doc:join-lines",
    "doc:indent",
    "doc:unindent",
    "doc:duplicate-lines",
    "doc:delete-lines",
    "doc:move-lines-up",
    "doc:move-lines-down",
    "doc:toggle-block-comments",
    "doc:toggle-line-comments",
    "doc:upper-case",
    "doc:lower-case",
    "doc:toggle-line-ending",
    "doc:change-encoding",
    "doc:reload-with-encoding",
    "doc:toggle-overwrite",
    "doc:save-as",
    "doc:save",
    "doc:reload",
    "file:rename",
    "file:delete",
  }
  local translations = {
    "previous-char",
    "next-char",
    "previous-word-start",
    "next-word-end",
    "previous-block-start",
    "next-block-end",
    "start-of-doc",
    "end-of-doc",
    "start-of-line",
    "end-of-line",
    "start-of-word",
    "start-of-indentation",
    "end-of-word",
    "previous-line",
    "next-line",
    "previous-page",
    "next-page",
  }
  for _, name in ipairs(translations) do
    blocked[#blocked + 1] = "doc:delete-to-" .. name
  end
  for _, name in ipairs(blocked) do
    wrap_command_to_block_output_view(name)
  end
end

function M.prewarm()
  if config.plugins.command_slots.prewarm == false then return end
  core.add_thread(function()
    coroutine.yield(0.2)
    for _, def in ipairs(SLOT_DEFS) do
      local slot = slot_for_index(def.index)
      if slot then
        ensure_worker(slot)
        coroutine.yield(0.05)
      end
    end
  end)
end

function M._reset_for_tests()
  if M.output_panel then
    panes.remove_view(M.output_panel, { force = true, focus_left = false })
    M.output_panel = nil
  end
  for _, slot in ipairs(M.slots) do
    if slot.proc then kill_worker(slot) end
    slot.proc = nil
    slot.worker_consumed = false
    slot.running = false
    slot.run_generation = 0
    slot.token = nil
    slot.pending_output = ""
    slot.output_history = {}
    slot.output_history_index = 0
    slot.current_output_entry = nil
    slot.last_command_text = nil
    slot.last_cwd = nil
    slot.view = nil
  end
  M.project_state_cache = {}
  M._run_command_impl = default_run_command
end

for _, def in ipairs(SLOT_DEFS) do
  local slot = M.slots[def.index] or {}
  slot.index = def.index
  slot.key = def.key
  slot.label = def.label
  slot.pending_output = slot.pending_output or ""
  slot.output_history = slot.output_history or {}
  slot.output_history_index = slot.output_history_index or #slot.output_history
  M.slots[def.index] = slot
end

ensure_output_panel()

install_commands()
install_keymaps()
install_readonly_command_guards()

if not running_lua_tests() then
  M.prewarm()
end

return M
