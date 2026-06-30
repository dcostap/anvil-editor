-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"
local View = require "core.view"

---Configuration options for `diffview` plugin.
---@class config.plugins.diffview
---Logs the amount of time taken to recompute differences.
---@field log_times boolean
---Disable syntax coloring on changed lines to improve visibility.
---@field plain_text boolean
---The color used on changed lines when plain text is enabled.
---@field plain_text_color renderer.color
---Collapse long unchanged regions by default.
---@field fold_unchanged_by_default boolean
---Unchanged context lines to keep around changes when folding.
---@field fold_context_lines integer
---Minimum hidden unchanged lines needed to create a fold.
---@field fold_min_lines integer
config.plugins.diffview.config_spec = {
    name = "Differences Viewer",
    {
      label = "Log Times",
      description = "Logs the amount of time taken to compute differences.",
      path = "log_times",
      type = "toggle",
      default = false
    },
    {
      label = "Plain Text",
      description = "Disable syntax coloring on changed lines to improve visibility.",
      path = "plain_text",
      type = "toggle",
      default = false
    },
    {
      label = "Plain Text Color",
      description = "The color used on changed lines when plain text is enabled.",
      path = "plain_text_color",
      type = "color",
      default = config.plugins.diffview.plain_text_color
    },
    {
      label = "Fold Unchanged Regions",
      description = "Collapse long unchanged diff regions by default.",
      path = "fold_unchanged_by_default",
      type = "toggle",
      default = true
    },
    {
      label = "Fold Context Lines",
      description = "Unchanged context lines to keep around diff hunks.",
      path = "fold_context_lines",
      type = "number",
      default = config.plugins.diffview.fold_context_lines
    },
    {
      label = "Fold Minimum Lines",
      description = "Minimum hidden unchanged lines needed to create a collapsed region.",
      path = "fold_min_lines",
      type = "number",
      default = config.plugins.diffview.fold_min_lines
    }
  }

---@type string?
local element_a = nil
---@type string?
local element_b = nil
---@type string?
local element_a_text = nil
---@type string?
local element_b_text = nil
---@type integer
local diff_updater_idx = 0

local function with_docview_selection(view, fn, ...)
  if view and view.with_selection_state then
    return view:with_selection_state(fn, ...)
  end
  return fn(...)
end

local function call_docview_method(view, method, ...)
  return with_docview_selection(view, method, view, ...)
end

local is_fold_widget_line

---@class plugins.diffview.view : core.view
---@field super core.view
---@field doc_view_a core.docview
---@field doc_view_b core.docview
---@field a_changes diff.changes[]
---@field b_changes diff.changes[]
---@field a_gaps table<integer,table<integer,integer>>
---@field b_gaps table<integer,table<integer,integer>>
---@field compare_type plugins.diffview.view.type
---@field hovered_sync? plugins.diffview.view.hovered_sync
---@overload fun(a:string,b:string,ct?:plugins.diffview.view.type,names?:plugins.diffview.view.string_names):plugins.diffview.view
local DiffView = View:extend()

---@enum plugins.diffview.view.type
DiffView.type = {
  STRING_FILE = 1,
  FILE_STRING = 2,
  FILE_FILE = 3,
  STRING_STRING = 4
}

---Represents the active sync indicator.
---@class plugins.diffview.view.hovered_sync
---@field is_a boolean
---@field line integer
---@field target_line integer

---Names used when a or b are not files.
---@class plugins.diffview.view.string_names
---@field a? string
---@field b? string

---Constructor
---@param a string
---@param b string
---@param compare_type? plugins.diffview.view.type
---@param names? plugins.diffview.view.string_names
function DiffView:new(a, b, compare_type, names)
  DiffView.super.new(self)

  self.scrollable = true
  self.compare_type = compare_type or DiffView.type.STRING_STRING
  self.hovered_sync = nil
  self.skip_update_diff = false

  names = names or {}

  local doc_a, doc_b
  if compare_type == DiffView.type.FILE_FILE then
    doc_a = Doc(common.basename(a), a)
    doc_b = Doc(common.basename(b), b)
  elseif compare_type == DiffView.type.STRING_STRING then
    doc_a = Doc(names.a, names.a, true)
    if a ~= "" then doc_a:insert(1, 1, a) doc_a:clear_undo_redo() end
    doc_b = Doc(names.b, names.b, true)
    if b ~= "" then doc_b:insert(1, 1, b) doc_b:clear_undo_redo() end
  elseif compare_type == DiffView.type.STRING_FILE then
    doc_a = Doc(names.a, names.a, true)
    if a ~= "" then doc_a:insert(1, 1, a) doc_a:clear_undo_redo() end
    doc_b = Doc(common.basename(b), b)
  elseif compare_type == DiffView.type.FILE_STRING then
    doc_a = Doc(common.basename(a), a)
    doc_b = Doc(names.b, names.b, true)
    if b ~= "" then doc_b:insert(1, 1, b) doc_b:clear_undo_redo() end
  end

  self.doc_view_a = DocView(doc_a)
  self.doc_view_b = DocView(doc_b)

  self.doc_view_a.diff_view_parent = self
  self.doc_view_b.diff_view_parent = self

  self.a_gaps = {}
  self.b_gaps = {}
  self.a_changes = {}
  self.b_changes = {}
  self.diff_folds_a = {}
  self.diff_folds_b = {}
  self.expanded_diff_folds = {}
  self.folding_enabled = config.plugins.diffview.fold_unchanged_by_default ~= false
  self.views_patched = false

  self:patch_views()
  self:update_diff()

  self.v_scrollbar.contracted_size = style.expanded_scrollbar_size * 2
  self.v_scrollbar.expanded_size = style.expanded_scrollbar_size * 2
end

function DiffView:get_focus_view()
  return self.doc_view_a
end

function DiffView:get_name()
  if self.compare_type == DiffView.type.FILE_FILE then
    return "Files Comparison"
  elseif self.compare_type == DiffView.type.STRING_STRING then
    return "Text Diff View"
  elseif self.compare_type == DiffView.type.FILE_STRING then
    return "File/Text Diff View"
  elseif self.compare_type == DiffView.type.STRING_FILE then
    return "Text/File Diff View"
  end
  return "Diff Viewer"
end

