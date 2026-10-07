-- Real editor workloads. Only the isolated benchmark plugin loads this module.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local linewrapping = require "core.linewrapping"
local Workload = {}
Workload.__index = Workload

local function open(path)
  return assert(core.open_file(path, { placement = "current", focus = true }))
end

local function ready_editor(view)
  return view and view.buffer and view.__async_wrap_reconstruction == nil
end

local function position(view, line)
  view:with_selection_state(function() view.buffer:set_selection(line, 1) end)
  view:scroll_to_line(line, false, true)
end

-- One-letter words stay below the autocomplete threshold, so typing draws no popup.
local TYPED_TEXT = "a b c d e f g h i j k l m n o p q r s t "
local TYPE_LINE = 8
-- Smooth scroll moves down for most ticks, then back up, so it passes rows in both directions.
local SCROLL_DOWN_TICKS = 30

local function editor_target(settings, index)
  index = (index - 1) % 4 + 1
  local rows = settings.lines
  if index == 1 or index == 4 then return math.min(rows, 8) end
  if index == 2 then return math.min(rows, 12) end
  return math.min(rows, math.max(20, math.floor(rows / 2)))
end

function Workload.new(settings, root)
  return setmetatable({ settings = settings, root = root, completed = 0 }, Workload)
end

function Workload:path(name)
  return self.root .. PATHSEP .. name
end

