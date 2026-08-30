-- mod-version:3 priority:250
-- Project-scoped shell command slots and one-time shell output Views.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local json = require "core.json"
local process = require "core.process"
local storage = require "core.storage"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local View = require "core.view"
local file_context = require "core.file_context"
local panes = require "core.panes"
local shell = require "core.shell"
local text_poi_locations = require "core.text_poi_locations"
local Tabs = require "core.tabs"
local view_icons = require "core.view_icons"

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
local ACTIVE_WORKER_POLL_SECONDS = 0.01
local IDLE_WORKER_POLL_SECONDS = 1

M.slots = M.slots or {}
M.project_slots = M.project_slots or {}
M.project_state_cache = M.project_state_cache or {}
M.quick_output_views = M.quick_output_views or {}
M.last_quick_slots = M.last_quick_slots or {}
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

local function existing_file(path)
  local info = path and system.get_file_info(path)
  return info and info.type ~= "dir"
end

local extract_output_location_candidates = text_poi_locations.extract_candidates
local function resolve_output_candidates(candidates, root)
  return text_poi_locations.resolve_candidates(candidates, root, "command-output-location")
end

local function extract_output_location_pois(text, opts)
  opts = opts or {}
  return resolve_output_candidates(extract_output_location_candidates(text), opts.root or root_project_path())
end

M.extract_output_location_pois = extract_output_location_pois

local function slots_for_project(project_path)
  local key = project_path or root_project_path()
  local slots = M.project_slots[key]
  if not slots then
    slots = {}
    for _, def in ipairs(SLOT_DEFS) do
      slots[def.index] = {
        index = def.index,
        key = def.key,
        label = def.label,
        project_path = key,
        output_history = {},
        output_history_index = 0,
      }
    end
    M.project_slots[key] = slots
  end
  if key == root_project_path() then M.slots = slots end
  return slots
end

local function slot_for_index(index, project_path)
  return slots_for_project(project_path)[index]
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

local CommandOutputBuffer = Buffer:extend()

function CommandOutputBuffer:__tostring() return "CommandOutputBuffer" end

function CommandOutputBuffer:new()
  CommandOutputBuffer.super.new(self)
  self.output_text = ""
  self:clean()
end

function CommandOutputBuffer:is_dirty()
  return false
end

function CommandOutputBuffer:save()
  return true
end

function CommandOutputBuffer:reload()
end

function CommandOutputBuffer:_with_internal_mutation(fn)
  self.__command_output_mutating = true
  local ok, a, b, c = pcall(fn)
  self.__command_output_mutating = false
  if not ok then error(a, 2) end
  return a, b, c
end

function CommandOutputBuffer:insert(line, col, text)
  if not self.__command_output_mutating then return end
  return CommandOutputBuffer.super.insert(self, line, col, text)
end

function CommandOutputBuffer:remove(line1, col1, line2, col2)
  if not self.__command_output_mutating then return end
  return CommandOutputBuffer.super.remove(self, line1, col1, line2, col2)
end

function CommandOutputBuffer:can_apply_edits(edits, opts)
  return self.__command_output_mutating == true
end

function CommandOutputBuffer:text_input()
end

function CommandOutputBuffer:ime_text_editing()
end

function CommandOutputBuffer:undo()
end

function CommandOutputBuffer:redo()
end

function CommandOutputBuffer:delete_to_cursor()
end

function CommandOutputBuffer:delete_to()
end

function CommandOutputBuffer:replace()
end

function CommandOutputBuffer:indent_text()
end

function CommandOutputBuffer:_display_text()
  local text = self.output_text or ""
  if text == "" or text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  return text
end

function CommandOutputBuffer:_replace_display_text(selection_mode)
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
  CommandOutputBuffer.super.insert(self, 1, 1, self:_display_text())

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

function CommandOutputBuffer:set_text(text)
  self.output_text = tostring(text or "")
  self:_with_internal_mutation(function()
    self:_replace_display_text("end")
  end)
end