---Updates the registered differences between current side A and B.
function DiffView:update_diff()
  if self.skip_update_diff then self.skip_update_diff = false return end

  -- stop previous update if still running.
  if self.updater_idx then
    for _, thread in pairs(core.threads) do
      if thread.diff_viewer and thread.diff_viewer == self.updater_idx then
        thread.cr = coroutine.create(function() end)
      end
    end
  end

  local start_time = system.get_time()

  if config.plugins.diffview.log_times then
    core.log(
      (#self.a_changes == 0 and "Computing " or "Recomputing ")
      .. "differences..."
    )
  end

  local idx = core.add_thread(function()
    local ai, bi = 1, 1
    local a_offset, b_offset = 0, 0
    local a_offset_total, b_offset_total = 0, 0
    local a_len = #self.doc_view_a.doc.lines
    local b_len = #self.doc_view_b.doc.lines

    local computing_start = system.get_time()
    local a_gaps = #self.a_gaps == 0 and self.a_gaps or {}
    local b_gaps = #self.b_gaps == 0 and self.b_gaps or {}
    local a_changes = #self.a_changes == 0 and self.a_changes or {}
    local b_changes = #self.b_changes == 0 and self.b_changes or {}
    local equal_blocks = {}
    local equal_block, seen_change = nil, false
    local function flush_equal_block(has_next_change)
      if equal_block and equal_block.count > 0 then
        equal_block.has_next_change = has_next_change == true
        equal_blocks[#equal_blocks + 1] = equal_block
      end
      equal_block = nil
    end
    for edit in diff.diff_iter(self.doc_view_a.doc.lines, self.doc_view_b.doc.lines) do
      if edit.tag == "equal" or edit.tag == "modify" then
        -- Assign gaps for this line
        a_gaps[ai] = { a_offset, a_offset_total }
        b_gaps[bi] = { b_offset, b_offset_total }

        -- Insert inline diffs if present
        if edit.a and edit.b and edit.tag == "equal" then
          equal_block = equal_block or { a_start = ai, b_start = bi, count = 0, has_prev_change = seen_change }
          equal_block.count = equal_block.count + 1
        else
          flush_equal_block(true)
          seen_change = true
        end
        if edit.a then
          table.insert(a_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.b or "", edit.a)
          })
          ai = ai + 1
          a_offset = 0
        end
        if edit.b then
          table.insert(b_changes, {
            tag = edit.tag,
            changes = diff.inline_diff(edit.a or "", edit.b)
          })
          bi = bi + 1
          b_offset = 0
        end

      elseif edit.tag == "delete" then
        flush_equal_block(true)
        seen_change = true
        -- Lines only in A (deleted from B)
        if edit.a then
          a_gaps[ai] = { a_offset, a_offset_total }
          table.insert(a_changes, { tag = "delete" })
          ai = ai + 1
          -- Increase gap on B side because these lines are missing in B
          b_offset = b_offset + 1
          b_offset_total = b_offset_total + 1
        end

      elseif edit.tag == "insert" then
        flush_equal_block(true)
        seen_change = true
        -- Lines only in B (inserted in B)
        if edit.b then
          b_gaps[bi] = { b_offset, b_offset_total }
          table.insert(b_changes, { tag = "insert" })
          bi = bi + 1
          -- Increase gap on A side because these lines are missing in A
          a_offset = a_offset + 1
          a_offset_total = a_offset_total + 1
        end
      end

      if system.get_time() - computing_start >= 0.5 then
        coroutine.yield()
        computing_start = system.get_time()
      end
    end

    flush_equal_block(false)

    -- Fill trailing lines spaces after diff ends
    while ai <= a_len do
      a_gaps[ai] = a_gaps[ai] or { a_offset, a_offset_total }
      ai = ai + 1
    end
    while bi <= b_len do
      b_gaps[bi] = b_gaps[bi] or { b_offset, b_offset_total }
      bi = bi + 1
    end

    self.a_gaps = a_gaps
    self.b_gaps = b_gaps
    self.a_changes = a_changes
    self.b_changes = b_changes
    self.diff_equal_blocks = equal_blocks
    self:rebuild_diff_folds()

    self.updater_idx = nil

    self.doc_view_b.scroll.to.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.y = self.doc_view_a.scroll.y

    if config.plugins.diffview.log_times then
      core.log(
        "Finished computing differences in %.2fs",
        system.get_time() - start_time
      )
    end
  end)

  core.threads[idx].diff_viewer = diff_updater_idx
  self.updater_idx = diff_updater_idx
  diff_updater_idx = diff_updater_idx + 1
end

