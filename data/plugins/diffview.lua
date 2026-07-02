-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"
local View = require "core.view"
local diff_model = require "plugins.diff.model"

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

local function content_text(text, opts)
  opts = opts or {}
  return { kind = "text", text = text or "", name = opts.name, editable = opts.editable, owns_doc = true }
end

local function content_file(path, opts)
  opts = opts or {}
  return { kind = "file", filename = path, name = opts.name or common.basename(path), editable = opts.editable, owns_doc = false }
end

local function content_document(doc, opts)
  opts = opts or {}
  return { kind = "document", doc = doc, name = opts.name, editable = opts.editable, owns_doc = opts.owns_doc == true }
end

local function content_empty(opts)
  opts = opts or {}
  return { kind = "empty", name = opts.name, editable = opts.editable ~= false, owns_doc = true }
end

local function legacy_request(a, b, compare_type, names)
  names = names or {}
  compare_type = compare_type or DiffView.type.STRING_STRING
  local left, right
  if compare_type == DiffView.type.FILE_FILE then
    left, right = content_file(a), content_file(b)
  elseif compare_type == DiffView.type.STRING_STRING then
    left, right = content_text(a, { name = names.a }), content_text(b, { name = names.b })
  elseif compare_type == DiffView.type.STRING_FILE then
    left, right = content_text(a, { name = names.a }), content_file(b)
  elseif compare_type == DiffView.type.FILE_STRING then
    left, right = content_file(a), content_text(b, { name = names.b })
  end
  return {
    title = compare_type == DiffView.type.STRING_STRING and "Text Diff View" or nil,
    kind = compare_type == DiffView.type.STRING_STRING and "text" or "file",
    compare_type = compare_type,
    contents = { left = left, right = right },
    content_titles = { left = names.a, right = names.b },
    editable_policy = "content",
  }
end

local function doc_for_content(content)
  if content.kind == "document" then return assert(content.doc), content.owns_doc == true end
  if content.kind == "file" then return Doc(content.name or common.basename(content.filename), content.filename), false end
  local doc = Doc(content.name, content.name, true)
  local text = content.kind == "empty" and "" or (content.text or "")
  if text ~= "" then doc:insert(1, 1, text) doc:clear_undo_redo() end
  return doc, true
end

---Constructor
---@param a string|table
---@param b string?
---@param compare_type? plugins.diffview.view.type
---@param names? plugins.diffview.view.string_names
function DiffView:new(a, b, compare_type, names)
  DiffView.super.new(self)

  self.scrollable = true
  self.request = type(a) == "table" and a.contents and a or legacy_request(a, b, compare_type, names)
  self.compare_type = self.request.compare_type or compare_type or DiffView.type.STRING_STRING
  self.hovered_sync = nil
  self.skip_update_diff = false
  self.diff_generation = 0
  self.disposed = false

  local doc_a, owns_a = doc_for_content(self.request.contents.left)
  local doc_b, owns_b = doc_for_content(self.request.contents.right)
  self.owned_docs = { [doc_a] = owns_a, [doc_b] = owns_b }

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

  self:install_view_integrations()
  self:update_diff()

  self.v_scrollbar.contracted_size = style.expanded_scrollbar_size * 2
  self.v_scrollbar.expanded_size = style.expanded_scrollbar_size * 2
end

function DiffView:get_focus_view()
  return self.doc_view_a
end