function CommandOutputBuffer:append(text)
  if not text or text == "" then return end
  self.output_text = (self.output_text or "") .. text
  self:_with_internal_mutation(function()
    self:_replace_display_text("preserve")
  end)
end

local CommandOutputView = TextView:extend()
CommandOutputView.view_icon = view_icons.register("command_output", view_icons.ui("F"))

function CommandOutputView:__tostring() return "CommandOutputView" end

function CommandOutputView:new(slot)
  CommandOutputView.super.new(self, CommandOutputBuffer())
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
    M.kill_slot(self.slot, "closed")
  end
  do_close()
end

function CommandOutputView:can_close(approve)
  approve()
end

function CommandOutputView:on_close()
  local slot = self.slot
  if slot and slot.running then slot.running:cancel() end
  if slot and slot.view == self then
    slot.view = nil
  end
  CommandOutputView.super.on_close(self)
end

function CommandOutputView:can_discard_from_history()
  return not (self.slot and self.slot.running)
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
  self.buffer:set_text(entry and entry.text or "")

  if entry and entry.selection_state then
    self:set_selection_state(entry.selection_state)
    self.scroll.x = entry.scroll_x or entry.scroll_to_x or 0
    self.scroll.to.x = entry.scroll_to_x or entry.scroll_x or 0
    self.scroll.y = entry.scroll_y or entry.scroll_to_y or 0
    self.scroll.to.y = entry.scroll_to_y or entry.scroll_y or 0
  elseif opts.follow_end then
    self.buffer:set_selection(#self.buffer.lines, 1)
    self:scroll_to_make_visible(#self.buffer.lines, math.huge, true)
  else
    self.buffer:set_selection(1, 1)
    self.scroll.x, self.scroll.to.x = 0, 0
    self.scroll.y, self.scroll.to.y = 0, 0
  end
  core.redraw = true
end

function CommandOutputView:clear_for_run(command_text, cwd)
  local header = string.format("PS %s> %s\n\n", tostring(cwd or ""), tostring(command_text or ""))
  self.displayed_entry = nil
  self.poi_cache = nil
  self.buffer:set_text(header)
  self:scroll_to_make_visible(#self.buffer.lines, math.huge, true)
end

function CommandOutputView:append_text(text)
  local old_scroll_x, old_scroll_to_x = self.scroll.x, self.scroll.to.x
  local old_scroll_y, old_scroll_to_y = self.scroll.y, self.scroll.to.y
  local old_last_line = #self.buffer.lines
  local line1, col1, line2, col2 = self.buffer:get_selection()
  local follow_output = line1 == old_last_line and line2 == old_last_line

  self.buffer:append(text)
  self.poi_cache = nil

  if follow_output then
    self:scroll_to_make_visible(#self.buffer.lines, col1, false)
    self.scroll.x, self.scroll.to.x = old_scroll_x, old_scroll_to_x
  else
    self.scroll.x, self.scroll.to.x = old_scroll_x, old_scroll_to_x
    self.scroll.y, self.scroll.to.y = old_scroll_y, old_scroll_to_y
  end
  core.redraw = true
end

function CommandOutputView:cache_key_for_pois()
  local entry = self.displayed_entry
  return entry or self.buffer.output_text or ""
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
  local text = self.buffer.output_text or ""
  local key = self:cache_key_for_pois()
  local entry = self.displayed_entry
  local root = entry and entry.cwd or root_project_path()
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
  local pane = panes.pane_for_view(self)
  local placement = opts.placement or (opts.pane == "right" and "split" or "current")
  local view = core.open_file(poi.path, {
    pane = pane,
    placement = placement,
    direction = placement == "split" and "right" or nil,
    line = poi.target_line or poi.line,
    col = poi.target_col or 1,
    focus = not preserve_focus,
    preserve_focus = preserve_focus,
  })
  if view and view.buffer then
    view.buffer:set_selection(
      poi.target_line or poi.line,
      poi.target_col or 1
    )
  end
  return view
end

function CommandOutputView:get_navigation_state()
  return {
    output_history_index = self.slot and self.slot.output_history_index or nil,
    selection_state = self:get_selection_state(),
    scroll = { x = self.scroll.x, y = self.scroll.y },
  }
end

function CommandOutputView:set_navigation_state(state)
  if state and state.output_history_index and self.slot then
    local index = common.clamp(state.output_history_index, 1, #(self.slot.output_history or {}))
    self.slot.output_history_index = index
    self:show_entry(self.slot.output_history[index])
  end
  if state and state.selection_state then self:set_selection_state(state.selection_state) end
  if state and state.scroll then
    self.scroll.x, self.scroll.to.x = state.scroll.x or 0, state.scroll.x or 0
    self.scroll.y, self.scroll.to.y = state.scroll.y or 0, state.scroll.y or 0
  end
end

function CommandOutputView:draw_poi_underlines(line, x, y)
  self:get_points_of_interest({ silent = true })
  local cache = self.poi_cache
  local points = cache and cache.by_line and cache.by_line[line]
  if not points or #points == 0 then return end
  local thickness = math.max(1, math.floor(SCALE))
  local min_x = self.position.x
  local max_x = self.position.x + self.size.x
  for _, poi in ipairs(points) do
    if poi.text_bounds and poi.line == line and (poi.line2 or poi.line) == line then
      for x1, row_y, x2, row_height in self:iter_text_range_screen_segments(
        line, poi.col, poi.col2 or poi.col, x, y
      ) do
        if x2 > min_x and x1 < max_x and x2 > x1 then
          x1 = math.max(x1, min_x)
          x2 = math.min(x2, max_x)
          renderer.draw_rect(
            x1, row_y + row_height - thickness * 2,
            x2 - x1, thickness, style.accent or style.text
          )
        end
      end
    end
  end
end

function CommandOutputView:draw_line_body(line, x, y)
  local height = CommandOutputView.super.draw_line_body(self, line, x, y)
  self:draw_poi_underlines(line, x, y)
  return height
end

M.CommandOutputBuffer = CommandOutputBuffer
M.CommandOutputView = CommandOutputView

local QuickCommandOutputView = View:extend()
QuickCommandOutputView.view_icon = view_icons.register("quick_command_output", view_icons.ui("F"))

local function new_quick_output_tab_bar(owner)
  return Tabs(owner, {
    should_show = function() return true end,
    log_prefix = "Quick Command Output tabs",
  })
end

function QuickCommandOutputView:__tostring() return "QuickCommandOutputView" end

function QuickCommandOutputView:new(project_path)
  QuickCommandOutputView.super.new(self)
  self.project_path = project_path or root_project_path()
  self.quick_command_output_view = true
  self.active_slot_index = 1
  self.views = {}
  self.tab_offset = 1
  self.tab_shift = 0
  self.hovered_tab = nil
  self.hovered_scroll_button = 0
  self.tab_bar = new_quick_output_tab_bar(self)
  self.cursor = "arrow"
  file_context.exclude_content_view(self)
  self:sync_slot_views()
end

function QuickCommandOutputView:get_name()
  return "Quick Command Output"
end

function QuickCommandOutputView:get_tab_bar()
  if not self.tab_bar or self.tab_bar.owner ~= self then
    self.tab_bar = new_quick_output_tab_bar(self)
  end
  return self.tab_bar
end

function QuickCommandOutputView:slots()
  return slots_for_project(self.project_path)
end

function QuickCommandOutputView:slot_view(slot)
  if not slot then return nil end
  local view = slot.view
  if not view then
    view = CommandOutputView(slot)
    slot.view = view
  end
  view.quick_command_output_owner = self
  self.views[slot.index] = view
  panes.register_focus_target(self, view)
  return view
end

function QuickCommandOutputView:sync_slot_views()
  local slots = self:slots()
  for _, def in ipairs(SLOT_DEFS) do
    self.views[def.index] = self:slot_view(slots[def.index])
  end
  self.active_slot_index = common.clamp(
    math.floor(tonumber(self.active_slot_index) or 1), 1, #SLOT_DEFS
  )
  self.active_view = self.views[self.active_slot_index]
  return self.views
end

function QuickCommandOutputView:active_slot()
  return self:slots()[self.active_slot_index]
end

function QuickCommandOutputView:active_output_view()
  self:sync_slot_views()
  return self.active_view
end

function QuickCommandOutputView:get_focus_view()
  return self:active_output_view()
end

function QuickCommandOutputView:get_surface_focus_targets()
  return self:sync_slot_views()
end

function QuickCommandOutputView:focus_surface_target(target)
  self:sync_slot_views()
  for index, view in ipairs(self.views) do
    if view == target then return self:select_slot(index, { focus = true }) ~= nil end
  end
  return false
end

function QuickCommandOutputView:layout_active_view()
  local view = self:active_output_view()
  if not view then return end
  local tab_height = self:get_tab_bar():get_height()
  view.position.x = self.position.x
  view.position.y = self.position.y + tab_height
  view.size.x = self.size.x
  view.size.y = math.max(0, self.size.y - tab_height)
end

function QuickCommandOutputView:select_slot(index, opts)
  opts = opts or {}
  self:sync_slot_views()
  index = common.clamp(math.floor(tonumber(index) or 1), 1, #SLOT_DEFS)
  local old_view = self.active_view
  if old_view then old_view:save_displayed_entry_state() end
  self.active_slot_index = index
  self.active_view = self.views[index]
  self.manual_tab_scroll = nil
  if old_view and old_view ~= self.active_view and old_view.on_mouse_left then
    old_view:on_mouse_left()
  end
  local slot = self:active_slot()
  self.active_view:show_entry(current_output_entry(slot), { follow_end = opts.follow_end == true })
  self:layout_active_view()
  self:get_tab_bar():scroll_to_visible(index)
  if opts.focus == true then core.set_active_view(self.active_view) end
  core.redraw = true
  return self.active_view
end

function QuickCommandOutputView:get_navigation_state()
  local slot_states = {}
  for index, view in ipairs(self:sync_slot_views()) do
    slot_states[index] = view:get_navigation_state()
  end
  return {
    active_slot_index = self.active_slot_index,
    slot_states = slot_states,
  }
end

function QuickCommandOutputView:set_navigation_state(state)
  for index, slot_state in ipairs(state and state.slot_states or {}) do
    local view = self:sync_slot_views()[index]
    if view then view:set_navigation_state(slot_state) end
  end
  if state and state.active_slot_index then
    self:select_slot(state.active_slot_index, { focus = false })
  end
end

function QuickCommandOutputView:update()
  self:sync_slot_views()
  self:layout_active_view()
  if self.active_view then self.active_view:update() end
  local mouse = core.root_panel and core.root_panel.mouse
  if mouse then
    self:get_tab_bar():update(mouse.x, mouse.y)
  else
    self:get_tab_bar():update()
  end
end

function QuickCommandOutputView:draw()
  self:draw_background(style.background)
  self:get_tab_bar():draw_tabs()
  self:layout_active_view()
  if self.active_view then
    core.push_clip_rect(
      self.active_view.position.x, self.active_view.position.y,
      self.active_view.size.x, self.active_view.size.y
    )
    self.active_view:draw()
    core.pop_clip_rect()
  end
end

function QuickCommandOutputView:on_mouse_pressed(button, x, y, clicks)
  local tab_bar = self:get_tab_bar()
  local scroll_button = tab_bar:get_scroll_button_index(x, y)
  if scroll_button then tab_bar:scroll_tabs(scroll_button); return true end
  local tab = tab_bar:get_tab_overlapping_point(x, y)
  if tab then self:select_slot(tab, { focus = true }); return true end
  local view = self:active_output_view()
  if view then
    core.set_active_view(view)
    return view:on_mouse_pressed(button, x, y, clicks)
  end
  return true
end

function QuickCommandOutputView:on_mouse_released(button, x, y, ...)
  if self:get_tab_bar():is_in_tab_area(x, y) then return true end
  local view = self:active_output_view()
  if view then return view:on_mouse_released(button, x, y, ...) end
end

function QuickCommandOutputView:on_mouse_moved(x, y, dx, dy)
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

function QuickCommandOutputView:on_mouse_left()
  self.hovered_tab = nil
  self.hovered_scroll_button = 0
  local view = self:active_output_view()
  if view then view:on_mouse_left() end
end

function QuickCommandOutputView:on_mouse_wheel(delta_y, delta_x, ...)
  local mouse = core.root_panel and core.root_panel.mouse
  local tab_bar = self:get_tab_bar()
  if mouse and tab_bar:is_in_tab_area(mouse.x, mouse.y) then
    local dir
    if math.abs(delta_x or 0) > math.abs(delta_y or 0) then
      dir = delta_x > 0 and 1 or 2
    elseif delta_y ~= 0 then
      dir = delta_y > 0 and 1 or 2
    end
    if dir and tab_bar:can_scroll_tabs(dir) then tab_bar:scroll_tabs(dir) end
    return true
  end
  local view = self:active_output_view()
  if view then return view:on_mouse_wheel(delta_y, delta_x, ...) end
end

function QuickCommandOutputView:can_discard_from_history()
  for _, slot in ipairs(self:slots()) do
    if slot.running then return false end
  end
  return true
end

function QuickCommandOutputView:on_close()
  for _, view in ipairs(self:sync_slot_views()) do
    panes.unregister_focus_target(view)
    view:on_close()
  end
  if M.quick_output_views[self.project_path] == self then
    M.quick_output_views[self.project_path] = nil
  end
  QuickCommandOutputView.super.on_close(self)
end

M.QuickCommandOutputView = QuickCommandOutputView

local function ensure_quick_output_view(slot, focus)
  local quick_output = M.quick_output_views[slot.project_path]
  local pane = quick_output and panes.pane_for_view(quick_output) or nil
  if quick_output and not pane then
    quick_output:on_close()
    quick_output = nil
  end
  if not quick_output then
    quick_output = QuickCommandOutputView(slot.project_path)
    quick_output:select_slot(slot.index, { focus = false })
    local placed = panes.place(function() return quick_output end, {
      placement = "current",
      focus = focus ~= false,
      reason = "quick-command-output",
    })
    if not placed then quick_output:on_close(); return nil end
    M.quick_output_views[slot.project_path] = quick_output
    pane = panes.pane_for_view(quick_output)
  else
    if pane.current_view ~= quick_output then
      panes.present(quick_output, { pane = pane, focus = focus ~= false })
    elseif focus ~= false then
      panes.focus(pane)
    end
    quick_output:select_slot(slot.index, { focus = focus ~= false })
  end
  return quick_output:slot_view(slot)
end

local function ensure_one_time_output_view(slot, focus)
  local view = slot.view or CommandOutputView(slot)
  local pane = panes.pane_for_view(view)
  if pane then
    if pane.current_view ~= view then
      panes.present(view, { pane = pane, focus = focus ~= false })
    elseif focus ~= false then
      panes.focus(pane)
    end
    return view
  end
  local placed = panes.place(function() return view end, {
    placement = "current",
    focus = focus ~= false,
    reason = "command-output",
  })
  if not placed then return nil end
  slot.view = placed
  return placed
end

local function ensure_output_view(slot, focus)
  if slot.index then return ensure_quick_output_view(slot, focus) end
  return ensure_one_time_output_view(slot, focus)
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
  elseif kind == "cancelled" or kind == "killed" then
    footer = string.format("\n--- cancelled after %.1fs ---\n", elapsed)
  elseif kind == "start-error" then
    footer = string.format("\n--- could not start PowerShell: %s ---\n", tostring(detail or "unknown error"))
  elseif kind == "write-error" then
    footer = string.format("\n--- could not send command to PowerShell: %s ---\n", tostring(detail or "unknown error"))
  else
    footer = string.format("\n--- PowerShell worker exited before the command completed%s in %.1fs ---\n", exit_code and (" with code " .. tostring(exit_code)) or "", elapsed)
  end

  append_to_output(slot, footer, true)
  core.log_quiet(
    "Command Output %s: run finished kind=%s exit=%s detail=%s elapsed=%.1fs",
    tostring(slot.index or "one-time"),
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
            -- A prewarmed shell has no useful frame-rate-coupled work. Poll
            -- it sparsely until a command is running, then switch to a short
            -- fixed interval for responsive streaming output. Tying four idle
            -- workers to a high-refresh display wakes the entire app hundreds
            -- of times per second.
            coroutine.yield(slot.running
              and ACTIVE_WORKER_POLL_SECONDS
              or IDLE_WORKER_POLL_SECONDS)
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
      end, slot)

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

function M.kill_slot(index_or_slot, reason)
  local slot = type(index_or_slot) == "table" and index_or_slot or slot_for_index(index_or_slot)
  if not slot then return false end
  local run = slot.running
  if not run then return false end
  core.log_quiet("Command Slot %s: cancelling run reason=%s", tostring(slot.index or "one-time"), tostring(reason or "manual"))
  return run:cancel()
end

local function next_token(slot)
  M.token_counter = M.token_counter + 1
  return string.format("%d_%d_%d", slot.index, math.floor(system.get_time() * 1000000), M.token_counter)
end

local function default_run_command(slot, command_text, opts)
  opts = opts or {}
  if slot.running then M.kill_slot(slot, "rerun") end

  local cwd = opts.cwd or root_project_path()
  local shell_name = opts.shell
  local powershell = (not shell_name and PLATFORM == "Windows")
    or shell.kind(shell_name) == "powershell"
  local marker = powershell and "PS" or "$"
  local header = string.format("%s %s> %s\n\n", marker, tostring(cwd or ""), tostring(command_text or ""))
  local entry = push_output_entry(slot, command_text, cwd, header)
  local view = ensure_output_view(slot, opts.focus)
  if not view then return nil end
  view:show_entry(entry, { follow_end = true })

  slot.start_time = system.get_time()
  slot.output_bytes = 0
  slot.truncated = false
  slot.last_command_text = command_text
  slot.last_cwd = cwd
  slot.run_generation = (slot.run_generation or 0) + 1
  local generation = slot.run_generation
  if slot.index then M.last_quick_slots[slot.project_path] = slot end
  M.record_history(command_text, opts.project_path)

  local run
  run = shell.capture(command_text, {
    cwd = cwd,
    shell = shell_name,
    max_output_bytes = config.plugins.command_slots.max_output_bytes,
    on_output = function(text)
      if slot.run_generation ~= generation then return end
      if config.plugins.command_slots.strip_ansi ~= false then text = strip_ansi(text) end
      append_output_text(slot, text)
    end,
    on_error = function(detail)
      if slot.run_generation ~= generation then return end
      finish_run(slot, "start-error", nil, detail.message)
    end,
    on_exit = function(result)
      if slot.run_generation ~= generation then return end
      if result.truncated then
        append_output_text(slot, "\n--- output truncated; process output was drained ---\n")
      end
      finish_run(slot, result.cancelled and "cancelled" or "exited", result.code)
    end,
  })
  slot.running = run
  core.log_quiet(
    "Command Output %s: running command cwd_len=%d command_len=%d",
    tostring(slot.index or "one-time"), #tostring(cwd or ""), #tostring(command_text or "")
  )
  return view
end

M._default_run_command = default_run_command
M._run_command_impl = M._run_command_impl or default_run_command

function M.run_command(index, command_text, opts)
  local slot = slot_for_index(index)
  if not slot or is_blank(command_text) then return nil end
  return M._run_command_impl(slot, command_text, opts)
end

function M.run_once(command_text, opts)
  if is_blank(command_text) then return nil end
  local slot = {
    label = "Output",
    output_history = {},
    output_history_index = 0,
  }
  return default_run_command(slot, command_text, opts)
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

local function active_quick_output_slot()
  local view = core.active_view
  if view and view.command_output_view and view.slot and view.slot.index then return view.slot end
end

function M.navigate_output_history(delta)
  local slot = active_quick_output_slot()
  if not slot or not slot.view or #(slot.output_history or {}) == 0 then return false end
  local current = slot.output_history_index or #slot.output_history
  local next_index = common.clamp(current + delta, 1, #slot.output_history)
  if next_index == current then return false end
  panes.record_location(panes.pane_for_view(slot.view))
  slot.view:save_displayed_entry_state()
  slot.output_history_index = next_index
  slot.view:show_entry(slot.output_history[next_index])
  return true
end

local function install_commands()
  local map = {}
  for _, def in ipairs(SLOT_DEFS) do
    local index = def.index
    map["quick_command_output:run_" .. def.key] = command.palette(function()
      return M.run_slot(index)
    end, { opens_view = true })
    map["quick_command_output:edit_" .. def.key] = command.palette(function()
      return M.prompt_slot(index, true)
    end)
  end
  map["quick_command_output:kill_active"] = command.palette(function()
    local slot = active_quick_output_slot()
    if slot then return M.kill_slot(slot, "command") end
    return false
  end)
  map["quick_command_output:open"] = command.palette(function()
    local project_path = root_project_path()
    local slot = M.last_quick_slots[project_path] or slot_for_index(1, project_path)
    return slot and ensure_output_view(slot, true) ~= nil
  end, { opens_view = true })
  command.add(nil, map)

  command.add(function()
    local slot = active_quick_output_slot()
    return slot ~= nil, slot
  end, {
    ["quick_command_output:history_previous"] = function()
      M.navigate_output_history(-1)
    end,
    ["quick_command_output:history_next"] = function()
      M.navigate_output_history(1)
    end,
  })
end

local function install_keymaps()
  local map = {}
  for _, def in ipairs(SLOT_DEFS) do
    map["alt+" .. def.key] = "quick_command_output:run_" .. def.key
    map["alt+shift+" .. def.key] = "quick_command_output:edit_" .. def.key
  end
  keymap.add_direct(map)
end

local function output_view_active()
  local view = core.active_view
  return view and view.command_output_view == true
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
    "core:cut",
    "core:undo",
    "core:redo",
    "core:paste",
    "core:paste_primary_selection",
    "core:newline",
    "core:newline_below",
    "core:newline_above",
    "core:delete",
    "core:backspace",
    "editor:join_lines",
    "core:indent",
    "core:unindent",
    "editor:duplicate_lines",
    "editor:delete_lines",
    "editor:move_lines_up",
    "editor:move_lines_down",
    "editor:toggle_block_comments",
    "editor:toggle_line_comments",
    "editor:upper_case",
    "editor:lower_case",
    "editor:toggle_line_ending",
    "editor:change_encoding",
    "editor:reload_with_encoding",
    "core:toggle_overwrite",
    "editor:save_as",
    "editor:save",
    "editor:reload",
    "editor:rename",
    "editor:delete",
  }
  local translations = {
    "previous-char",
    "next-char",
    "previous-word-start",
    "next-word-end",
    "previous-block-start",
    "next-block-end",
    "start-of-buffer",
    "end-of-buffer",
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
    blocked[#blocked + 1] = "core:delete_to_" .. name
  end
  for _, name in ipairs(blocked) do
    wrap_command_to_block_output_view(name)
  end
end

function M.prewarm()
  core.log_quiet("Command Slots: shell capture prewarming is disabled")
end

function M._reset_for_tests()
  for _, slots in pairs(M.project_slots) do
    for _, slot in ipairs(slots) do
      if slot.running and slot.running.cancel then slot.running:cancel() end
      if slot.proc then kill_worker(slot) end
    end
  end
  M.project_slots = {}
  M.slots = slots_for_project()
  M.quick_output_views = {}
  M.last_quick_slots = {}
  M.project_state_cache = {}
  M._run_command_impl = default_run_command
end

M.slots = slots_for_project()

install_commands()
install_keymaps()
install_readonly_command_guards()

return M