function DiffView:sync(line, target_line, is_a)
  local changes = is_a and self.a_changes or self.b_changes
  local target_changes = is_a and self.b_changes or self.a_changes
  local target_gaps = is_a and self.b_gaps or self.a_gaps

  ---@type core.docview
  local from = is_a and self.doc_view_a or self.doc_view_b
  ---@type core.docview
  local to = is_a and self.doc_view_b or self.doc_view_a

  local l = line
  local tag = changes[l].tag
  local text = ""
  local total = 0
  while changes[l] and changes[l].tag == tag do
    total = total + 1
    changes[l] = {tag = "equal"}
    text = text .. from.doc.lines[l]
    l = l + 1
  end
  if tag == "modify" then
    with_docview_selection(to, function()
      to.doc:set_selection(target_line, 1, target_line+total-1, math.huge)
      to.doc:replace(function() return text:sub(1, #text-1) end)
    end)
    for i=target_line, target_line+total-1 do
      target_changes[i] = {tag = "equal"}
    end
  else
    with_docview_selection(to, function()
      if line == 1 and target_line == 1 then
        to.doc:apply_edits({
          { line1 = target_line, col1 = 1, line2 = target_line, col2 = 1, text = text },
        }, { type = "insert", merge_cursors = false })
        target_line = target_line - 1
      else
        to.doc:apply_edits({
          { line1 = target_line, col1 = math.huge, line2 = target_line, col2 = math.huge, text = "\n" .. text:sub(1, #text - 1) },
        }, { type = "insert", merge_cursors = false })
      end
    end)

    -- update target changes and target gaps
    local changes_inserts = {}

    for _=1, total do
      table.insert(changes_inserts, {tag = "equal"})
    end

    common.splice(target_changes, target_line, 0, changes_inserts)

    local gaps_inserts = {}
    local gaps = {0, 0}

    if target_gaps[target_line+1] then
      gaps = {0, target_gaps[target_line+1][2] - total}
      target_gaps[target_line+1] = {table.unpack(gaps)}
      for i=target_line+2, #target_gaps do
        target_gaps[i][2] = target_gaps[i][2] - total
      end
    end

    for _=1, total do
      table.insert(gaps_inserts, {table.unpack(gaps)})
    end

    common.splice(target_gaps, target_line, 0, gaps_inserts)
  end
end

function DiffView:sync_selected()
  local view, changes, to_view, is_a

  if core.active_view == self.doc_view_a then
    view = self.doc_view_a
    to_view = self.doc_view_b
    changes = self.a_changes
    is_a = true
  elseif core.active_view == self.doc_view_b then
    view = self.doc_view_b
    to_view = self.doc_view_a
    changes = self.b_changes
  end

  if not view then return end

  local line = view.doc:get_selection()
  local tag = changes[line].tag
  if tag == "equal" then
    core.error("No valid change selected")
    return
  end

  while changes[line-1] and changes[line-1].tag == tag do
    line = line - 1
  end

  view.doc:set_selection(line, 1, line, 1)

  local _, y = view:get_line_screen_position(line, 1)
  to_view.scroll.to.y =  view.scroll.y
  to_view.scroll.y =  view.scroll.y

  local target_line = to_view:resolve_screen_position(
    to_view.position.x + style.padding.x, y
  )

  self:sync(line, target_line, is_a)
end

function DiffView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    for _, side in ipairs({
      { view = self.doc_view_a, folds = self.diff_folds_a },
      { view = self.doc_view_b, folds = self.diff_folds_b },
    }) do
      local view = side.view
      if x >= view.position.x and x <= view.position.x + view.size.x
        and y >= view.position.y and y <= view.position.y + view.size.y
      then
        local line = view:resolve_screen_position(x, y)
        local is_widget, fold = is_fold_widget_line(side.folds, line)
        if is_widget then return self:expand_fold(fold) end
      end
    end
  end
  if button == "left" and self.hovered_sync then
    self:sync(
      self.hovered_sync.line,
      self.hovered_sync.target_line,
      self.hovered_sync.is_a
    )
    self.hovered_sync = nil
    return
  end
  if DiffView.super.on_mouse_pressed(self, button, x, y, clicks) then
    self.scroll.y = self.scroll.to.y
    self.doc_view_a.scroll.to.y = self.scroll.y
    self.doc_view_a.scroll.y = self.scroll.y
    self.doc_view_b.scroll.to.y = self.scroll.y
    self.doc_view_b.scroll.y = self.scroll.y
    return true
  elseif call_docview_method(self.doc_view_a, self.doc_view_a.on_mouse_pressed, button, x, y, clicks) then
    self.doc_view_a.scroll.y = self.doc_view_a.scroll.to.y
    self.scroll.to.y = self.doc_view_a.scroll.y
    self.scroll.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.to.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.y = self.doc_view_a.scroll.y
    return true
  elseif call_docview_method(self.doc_view_b, self.doc_view_b.on_mouse_pressed, button, x, y, clicks) then
    self.doc_view_b.scroll.y = self.doc_view_b.scroll.to.y
    self.scroll.to.y = self.doc_view_b.scroll.y
    self.scroll.y = self.doc_view_b.scroll.y
    self.doc_view_a.scroll.to.y = self.doc_view_b.scroll.y
    self.doc_view_a.scroll.y = self.doc_view_b.scroll.y
    return true
  end
  for _, view in ipairs({self.doc_view_a, self.doc_view_b}) do
    if
      x >= view.position.x
      and
      x <= view.position.x + view.size.x
    then
      core.set_active_view(view)
      break
    end
  end
end

function DiffView:on_mouse_released(...)
  DiffView.super.on_mouse_released(self, ...)
  call_docview_method(self.doc_view_a, self.doc_view_a.on_mouse_released, ...)
  call_docview_method(self.doc_view_b, self.doc_view_b.on_mouse_released, ...)
end

---@param self plugins.diffview.view
local function check_hovered_sync(self, x, y)
  local x1 = self.doc_view_a.position.x + self.doc_view_a.size.x
  local x2 = self.doc_view_b.position.x + style.padding.x / 2

  if x >= x1 and x <= x2 then
    ---@type integer
    local line
    ---@type integer
    local target_line
    ---@type diff.changes[]
    local changes
    ---@type boolean
    local is_a = false

    -- hovering side A
    if x <= x1 + ((x2 - x1) / 2) then
      line = self.doc_view_a:resolve_screen_position(x1 - style.padding.x, y)
      target_line = self.doc_view_b:resolve_screen_position(x2 - style.padding.x, y)
      changes = self.a_changes
      is_a = true

    -- hovering side B
    elseif x >= x1 + ((x2 - x1) / 2) + style.padding.x / 2  then
      line = self.doc_view_b:resolve_screen_position(x2 - style.padding.x, y)
      target_line = self.doc_view_a:resolve_screen_position(x1 - style.padding.x, y)
      changes = self.b_changes
    end

    -- check if hovering valid line and save it
    if line and changes[line] and changes[line].tag ~= "equal" then
      if not changes[line-1] or changes[line-1].tag ~= changes[line].tag then
        self.hovered_sync = {
          is_a = is_a,
          line = line,
          target_line = target_line
        }
        return
      end
    end
  end

  self.hovered_sync = nil
end

function DiffView:on_mouse_moved(...)
  -- ignore config.animate_drag_scroll by setting scroll.y to scroll.to.y
  -- since views would end in different positions, also scrolling two
  -- views at the same time with animation on would be more cpu demanding.

  if DiffView.super.on_mouse_moved(self, ...) then
    if self.v_scrollbar.dragging then
      self.scroll.y = self.scroll.to.y
      self.doc_view_a.scroll.to.y = self.scroll.y
      self.doc_view_a.scroll.y = self.scroll.y
      self.doc_view_b.scroll.to.y = self.scroll.y
      self.doc_view_b.scroll.y = self.scroll.y
      return true
    end
  end
  call_docview_method(self.doc_view_a, self.doc_view_a.on_mouse_moved, ...)
  if self.doc_view_a:scrollbar_dragging() then
    self.doc_view_a.scroll.y = self.doc_view_a.scroll.to.y
    self.scroll.to.y = self.doc_view_a.scroll.y
    self.scroll.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.y = self.doc_view_a.scroll.y
    self.doc_view_b.scroll.to.y = self.doc_view_a.scroll.y
    return true
  end
  call_docview_method(self.doc_view_b, self.doc_view_b.on_mouse_moved, ...)
  if self.doc_view_b:scrollbar_dragging() then
    self.doc_view_b.scroll.y = self.doc_view_b.scroll.to.y
    self.scroll.to.y = self.doc_view_b.scroll.y
    self.scroll.y = self.doc_view_b.scroll.y
    self.doc_view_a.scroll.y = self.doc_view_b.scroll.y
    self.doc_view_a.scroll.to.y = self.doc_view_b.scroll.y
    return true
  end
  check_hovered_sync(self, ...)
end

function DiffView:on_mouse_left()
  DiffView.super.on_mouse_left(self)
  self.doc_view_a:on_mouse_left()
  self.doc_view_b:on_mouse_left()
end

function DiffView:on_mouse_wheel(y, x)
  if keymap.modkeys["shift"] then
    x = y
    y = 0
  end
  if y and y ~= 0 then
    self.doc_view_a.scroll.to.y = self.doc_view_a.scroll.to.y + y * -config.mouse_wheel_scroll
    self.doc_view_b.scroll.to.y = self.doc_view_b.scroll.to.y + y * -config.mouse_wheel_scroll
  end
  if x and x ~= 0 then
    self.doc_view_a.scroll.to.x = self.doc_view_a.scroll.to.x + x * -config.mouse_wheel_scroll
    self.doc_view_b.scroll.to.x = self.doc_view_b.scroll.to.x + x * -config.mouse_wheel_scroll
  end
end

function DiffView:on_scale_change(...)
  self.v_scrollbar.contracted_size = style.expanded_scrollbar_size  * 2
  self.v_scrollbar.expanded_size = style.expanded_scrollbar_size * 2
  self.doc_view_a:on_scale_change(...)
  self.doc_view_b:on_scale_change(...)
end

function DiffView:on_touch_moved(...)
  DiffView.super.on_touch_moved(self, ...)
  call_docview_method(self.doc_view_a, self.doc_view_a.on_touch_moved, ...)
  call_docview_method(self.doc_view_b, self.doc_view_b.on_touch_moved, ...)
end

local function wrapped_total_visual_lines(doc_view)
  if doc_view.get_total_visual_lines then return doc_view:get_total_visual_lines() end
  if not doc_view.wrapped_settings or not doc_view.wrapped_lines then
    return doc_view.doc and #doc_view.doc.lines or 0
  end
  return #doc_view.wrapped_lines / 2
end

local function visual_rows_before_line(doc_view, line)
  if not doc_view.wrapped_settings or not doc_view.wrapped_line_to_idx then
    return math.max(0, line - 1)
  end
  local idx = doc_view.wrapped_line_to_idx[line]
  if idx then return idx - 1 end
  return math.max(0, math.min(wrapped_total_visual_lines(doc_view), line - 1))
end

local function visual_line_count(doc_view, line)
  if doc_view.get_visual_row_count_for_line then return doc_view:get_visual_row_count_for_line(line) end
  if not doc_view.wrapped_settings or not doc_view.wrapped_line_to_idx then return 1 end
  local total = wrapped_total_visual_lines(doc_view)
  local idx = doc_view.wrapped_line_to_idx[line]
  if not idx then return 1 end
  local next_idx = doc_view.wrapped_line_to_idx[line + 1] or (total + 1)
  return math.max(1, next_idx - idx)
end

local function visual_row_offset_for_col(doc_view, line, col, line_end)
  if not col or not doc_view.wrapped_settings or not doc_view.wrapped_line_to_idx then return 0 end
  local first_idx = doc_view.wrapped_line_to_idx[line]
  if not first_idx then return 0 end
  if doc_view.get_visual_row then
    local idx = doc_view:get_visual_row(line, col, line_end)
    return math.max(0, idx - first_idx)
  end
  local offset = 0
  local i = first_idx + 1
  while doc_view.wrapped_lines[(i - 1) * 2 + 1] == line
    and col >= doc_view.wrapped_lines[(i - 1) * 2 + 2]
  do
    offset = offset + 1
    i = i + 1
  end
  return offset
end

local function gap_rows_before_line(gaps, line)
  return gaps[line] and gaps[line][2] or 0
end

local function trailing_gap_rows(gaps, line)
  return gaps[line] and gaps[line][1] or 0
end

local function diffview_visual_line_count(doc_view, gaps)
  local line_count = #doc_view.doc.lines
  if line_count == 0 then return 0 end
  return visual_rows_before_line(doc_view, line_count)
    + visual_line_count(doc_view, line_count)
    + gap_rows_before_line(gaps, line_count)
    + trailing_gap_rows(gaps, line_count)
end

local function fold_visual_rows(doc_view, first, last)
  local rows = 0
  for line = first, last do rows = rows + visual_line_count(doc_view, line) end
  return rows
end

local function fold_saved_rows(doc_view, fold)
  if not fold then return 0 end
  return math.max(0, fold_visual_rows(doc_view, fold.hidden_start, fold.hidden_end) - 1)
end

local function folded_rows_total(doc_view, folds)
  local total = 0
  for _, fold in ipairs(folds or {}) do total = total + fold_saved_rows(doc_view, fold) end
  return total
end

local function fold_for_line(folds, line)
  for _, fold in ipairs(folds or {}) do
    if line >= fold.hidden_start and line <= fold.hidden_end then return fold end
  end
end

function is_fold_widget_line(folds, line)
  local fold = fold_for_line(folds, line)
  return fold and line == fold.hidden_start, fold
end

local function is_fold_hidden_line(folds, line)
  local fold = fold_for_line(folds, line)
  return fold and line > fold.hidden_start, fold
end

local function folded_visual_line_count(doc_view, folds, line)
  if is_fold_hidden_line(folds, line) then return 0 end
  if is_fold_widget_line(folds, line) then return 1 end
  return visual_line_count(doc_view, line)
end

local function folded_rows_before_line(doc_view, folds, line)
  local rows = 0
  for _, fold in ipairs(folds or {}) do
    if line > fold.hidden_end then
      rows = rows + fold_saved_rows(doc_view, fold)
    elseif line > fold.hidden_start then
      rows = rows + math.max(0, fold_visual_rows(doc_view, fold.hidden_start, line - 1) - 1)
      break
    end
  end
  return rows
end

local function effective_row_before_line(doc_view, gaps, folds, line)
  return visual_rows_before_line(doc_view, line)
    + gap_rows_before_line(gaps, line)
    - folded_rows_before_line(doc_view, folds, line)
end

local function effective_visual_line_count(doc_view, gaps, folds)
  return math.max(0, diffview_visual_line_count(doc_view, gaps) - folded_rows_total(doc_view, folds))
end

local function line_for_effective_row(doc_view, gaps, folds, row)
  local fallback = #doc_view.doc.lines
  for line = 1, #doc_view.doc.lines do
    local count = folded_visual_line_count(doc_view, folds, line)
    if count > 0 then
      local start_row = effective_row_before_line(doc_view, gaps, folds, line)
      if row < start_row + count then return line end
      fallback = line
    end
  end
  return fallback
end

local function build_diff_folds(blocks, side, opts, expanded)
  if not opts.enabled then return {} end
  local folds = {}
  local context = math.max(0, tonumber(opts.context_lines) or 0)
  local min_lines = math.max(1, tonumber(opts.min_lines) or 1)
  for fold_index, block in ipairs(blocks or {}) do
    local start = side == "a" and block.a_start or block.b_start
    local count = block.count or 0
    local keep_start = block.has_prev_change and context or 0
    local keep_end = block.has_next_change and context or 0
    local hidden_start = start + keep_start
    local hidden_end = start + count - 1 - keep_end
    local hidden_count = hidden_end - hidden_start + 1
    if count >= keep_start + keep_end + min_lines and hidden_count >= min_lines and not expanded[fold_index] then
      folds[#folds + 1] = {
        index = fold_index,
        hidden_start = hidden_start,
        hidden_end = hidden_end,
        hidden_count = hidden_count,
      }
    end
  end
  return folds
end

function DiffView:rebuild_diff_folds()
  local opts = {
    enabled = self.folding_enabled,
    context_lines = config.plugins.diffview.fold_context_lines or 6,
    min_lines = config.plugins.diffview.fold_min_lines or 16,
  }
  local expanded = self.expanded_diff_folds or {}
  self.diff_folds_a = build_diff_folds(self.diff_equal_blocks or {}, "a", opts, expanded)
  self.diff_folds_b = build_diff_folds(self.diff_equal_blocks or {}, "b", opts, expanded)
end

function DiffView:toggle_folding()
  self.folding_enabled = not self.folding_enabled
  if self.folding_enabled then self.expanded_diff_folds = {} end
  self:rebuild_diff_folds()
  core.redraw = true
  return true
end

function DiffView:expand_fold(fold)
  if not fold then return false end
  self.expanded_diff_folds = self.expanded_diff_folds or {}
  self.expanded_diff_folds[fold.index] = true
  self:rebuild_diff_folds()
  core.redraw = true
  return true
end

function DiffView:sync_scroll_from(doc_view, is_a)
  local other = is_a and self.doc_view_b or self.doc_view_a
  self.scroll.y, self.scroll.to.y = doc_view.scroll.y, doc_view.scroll.to.y
  other.scroll.y, other.scroll.to.y = doc_view.scroll.y, doc_view.scroll.to.y
end

local function clamp_position_out_of_fold(doc_view, folds, old_line, line, col)
  if is_fold_widget_line(folds, line) then return line, 1 end
  local hidden, fold = is_fold_hidden_line(folds, line)
  if not hidden then return line, col end
  if tonumber(line) and tonumber(old_line) and line >= old_line and fold.hidden_end < #doc_view.doc.lines then
    return fold.hidden_end + 1, 1
  end
  return fold.hidden_start, 1
end

function DiffView:clamp_selection_out_of_folds(doc_view, is_a, line1, col1, line2, col2)
  local folds = is_a and self.diff_folds_a or self.diff_folds_b
  if not folds or #folds == 0 then return line1, col1, line2, col2 end
  local old_line = doc_view.doc:get_selection()
  line1, col1 = clamp_position_out_of_fold(doc_view, folds, old_line, line1, col1)
  if line2 then line2, col2 = clamp_position_out_of_fold(doc_view, folds, old_line, line2, col2) end
  return line1, col1, line2, col2
end

function DiffView:sync_caret_from(doc_view, is_a)
  if self.syncing_diff_caret then return end
  local other = is_a and self.doc_view_b or self.doc_view_a
  if not other then return end
  local source_gaps = is_a and self.a_gaps or self.b_gaps
  local target_gaps = is_a and self.b_gaps or self.a_gaps
  local source_folds = is_a and self.diff_folds_a or self.diff_folds_b
  local target_folds = is_a and self.diff_folds_b or self.diff_folds_a
  local line, col = doc_view.doc:get_selection()
  local row = effective_row_before_line(doc_view, source_gaps, source_folds, line)
  local target_line = line_for_effective_row(other, target_gaps, target_folds, row)
  local target_col = math.max(1, math.min(col or 1, #(other.doc.lines[target_line] or "")))
  target_line, target_col = clamp_position_out_of_fold(other, target_folds, other.doc:get_selection(), target_line, target_col)
  self.syncing_diff_caret = true
  other.doc:set_selection(target_line, target_col, target_line, target_col)
  self.syncing_diff_caret = false
end

function DiffView:get_scrollable_size()
  local a_count = effective_visual_line_count(self.doc_view_a, self.a_gaps, self.diff_folds_a)
  local b_count = effective_visual_line_count(self.doc_view_b, self.b_gaps, self.diff_folds_b)
  local lc = math.max(a_count, b_count)
  if not config.scroll_past_end then
    local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
    return self.doc_view_a:get_line_height() * lc + style.padding.y * 2 + h_scroll
  end
  return self.doc_view_a:get_line_height() * math.max(0, lc - 1) + self.size.y
end

---@param parent core.diffview
---@param self core.docview
---@param line integer
---@param x number
---@param y number
---@param changes diff.changes[]
local function draw_fold_widget(doc_view, fold, x, y)
  local h = doc_view:get_line_height()
  local gw = doc_view:get_gutter_width()
  renderer.draw_rect(doc_view.position.x + gw, y, doc_view.size.x - gw, h, style.line_highlight)
  local label = string.format("  ⋯ %d unchanged lines collapsed — click or Ctrl+R to expand ⋯", fold.hidden_count)
  renderer.draw_text(doc_view:get_font(), label, x + style.padding.x, y + doc_view:get_line_text_y_offset(), style.dim)
end

local function diff_color(tag, background)
  if tag == "insert" then return background and style.diff_insert_background or style.diff_insert end
  if tag == "delete" then return background and style.diff_delete_background or style.diff_delete end
  if tag == "modify" then return background and style.diff_modify_background or style.diff_modify end
end

local function gap_marker_color(tag)
  if tag == "delete" then return style.git_change_deletion or diff_color(tag) end
  return diff_color(tag)
end

local function alpha_color(color, alpha)
  if not color then return nil end
  local c = { table.unpack(color) }
  c[4] = math.min(c[4] or 255, alpha)
  return c
end

local function normalize_marker_range(y1, y2)
  if math.abs(y2 - y1) >= 2 * SCALE then return y1, y2 end
  return y1 - SCALE, y1
end

local function curve_point(x1, x2, y1, y2, t)
  local inv = 1 - t
  local width = x2 - x1
  local cx1 = x1 + width * 0.3
  local cx2 = x1 + width * 0.7
  local x = inv * inv * inv * x1
    + 3 * inv * inv * t * cx1
    + 3 * inv * t * t * cx2
    + t * t * t * x2
  local y = inv * inv * inv * y1
    + 3 * inv * inv * t * y1
    + 3 * inv * t * t * y2
    + t * t * t * y2
  return x, y
end

local function draw_curved_trapezium(x1, x2, start1, end1, start2, end2, color)
  if not color or x2 <= x1 then return end
  start1, end1 = normalize_marker_range(start1, end1)
  start2, end2 = normalize_marker_range(start2, end2)

  local points = {}
  local steps = 12
  for i = 0, steps do
    local x, y = curve_point(x1, x2, start1, start2, i / steps)
    points[#points + 1] = { x, y }
  end
  for i = steps, 0, -1 do
    local x, y = curve_point(x1, x2, end1, end2, i / steps)
    points[#points + 1] = { x, y }
  end
  renderer.draw_poly(points, color)
end

local function draw_gap_marker(doc_view, y, color)
  color = alpha_color(color, 190)
  if not color then return end
  local gw = doc_view:get_gutter_width()
  local h = math.max(1, SCALE)
  renderer.draw_rect(
    doc_view.position.x + gw,
    y - h / 2,
    math.max(0, doc_view.size.x - gw),
    h,
    color
  )
end

local function change_blocks(changes, tags)
  local blocks = {}
  local i = 1
  while i <= #changes do
    local change = changes[i]
    local tag = change and change.tag
    if tag and tag ~= "equal" and (not tags or tags[tag]) then
      local start_line = i
      local end_line = i
      while changes[end_line + 1] and changes[end_line + 1].tag == tag do
        end_line = end_line + 1
      end
      blocks[#blocks + 1] = { tag = tag, start_line = start_line, end_line = end_line }
      i = end_line + 1
    else
      i = i + 1
    end
  end
  return blocks
end

local function line_range_y(doc_view, folds, start_line, end_line)
  local _, start_y = doc_view:get_line_screen_position(start_line, 1)
  local _, end_y = doc_view:get_line_screen_position(end_line, 1)
  end_y = end_y + folded_visual_line_count(doc_view, folds, end_line) * doc_view:get_line_height()
  return start_y, end_y
end

local function draw_line_text_override(parent, self, line, x, y, changes)
  local text_y = y + self:get_line_text_y_offset()
  local h = self:get_line_height()
  local change = changes[line]
  if change and change.tag ~= "equal" then
    local delete_bg = style.diff_delete_background
    local insert_bg = style.diff_insert_background
    local delete_inline = style.diff_delete_inline
    local insert_inline = style.diff_insert_inline
    if config.plugins.diffview.plain_text then
      -- increase opacity to half
      delete_bg = { table.unpack(delete_bg) }
      delete_bg[4] = 128
      insert_bg = { table.unpack(insert_bg) }
      insert_bg[4] = 128
      -- make inline opaque
      delete_inline = style.diff_delete
      insert_inline = style.diff_insert
    end

    local first_idx, last_idx, logical_first_idx
    if self.wrapped_settings and self.wrapped_line_to_idx then
      logical_first_idx = self.wrapped_line_to_idx[line]
      if logical_first_idx then
        local total = self:get_total_visual_lines()
        local logical_last_idx = (self.wrapped_line_to_idx[line + 1] or (total + 1)) - 1
        first_idx = math.max(logical_first_idx, self.__wrapped_draw_first_idx or logical_first_idx)
        last_idx = math.min(logical_last_idx, self.__wrapped_draw_last_idx or logical_last_idx)
      end
    end

    local function draw_row_background(color)
      if first_idx and last_idx then
        for idx = first_idx, last_idx do
          renderer.draw_rect(self.position.x, text_y + (idx - logical_first_idx) * h, self.size.x, h, color)
        end
      else
        renderer.draw_rect(self.position.x, text_y, self.size.x, h, color)
      end
    end

    local function draw_inline_segment(col1, col2, color, text)
      if first_idx and last_idx then
        for idx = first_idx, last_idx do
          local row_start, row_end = self:get_visual_row_bounds_for_line(line, idx - logical_first_idx + 1)
          if row_start and row_end and col2 > row_start and col1 < row_end then
            local seg_col1 = math.max(col1, row_start)
            local seg_col2 = math.min(col2, row_end)
            local tx1 = self:get_col_x_offset(line, seg_col1, false)
            local tx2 = self:get_col_x_offset(line, seg_col2, seg_col2 == row_end)
            if tx2 > tx1 then
              renderer.draw_rect(x + tx1, text_y + (idx - logical_first_idx) * h, tx2 - tx1, h, color)
            end
          end
        end
      else
        local tx = self:get_col_x_offset(line, col1)
        local w = self:get_font():get_width(text or self.doc.lines[line]:sub(col1, math.max(col1, col2 - 1)))
        renderer.draw_rect(x + tx, text_y, w, h, color)
      end
    end

    if change.tag == "delete" then
      draw_row_background(delete_bg)
    elseif change.tag == "insert" then
      draw_row_background(insert_bg)
    else
      if change.changes then
        draw_row_background(changes == parent.a_changes and delete_bg or insert_bg)
        ---@type diff.changes[]
        local mods = change.changes
        local deletes = 0
        for i, edit in ipairs(mods) do
          if edit.tag == "insert" then
            local col1 = i - deletes
            draw_inline_segment(
              col1,
              col1 + #edit.val,
              changes == parent.a_changes and delete_inline or insert_inline,
              edit.val
            )
          elseif edit.tag == "delete" then
            deletes = deletes + 1
          end
        end
      end
    end
  end
end

function DiffView:patch_views()
  if self.views_patched then return end
  self.views_patched = true

  local parent = self

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_draw_line_text(doc_view, is_a)
    local orig = doc_view.draw_line_text
    doc_view.draw_line_text = function(self, line, x, y)
      local changes = is_a and parent.a_changes or parent.b_changes
      draw_line_text_override(parent, self, line, x, y, changes)
      local has_changes = changes[line] and changes[line].tag ~= "equal"
      if
        changes[line] and changes[line].tag ~= "equal"
        and
        (not changes[line-1] or changes[line].tag ~= changes[line-1].tag)
      then
        local ax, icon
        local pad = style.padding.x / 2
        if is_a then
          icon = ">"
          ax = self.position.x + self.size.x + pad
        else
          icon = "<"
          ax = self.position.x - pad
        end
        local color = style.text
        if parent.hovered_sync and parent.hovered_sync.is_a == is_a then
          if parent.hovered_sync.line == line then
            color = style.caret
          end
        end
        core.root_panel:defer_draw(function()
          core.push_clip_rect(parent.position.x, parent.position.y, parent.size.x, parent.size.y)
          local ay = y + (self:get_line_height() / 2) - (style.icon_font:get_height() / 2)
          renderer.draw_text(style.icon_font, icon, ax, ay, color)
          core.pop_clip_rect()
        end)
      end
      if has_changes and config.plugins.diffview.plain_text and not self.wrapped_settings then
        renderer.draw_text(
          self:get_font(),
          self.doc.lines[line],
          x, y + self:get_line_text_y_offset(),
          config.plugins.diffview.plain_text_color
        )
        return self:get_line_height()
      else
        return orig(self, line, x, y)
      end
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_get_line_screen_position(doc_view, is_a)
    doc_view.get_line_screen_position = function(self, line, col, line_end)
      if line_end == nil and self.__use_wrapped_caret_affinity then
        line_end = linewrapping.has_wrapped_line_end_affinity(self, line, col)
      end
      local x, y = self:get_content_offset()
      local lh = self:get_line_height()
      local gaps = is_a and parent.a_gaps or parent.b_gaps
      local folds = is_a and parent.diff_folds_a or parent.diff_folds_b
      local visual_row = visual_rows_before_line(self, line) + visual_row_offset_for_col(self, line, col, line_end)
      local folded_rows = folded_rows_before_line(self, folds, line)
      local gap_y = gap_rows_before_line(gaps, line) * lh
      y = y + (visual_row - folded_rows) * lh + gap_y + style.padding.y
      if col then
        return x + self:get_gutter_width() + self:get_col_x_offset(line, col, line_end), y
      else
        return x + self:get_gutter_width(), y
      end
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_resolve_screen_position(doc_view, is_a)
    local orig = doc_view.resolve_screen_position
    doc_view.resolve_screen_position = function(self, x, y)
      local lines = self.doc.lines
      local lh = self:get_line_height()
      local gaps = is_a and parent.a_gaps or parent.b_gaps
      local folds = is_a and parent.diff_folds_a or parent.diff_folds_b

      for i = 1, #lines do
        local line_x, line_y = self:get_line_screen_position(i)
        local line_h = folded_visual_line_count(self, folds, i) * lh
        local line_end_y = line_y + line_h
        local next_y
        if i < #lines then
          local _
          _, next_y = self:get_line_screen_position(i + 1)
        else
          next_y = line_end_y + trailing_gap_rows(gaps, i) * lh
        end

        if y >= line_y and y < line_end_y then
          return orig(self, x, y - gap_rows_before_line(gaps, i) * lh)
        elseif (y >= line_y or i == 1) and y < next_y then
          local col = self:get_x_offset_col(i, x - line_x)
          return i, col
        end
      end

      local last = #lines
      local line_x, _ = self:get_line_screen_position(last)
      return last, self:get_x_offset_col(last, x - line_x)
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_get_visible_line_range(doc_view, is_a)
    doc_view.get_visible_line_range = function(self)
      local _, oy, _, y2 = self:get_content_bounds()
      local lh = self:get_line_height()
      local lines = self.doc.lines
      local minline, maxline = 1, #lines
      local gaps = is_a and parent.a_gaps or parent.b_gaps
      local folds = is_a and parent.diff_folds_a or parent.diff_folds_b
      local found_min = false

      for i = 1, #lines do
        local row = visual_rows_before_line(self, i) + gap_rows_before_line(gaps, i) - folded_rows_before_line(self, folds, i)
        local start_y = style.padding.y + row * lh
        local end_y = start_y + folded_visual_line_count(self, folds, i) * lh
        if not found_min and end_y > oy then
          minline = i
          found_min = true
        end
        if found_min and start_y < y2 then
          maxline = i
        elseif found_min then
          break
        end
      end

      return minline, maxline
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_get_scrollable_size(doc_view, is_a)
    doc_view.get_scrollable_size = function(self)
      local gaps = is_a and parent.a_gaps or parent.b_gaps
      local folds = is_a and parent.diff_folds_a or parent.diff_folds_b
      local lc = effective_visual_line_count(self, gaps, folds)
      if not config.scroll_past_end then
        local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
        return self:get_line_height() * lc + style.padding.y * 2 + h_scroll
      end
      return self:get_line_height() * math.max(0, lc - 1) + self.size.y
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_scroll_to_line(doc_view, is_a)
    local orig = doc_view.scroll_to_line
    doc_view.scroll_to_line = function(self, ...)
      orig(self, ...)
      parent:sync_scroll_from(self, is_a)
    end
  end

  local function wrap_scroll_to_make_visible(doc_view, is_a)
    local orig = doc_view.scroll_to_make_visible
    doc_view.scroll_to_make_visible = function(self, ...)
      orig(self, ...)
      parent:sync_scroll_from(self, is_a)
    end
  end

  local function wrap_folded_selection(doc_view, is_a)
    local doc = doc_view.doc
    local orig_set_selection = doc.set_selection
    doc.set_selection = function(self, line1, col1, line2, col2, swap)
      line1, col1, line2, col2 = parent:clamp_selection_out_of_folds(doc_view, is_a, line1, col1, line2, col2)
      local result = orig_set_selection(self, line1, col1, line2, col2, swap)
      if not parent.syncing_diff_caret then parent:sync_caret_from(doc_view, is_a) end
      return result
    end
    local orig_set_selections = doc.set_selections
    doc.set_selections = function(self, idx, line1, col1, line2, col2, swap, rm)
      line1, col1, line2, col2 = parent:clamp_selection_out_of_folds(doc_view, is_a, line1, col1, line2, col2)
      local result = orig_set_selections(self, idx, line1, col1, line2, col2, swap, rm)
      if not parent.syncing_diff_caret then parent:sync_caret_from(doc_view, is_a) end
      return result
    end
    local orig_set_selection_list = doc.set_selection_list
    doc.set_selection_list = function(self, selections, last_selection, opts)
      if selections and #selections > 0 then
        local old_line = self:get_selection()
        local folds = is_a and parent.diff_folds_a or parent.diff_folds_b
        if folds and #folds > 0 then
          local mapped = {}
          for i = 1, #selections, 4 do
            local line1, col1 = clamp_position_out_of_fold(doc_view, folds, old_line, selections[i], selections[i + 1])
            local line2, col2 = clamp_position_out_of_fold(doc_view, folds, old_line, selections[i + 2], selections[i + 3])
            mapped[i], mapped[i + 1], mapped[i + 2], mapped[i + 3] = line1, col1, line2, col2
          end
          selections = mapped
        end
      end
      local result = orig_set_selection_list(self, selections, last_selection, opts)
      if not parent.syncing_diff_caret then parent:sync_caret_from(doc_view, is_a) end
      return result
    end
  end

  ---@param doc_view core.docview
  local function wrap_draw(doc_view, is_a)
    doc_view.draw = function(self)
      self:draw_background(style.background)
      local _, indent_size = self.doc:get_indent_info()
      self:get_font():set_tab_size(indent_size)

      local minline, maxline = self:get_visible_line_range()
      local lh = self:get_line_height()

      local gw, gpad = self:get_gutter_width()
      local folds = is_a and parent.diff_folds_a or parent.diff_folds_b
      for i = minline, maxline do
        if not is_fold_hidden_line(folds, i) then
          local _, y = self:get_line_screen_position(i)
          self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw)
        end
      end

      local pos = self.position
      -- the clip below ensure we don't write on the gutter region. On the
      -- right side it is redundant with the Node's clip.
      core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
      for i = minline, maxline do
        if not is_fold_hidden_line(folds, i) then
          local x, y = self:get_line_screen_position(i)
          local is_widget, fold = is_fold_widget_line(folds, i)
          if is_widget then
            draw_fold_widget(self, fold, x, y)
          else
            y = y + (self:draw_line_body(i, x, y) or lh)
          end
        end
      end
      self:draw_overlay()
      core.pop_clip_rect()

      self:draw_scrollbar()
    end
  end

  ---@param doc_view core.docview
  local function wrap_doc_raw_insert(doc_view)
    local orig = doc_view.doc.raw_insert
    doc_view.doc.raw_insert = function(...)
      parent:update_diff()
      return orig(...)
    end
  end

  ---@param doc_view core.docview
  local function wrap_doc_raw_remove(doc_view)
    local orig = doc_view.doc.raw_remove
    doc_view.doc.raw_remove = function(...)
      parent:update_diff()
      return orig(...)
    end
  end

  ---@param doc_view core.docview
  local function wrap_doc_transaction(doc_view)
    local orig = doc_view.doc.on_text_transaction
    doc_view.doc.on_text_transaction = function(doc, transaction)
      parent:update_diff()
      return orig(doc, transaction)
    end
  end

  ---@param changes diff.changes[]
  local function has_changes(changes)
    for _, change in ipairs(changes) do
      if change.tag ~= "equal" then
        return true
      end
    end
    return false
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_points_of_interest(doc_view, is_a)
    doc_view.get_points_of_interest = function(self)
      local changes = is_a and parent.a_changes or parent.b_changes
      if not has_changes(changes) then return {} end
      local points = {}
      local last_tag
      for line, change in ipairs(changes) do
        local tag = change and change.tag or "equal"
        if tag ~= "equal" and tag ~= last_tag then
          points[#points + 1] = {
            line = math.min(#self.doc.lines, math.max(1, line)),
            col = 1,
            line_only_navigation = true,
            scroll_to_line = true,
            kind = "diff-change",
            label = tag,
            change = change,
          }
        end
        last_tag = tag
      end
      return points
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_prev_change(doc_view, is_a)
    doc_view.prev_change = function(self)
      local changes = is_a and parent.a_changes or parent.b_changes
      if not has_changes(changes) then return end

      local line = self.doc:get_selection()
      if not changes[line] then return end
      local tag = changes[line].tag
      if line == 1 then
        line = #self.doc.lines
      else
        line = line - 1
      end

      local target = line
      local in_first_block = tag ~= "equal" and true or false
      local in_second_block = tag == "equal" and true or false

      while true do
        if not changes[target] then break end
        if in_first_block then
          if changes[target].tag ~= tag then
            in_first_block = false
            in_second_block = true
          end
        elseif in_second_block and changes[target].tag ~= "equal" then
          if changes[target-1].tag ~= changes[target].tag then
            break
          end
        end
        target = target - 1
        if target == 1 then
          if changes[target].tag == "equal" then
            target = #self.doc.lines
          else
            break
          end
        elseif target < 1 then
          target = #self.doc.lines
        end
      end

      self.doc:set_selection(target, 1, target, 1)
      self:scroll_to_line(target, false, true)
    end
  end

  ---@param doc_view core.docview
  ---@param is_a boolean
  local function wrap_next_change(doc_view, is_a)
    doc_view.next_change = function(self)
      local changes = is_a and parent.a_changes or parent.b_changes
      if not has_changes(changes) then return end

      local count_lines = #self.doc.lines
      local line = self.doc:get_selection()
      if not changes[line] then return end
      local tag = changes[line].tag
      if line == count_lines then
        line = 1
      else
        line = line + 1
      end

      local target = line
      local in_first_block = tag ~= "equal" and true or false
      local in_second_block = tag == "equal" and true or false

      while true do
        if not changes[target] then break end
        if in_first_block then
          if changes[target].tag ~= tag then
            in_first_block = false
            in_second_block = true
          end
        elseif in_second_block and changes[target].tag ~= "equal" then
          if not changes[target-1] or changes[target-1].tag ~= changes[target].tag then
            break
          end
        end
        target = target + 1
        if target == count_lines then
          if changes[target].tag == "equal" then
            target = 1
          else
            break
          end
        elseif target > count_lines then
          target = 1
        end
      end

      self.doc:set_selection(target, 1, target, 1)
      self:scroll_to_line(target, false, true)
    end
  end

  -- Apply to both views with dynamic referencing
  for _, side in ipairs {
    {view = self.doc_view_a, is_a = true},
    {view = self.doc_view_b, is_a = false}
  } do
    wrap_draw_line_text(side.view, side.is_a)
    wrap_get_line_screen_position(side.view, side.is_a)
    wrap_resolve_screen_position(side.view, side.is_a)
    wrap_get_visible_line_range(side.view, side.is_a)
    wrap_get_scrollable_size(side.view, side.is_a)
    wrap_scroll_to_line(side.view, side.is_a)
    wrap_scroll_to_make_visible(side.view, side.is_a)
    wrap_folded_selection(side.view, side.is_a)
    wrap_draw(side.view, side.is_a)
    wrap_points_of_interest(side.view, side.is_a)
    wrap_doc_raw_insert(side.view)
    wrap_doc_raw_remove(side.view)
    wrap_doc_transaction(side.view)
    wrap_prev_change(side.view, side.is_a)
    wrap_next_change(side.view, side.is_a)
  end
end

local function redraw_thumb(view_scrollbar)
  local color = { table.unpack(style.scrollbar) }
  color[4] = 100
  local x, y, w, h = view_scrollbar:get_thumb_rect()
  renderer.draw_rect(x, y, w, h, color)
end

function DiffView:draw_divider_changes()
  local left = self.doc_view_a
  local right = self.doc_view_b
  local x1 = left.position.x + left.size.x
  local x2 = right.position.x
  if x2 <= x1 then return end

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  local connector_alpha = 95
  local function draw_connector(tag, left_start_y, left_end_y, right_start_y, right_end_y)
    draw_curved_trapezium(
      x1, x2,
      left_start_y, left_end_y,
      right_start_y, right_end_y,
      alpha_color(diff_color(tag, true), connector_alpha)
    )
  end

  for _, block in ipairs(change_blocks(self.a_changes, { delete = true, modify = true })) do
    local a_start_y, a_end_y = line_range_y(left, self.diff_folds_a, block.start_line, block.end_line)
    if block.tag == "delete" then
      draw_connector(block.tag, a_start_y, a_end_y, a_start_y, a_start_y)
      draw_gap_marker(right, a_start_y, gap_marker_color(block.tag))
    else
      local start_row = effective_row_before_line(left, self.a_gaps, self.diff_folds_a, block.start_line)
      local end_row = effective_row_before_line(left, self.a_gaps, self.diff_folds_a, block.end_line)
      local b_start_line = line_for_effective_row(right, self.b_gaps, self.diff_folds_b, start_row)
      local b_end_line = line_for_effective_row(right, self.b_gaps, self.diff_folds_b, end_row)
      local b_start_y, b_end_y = line_range_y(right, self.diff_folds_b, b_start_line, b_end_line)
      draw_connector(block.tag, a_start_y, a_end_y, b_start_y, b_end_y)
    end
  end

  for _, block in ipairs(change_blocks(self.b_changes, { insert = true })) do
    local b_start_y, b_end_y = line_range_y(right, self.diff_folds_b, block.start_line, block.end_line)
    draw_connector(block.tag, b_start_y, b_start_y, b_start_y, b_end_y)
    draw_gap_marker(left, b_start_y, diff_color(block.tag))
  end

  core.pop_clip_rect()
end

function DiffView:draw_scrollbar()
  DiffView.super.draw_scrollbar(self)

  for _, side in ipairs {
    {view = self.doc_view_a, changes = self.a_changes, gaps = self.a_gaps, folds = self.diff_folds_a},
    {view = self.doc_view_b, changes = self.b_changes, gaps = self.b_gaps, folds = self.diff_folds_b},
  } do
    local view = side.view
    local changes = side.changes
    local scrollbar = view.v_scrollbar

    local lh = view:get_line_height()
    local full_h = view:get_scrollable_size()
    local visible_h = view.size.y
    local x, y, w, h = scrollbar:get_track_rect()

    local scroll_range = math.max(1, full_h - visible_h)

    -- Step 1: group consecutive lines of same change tag
    local change_lines = {}
    for line, change in pairs(changes) do
      change_lines[#change_lines+1] = { line = line, tag = change.tag }
    end
    table.sort(change_lines, function(a, b) return a.line < b.line end)

    local i = 1
    while i <= #change_lines do
      local tag = change_lines[i].tag
      local start_line = change_lines[i].line
      local end_line = start_line

      -- Group consecutive lines with same tag
      while i + 1 <= #change_lines and
            change_lines[i+1].tag == tag and
            change_lines[i+1].line == end_line + 1 do
        i = i + 1
        end_line = change_lines[i].line
      end

      -- Draw block for [start_line, end_line]
      local color =
        tag == "insert" and style.diff_insert
        or tag == "delete" and style.diff_delete
        or tag == "modify" and style.diff_modify

      if color then
        local start_row = visual_rows_before_line(view, start_line)
          + gap_rows_before_line(side.gaps, start_line)
          - folded_rows_before_line(view, side.folds, start_line)
        local end_row = visual_rows_before_line(view, end_line)
          + folded_visual_line_count(view, side.folds, end_line)
          + gap_rows_before_line(side.gaps, end_line)
          - folded_rows_before_line(view, side.folds, end_line)
        local scroll_y_start = start_row * lh
        local scroll_y_end = end_row * lh
        local ratio_start = scroll_y_start / scroll_range
        local ratio_end = scroll_y_end / scroll_range
        local marker_y = y + ratio_start * h
        local marker_h = math.max(2, (ratio_end - ratio_start) * h) * SCALE

        renderer.draw_rect(x, marker_y, w, marker_h, color)

        local sx, _, sw = self.v_scrollbar:get_track_rect()
        renderer.draw_rect(sx, marker_y, sw, marker_h, color)
      end

      i = i + 1
    end
  end

  redraw_thumb(self.doc_view_a.v_scrollbar)
  redraw_thumb(self.doc_view_b.v_scrollbar)
  redraw_thumb(self.v_scrollbar)
end

function DiffView:update()
  DiffView.super.update(self)
  local _, _, scroll_w, _ = self.v_scrollbar:_get_track_rect_normal()

  self.doc_view_a.position.x = self.position.x
  self.doc_view_a.position.y = self.position.y
  self.doc_view_a.size.x = (self.size.x / 2) - scroll_w - 20 * SCALE
  self.doc_view_a.size.y = self.size.y

  self.doc_view_b.position.x = (self.position.x + self.size.x / 2) - scroll_w + 20 * SCALE
  self.doc_view_b.position.y = self.position.y
  self.doc_view_b.size.x = (self.size.x / 2) - scroll_w - 20 * SCALE
  self.doc_view_b.size.y = self.size.y

  call_docview_method(self.doc_view_a, self.doc_view_a.update)
  call_docview_method(self.doc_view_b, self.doc_view_b.update)
end

function DiffView:draw()
  DiffView.super.draw(self)
  self:draw_background(style.background)
  call_docview_method(self.doc_view_a, self.doc_view_a.draw)
  call_docview_method(self.doc_view_b, self.doc_view_b.draw)
  self:draw_divider_changes()
  self:draw_scrollbar()
end


-- Helper functions to start file to file or string to string diff viewer.
local function start_compare()
  if not element_a or not element_b then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a, element_b, DiffView.type.FILE_FILE)
  core.root_panel:get_active_node_default():add_view(view)
  core.set_active_view(view)
  element_a = nil
  element_b = nil
end

local function start_compare_string()
  if not element_a_text or not element_b_text then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a_text, element_b_text, DiffView.type.STRING_STRING)
  core.root_panel:get_active_node_default():add_view(view)
  core.set_active_view(view)
  element_a_text = nil
  element_b_text = nil
end


-- Register file compare commands
command.add("core.docview", {
  ["diff-view:select-file-for-compare"] = function(dv)
    if dv.doc and dv.doc.abs_filename then
      element_a = dv.doc.abs_filename
    end
  end
})

command.add(
  function()
    return element_a and core.active_view and core.active_view:is(DocView),
    core.active_view
  end, {
  ["diff-view:compare-file-with-selected"] = function(dv)
    if dv.doc and dv.doc.abs_filename then
      element_b = dv.doc.abs_filename
    end
    start_compare()
  end
})

command.add(nil, {
  ["diff-view:start-files-comparison"] = function()
    command.perform("core:open-file", "Select File A", function(file_a)
      element_a = file_a
      command.perform("core:open-file", "Select File B", function(file_b)
        element_b = file_b
        start_compare()
      end)
    end)
  end
})

command.add(nil, {
  ["diff-view:start-strings-comparison"] = function()
    element_a_text = ""
    element_b_text = ""
    start_compare_string()
  end
})


-- Register changes navigation and sync commands
command.add(
  function()
    return core.active_view
        and core.active_view:is(DocView)
        and core.active_view.diff_view_parent,
      core.active_view
  end, {
  ["diff-view:prev-change"] = function(dv)
    require("core.poi").navigate(dv, -1)
  end,

  ["diff-view:next-change"] = function(dv)
    require("core.poi").navigate(dv, 1)
  end,

  ["diff-view:sync-change"] = function(dv)
    dv.diff_view_parent:sync_selected()
  end
})

command.add(function()
  local view = core.active_view
  if view and view.diff_view_parent then return true, view.diff_view_parent end
  if view and view.is and view:is(DiffView) then return true, view end
  return false
end, {
  ["diff-view:toggle-folding"] = function(view)
    view:toggle_folding()
  end
})

keymap.add({
  ["ctrl+alt+,"] = "poi:previous",
  ["ctrl+alt+."] = "poi:next",
  ["ctrl+return"] = "diff-view:sync-change",
  ["ctrl+r"] = "diff-view:toggle-folding",
})


-- Register text compare commands
local function text_select_compare_predicate()
  local is_docview = core.active_view
    and core.active_view:is(DocView)
    and core.active_view.doc
  local has_selection = is_docview and core.active_view.doc:has_any_selection()
  return has_selection, has_selection and core.active_view.doc
end

local function text_compare_with_predicate()
  local is_docview = (element_a_text and core.active_view)
    and (core.active_view:is(DocView) and core.active_view.doc)
  local has_selection = is_docview and core.active_view.doc:has_any_selection()
  return has_selection, has_selection and core.active_view.doc
end

command.add(text_select_compare_predicate, {
  ["diff-view:select-text-for-compare"] = function(doc)
    element_a_text = doc:get_selection_text()
  end
})

command.add(text_compare_with_predicate, {
  ["diff-view:compare-text-with-selected"] = function(doc)
    element_b_text = doc:get_selection_text()
    start_compare_string()
  end
})


-- Register context menu items
core.add_thread(function()
  if config.plugins.cotextmenu then
    local contextmenu = require "plugins.contextmenu"

    contextmenu:register(text_select_compare_predicate, {
      contextmenu.DIVIDER,
      {
        text = "Select Text for Compare",
        command = "diff-view:select-text-for-compare"
      }
    })

    contextmenu:register(text_compare_with_predicate, {
      {
        text = "Compare Text with Selected",
        command = "diff-view:compare-text-with-selected"
      }
    })
  end
end)



---Functionality to view the textual differences of two elements.
---@class plugins.diffview
local diffview = {
  ---The differences viewer exposed for extensiblity.
  ---@type plugins.diffview.view
  Viewer = DiffView
}

---Helper differences view to rootpanel add.
---@param view plugins.diffview.view
local function compare_add_to_root_node(view)
  core.root_panel:get_active_node_default():add_view(view)
  core.set_active_view(view)
end

---Helper differences starter.
---@param a string
---@param b string
---@param ct? plugins.diffview.view.type
---@param names? plugins.diffview.view.string_names
---@param noshow? boolean
---@return plugins.diffview.view
local function compare_start(a, b, ct, names, noshow)
  local view = DiffView(a, b, ct, names)
  if not noshow then
    compare_add_to_root_node(view)
  end
  return view
end

---Create a file to file diff viewer.
---@param a string
---@param b string
---@param noshow? boolean If true doesn't adds to the rootpanel
---@return plugins.diffview.view
function diffview.file_to_file(a, b, noshow)
  return compare_start(a, b, DiffView.type.FILE_FILE, nil, noshow)
end

---Create a string to string diff viewer.
---@param a string
---@param b string
---@param a_name? string
---@param b_name? string
---@param noshow? boolean If true doesn't adds to the rootpanel
---@return plugins.diffview.view
function diffview.string_to_string(a, b, a_name, b_name, noshow)
  return compare_start(
    a, b, DiffView.type.STRING_STRING, {a = a_name, b = b_name}, noshow
  )
end

---Create a file to string diff viewer.
---@param a string
---@param b string
---@param b_name? string
---@param noshow? boolean If true doesn't adds to the rootpanel
---@return plugins.diffview.view
function diffview.file_to_string(a, b, b_name, noshow)
  return compare_start(a, b, DiffView.type.FILE_STRING, {b = b_name}, noshow)
end

---Create a string to file diff viewer.
---@param a string
---@param b string
---@param a_name? string
---@param noshow? boolean If true doesn't adds to the rootpanel
---@return plugins.diffview.view
function diffview.string_to_file(a, b, a_name, noshow)
  return compare_start(a, b, DiffView.type.STRING_FILE, {a = a_name}, noshow)
end


return diffview
