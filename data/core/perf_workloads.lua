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
  if settings.kind == "diff" then
    self.diff = assert(require("plugins.diffview").file_to_file(
      self:path("left.lua"), self:path("right.lua")))
    self.view = self.diff.buffer_view_b
    core.set_active_view(self.view)
    for _, side in ipairs(self.diff:get_surface_focus_targets()) do
      side:set_wrapping_enabled(true)
      linewrapping.update_textview_breaks(side)
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
  else
    error("unknown benchmark workload: " .. tostring(settings.kind))
  end
  core.redraw = true
  return self.view
end

function Workload:setup_ready()
  if self.diff then
    assert(not self.diff.comparison_message, self.diff.comparison_message)
    return self.diff.diff_model ~= nil and not self.diff.updater_idx
      and not self.diff.pending_first_change_reveal
      and ready_editor(self.diff.buffer_view_a) and ready_editor(self.diff.buffer_view_b)
  end
  return ready_editor(self.view)
end

function Workload:action_name(index)
  local settings = self.settings
  if settings.kind == "fuzzy" then
    return index == 1 and ("first-" .. settings.action) or settings.action
  end
  if settings.kind == "diff" then return "diff-" .. settings.action end
  if settings.kind == "edit" then return index % 2 == 1 and "insert" or "undo" end
  return "file-" .. settings.kind
end

function Workload:dispatch(index)
  local settings = self.settings
  self.index = index
  if settings.kind == "diff" then
    if settings.action == "scroll" then
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
  if self.diff then
    assert(#self.diff.a_changes > 0 and #self.diff.b_changes > 0, "Diff fixture has no changes")
    assert(self.view.size.x > 0 and self.view.size.y > 0, "Diff Side is not visible")
  end
  local line, col = self.view:with_selection_state(function() return self.view.buffer:get_selection() end)
  self.result = string.format("%s:%d:%d:%d", self.target_name or self.settings.kind,
    #self.view.buffer.lines, line, col)
  return true, self.result
end

function Workload:state()
  return {
    workload_kind = self.settings.kind, workload_result = self.result or "",
    workload_actions = self.completed,
    diff_left_changes = self.diff and #self.diff.a_changes or 0,
    diff_right_changes = self.diff and #self.diff.b_changes or 0,
    code_scale = require("plugins.scale").get_code(),
  }
end

return Workload