function DiffView:get_name()
  if self.request and self.request.title then return self.request.title end
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

  self.diff_generation = (self.diff_generation or 0) + 1
  local generation = self.diff_generation
  local idx = core.add_thread(function()
    local computing_start = system.get_time()
    local model = diff_model.compute(self.doc_view_a.doc.lines, self.doc_view_b.doc.lines, {
      should_yield = function()
        if system.get_time() - computing_start >= 0.5 then
          computing_start = system.get_time()
          return true
        end
        return false
      end,
    })
    if self.disposed or generation ~= self.diff_generation then return end

    self.diff_model = model
    self.a_gaps = model.a_gaps
    self.b_gaps = model.b_gaps
    self:install_core_gap_rows()
    self.a_changes = model.a_changes
    self.b_changes = model.b_changes
    self.diff_equal_blocks = model.equal_blocks
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
  if doc_view.has_composed_visual_rows and doc_view:has_composed_visual_rows() then
    return math.max(0, doc_view:get_visual_row(line, 1) - 1)
  end
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
  return visual_line_count(doc_view, line)
end

local function effective_row_before_line(doc_view, gaps, folds, line)
  return visual_rows_before_line(doc_view, line)
end

local function effective_visual_line_count(doc_view, gaps, folds)
  return doc_view:get_scrollable_line_count()
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

local function install_core_gap_rows_for_docview(doc_view, gaps)
  if not doc_view or not doc_view.add_visual_row_provider then return end
  local before, any = {}, false
  for line, gap in pairs(gaps or {}) do
    local cumulative = math.max(0, math.floor(tonumber(gap[2]) or 0))
    if cumulative > 0 then before[line], any = cumulative, true end
  end
  if any then
    doc_view:add_visual_row_provider("diff-gaps", { before = before }, { priority = 50 })
  else
    doc_view:remove_visual_row_provider("diff-gaps")
  end
end

function DiffView:install_core_gap_rows()
  install_core_gap_rows_for_docview(self.doc_view_a, self.a_gaps)
  install_core_gap_rows_for_docview(self.doc_view_b, self.b_gaps)
end

local function clear_core_diff_folds(doc_view)
  if not doc_view or not doc_view.fold_regions then return end
  for i = #doc_view.fold_regions, 1, -1 do
    local fold = doc_view.fold_regions[i]
    if fold.kind == "diff-view" then
      doc_view:remove_fold_region(fold, "diff-rebuild")
    end
  end
end

local function install_core_diff_folds(doc_view, folds, side)
  if not doc_view or not doc_view.add_fold_region then return end
  for _, fold in ipairs(folds or {}) do
    local core_fold = doc_view:add_fold_region {
      id = "diff-" .. side .. "-" .. tostring(fold.index),
      line1 = fold.hidden_start,
      col1 = 1,
      line2 = fold.hidden_end,
      col2 = #(doc_view.doc.lines[fold.hidden_end] or "") + 1,
      kind = "diff-view",
      metadata = { diff_fold = fold, side = side },
      placeholder = string.format("⋯ %d unchanged lines folded ⋯", fold.hidden_count),
    }
    fold.core_fold = core_fold
  end
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
  self.rebuilding_diff_folds = true
  clear_core_diff_folds(self.doc_view_a)
  clear_core_diff_folds(self.doc_view_b)
  self.diff_folds_a = build_diff_folds(self.diff_equal_blocks or {}, "a", opts, expanded)
  self.diff_folds_b = build_diff_folds(self.diff_equal_blocks or {}, "b", opts, expanded)
  install_core_diff_folds(self.doc_view_a, self.diff_folds_a, "a")
  install_core_diff_folds(self.doc_view_b, self.diff_folds_b, "b")
  self.rebuilding_diff_folds = false
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

function DiffView:on_core_fold_event(is_a, event, core_fold, reason)
  if self.rebuilding_diff_folds or self.disposed then return end
  if event ~= "expand" then return end
  if not core_fold or core_fold.kind ~= "diff-view" then return end
  local fold = core_fold.metadata and core_fold.metadata.diff_fold
  if fold then self:expand_fold(fold) end
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

local function diff_has_changes(changes)
  for _, change in ipairs(changes or {}) do
    if change.tag ~= "equal" then return true end
  end
  return false
end

function DiffView:diff_points_of_interest(is_a)
  local changes = is_a and self.a_changes or self.b_changes
  if not diff_has_changes(changes) then return {} end
  local points = {}
  local last_tag
  for line, change in ipairs(changes) do
    local tag = change and change.tag or "equal"
    if tag ~= "equal" and tag ~= last_tag then
      points[#points + 1] = {
        line = line,
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

local function diff_decoration_provider(parent, is_a)
  return {
    priority = 50,
    line_background = function(_, view, line)
      local changes = is_a and parent.a_changes or parent.b_changes
      local change = changes[line]
      if not change or change.tag == "equal" then return nil end
      if change.tag == "delete" then
        local color = style.diff_delete_background
        if config.plugins.diffview.plain_text then color = alpha_color(color, 128) end
        return color
      elseif change.tag == "insert" then
        local color = style.diff_insert_background
        if config.plugins.diffview.plain_text then color = alpha_color(color, 128) end
        return color
      elseif change.tag == "modify" then
        local color = is_a and style.diff_delete_background or style.diff_insert_background
        if config.plugins.diffview.plain_text then color = alpha_color(color, 128) end
        return color
      end
    end,
    inline_ranges = function(_, view, line)
      local changes = is_a and parent.a_changes or parent.b_changes
      local change = changes[line]
      if not change or change.tag ~= "modify" or not change.changes then return nil end
      local ranges = {}
      local deletes = 0
      local color = is_a and style.diff_delete_inline or style.diff_insert_inline
      if config.plugins.diffview.plain_text then color = is_a and style.diff_delete or style.diff_insert end
      for i, edit in ipairs(change.changes) do
        if edit.tag == "insert" then
          local col1 = i - deletes
          ranges[#ranges + 1] = { col1 = col1, col2 = col1 + #edit.val, color = color }
        elseif edit.tag == "delete" then
          deletes = deletes + 1
        end
      end
      return ranges
    end,
    text_color = function(_, view, line)
      local changes = is_a and parent.a_changes or parent.b_changes
      local change = changes[line]
      if change and change.tag ~= "equal" and config.plugins.diffview.plain_text then
        return config.plugins.diffview.plain_text_color
      end
    end,
  }
end

function DiffView:install_view_integrations()
  if self.views_patched then return end
  self.views_patched = true

  for _, side in ipairs {
    { view = self.doc_view_a, is_a = true, id = "a" },
    { view = self.doc_view_b, is_a = false, id = "b" },
  } do
    local provider_id = "diff-view"
    side.view:add_decoration_provider(provider_id, diff_decoration_provider(self, side.is_a), { priority = 50 })
    side.view:add_poi_provider(provider_id, {
      priority = 50,
      points_of_interest = function()
        return self:diff_points_of_interest(side.is_a)
      end,
    }, { priority = 50 })
    side.view:add_selection_listener(provider_id, function(view)
      if not self.syncing_diff_caret then self:sync_caret_from(view, side.is_a) end
    end)
    side.view:add_scroll_listener(provider_id, function(view)
      self:sync_scroll_from(view, side.is_a)
    end)
    side.view:add_fold_listener(provider_id, function(view, event, fold, reason)
      self:on_core_fold_event(side.is_a, event, fold, reason)
    end)
    side.view.doc:add_text_change_listener("diff-view-" .. side.id .. "-" .. tostring(self), {
      after_change = function()
        self:update_diff()
      end,
    })
  end
end

function DiffView:dispose_integrations()
  if self.disposed then return end
  self.disposed = true
  for _, side in ipairs {
    { view = self.doc_view_a, id = "a" },
    { view = self.doc_view_b, id = "b" },
  } do
    side.view:remove_decoration_provider("diff-view")
    side.view:remove_poi_provider("diff-view")
    side.view:remove_selection_listener("diff-view")
    side.view:remove_scroll_listener("diff-view")
    side.view:remove_fold_listener("diff-view")
    side.view:remove_visual_row_provider("diff-gaps")
    side.view.doc:remove_text_change_listener("diff-view-" .. side.id .. "-" .. tostring(self))
  end
  self.diff_generation = (self.diff_generation or 0) + 1
end

function DiffView:try_close(do_close)
  self:dispose_integrations()
  return DiffView.super.try_close(self, do_close)
end

local function redraw_thumb(view_scrollbar)
  view_scrollbar:draw_thumb()
end

function DiffView:draw_divider_sync_actions()
  local left = self.doc_view_a
  local right = self.doc_view_b
  local x1 = left.position.x + left.size.x
  local x2 = right.position.x
  if x2 <= x1 then return end
  local pad = style.padding.x / 2
  local function draw_action(is_a, line, y)
    local icon = is_a and ">" or "<"
    local ax = is_a and (x1 + pad) or (x2 - pad)
    local color = style.text
    if self.hovered_sync and self.hovered_sync.is_a == is_a and self.hovered_sync.line == line then
      color = style.caret
    end
    local ay = y + (left:get_line_height() / 2) - (style.icon_font:get_height() / 2)
    renderer.draw_text(style.icon_font, icon, ax, ay, color)
  end
  for _, block in ipairs(change_blocks(self.a_changes)) do
    local _, y = left:get_line_screen_position(block.start_line, 1)
    draw_action(true, block.start_line, y)
  end
  for _, block in ipairs(change_blocks(self.b_changes)) do
    local _, y = right:get_line_screen_position(block.start_line, 1)
    draw_action(false, block.start_line, y)
  end
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

  self:draw_divider_sync_actions()
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
        local end_row = visual_rows_before_line(view, end_line)
          + folded_visual_line_count(view, side.folds, end_line)
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


local function navigate_diff_change(dv, direction)
  local poi = require "core.poi"
  local points = poi.points_for_view(dv, { source = "diff-view" }) or {}
  if #points == 0 then return poi.navigate(dv, direction) end
  direction = direction and direction < 0 and -1 or 1
  return with_docview_selection(dv, function()
    local line = dv.doc:get_selection()
    local selected
    if direction > 0 then
      for _, point in ipairs(points) do
        if point.line > line then selected = point; break end
      end
      selected = selected or points[1]
    else
      for i = #points, 1, -1 do
        if points[i].line < line then selected = points[i]; break end
      end
      selected = selected or points[#points]
    end
    dv.doc:set_selection(selected.line, selected.col or 1, selected.line, selected.col or 1)
    if selected.scroll_to_line and dv.scroll_to_line then
      dv:scroll_to_line(selected.line, false, true)
    elseif dv.scroll_to_make_visible then
      dv:scroll_to_make_visible(selected.line, selected.col or 1)
    end
    return selected
  end)
end

-- Register changes navigation and sync commands
command.add(
  function()
    return core.active_view
        and core.active_view:is(DocView)
        and core.active_view.diff_view_parent,
      core.active_view
  end, {
  ["diff-view:prev-change"] = function(dv)
    return navigate_diff_change(dv, -1)
  end,

  ["diff-view:next-change"] = function(dv)
    return navigate_diff_change(dv, 1)
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



local compare_add_to_root_node

---Functionality to view the textual differences of two elements.
---@class plugins.diffview
local diffview = {
  ---The differences viewer exposed for extensiblity.
  ---@type plugins.diffview.view
  Viewer = DiffView,
  content = {},
}

diffview.content.text = content_text
diffview.content.file = content_file
diffview.content.document = content_document
diffview.content.empty = content_empty

function diffview.open(request, noshow)
  local view = DiffView(request)
  if not noshow then
    compare_add_to_root_node(view)
  end
  return view
end

---Helper differences view to rootpanel add.
---@param view plugins.diffview.view
compare_add_to_root_node = function(view)
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
  local view = DiffView(legacy_request(a, b, ct, names))
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