function Workload:setup()
  local settings = self.settings
  require("plugins.scale").set(1)
  require("plugins.scale").set_code(settings.code_scale)
  if settings.kind == "find" then
    self.view = open(self:path("find.c"))
    self.view:set_wrapping_enabled(settings.wrap)
    if settings.wrap then linewrapping.update_textview_breaks(self.view) end
    position(self.view, math.floor(settings.lines / 2))
    assert(command.perform("editor:find"))
    self.find_input = core.active_view
    self.find_input:set_text("input")
    if settings.marker_alpha then
      local style = require "core.style"
      style.search_overview_secondary = { 230, 50, 170, settings.marker_alpha }
      style.search_overview = { 70, 116, 181, 113 }
      style.scrollbar_overview_min_height = 1.37
    end
    if settings.reference_overview then
      -- Pixel reference: the former per-match overview, using public geometry.
      local TextView = require "core.textview"
      local style = require "core.style"
      self.view.draw_scrollbar = function(view)
        local depth = TextView.__local_find_draw_scrollbar_depth or 0
        TextView.__local_find_draw_scrollbar_depth = depth + 1
        TextView.draw_scrollbar(view)
        TextView.__local_find_draw_scrollbar_depth = depth
        local state = self.find_input.local_find_state
        local source_h = math.max(1, view:get_scrollable_size())
        local function draw(match, color)
          local first = view:get_visual_row(match.line, match.col1, false)
          local last = view:get_visual_row(match.line, math.max(match.col1, match.col2 - 1), false)
          local x, y, w, h = view.v_scrollbar:get_overview_marker_rect(
            view:get_visual_row_y_offset(first) / source_h,
            view:get_visual_row_y_offset(last + 1) / source_h)
          if x then renderer.draw_rect(x, y, w, h, color) end
        end
        for index, match in ipairs(state.matches) do
          if index ~= state.current then draw(match, style.search_overview_secondary) end
        end
        local selected = state.matches[state.current]
        if selected then draw(selected, style.search_overview) end
        view.v_scrollbar:draw_thumb()
      end
    end
  elseif settings.kind == "diff" then
    self.diff = assert(require("plugins.diffview").file_to_file(
      self:path("left.lua"), self:path("right.lua")))
    self.diff:update()
    self.view = self.diff:get_focus_view()
    core.set_active_view(self.view)
    for _, side in ipairs(self.diff:get_surface_focus_targets()) do
      side:set_wrapping_enabled(settings.wrap)
      if settings.wrap then linewrapping.update_textview_breaks(side) end
    end
  elseif settings.kind == "fuzzy" then
    local root = self:path("project")
    core.projects = { require("core.project")(root) }
    core.visited_files = {}
    system.chdir(root)
    require("core.project_paths").configure_workspace {}
    self.view = assert(core.open_text("Fuzzy Searcher benchmark\n", { name = "Benchmark" }))
  elseif settings.kind == "switch" then
    -- Cached file switching is separate from first-open measurement.
    self.switch_buffers = {}
    for i = 1, settings.files do
      self.view = open(self:path(string.format("switch-%03d.lua", i)))
      self.view:set_wrapping_enabled(false)
      self.switch_buffers[i] = self.view.buffer
    end
  elseif settings.kind == "open" then
    self.view = assert(core.open_text("Large file open benchmark\n", { name = "Benchmark" }))
  elseif settings.kind == "edit" then
    self.view = open(self:path("edit.txt"))
    self.view:set_wrapping_enabled(false)
    self.view:with_selection_state(function()
      self.view.buffer:set_selection(1, 1)
      for line = 2, settings.carets do self.view.buffer:add_selection(line, 1) end
    end)
  elseif settings.kind == "editor" then
    self.view = open(self:path(settings.content == "markdown" and "scene.md"
      or settings.content == "unicode-source" and "scene.txt" or "scene.cpp"))
    self.view:set_wrapping_enabled(settings.wrap)
    if settings.wrap then linewrapping.update_textview_breaks(self.view) end
    assert(#self.view.buffer.lines == settings.lines, "Editor fixture has the wrong line count")
    if settings.action == "type" then
      local line = math.min(settings.lines, TYPE_LINE)
      self.view:with_selection_state(function()
        self.view.buffer:set_selection(line, math.huge)
      end)
      self.view:scroll_to_line(1, false, true)
      self.typed_line = line
      self.typed_original = self.view.buffer.lines[line]:gsub("\n$", "")
    else
      position(self.view, editor_target(settings, 1))
    end
    assert(self.view:is_wrapping_enabled() == settings.wrap, "Editor wrapping mode changed")
    if settings.content == "markdown" then
      assert(self.view.__markdown_live_attached, "Markdown Live Preview did not attach")
    end
  else
    error("unknown benchmark workload: " .. tostring(settings.kind))
  end
  core.redraw = true
  return self.view
end

function Workload:setup_ready()
  if self.find_input then
    local state = self.find_input.local_find_state
    if state.pending or (state.overview and not state.overview.complete) then return false end
  end
  if self.settings.kind == "editor" and self.settings.content == "markdown" then
    local model = require("core.markdown.model").peek(self.view.buffer)
    if not (model and model.status == "ready"
      and model.published_revision == self.view.buffer.text_revision) then
      return false
    end
  end
  if self.diff then
    assert(not self.diff.comparison_message, self.diff.comparison_message)
    self.view = self.diff:get_focus_view()
    if not self.diff.diff_model or self.diff.updater_idx or self.diff.pending_first_change_reveal then return false end
    for _, surface in ipairs(self.diff:get_surface_focus_targets()) do
      if not ready_editor(surface) then return false end
    end
    return true
  end
  return ready_editor(self.view)
end

function Workload:action_name(index)
  local settings = self.settings
  if settings.kind == "fuzzy" then
    return index == 1 and ("first-" .. settings.action) or settings.action
  end
  if settings.kind == "diff" then
    if settings.save_workspace and index == settings.actions then return "workspace-save" end
    return "diff-" .. settings.action
  end
  if settings.kind == "edit" then return index % 2 == 1 and "insert" or "undo" end
  if settings.kind == "editor" and settings.action == "type" then return "type-char" end
  if settings.kind == "editor" and settings.action == "scroll" then
    return index <= SCROLL_DOWN_TICKS and "wheel-down" or "wheel-up"
  end
  if settings.kind == "editor" then
    return ({ "steady-redraw", "scroll-near", "jump-middle", "return-near" })[
      (index - 1) % 4 + 1]
  end
  return "file-" .. settings.kind
end

function Workload:dispatch(index)
  local settings = self.settings
  self.index = index
  if settings.kind == "find" then
    assert(command.perform("editor:find_field_next"))
  elseif settings.kind == "editor" and settings.action == "type" then
    assert(core.active_view == self.view, "Editor lost input focus")
    core.on_event("textinput", TYPED_TEXT:sub(index, index))
  elseif settings.kind == "editor" and settings.action == "scroll" then
    assert(command.perform("core:scroll", index <= SCROLL_DOWN_TICKS and -1 or 1),
      "Editor did not accept the wheel scroll")
  elseif settings.kind == "editor" then
    self.target_line = editor_target(settings, index)
    position(self.view, self.target_line)
  elseif settings.kind == "diff" then
    if settings.save_workspace and index == settings.actions then
      core.save_workspace()
    elseif settings.action == "wheel" then
      self.wheel_start_y = self.view.scroll.y
      self.wheel_direction = index <= SCROLL_DOWN_TICKS and 1 or -1
      assert(self.diff:on_mouse_wheel(-self.wheel_direction, 0),
        "Diff View did not accept the wheel scroll")
      core.request_workspace_save("Diff wheel benchmark")
    elseif settings.action == "scroll" then
      local span = math.max(1, #self.view.buffer.lines - 100)
      local line = 1 + math.floor((index - 1) * span / math.max(1, settings.actions - 1))
      position(self.view, line)
      self.diff:sync_scroll_from(self.view, false)
    elseif settings.action == "navigate" then
      local before = self.view:with_selection_state(function() return self.view.buffer:get_selection() end)
      assert(command.perform("diff:next_change"), "Diff change navigation failed")
      local after = self.view:with_selection_state(function() return self.view.buffer:get_selection() end)
      assert(after > before, "Diff navigation did not reach another change")
    end
  elseif settings.kind == "fuzzy" then
    local target = 1 + ((index - 1) * 7919) % settings.files
    self.target_name = string.format("candidate_%06d.lua", target)
    self.query = settings.action == "text-query"
      and string.format('#"BENCH_NEEDLE_%06d"', target)
      or string.format("candidate_%06d", target)
    local fuzzy = require "plugins.fuzzy_searcher"
    if not self.picker then
      fuzzy.open(self.query)
      self.picker = assert(core.fuzzy_searcher_active_view)
    else
      self.picker.input:set_text("")
      self.picker:on_text_input(self.query)
    end
  elseif settings.kind == "switch" or settings.kind == "open" then
    local name = settings.kind == "open" and "huge.lua"
      or string.format("switch-%03d.lua", 1 + (index - 1) % settings.files)
    self.target_name = name
    if settings.kind == "open" then
      assert(not core.buffer_registry:find(self:path(name)), "First-open fixture was already loaded")
    end
    self.view = open(self:path(name))
    if self.switch_buffers then
      assert(self.view.buffer == self.switch_buffers[1 + (index - 1) % settings.files],
        "File switching reloaded a cached Buffer")
    end
    self.view:set_wrapping_enabled(false)
    assert(common.basename(self.view.buffer.abs_filename) == name, "File open returned the wrong Buffer")
    assert(#self.view.buffer.lines == settings.lines, string.format(
      "File open loaded %d lines; expected %d", #self.view.buffer.lines, settings.lines))
    local last = self.view.buffer.lines[settings.lines]
    local expected = string.format(settings.kind == "open" and "value_%07d" or "value_%06d", settings.lines)
    assert(last:find(expected, 1, true),
      "File open did not retain the final fixture line")
  elseif settings.kind == "edit" then
    assert(core.active_view == self.view, "Editor lost input focus")
    if index % 2 == 1 then
      core.on_event("textinput", "z")
    else
      assert(command.perform("core:undo"), "Undo was unavailable")
    end
    self.view:with_selection_state(function()
      for line = 1, settings.carets do
        local expected = index % 2 == 1 and "z" or "x"
        assert(self.view.buffer.lines[line]:sub(1, 1) == expected, "Edit did not reach every caret")
      end
    end)
  end
  core.redraw = true
end

function Workload:action_ready()
  if self.picker then
    assert(core.fuzzy_searcher_active_view == self.picker, "Fuzzy Searcher closed during a query")
    if self.picker.input:get_text() ~= self.query then return false end
    for index, result in ipairs(self.picker.results or {}) do
      local path = result.abs_path or result.file
      if path and common.basename(path) == self.target_name then
        -- Require the result to be within the rendered list, not only in a hidden tail.
        local metrics = self.picker:list_metrics()
        local first = self.picker.viewport_offset or 1
        if index >= first and index < first + metrics.result_rows then
          self.result = self.query .. " -> " .. self.target_name
          return true, self.result
        end
      end
    end
    return false
  end
  if not self:setup_ready() then return false end
  if self.settings.kind == "editor" then
    assert(self.view:is_wrapping_enabled() == self.settings.wrap,
      "Editor wrapping mode changed")
    if self.settings.content == "markdown" then
      assert(self.view.__markdown_live_attached, "Markdown Live Preview detached")
    end
    if self.settings.action == "type" then
      local expected = self.typed_original .. TYPED_TEXT:sub(1, self.index) .. "\n"
      if self.view.buffer.lines[self.typed_line] ~= expected then return false end
    elseif self.settings.action == "scroll" then
      local scroll = self.view.scroll
      if math.abs(scroll.y - scroll.to.y) >= 0.5 then return false end
    else
      local line = self.view:with_selection_state(function()
        return self.view.buffer:get_selection()
      end)
      assert(line == self.target_line, "Editor action did not reach its line")
    end
  end
  if self.diff then
    assert(#self.diff.a_changes > 0 and #self.diff.b_changes > 0, "Diff fixture has no changes")
    assert(self.view.size.x > 0 and self.view.size.y > 0, "Diff Side is not visible")
    for _, side in ipairs(self.diff:get_surface_focus_targets()) do
      assert(side:is_wrapping_enabled() == self.settings.wrap, "Diff wrapping mode changed")
      if self.settings.action == "wheel" and math.abs(side.scroll.y - side.scroll.to.y) >= 0.5 then
        return false
      end
    end
    if self.wheel_start_y then
      assert((self.view.scroll.y - self.wheel_start_y) * self.wheel_direction > 0,
        "Diff wheel action did not move the visible text")
      self.wheel_start_y = nil
    end
  end
  local line, col = self.view:with_selection_state(function() return self.view.buffer:get_selection() end)
  self.result = string.format("%s:%d:%d:%d", self.target_name or self.settings.kind,
    #self.view.buffer.lines, line, col)
  return true, self.result
end

-- Screenshots wait for asynchronous decorations so a capture never depends on
-- how quickly a debounced background result arrives.
function Workload.buffers_ready(buffers)
  local gitdiff = package.loaded["plugins.gitdiff_highlight"]
  local git_status = package.loaded["plugins.file_git_status"]
  for _, buffer in ipairs(buffers) do
    local path = buffer.abs_filename
    if path then
      if gitdiff and not gitdiff.is_settled(buffer) then return false end
      if git_status and not git_status:is_settled(path, false) then return false end
    end
  end
  return true
end

function Workload:capture_ready()
  local buffer = self.view and self.view.buffer
  if buffer and not Workload.buffers_ready({ buffer }) then return false end
  -- Tab titles and picker rows color file names by their Git status.
  local git_status = package.loaded["plugins.file_git_status"]
  return not (git_status and self.picker) or git_status:is_settled(self:path("project"), true)
end

function Workload:state()
  return {
    workload_kind = self.settings.kind, workload_result = self.result or "",
    workload_actions = self.completed,
    diff_left_changes = self.diff and #self.diff.a_changes or 0,
    diff_right_changes = self.diff and #self.diff.b_changes or 0,
    diff_wrapped = self.diff and self.view:is_wrapping_enabled() or false,
    diff_scroll_y = self.diff and self.view.scroll.to.y or 0,
    code_scale = require("plugins.scale").get_code(),
    editor_wrapped = self.settings.kind == "editor" and self.view:is_wrapping_enabled() or false,
    editor_markdown_live = self.settings.kind == "editor"
      and self.view.__markdown_live_attached == true or false,
  }
end

return Workload
