-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local MouseRouter = require "core.mouse_router"
local style = require "core.style"
local TextView = require "core.textview"
local Editor = require "core.editor"
local Buffer = require "core.buffer"
local View = require "core.view"
local view_icons = require "core.view_icons"
local panes = require "core.panes"
local diff_model = require "plugins.diff.model"
local FragmentBuffer = require "plugins.diff.fragment_buffer"

---Configuration options for `diffview` plugin.
---@class config.plugins.diffview
---Logs the amount of time taken to recompute differences.
---@field log_times boolean
---The whitespace comparison policy used by the Diff View.
---@field whitespace_mode "none"|"trim"|"ignore"
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
      label = "Whitespace Comparison",
      description = "Choose whether the Diff View compares line-edge or all whitespace. Added or removed blank lines still count as changes.",
      path = "whitespace_mode",
      type = "selection",
      default = config.plugins.diffview.whitespace_mode,
      values = {
        { "None", "none" },
        { "Trim Whitespace", "trim" },
        { "Ignore All Whitespace", "ignore" },
      },
    },
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
      default = config.plugins.diffview.fold_unchanged_by_default
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

local function with_textview_selection(view, fn, ...)
  if view and view.with_selection_state then
    return view:with_selection_state(fn, ...)
  end
  return fn(...)
end

local function call_textview_method(view, method, ...)
  return with_textview_selection(view, method, view, ...)
end

local function perf_begin(name)
  if not core.perf_frame_stats then return end
  local perf = package.loaded["core.perf"]
  local scope = core.perf_draw_scope_active and perf and perf.scope_begin(name, true)
  return system.get_time(), scope
end

local function perf_end(name, started, scope)
  if not started then return end
  local perf = package.loaded["core.perf"]
  if not perf then return end
  if scope then perf.scope_end(scope) end
  perf.frame_add(name .. "_ms", (system.get_time() - started) * 1000)
end

-- Keep selection binding outside the method scope so its cost stays visible.
local function profile_textview_method(view, method, name)
  if not core.perf_frame_stats then
    return call_textview_method(view, method)
  end
  local started, scope = perf_begin(name)
  with_textview_selection(view, function()
    local body_started, body_scope = perf_begin(name .. "_body")
    method(view)
    perf_end(name .. "_body", body_started, body_scope)
  end)
  perf_end(name, started, scope)
end

local is_fold_widget_line

---@class plugins.diffview.view : core.view
---@field super core.view
---@field buffer_view_a core.textview
---@field buffer_view_b core.textview
---@field a_changes diff.changes[]
---@field b_changes diff.changes[]
---@field a_gaps table<integer,table<integer,integer>>
---@field b_gaps table<integer,table<integer,integer>>
---@field compare_type plugins.diffview.view.type
---@overload fun(a:string,b:string,ct?:plugins.diffview.view.type,names?:plugins.diffview.view.string_names):plugins.diffview.view
local DiffView = View:extend()
DiffView._module_name = "plugins.diffview"
DiffView.view_icon = view_icons.register("diff", view_icons.ui("s"))
local MutableDiffRequestChain
local DiffRequestController
local diff_status

---@enum plugins.diffview.view.type
DiffView.type = {
  STRING_FILE = 1,
  FILE_STRING = 2,
  FILE_FILE = 3,
  STRING_STRING = 4
}

---Names used when a or b are not files.
---@class plugins.diffview.view.string_names
---@field a? string
---@field b? string

local function content_text(text, opts)
  opts = opts or {}
  return {
    kind = "text", text = text or "", name = opts.name,
    editable = opts.editable, owns_buffer = true,
    read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint,
    source_path = opts.source_path, source_line = opts.source_line,
  }
end

local function content_file(path, opts)
  opts = opts or {}
  return {
    kind = "file", filename = path,
    name = opts.name or (path and common.basename(path) or nil),
    editable = opts.editable, owns_buffer = false,
    read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint,
    source_path = opts.source_path,
  }
end

local function content_buffer(buffer, opts)
  opts = opts or {}
  return {
    kind = "buffer", buffer = buffer, name = opts.name,
    editable = opts.editable, owns_buffer = opts.owns_buffer == true,
    read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint,
    source_path = opts.source_path,
  }
end

local function content_fragment(buffer, line1, col1, line2, col2, opts)
  opts = opts or {}
  return {
    kind = "fragment", buffer = buffer,
    line1 = line1, col1 = col1, line2 = line2, col2 = col2,
    name = opts.name, editable = opts.editable, owns_buffer = true,
    read_only_reason = opts.read_only_reason,
    source_path = opts.source_path or buffer.abs_filename,
  }
end

local function content_blank(opts)
  opts = opts or {}
  return {
    kind = "blank", text = opts.text or "", name = opts.name,
    editable = opts.editable ~= false, owns_buffer = true,
    read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint,
    untitled_id = opts.untitled_id,
  }
end

local function content_empty(opts)
  local content = content_blank(opts)
  content.kind = "empty"
  return content
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
    contents = { left, right },
    content_titles = { names.a, names.b },
    editable_policy = "content",
  }
end

local function normalize_side_table(value, field)
  if type(value) ~= "table" then return value end
  if value[1] or value[2] or value[3] then return value end
  if value.left or value.right or value.base then
    return { value.left, value.right, value.base }
  end
  return value
end

local function normalize_request(request)
  if type(request) ~= "table" then
    return nil, "diff request must be a table"
  end
  local normalized = common.merge({}, request)
  normalized.contents = normalize_side_table(request.contents, "contents")
  normalized.content_titles = normalize_side_table(request.content_titles, "content_titles")
  normalized.user_data = normalized.user_data or normalized.metadata or {}
  normalized.metadata = nil
  normalized.editable_policy = normalized.editable_policy or "content"
  if normalized.kind == nil then normalized.kind = "text" end
  return normalized
end

local function validate_content(content, index)
  if type(content) ~= "table" then
    return nil, string.format("diff content %d must be a table", index)
  end
  if content.editable ~= nil and type(content.editable) ~= "boolean" then
    return nil, string.format("diff content %d editable must be a boolean", index)
  end
  if content.source_path ~= nil and (type(content.source_path) ~= "string" or content.source_path == "") then
    return nil, string.format("diff content %d source_path must be a non-empty string", index)
  end
  local kind = content.kind
  if kind == "text" then
    if content.text ~= nil and type(content.text) ~= "string" then
      return nil, string.format("diff content %d text must be a string", index)
    end
  elseif kind == "blank" or kind == "empty" then
    -- valid mutable blank-buffer content
  elseif kind == "file" then
    if type(content.filename) ~= "string" or content.filename == "" then
      return nil, string.format("diff content %d file content requires a filename", index)
    end
  elseif kind == "buffer" then
    if not content.buffer then
      return nil, string.format("diff content %d buffer content requires a buffer", index)
    end
    if not (content.buffer.is and content.buffer:is(Buffer)) then
      return nil, string.format("diff content %d buffer content requires a Buffer", index)
    end
  elseif kind == "fragment" then
    if not content.buffer or not (content.buffer.is and content.buffer:is(Buffer)) then
      return nil, string.format("diff content %d fragment content requires a Buffer", index)
    end
    for _, field in ipairs { "line1", "col1", "line2", "col2" } do
      if type(content[field]) ~= "number" then
        return nil, string.format("diff content %d fragment content requires %s", index, field)
      end
    end
  else
    return nil, string.format("unknown diff content kind '%s'", tostring(kind))
  end
  return true
end

local function validate_request(request)
  request = normalize_request(request)
  if not request then return nil, "diff request must be a table" end
  if type(request.contents) ~= "table" then
    return nil, "diff request requires contents"
  end
  if request.content_titles ~= nil and type(request.content_titles) ~= "table" then
    return nil, "diff request content_titles must be a table"
  end
  if request.content_titles then
    for i = 1, 3 do
      local title = request.content_titles[i]
      if title ~= nil and type(title) ~= "string" then
        return nil, string.format("diff request content title %d must be a string", i)
      end
    end
  end
  if request.editable_policy ~= "read-only" and request.editable_policy ~= "content" and request.editable_policy ~= "editable" then
    return nil, "diff request editable_policy must be read-only, content, or editable"
  end
  local count = #request.contents
  if count ~= 2 then
    if count == 3 then return nil, "three-way diff viewer is not implemented" end
    return nil, "diff request requires exactly two contents"
  end
  for i = 1, count do
    local ok, err = validate_content(request.contents[i], i)
    if not ok then return nil, err end
  end
  if request.contents[1].kind == "buffer" and request.contents[2].kind == "buffer"
      and request.contents[1].buffer == request.contents[2].buffer then
    return nil, "diff request cannot use the same buffer on both sides"
  end
  local function comparable_content_path(content)
    local path
    if content.kind == "file" then
      path = content.filename
    elseif content.kind == "buffer" or content.kind == "fragment" then
      path = content.buffer.abs_filename
    end
    if path and not common.is_absolute_path(path) then
      local ok, abs = pcall(core.project_absolute_path, path)
      if ok and abs then path = abs end
    end
    return path
  end
  local function content_path(content)
    return comparable_content_path(content)
  end
  local path1, path2 = content_path(request.contents[1]), content_path(request.contents[2])
  if path1 and path2 and common.path_equals(path1, path2) then
    return nil, "diff request cannot use the same file on both sides"
  end
  return request
end

local function call_assignment_hook(owner, method, ...)
  local fn = owner and owner[method]
  if not fn then return end
  local ok, err = pcall(fn, owner, ...)
  if not ok then core.log_quiet("Diff View %s hook failed: %s", method, tostring(err)) end
end

local function title_for_content(content, title)
  if title and title ~= "" then return title end
  if content.name and content.name ~= "" then return content.name end
  if content.kind == "file" then return common.basename(content.filename) end
  return nil
end

local function content_editable(request, content)
  local policy = request.editable_policy or "content"
  if policy == "read-only" then return false end
  if policy == "editable" then return content.editable ~= false end
  return content.editable ~= false
end

local function content_read_only_reason(content)
  return content.read_only_reason or "This Diff View side is read-only"
end

local function set_buffer_text(buffer, text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines, start = {}, 1
  while start <= #text do
    local newline = text:find("\n", start, true)
    if newline then
      lines[#lines + 1] = text:sub(start, newline)
      start = newline + 1
    else
      lines[#lines + 1] = text:sub(start) .. "\n"
      break
    end
  end
  if #lines == 0 then lines[1] = "\n" end
  buffer.lines = lines
  buffer:set_selection(1, 1, 1, 1)
end

local function buffer_needs_dirty_prompt(buffer)
  if not (buffer and buffer.is_dirty and buffer:is_dirty()) then return false end
  if buffer.intellij_untitled and table.concat(buffer.lines or {}):gsub("\n$", "") == "" then return false end
  return true
end

local function prompt_dirty_buffers(buffers, callback)
  local dirty = {}
  for _, buffer in ipairs(buffers or {}) do
    if buffer_needs_dirty_prompt(buffer) then dirty[#dirty + 1] = buffer end
  end
  if #dirty == 0 then callback(true); return end
  local names = {}
  for _, buffer in ipairs(dirty) do names[#names + 1] = buffer:get_name() end
  core.nag_view:show(
    "Unsaved Diff Content",
    string.format("Discard unsaved diff content in %s?", table.concat(names, ", ")),
    {
      { text = "Discard Changes" },
      { text = "Cancel", default_no = true },
    },
    function(item)
      callback(item and item.text == "Discard Changes")
    end
  )
  core.log_quiet("Diff View close/replacement waiting for dirty owned buffers: %s", table.concat(names, ", "))
end

local function buffer_for_content(content, title)
  local buffer_name = title_for_content(content, title)
  if content.kind == "buffer" then return assert(content.buffer), content.owns_buffer == true end
  if content.kind == "file" then return core.open_buffer(content.filename), false end
  if content.kind == "fragment" then
    return FragmentBuffer.new(
      content.buffer, content.line1, content.col1, content.line2, content.col2,
      { name = buffer_name }
    ), true
  end
  local buffer = Buffer(nil, nil, true)
  buffer.display_name = buffer_name
  -- Language detection must not give generated content a disk identity.
  buffer.syntax_path = content.source_path
  local text = content.kind == "empty" and "" or (content.text or "")
  set_buffer_text(buffer, text)
  buffer:reset_syntax()
  buffer:clear_undo_redo()
  buffer:clean()
  if content.kind == "blank" then
    require("plugins.untitled_tabs").tag_buffer(buffer, buffer_name, content.untitled_id)
  else
    buffer.new_file = false
  end
  return buffer, true
end

local function source_path_for_content(content)
  local path = content and content.source_path
  if not path and content then
    if content.kind == "file" then
      path = content.filename
    elseif content.kind == "buffer" or content.kind == "fragment" then
      path = content.buffer and content.buffer.abs_filename
    end
  end
  if path and not common.is_absolute_path(path) then
    local ok, absolute = pcall(core.project_absolute_path, path)
    if ok then path = absolute end
  end
  return path and common.normalize_path(path) or nil
end

local function comparison_rejection(buffers)
  local total_bytes, total_lines = 0, 0
  for _, buffer in ipairs(buffers or {}) do
    total_lines = total_lines + #(buffer.lines or {})
    for _, line in ipairs(buffer.lines or {}) do
      total_bytes = total_bytes + #line
      if line:find("\0", 1, true) then return "Binary content cannot use the text Diff View" end
    end
  end
  if total_bytes > 48 * 1024 * 1024 or total_lines > 1200000 then
    return "Content is too large for the text Diff View"
  end
end

function DiffView:assign_request()
  if self.request_assigned then return end
  self.request_assigned = true
  call_assignment_hook(self.request, "on_assigned", true, { view = self })
  call_assignment_hook(self.request.contents[1], "on_assigned", true, self.request, "left")
  call_assignment_hook(self.request.contents[2], "on_assigned", true, self.request, "right")
end

---Constructor
---@param a string|table
---@param b string?
---@param compare_type? plugins.diffview.view.type
---@param names? plugins.diffview.view.string_names
function DiffView:new(a, b, compare_type, names)
  self.__hide_right_pane_on_focus = true
  DiffView.super.new(self)

  -- Scrolling belongs to the two synchronized Diff Sides. A third scrollbar
  -- on this container only duplicated the right-side scrollbar and left a
  -- conspicuously wide dead strip at the outer edge.
  self.scrollable = false
  local request, request_err = validate_request(type(a) == "table" and a.contents and a or legacy_request(a, b, compare_type, names))
  if not request then error(request_err, 2) end
  self.request = request
  self.compare_type = self.request.compare_type or compare_type or DiffView.type.STRING_STRING
  self.skip_update_diff = false
  self.diff_generation = 0
  self.disposed = false
  self.request_assigned = false

  local buffer_a, owns_a = buffer_for_content(self.request.contents[1], self.request.content_titles and self.request.content_titles[1])
  local buffer_b, owns_b = buffer_for_content(self.request.contents[2], self.request.content_titles and self.request.content_titles[2])
  self.side_buffers = { buffer_a, buffer_b }
  self.side_owns = { owns_a, owns_b }
  self.owned_buffers = { [buffer_a] = owns_a, [buffer_b] = owns_b }
  self.retained_buffers = {}
  local function retain_registered(buffer)
    local registry = core.buffer_registry
    if not (registry and registry:identity(buffer)) or self.retained_buffers[buffer] then return end
    registry:retain(buffer, self)
    self.retained_buffers[buffer] = true
  end
  if not owns_a then retain_registered(buffer_a) end
  if not owns_b then retain_registered(buffer_b) end
  for _, content in ipairs(self.request.contents) do
    if content.kind == "fragment" then retain_registered(content.buffer) end
  end
  self.comparison_message = comparison_rejection(self.side_buffers)

  self.buffer_view_a = TextView(buffer_a)
  self.buffer_view_b = TextView(buffer_b)
  self.mouse_router = MouseRouter(self, function(owner, x, y)
    return owner:mouse_side_at(x, y)
  end)
  -- Both line-number lanes sit in the center instead of the outer gutters.
  self.buffer_view_a.show_line_numbers = false
  self.buffer_view_b.show_line_numbers = false
  -- Current Line Highlights cover the Diff View's change colors. The caret
  -- already identifies its row on each synchronized Diff Side.
  self.buffer_view_a.show_current_line_highlight = false
  self.buffer_view_b.show_current_line_highlight = false
  self.buffer_view_a.gutter_padding = 4 * SCALE
  self.buffer_view_b.gutter_padding = 0
  self.buffer_view_a.suppress_gitdiff_gutter = true
  self.buffer_view_b.suppress_gitdiff_gutter = true
  self.side_editable = {
    a = content_editable(self.request, self.request.contents[1]),
    b = content_editable(self.request, self.request.contents[2]),
  }

  self.buffer_view_a.diff_view_parent = self
  self.buffer_view_b.diff_view_parent = self
  self.buffer_view_a.diff_view_side_index = 1
  self.buffer_view_b.diff_view_side_index = 2
  self.buffer_view_a.get_path_target = function(view) return self:get_side_path_target(1, view) end
  self.buffer_view_b.get_path_target = function(view) return self:get_side_path_target(2, view) end

  if not self.request._defer_assignment then self:assign_request() end

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
  self.pending_first_change_reveal = not self.comparison_message
    and self.request.auto_reveal_first_change ~= false

end

function DiffView:get_focus_view()
  return self.navigation_focus_side == "left" and self.buffer_view_a or self.buffer_view_b
end

function DiffView:get_navigation_state()
  if core.active_view == self.buffer_view_a then
    self.navigation_focus_side = "left"
  elseif core.active_view == self.buffer_view_b then
    self.navigation_focus_side = "right"
  end
  return {
    selection_state = {
      side = self.navigation_focus_side or "right",
      left = self.buffer_view_a:get_selection_state(),
      right = self.buffer_view_b:get_selection_state(),
    },
    left_scroll = { x = self.buffer_view_a.scroll.x, y = self.buffer_view_a.scroll.y },
    right_scroll = { x = self.buffer_view_b.scroll.x, y = self.buffer_view_b.scroll.y },
  }
end

function DiffView:set_navigation_state(state, opts)
  local selection = state.selection_state
  self.navigation_focus_side = selection.side
  self.pending_first_change_reveal = false
  self.syncing_diff_caret = true
  local function restore(view, saved, scroll)
    view:set_selection_state(saved)
    view.scroll.to.x, view.scroll.to.y = scroll.x, scroll.y
    if not (opts and opts.animate_scroll) then
      view.scroll.x, view.scroll.y = scroll.x, scroll.y
      view.scroll.move_data_x, view.scroll.move_data_y = nil, nil
    end
  end
  restore(self.buffer_view_a, selection.left, state.left_scroll)
  restore(self.buffer_view_b, selection.right, state.right_scroll)
  self.syncing_diff_caret = nil
  core.log_quiet("Diff View: restored Navigation Place on %s side", selection.side)
end

function DiffView:get_surface_focus_targets()
  return { self.buffer_view_a, self.buffer_view_b }
end

function DiffView:get_path_target()
  local focus = core.active_view
  if focus ~= self.buffer_view_a and focus ~= self.buffer_view_b then
    focus = self.buffer_view_a
  end
  return focus and focus.get_path_target and focus:get_path_target() or nil
end

function DiffView:swap_sides()
  if self.disposed then return false end
  self:dispose_integrations()
  self.disposed = false
  self.request.contents[1], self.request.contents[2] = self.request.contents[2], self.request.contents[1]
  if self.request.content_titles then
    self.request.content_titles[1], self.request.content_titles[2] =
      self.request.content_titles[2], self.request.content_titles[1]
  end
  self.buffer_view_a, self.buffer_view_b = self.buffer_view_b, self.buffer_view_a
  self.side_buffers[1], self.side_buffers[2] = self.side_buffers[2], self.side_buffers[1]
  self.side_owns[1], self.side_owns[2] = self.side_owns[2], self.side_owns[1]
  self.side_editable.a, self.side_editable.b = self.side_editable.b, self.side_editable.a
  self.buffer_view_a.diff_view_side_index = 1
  self.buffer_view_b.diff_view_side_index = 2
  self.buffer_view_a.get_path_target = function(view) return self:get_side_path_target(1, view) end
  self.buffer_view_b.get_path_target = function(view) return self:get_side_path_target(2, view) end
  self.request.user_data = self.request.user_data or {}
  self.request.user_data.diff_fold_state = nil
  self.request_assigned = false
  self.views_patched = false
  self:install_view_integrations()
  self:assign_request()
  self:update_diff()
  core.log_quiet("Diff View swapped sides: %s", self:get_name())
  return true
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

---Return the line counts used by the change summary in the Diff View heading.
---@return table|nil
function DiffView:get_change_stats()
  if not self.diff_model then return nil end
  local deleted, inserted, changed = 0, 0, 0
  for _, change in ipairs(self.a_changes or {}) do
    if change.tag == "delete" then
      deleted = deleted + 1
    elseif change.tag == "modify" then
      changed = changed + 1
    end
  end
  for _, change in ipairs(self.b_changes or {}) do
    if change.tag == "insert" then inserted = inserted + 1 end
  end
  return {
    deleted = deleted,
    inserted = inserted,
    changed = changed,
    total = deleted + inserted + changed,
  }
end

---Return the display title for one Diff View side.
---@param index integer
---@return string
function DiffView:get_side_title(index)
  local content = self.request and self.request.contents and self.request.contents[index]
  local title = self.request and self.request.content_titles
    and self.request.content_titles[index]
  return title_for_content(content or {}, title) or (index == 1 and "Left" or "Right")
end

---Updates the registered differences between current side A and B.
function DiffView:cancel_diff_update()
  if not self.updater_idx then return end
  for _, thread in pairs(core.threads) do
    if thread.diff_viewer == self.updater_idx then
      thread.cr = coroutine.create(function() end)
    end
  end
  self.updater_idx = nil
end

function DiffView:update_diff(scroll_source)
  if self.skip_update_diff then self.skip_update_diff = false return end
  local whitespace_mode = config.plugins.diffview.whitespace_mode or "trim"
  if self.diff_whitespace_mode ~= whitespace_mode then
    core.log_quiet("Diff View whitespace comparison: %s", whitespace_mode)
  end
  self.diff_whitespace_mode = whitespace_mode
  self.comparison_message = comparison_rejection(self.side_buffers)
  if self.comparison_message then
    self.diff_generation = (self.diff_generation or 0) + 1
    self:cancel_diff_update()
    self.a_changes, self.b_changes = {}, {}
    self.a_gaps, self.b_gaps = {}, {}
    self.diff_model = nil
    return
  end

  -- stop previous update if still running.
  self:cancel_diff_update()

  local start_time = system.get_time()
  local transition_trace = self.request and self.request.user_data
    and self.request.user_data.transition_trace
  if transition_trace then transition_trace("diff_queued") end
  self.diff_started_at = start_time
  self.diff_loading_visible = false
  local generation_scroll_source = scroll_source

  if config.plugins.diffview.log_times then
    core.log(
      (#self.a_changes == 0 and "Computing " or "Recomputing ")
      .. "differences..."
    )
  end

  self.diff_generation = (self.diff_generation or 0) + 1
  local generation = self.diff_generation
  local idx = core.add_thread(function()
    if transition_trace then transition_trace("diff_compute_start") end
    local computing_start = system.get_time()
    local model = diff_model.compute(self.buffer_view_a.buffer.lines, self.buffer_view_b.buffer.lines, {
      whitespace_mode = whitespace_mode,
      should_yield = function()
        if system.get_time() - computing_start >= 0.5 then
          computing_start = system.get_time()
          return true
        end
        return false
      end,
    })
    if transition_trace then transition_trace("diff_compute_complete") end
    if self.disposed or generation ~= self.diff_generation then return end

    if self.diff_equal_blocks and self.diff_fold_identity_counts then self:save_diff_fold_state() end
    self.expanded_diff_folds = {}
    self.diff_model = model
    self.a_gaps = model.a_gaps
    self.b_gaps = model.b_gaps
    self.a_changes = model.a_changes
    self.b_changes = model.b_changes
    self.diff_equal_blocks = model.equal_blocks
    self:rebuild_diff_folds()
    self:refresh_core_gap_rows(true)
    if transition_trace then transition_trace("diff_layout_complete") end

    self.updater_idx = nil

    local scroll_view = generation_scroll_source
    if scroll_view ~= self.buffer_view_a and scroll_view ~= self.buffer_view_b then
      local active_view = core.active_view
      if active_view == self.buffer_view_a or active_view == self.buffer_view_b then
        scroll_view = active_view
      else
        scroll_view = self.buffer_view_a
      end
    end
    self:sync_scroll_from(scroll_view, scroll_view == self.buffer_view_a)

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

local function point_in_diff_side(view, x, y)
  return x >= view.position.x and y >= view.position.y
    and x < view.position.x + view.size.x
    and y < view.position.y + view.size.y
end

function DiffView:get_state()
  local data = self.request and self.request.user_data
  if not (data and data.blank_diff) then return nil end
  return {
    kind = "blank_diff",
    title = self.request.title,
    left_text = table.concat(self.buffer_view_a.buffer.lines or {}):gsub("\n$", ""),
    right_text = table.concat(self.buffer_view_b.buffer.lines or {}):gsub("\n$", ""),
    left_untitled_id = self.buffer_view_a.buffer.intellij_untitled_id,
    right_untitled_id = self.buffer_view_b.buffer.intellij_untitled_id,
    content_titles = self.request.content_titles,
    preferred_focus_side = core.active_view == self.buffer_view_b and "right" or "left",
  }
end

function DiffView:mouse_side_at(x, y)
  if point_in_diff_side(self.buffer_view_a, x, y) then return self.buffer_view_a, true end
  if point_in_diff_side(self.buffer_view_b, x, y) then return self.buffer_view_b, false end
end

function DiffView:on_mouse_pressed(button, x, y, clicks)
  local side = self.mouse_router:press_target(x, y)
  if not side then return nil end
  local is_a = side == self.buffer_view_a
  local scrollbar, handled = self.mouse_router:press_scrollbar(side, button, x, y, clicks)
  if scrollbar then
    side.scroll.y = side.scroll.to.y
    self:sync_scroll_from(side, is_a)
    return handled
  end
  self.mouse_router:capture(side)
  core.set_active_view(side)
  handled = self.mouse_router:call(side, "on_mouse_pressed", button, x, y, clicks)
  if side:scrollbar_dragging() then
    side.scroll.y = side.scroll.to.y
    self:sync_scroll_from(side, is_a)
  end
  return handled
end

function DiffView:on_mouse_released(button, x, y, ...)
  local handled = self.mouse_router:release(button, x, y, ...)
  return handled
end

function DiffView:on_mouse_moved(x, y, dx, dy)
  local handled, side = self.mouse_router:move(x, y, dx, dy)
  if not side then return nil end
  local is_a = side == self.buffer_view_a
  if side:scrollbar_dragging() then
    side.scroll.y = side.scroll.to.y
    self:sync_scroll_from(side, is_a)
    return true
  end
  return handled
end

function DiffView:on_mouse_left()
  self.mouse_router:leave()
end

function DiffView:on_mouse_wheel(y, x)
  if keymap.modkeys["shift"] then
    x = y
    y = 0
  end
  if y and y ~= 0 then
    self.buffer_view_a.scroll.to.y = self.buffer_view_a.scroll.to.y + y * -config.mouse_wheel_scroll
    self.buffer_view_b.scroll.to.y = self.buffer_view_b.scroll.to.y + y * -config.mouse_wheel_scroll
  end
  if x and x ~= 0 then
    local side = self.mouse_router:wheel_target()
    if side ~= self.buffer_view_a and side ~= self.buffer_view_b then
      side = core.active_view == self.buffer_view_b and self.buffer_view_b or self.buffer_view_a
    end
    side.scroll.to.x = side.scroll.to.x + x * -config.mouse_wheel_scroll
  end
  return (y and y ~= 0) or (x and x ~= 0) or false
end

function DiffView:on_scale_change(...)
  self.buffer_view_a:on_scale_change(...)
  self.buffer_view_b:on_scale_change(...)
end

function DiffView:on_touch_moved(...)
  DiffView.super.on_touch_moved(self, ...)
  call_textview_method(self.buffer_view_a, self.buffer_view_a.on_touch_moved, ...)
  call_textview_method(self.buffer_view_b, self.buffer_view_b.on_touch_moved, ...)
end

local function wrapped_total_visual_lines(buffer_view)
  if buffer_view.get_total_visual_lines then return buffer_view:get_total_visual_lines() end
  if not buffer_view.wrapped_settings or not buffer_view.wrapped_lines then
    return buffer_view.buffer and #buffer_view.buffer.lines or 0
  end
  return #buffer_view.wrapped_lines / 2
end

local function visual_rows_before_line(buffer_view, line)
  if buffer_view.has_composed_visual_rows and buffer_view:has_composed_visual_rows() then
    return math.max(0, buffer_view:get_visual_row(line, 1) - 1)
  end
  if not buffer_view.wrapped_settings or not buffer_view.wrapped_line_to_idx then
    return math.max(0, line - 1)
  end
  local idx = buffer_view.wrapped_line_to_idx[line]
  if idx then return idx - 1 end
  return math.max(0, math.min(wrapped_total_visual_lines(buffer_view), line - 1))
end

local function visual_line_count(buffer_view, line)
  if buffer_view.get_visual_row_count_for_line then return buffer_view:get_visual_row_count_for_line(line) end
  if not buffer_view.wrapped_settings or not buffer_view.wrapped_line_to_idx then return 1 end
  local total = wrapped_total_visual_lines(buffer_view)
  local idx = buffer_view.wrapped_line_to_idx[line]
  if not idx then return 1 end
  local next_idx = buffer_view.wrapped_line_to_idx[line + 1] or (total + 1)
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

local function line_for_visual_row(buffer_view, row)
  local total = math.max(1, buffer_view:get_scrollable_line_count())
  local visual_row = common.clamp(math.floor(tonumber(row) or 0) + 1, 1, total)
  local line = buffer_view:get_visual_row_line_col(visual_row)
  return common.clamp(line or 1, 1, #buffer_view.buffer.lines)
end

local function install_core_gap_rows_for_textview(buffer_view, gaps)
  if not buffer_view or not buffer_view.add_visual_row_provider then return end
  local before, any = {}, false
  for line, gap in pairs(gaps or {}) do
    local cumulative = math.max(0, math.floor(tonumber(gap[2]) or 0))
    if cumulative > 0 then before[line], any = cumulative, true end
  end
  if any then
    buffer_view:add_visual_row_provider("diff-gaps", { before = before }, { priority = 50 })
  else
    buffer_view:remove_visual_row_provider("diff-gaps")
  end
end

local function gap_layout_signature(buffer_view)
  return table.concat({
    tostring(buffer_view.size and buffer_view.size.x or 0),
    tostring(buffer_view.buffer and buffer_view.buffer.text_revision or 0),
    tostring(buffer_view.__wrap_layout_generation or 0),
    tostring(buffer_view.fold_generation or 0),
    tostring(buffer_view.wrapping_enabled),
  }, ":")
end

function DiffView:get_side_path_target(index, side_view)
  local content = self.request and self.request.contents and self.request.contents[index]
  local path = source_path_for_content(content)
  if not path then return nil end
  local line = with_textview_selection(side_view, function()
    return side_view.buffer:get_selection(false)
  end)
  if content and content.kind == "fragment" then
    line = FragmentBuffer.map_line(side_view.buffer, line)
  elseif content and content.source_line then
    line = content.source_line + line - 1
  end
  return { path = path, line = line }
end

-- Let connectors show small offsets and short unchanged tails without empty space.
-- Prefer nearby blank boundaries when a large offset needs empty space.
local MAX_UNPADDED_DIFF_ROWS = 8
local MIN_UNCHANGED_TAIL_ROWS_FOR_DIFF_GAP = 3

local function gap_line_indent(text, tab_size)
  local columns = 0
  for char in text:match("^[ \t]*"):gmatch(".") do
    columns = columns + (char == "\t" and tab_size - columns % tab_size or 1)
  end
  return columns
end

local function gap_neighbor_indent(lines, line, direction, tab_size)
  for distance = 1, 12 do
    local text = lines[line + distance * direction]
    if not text then return nil end
    if text:find("%S") then
      return gap_line_indent(text, tab_size)
    end
  end
end

local function gap_boundary(view, alignment, index, side)
  local buffer = view[side == "a" and "buffer_view_a" or "buffer_view_b"].buffer
  local lines = buffer.lines
  local _, tab_size = buffer:get_indent_info()
  local best_line, best_indent, best_distance
  -- Stay local and do not move padding across a paired replacement.
  for _, direction in ipairs({ -1, 1 }) do
    for distance = 0, 12 do
      local pair = alignment[index + distance * direction]
      if not pair or (pair.tag ~= "equal" and pair.a and pair.b) then break end
      if direction == 1 and pair.tag ~= "equal" then break end
      if pair.tag == "equal" and pair.a and pair.b
        and lines[pair[side]]:match("^%s*$") then
        local before = gap_neighbor_indent(lines, pair[side], -1, tab_size)
        local after = gap_neighbor_indent(lines, pair[side], 1, tab_size)
        -- Blank lines often have no indentation. Use both adjacent code lines
        -- so a blank before a closing brace still belongs to the deeper body.
        if before and after then
          local indent = math.max(before, after)
          if not best_line or indent < best_indent
            or (indent == best_indent and distance < best_distance) then
            best_line, best_indent, best_distance = pair[side], indent, distance
          end
        end
      end
    end
  end
  if best_line then return best_line end

  -- An unchanged continuation can be the first alignment pair after a large
  -- change. Keep it with its statement and use the following dedent instead.
  local trigger_line = alignment[index][side]
  local trigger_indent = gap_line_indent(lines[trigger_line], tab_size)
  for distance = 1, 12 do
    local pair = alignment[index + distance]
    if not pair or pair.tag ~= "equal" then break end
    local line = pair[side]
    if line and lines[line]:find("%S")
      and gap_line_indent(lines[line], tab_size) < trigger_indent then
      return line
    end
  end
  return trigger_line
end

local function has_useful_comparison_remaining(view, alignment, index)
  local first = alignment[index]
  if not (first and first.a and first.b) then return false end
  local a_rows, b_rows = 0, 0
  for i = index, #alignment do
    local pair = alignment[i]
    -- A later change makes alignment useful. Suppress only a short unchanged tail.
    if pair.tag ~= "equal" then return true end
    if pair.a and pair.b then
      a_rows = a_rows + view.buffer_view_a:get_visual_row_count_for_line(pair.a)
      b_rows = b_rows + view.buffer_view_b:get_visual_row_count_for_line(pair.b)
      if math.min(a_rows, b_rows) >= MIN_UNCHANGED_TAIL_ROWS_FOR_DIFF_GAP then return true end
    end
  end
  return false
end

function DiffView:refresh_core_gap_rows(force)
  local model = self.diff_model
  if not model then return end
  local signature = gap_layout_signature(self.buffer_view_a) .. "|" .. gap_layout_signature(self.buffer_view_b)
  if not force and signature == self.__diff_gap_layout_signature then return end

  local a_gaps, b_gaps = {}, {}
  local a_inserts, b_inserts = {}, {}
  local a_height, b_height = 0, 0

  local alignment = model.alignment or {}
  for index, pair in ipairs(alignment) do
    -- Keep changed blocks together. Resume alignment only at unchanged content.
    if pair.tag == "equal" and a_height < b_height and pair.a then
      local delta = b_height - a_height
      if delta > MAX_UNPADDED_DIFF_ROWS
        and has_useful_comparison_remaining(self, alignment, index)
      then
        local line = gap_boundary(self, alignment, index, "a")
        a_inserts[line] = (a_inserts[line] or 0) + delta
        a_height = b_height
      end
    elseif pair.tag == "equal" and b_height < a_height and pair.b then
      local delta = a_height - b_height
      if delta > MAX_UNPADDED_DIFF_ROWS
        and has_useful_comparison_remaining(self, alignment, index)
      then
        local line = gap_boundary(self, alignment, index, "b")
        b_inserts[line] = (b_inserts[line] or 0) + delta
        b_height = a_height
      end
    end

    if pair.a then
      a_height = a_height + self.buffer_view_a:get_visual_row_count_for_line(pair.a)
    end
    if pair.b then
      b_height = b_height + self.buffer_view_b:get_visual_row_count_for_line(pair.b)
    end
  end

  -- Measure offsets first, then place the gaps at the selected boundaries.
  -- A boundary can precede or follow the line that triggered alignment.
  local a_gap_total, b_gap_total = 0, 0
  for _, pair in ipairs(alignment) do
    if pair.a then
      a_gap_total = a_gap_total + (a_inserts[pair.a] or 0)
      a_gaps[pair.a] = { 0, a_gap_total }
    end
    if pair.b then
      b_gap_total = b_gap_total + (b_inserts[pair.b] or 0)
      b_gaps[pair.b] = { 0, b_gap_total }
    end
  end

  self.a_gaps, self.b_gaps = a_gaps, b_gaps
  install_core_gap_rows_for_textview(self.buffer_view_a, a_gaps)
  install_core_gap_rows_for_textview(self.buffer_view_b, b_gaps)
  -- Installing providers changes fold generations, so retain the post-install
  -- signature rather than triggering another identical rebuild next frame.
  self.__diff_gap_layout_signature = gap_layout_signature(self.buffer_view_a)
    .. "|" .. gap_layout_signature(self.buffer_view_b)
end

local function clear_core_diff_folds(buffer_view)
  if not buffer_view or not buffer_view.fold_regions then return end
  for i = #buffer_view.fold_regions, 1, -1 do
    local fold = buffer_view.fold_regions[i]
    if fold.kind == "diff-view" then
      buffer_view:remove_fold_region(fold, "diff-rebuild")
    end
  end
end

local function install_core_diff_folds(buffer_view, folds, side)
  if not buffer_view or not buffer_view.add_fold_region then return end
  for _, fold in ipairs(folds or {}) do
    local core_fold = buffer_view:add_fold_region {
      id = "diff-" .. side .. "-" .. tostring(fold.index),
      line1 = fold.hidden_start,
      col1 = 1,
      line2 = fold.hidden_end,
      col2 = #(buffer_view.buffer.lines[fold.hidden_end] or "") + 1,
      kind = "diff-view",
      metadata = { diff_fold = fold, side = side },
      placeholder = string.format("⋯ %d unchanged lines folded ⋯", fold.hidden_count),
    }
    fold.core_fold = core_fold
  end
end

local function normalize_fold_text(text)
  return tostring(text or ""):gsub("\r", ""):gsub("\n$", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function fold_side_range(block, side, opts)
  local context = math.max(0, tonumber(opts.context_lines) or 0)
  local start = side == "a" and block.a_start or block.b_start
  local count = block.count or 0
  local keep_start = block.has_prev_change and context or 0
  local keep_end = block.has_next_change and context or 0
  local hidden_start = start + keep_start
  local hidden_end = start + count - 1 - keep_end
  return hidden_start, hidden_end, math.max(0, hidden_end - hidden_start + 1)
end

local function diff_fold_tail_sample(lines, start_line, end_line)
  local sample = {}
  for line = math.max(start_line, end_line - 2), end_line do
    sample[#sample + 1] = normalize_fold_text(lines[line])
  end
  return table.concat(sample, "\31")
end

local function diff_fold_prefix_window(lines, start_line, end_line)
  local sample = {}
  for line = start_line, math.min(end_line, start_line + 2) do
    sample[#sample + 1] = normalize_fold_text(lines[line])
  end
  return sample
end

local function sample_contains(sample, value)
  if value == nil then return true end
  for _, item in ipairs(sample or {}) do
    if item == value then return true end
  end
  return false
end

local function diff_fold_count_bucket(count)
  count = tonumber(count) or 0
  if count <= 4 then return tostring(count) end
  if count <= 8 then return "5-8" end
  if count <= 16 then return "9-16" end
  if count <= 32 then return "17-32" end
  return "33+"
end

local function diff_fold_identity(view, block, opts)
  local a_start, a_end, hidden_count = fold_side_range(block, "a", opts)
  local b_start, b_end = fold_side_range(block, "b", opts)
  local a_lines = view.buffer_view_a and view.buffer_view_a.buffer and view.buffer_view_a.buffer.lines or {}
  local b_lines = view.buffer_view_b and view.buffer_view_b.buffer and view.buffer_view_b.buffer.lines or {}
  local parts = {
    "v2",
    diff_fold_count_bucket(hidden_count),
    diff_fold_tail_sample(a_lines, a_start, a_end),
    diff_fold_tail_sample(b_lines, b_start, b_end),
    block.has_prev_change and "p1" or "p0",
    block.has_next_change and "n1" or "n0",
  }
  return table.concat(parts, "\30")
end

local function diff_fold_candidate(view, block, index, opts)
  local min_lines = math.max(1, tonumber(opts.min_lines) or 1)
  local a_start, a_end, a_count = fold_side_range(block, "a", opts)
  local b_start, b_end, b_count = fold_side_range(block, "b", opts)
  if a_count < min_lines or b_count < min_lines then return nil end
  local context = math.max(0, tonumber(opts.context_lines) or 0)
  local keep_start = block.has_prev_change and context or 0
  local keep_end = block.has_next_change and context or 0
  if (block.count or 0) < keep_start + keep_end + min_lines then return nil end
  local a_lines = view.buffer_view_a and view.buffer_view_a.buffer and view.buffer_view_a.buffer.lines or {}
  local b_lines = view.buffer_view_b and view.buffer_view_b.buffer and view.buffer_view_b.buffer.lines or {}
  return {
    index = index,
    block = block,
    identity = diff_fold_identity(view, block, opts),
    prefix_a = normalize_fold_text(a_lines[a_start]),
    prefix_b = normalize_fold_text(b_lines[b_start]),
    prefix_window_a = diff_fold_prefix_window(a_lines, a_start, a_end),
    prefix_window_b = diff_fold_prefix_window(b_lines, b_start, b_end),
    a = { hidden_start = a_start, hidden_end = a_end, hidden_count = a_count },
    b = { hidden_start = b_start, hidden_end = b_end, hidden_count = b_count },
  }
end

local function diff_fold_candidates(view, blocks, opts)
  local candidates = {}
  local identity_counts = {}
  for index, block in ipairs(blocks or {}) do
    local candidate = diff_fold_candidate(view, block, index, opts)
    if candidate then
      candidates[#candidates + 1] = candidate
      identity_counts[candidate.identity] = (identity_counts[candidate.identity] or 0) + 1
    end
  end
  return candidates, identity_counts
end

function DiffView:fold_state_cache()
  self.request.user_data = self.request.user_data or {}
  local cache = self.request.user_data.diff_fold_state
  if type(cache) ~= "table" then
    cache = { default_expanded = not self.folding_enabled, states = {} }
    self.request.user_data.diff_fold_state = cache
  end
  return cache
end

local function cache_state_map(cache, default_expanded)
  if not cache or cache.default_expanded ~= default_expanded then return {} end
  local map, ambiguous = {}, {}
  for _, state in ipairs(cache.states or {}) do
    local key = state.identity
    if key then
      if map[key] and map[key].state ~= state.state then ambiguous[key] = true end
      map[key] = state
    end
  end
  for key in pairs(ambiguous) do map[key] = nil end
  return map
end

function DiffView:save_diff_fold_state()
  if not self.request or not (self.diff_equal_blocks and self.diff_fold_identity_counts) then return end
  local default_expanded = not self.folding_enabled
  local opts = {
    enabled = true,
    context_lines = config.plugins.diffview.fold_context_lines or 6,
    min_lines = config.plugins.diffview.fold_min_lines or 16,
  }
  local identity_counts = self.diff_fold_identity_counts or {}
  local prior = self.request.user_data and self.request.user_data.diff_fold_state
  local by_identity = {}
  if prior and prior.default_expanded == default_expanded then
    for _, state in ipairs(prior.states or {}) do
      if state.identity and identity_counts[state.identity] == 1 then by_identity[state.identity] = common.merge({}, state) end
    end
  end

  local collapsed = {}
  for _, fold in ipairs(self.diff_folds_a or {}) do if fold.identity then collapsed[fold.identity] = (collapsed[fold.identity] or 0) + 1 end end
  for _, fold in ipairs(self.diff_folds_b or {}) do if fold.identity then collapsed[fold.identity] = (collapsed[fold.identity] or 0) + 1 end end
  for identity, count in pairs(collapsed) do
    if identity_counts[identity] == 1 then
      by_identity[identity] = by_identity[identity] or { identity = identity }
      by_identity[identity].state = count == 2 and "collapsed" or "expanded"
      for _, fold in ipairs(self.diff_folds_a or {}) do
        if fold.identity == identity then by_identity[identity].prefix_a = fold.prefix_a; by_identity[identity].prefix_b = fold.prefix_b; break end
      end
    end
  end

  if not next(by_identity) then
    local candidates, fresh_identity_counts = diff_fold_candidates(self, self.diff_equal_blocks or {}, opts)
    for _, candidate in ipairs(candidates) do
      if fresh_identity_counts[candidate.identity] == 1 then by_identity[candidate.identity] = {
        identity = candidate.identity,
        prefix_a = candidate.prefix_a,
        prefix_b = candidate.prefix_b,
        side_ranges = {
          left = { start_line = candidate.a.hidden_start, end_line = candidate.a.hidden_end },
          right = { start_line = candidate.b.hidden_start, end_line = candidate.b.hidden_end },
        },
        state = default_expanded and "expanded" or "collapsed",
        index = candidate.index,
        description = string.format("unchanged block %d", candidate.index),
      } end
    end
  end

  local states = {}
  for _, state in pairs(by_identity) do states[#states + 1] = state end
  table.sort(states, function(a, b) return tostring(a.identity) < tostring(b.identity) end)
  self.request.user_data = self.request.user_data or {}
  self.request.user_data.diff_fold_state = {
    default_expanded = default_expanded,
    states = states,
  }
end

local function candidate_matches_cached_state(candidate, state)
  if not state then return false end
  return sample_contains(candidate.prefix_window_a, state.prefix_a)
    and sample_contains(candidate.prefix_window_b, state.prefix_b)
end

local function build_diff_folds(view, candidates, identity_counts, side, opts, state_map)
  if not opts.enabled and not state_map then return {} end
  local default_expanded = not opts.enabled
  local folds = {}
  for _, candidate in ipairs(candidates or {}) do
    local cached = identity_counts[candidate.identity] == 1 and state_map[candidate.identity] or nil
    if cached and not candidate_matches_cached_state(candidate, cached) then cached = nil end
    local state
    if cached then
      state = cached.state
    elseif identity_counts[candidate.identity] ~= 1 and view.expanded_diff_folds and view.expanded_diff_folds[candidate.index] then
      state = "expanded"
    else
      state = default_expanded and "expanded" or "collapsed"
    end
    if state == "collapsed" then
      local range = side == "a" and candidate.a or candidate.b
      folds[#folds + 1] = {
        index = candidate.index,
        identity = candidate.identity,
        identity_count = identity_counts[candidate.identity] or 0,
        prefix_a = candidate.prefix_a,
        prefix_b = candidate.prefix_b,
        hidden_start = range.hidden_start,
        hidden_end = range.hidden_end,
        hidden_count = range.hidden_count,
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
  local candidates, identity_counts = diff_fold_candidates(self, self.diff_equal_blocks or {}, opts)
  self.diff_fold_identity_counts = identity_counts
  local cache = self:fold_state_cache()
  local state_map = cache_state_map(cache, not self.folding_enabled)
  self.rebuilding_diff_folds = true
  clear_core_diff_folds(self.buffer_view_a)
  clear_core_diff_folds(self.buffer_view_b)
  self.diff_folds_a = build_diff_folds(self, candidates, identity_counts, "a", opts, state_map)
  self.diff_folds_b = build_diff_folds(self, candidates, identity_counts, "b", opts, state_map)
  install_core_diff_folds(self.buffer_view_a, self.diff_folds_a, "a")
  install_core_diff_folds(self.buffer_view_b, self.diff_folds_b, "b")
  self.rebuilding_diff_folds = false
  self:save_diff_fold_state()
end

function DiffView:toggle_folding()
  self:save_diff_fold_state()
  self.folding_enabled = not self.folding_enabled
  if self.request then
    self.request.user_data = self.request.user_data or {}
    self.request.user_data.diff_fold_state = { default_expanded = not self.folding_enabled, states = {} }
  end
  self.expanded_diff_folds = {}
  self:rebuild_diff_folds()
  core.redraw = true
  return true
end

function DiffView:expand_fold(fold)
  if not fold then return false end
  local opts = {
    enabled = true,
    context_lines = config.plugins.diffview.fold_context_lines or 6,
    min_lines = config.plugins.diffview.fold_min_lines or 16,
  }
  local _, identity_counts = diff_fold_candidates(self, self.diff_equal_blocks or {}, opts)
  if (identity_counts[fold.identity] or 0) == 1 then
    local cache = self:fold_state_cache()
    cache.default_expanded = not self.folding_enabled
    cache.states = cache.states or {}
    local updated = false
    for _, state in ipairs(cache.states) do
      if state.identity == fold.identity then
        state.state = "expanded"
        state.prefix_a = fold.prefix_a
        state.prefix_b = fold.prefix_b
        updated = true
      end
    end
    if not updated then
      cache.states[#cache.states + 1] = { identity = fold.identity, state = "expanded", index = fold.index, prefix_a = fold.prefix_a, prefix_b = fold.prefix_b }
    end
  end
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

function DiffView:sync_scroll_from(buffer_view, is_a)
  local other = is_a and self.buffer_view_b or self.buffer_view_a
  local y, target_y = buffer_view.scroll.y, buffer_view.scroll.to.y
  local function apply(view)
    local max_y = math.max(0, view:get_scrollable_size() - view.size.y)
    view.scroll.y = common.clamp(y, 0, max_y)
    view.scroll.to.y = common.clamp(target_y, 0, max_y)
  end
  apply(buffer_view)
  apply(other)
  self.scroll.y, self.scroll.to.y = buffer_view.scroll.y, buffer_view.scroll.to.y
end

local function clamp_position_out_of_fold(buffer_view, folds, old_line, line, col)
  if is_fold_widget_line(folds, line) then return line, 1 end
  local hidden, fold = is_fold_hidden_line(folds, line)
  if not hidden then return line, col end
  if tonumber(line) and tonumber(old_line) and line >= old_line and fold.hidden_end < #buffer_view.buffer.lines then
    return fold.hidden_end + 1, 1
  end
  return fold.hidden_start, 1
end

function DiffView:clamp_selection_out_of_folds(buffer_view, is_a, line1, col1, line2, col2)
  local folds = is_a and self.diff_folds_a or self.diff_folds_b
  if not folds or #folds == 0 then return line1, col1, line2, col2 end
  local old_line = buffer_view.buffer:get_selection()
  line1, col1 = clamp_position_out_of_fold(buffer_view, folds, old_line, line1, col1)
  if line2 then line2, col2 = clamp_position_out_of_fold(buffer_view, folds, old_line, line2, col2) end
  return line1, col1, line2, col2
end

function DiffView:sync_caret_from(buffer_view, is_a)
  if self.syncing_diff_caret then return end
  local other = is_a and self.buffer_view_b or self.buffer_view_a
  if not other then return end
  local target_folds = is_a and self.diff_folds_b or self.diff_folds_a
  local line, col = buffer_view.buffer:get_selection()
  local row = visual_rows_before_line(buffer_view, line)
  local target_line = line_for_visual_row(other, row)
  local target_col = math.max(1, math.min(col or 1, #(other.buffer.lines[target_line] or "")))
  local other_line = with_textview_selection(other, function()
    return other.buffer:get_selection()
  end)
  target_line, target_col = clamp_position_out_of_fold(
    other, target_folds, other_line, target_line, target_col
  )
  self.syncing_diff_caret = true
  with_textview_selection(other, function()
    other.buffer:set_selection(target_line, target_col, target_line, target_col)
  end)
  self.syncing_diff_caret = false
end

function DiffView:get_scrollable_size()
  return math.max(
    self.size.y,
    self.buffer_view_a:get_scrollable_size(),
    self.buffer_view_b:get_scrollable_size()
  )
end

local function diff_color(tag, background)
  if tag == "insert" then return background and style.diff_insert_background or style.diff_insert end
  if tag == "delete" then return background and style.diff_delete_background or style.diff_delete end
  if tag == "modify" then return background and style.diff_modify_background or style.diff_modify end
end

local function overview_marker_color(tag)
  if tag == "delete" then return style.diff_overview_delete or style.diff_delete end
  if tag == "insert" then return style.diff_overview_insert or style.diff_insert end
  if tag == "modify" then return style.diff_overview_modify or style.diff_modify end
end

local function alpha_color(color, alpha)
  if not color then return nil end
  local c = { table.unpack(color) }
  c[4] = math.min(c[4] or 255, alpha)
  return c
end

local function normalize_marker_range(y1, y2)
  local h = math.max(1, common.round(2 * SCALE))
  if math.abs(y2 - y1) >= h then return y1, y2 end
  return y1 - h, y1
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

-- Clip polygon edges, not curve endpoints, to keep the visible shape unchanged.
-- A positive sign keeps points below the boundary; a negative sign keeps points above it.
local function clip_polygon_y(points, boundary, sign)
  local clipped = {}
  local previous = points[#points]
  if not previous then return clipped end
  local previous_inside = sign * (previous[2] - boundary) >= 0
  for _, point in ipairs(points) do
    local inside = sign * (point[2] - boundary) >= 0
    if inside ~= previous_inside then
      local t = (boundary - previous[2]) / (point[2] - previous[2])
      local x = previous[1] + t * (point[1] - previous[1])
      clipped[#clipped + 1] = { math.modf(x + 0.5), boundary }
    end
    if inside then clipped[#clipped + 1] = point end
    previous, previous_inside = point, inside
  end
  return clipped
end

local function draw_curved_trapezium(x1, x2, start1, end1, start2, end2, color, top, bottom)
  if not color or x2 <= x1 then return end
  start1, end1 = normalize_marker_range(start1, end1)
  start2, end2 = normalize_marker_range(start2, end2)

  local points = {}
  local steps = 12
  -- Use the rectangle pixel grid; the polygon API otherwise truncates coordinates.
  for i = 0, steps do
    local x, y = curve_point(x1, x2, start1, start2, i / steps)
    points[#points + 1] = { math.modf(x + 0.5), (math.modf(y + 0.5)) }
  end
  for i = steps, 0, -1 do
    local x, y = curve_point(x1, x2, end1, end2, i / steps)
    points[#points + 1] = { math.modf(x + 0.5), (math.modf(y + 0.5)) }
  end
  -- Rasterizer clipping does not protect its edge arithmetic from huge coordinates.
  top, bottom = math.modf(top + 0.5), math.modf(bottom + 0.5)
  if math.min(start1, start2) < top then points = clip_polygon_y(points, top, 1) end
  if math.max(end1, end2) > bottom then points = clip_polygon_y(points, bottom, -1) end
  if #points >= 3 then renderer.draw_poly(points, color) end
end

local function draw_gap_marker(buffer_view, y, color)
  color = alpha_color(color, 190)
  if not color then return end
  local gw = buffer_view:get_gutter_width()
  local h = math.max(1, common.round(2 * SCALE))
  renderer.draw_rect(
    buffer_view.position.x + gw,
    y - h,
    math.max(0, buffer_view.size.x - gw),
    h,
    color
  )
end

local function change_blocks(changes)
  local blocks = {}
  local i = 1
  while i <= #changes do
    local change = changes[i]
    local tag = change and change.tag
    if tag and tag ~= "equal" then
      local start_line = i
      local end_line = i
      while changes[end_line + 1] do
        local next_tag = changes[end_line + 1].tag
        if next_tag ~= tag then break end
        end_line = end_line + 1
      end
      blocks[#blocks + 1] = {
        tag = tag,
        start_line = start_line,
        end_line = end_line,
      }
      i = end_line + 1
    else
      i = i + 1
    end
  end
  return blocks
end

local function cached_change_blocks(view, side, kind)
  local changes = side == "a" and view.a_changes or view.b_changes
  local cache = view.__change_blocks_cache
  if not cache or cache.a_source ~= view.a_changes or cache.b_source ~= view.b_changes then
    cache = { a_source = view.a_changes, b_source = view.b_changes }
    view.__change_blocks_cache = cache
  end
  local key = side .. ":" .. kind
  if not cache[key] then cache[key] = change_blocks(changes) end
  return cache[key]
end

local function line_range_y(buffer_view, start_line, end_line)
  local _, start_y = buffer_view:get_line_screen_position(start_line)
  local _, end_y = buffer_view:get_line_screen_position(end_line)
  local first_row = buffer_view:get_visual_row(end_line, 1)
  local row_count = visual_line_count(buffer_view, end_line)
  local end_row = first_row + row_count
  local end_height
  if buffer_view.get_visual_row_y_offset then
    end_height = buffer_view:get_visual_row_y_offset(end_row)
      - buffer_view:get_visual_row_y_offset(first_row)
  else
    end_height = row_count * buffer_view:get_line_height()
  end
  end_y = end_y + end_height
  return start_y, end_y
end

local function change_boundary_y(buffer_view, next_line)
  if next_line then
    local _, y = buffer_view:get_line_screen_position(next_line)
    return y
  end
  local last_line = #buffer_view.buffer.lines
  local _, y = line_range_y(buffer_view, last_line, last_line)
  return y
end

-- Keep document ranges separate from layout so resizing does not scan alignment.
local function connector_ranges(view)
  local model = view.diff_model
  local cache = view.__connector_ranges
  if cache and cache.model == model then return cache.ranges end
  local alignment = model and model.alignment or {}
  local ranges, index = {}, 1
  while index <= #alignment do
    if alignment[index].tag == "equal" then
      index = index + 1
    else
      local range = {}
      while index <= #alignment and alignment[index].tag ~= "equal" do
        local pair = alignment[index]
        if pair.a then range.a_start, range.a_end = range.a_start or pair.a, pair.a end
        if pair.b then range.b_start, range.b_end = range.b_start or pair.b, pair.b end
        index = index + 1
      end
      local next_pair = alignment[index]
      range.a_next = next_pair and next_pair.a
      range.b_next = next_pair and next_pair.b
      range.tag = range.a_start and (range.b_start and "modify" or "delete") or "insert"
      ranges[#ranges + 1] = range
    end
  end
  view.__connector_ranges = { model = model, ranges = ranges }
  core.log_quiet("Diff View cached %d connector ranges", #ranges)
  return ranges
end

local function connector_geometry(view)
  local left, right = view.buffer_view_a, view.buffer_view_b
  local ranges = connector_ranges(view)
  local a_signature = left:get_visual_metric_signature()
  local b_signature = right:get_visual_metric_signature()
  local cache = view.__connector_geometry
  if cache and cache.ranges == ranges and cache.left == left and cache.right == right
    and cache.a_signature == a_signature
    and cache.b_signature == b_signature and cache.padding == style.padding.y then
    return cache.entries
  end
  local started, scope = perf_begin("diffview_connector_geometry_build")
  local _, a_offset = left:get_content_offset()
  local _, b_offset = right:get_content_offset()
  local entries = {}
  for _, range in ipairs(ranges) do
    local a_start, a_end, b_start, b_end
    if range.a_start then
      a_start, a_end = line_range_y(left, range.a_start, range.a_end)
    else
      a_start = change_boundary_y(left, range.a_next)
      a_end = a_start
    end
    if range.b_start then
      b_start, b_end = line_range_y(right, range.b_start, range.b_end)
    else
      b_start = change_boundary_y(right, range.b_next)
      b_end = b_start
    end
    entries[#entries + 1] = {
      tag = range.tag,
      a_start = a_start - a_offset, a_end = a_end - a_offset,
      b_start = b_start - b_offset, b_end = b_end - b_offset,
    }
  end
  view.__connector_geometry = {
    ranges = ranges, left = left, right = right,
    a_signature = a_signature, b_signature = b_signature,
    padding = style.padding.y, entries = entries,
  }
  perf_end("diffview_connector_geometry_build", started, scope)
  return entries
end

local function overview_geometry(view, side)
  local buffer_view = side == "a" and view.buffer_view_a or view.buffer_view_b
  local blocks = cached_change_blocks(view, side, "overview")
  local signature = buffer_view:get_visual_metric_signature()
  local full_h = math.max(1, buffer_view:get_scrollable_size())
  local key = "__overview_geometry_" .. side
  local cache = view[key]
  if cache and cache.view == buffer_view and cache.blocks == blocks
    and cache.signature == signature and cache.full_h == full_h then
    return cache.entries
  end
  local started, scope = perf_begin("diffview_overview_geometry_build")
  local entries, lh = {}, buffer_view:get_line_height()
  for _, block in ipairs(blocks) do
    local start_row = visual_rows_before_line(buffer_view, block.start_line)
    local end_row = visual_rows_before_line(buffer_view, block.end_line)
      + visual_line_count(buffer_view, block.end_line)
    local first = common.clamp(start_row * lh / full_h, 0, 1)
    entries[#entries + 1] = {
      tag = block.tag, first = first,
      last = common.clamp(end_row * lh / full_h, first, 1),
    }
  end
  view[key] = {
    view = buffer_view, blocks = blocks, signature = signature, full_h = full_h, entries = entries,
  }
  perf_end("diffview_overview_geometry_build", started, scope)
  return entries
end

function DiffView:diff_points_of_interest(is_a)
  local changes = is_a and self.a_changes or self.b_changes
  local points = {}
  local side = is_a and "a" or "b"
  local buffer_view = is_a and self.buffer_view_a or self.buffer_view_b
  for _, range in ipairs(connector_ranges(self)) do
    -- Unchanged lines separate blocks, not changes in marker color.
    -- Empty sides use the boundary marker as their single stop.
    local first = range[side .. "_start"]
      or range[side .. "_next"] or #buffer_view.buffer.lines
    local last = range[side .. "_end"] or first
    for line = first, last, 30 do
      points[#points + 1] = {
        line = line,
        col = 1,
        line_only_navigation = true,
        scroll_to_line = true,
        kind = "diff-change",
        label = range.tag,
        change = changes[line],
      }
    end
  end
  return points
end

local function diff_decoration_provider(parent, is_a)
  local function background_color(tag)
    local color = diff_color(tag, true)
    if config.plugins.diffview.plain_text then color = alpha_color(color, 128) end
    return color
  end

  return {
    priority = 50,
    line_background = function(_, view, line)
      local changes = is_a and parent.a_changes or parent.b_changes
      local change = changes[line]
      if change and (change.tag == "delete" or change.tag == "insert") then
        return background_color(change.tag)
      end
    end,
    line_background_descriptor = function(_, view, line)
      local changes = is_a and parent.a_changes or parent.b_changes
      local change = changes[line]
      if not change or change.tag ~= "modify" then return nil end

      local model = parent.diff_model
      local mapping = is_a and model.a_to_b or model.b_to_a
      local other = is_a and parent.buffer_view_b or parent.buffer_view_a
      local other_text = other.buffer.lines[mapping[line]]
      local added_width = 0
      -- A pending edit can remove a paired line before the next comparison.
      if other_text and parent.diff_whitespace_mode == "none" then
        local indent = view.buffer.lines[line]:match("^[ \t]*")
        local other_indent = other_text:match("^[ \t]*")
        local font = view:get_font()
        local _, indent_size = view.buffer:get_indent_info()
        font:set_tab_size(indent_size)
        added_width = math.max(0, font:get_width(indent) - font:get_width(other_indent))
      end
      return {
        color = background_color("modify"),
        left_color = added_width > 0 and background_color(is_a and "delete" or "insert") or nil,
        -- Keep the changed indentation band on continuation rows too.
        -- The text origin includes the gutter; the background does not.
        x_offset = added_width - view:get_gutter_width(),
      }
    end,
    inline_ranges = function(_, view, line)
      local changes = is_a and parent.a_changes or parent.b_changes
      local change = changes[line]
      if not change or change.tag ~= "modify" or not change.inline_ranges then return nil end
      local ranges = {}
      local color = style.diff_modify_inline
      if config.plugins.diffview.plain_text then color = style.diff_modify end
      for _, range in ipairs(change.inline_ranges) do
        ranges[#ranges + 1] = { col1 = range.col1, col2 = range.col2, color = color }
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
    { view = self.buffer_view_a, is_a = true, id = "a" },
    { view = self.buffer_view_b, is_a = false, id = "b" },
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
      local reset = self.request.user_data and self.request.user_data.on_navigation_state_change
      if reset then reset() end
    end)
    side.view:add_scroll_listener(provider_id, function(view)
      self:sync_scroll_from(view, side.is_a)
    end)
    side.view:add_fold_listener(provider_id, function(view, event, fold, reason)
      self:on_core_fold_event(side.is_a, event, fold, reason)
    end)
    side.view:add_edit_guard(provider_id, function(view, reason)
      local content = self.request.contents[side.is_a and 1 or 2]
      if not self.side_editable[side.id] then
        return false, content_read_only_reason(content)
      end
      return true
    end)
    side.view.buffer:add_text_change_listener("diff-view-" .. side.id .. "-" .. tostring(self), {
      after_change = function()
        local reset = self.request.user_data and self.request.user_data.on_navigation_state_change
        if reset then reset() end
        self:update_diff(side.view)
      end,
    })
  end
end

function DiffView:dispose_integrations()
  if self.disposed then return end
  self.disposed = true
  for _, side in ipairs {
    { view = self.buffer_view_a, id = "a" },
    { view = self.buffer_view_b, id = "b" },
  } do
    side.view:remove_decoration_provider("diff-view")
    side.view:remove_poi_provider("diff-view")
    side.view:remove_selection_listener("diff-view")
    side.view:remove_scroll_listener("diff-view")
    side.view:remove_fold_listener("diff-view")
    side.view:remove_edit_guard("diff-view")
    side.view:remove_visual_row_provider("diff-gaps")
    side.view.buffer:remove_text_change_listener("diff-view-" .. side.id .. "-" .. tostring(self))
  end
  self.diff_generation = (self.diff_generation or 0) + 1
  self:cancel_diff_update()
  if self.request_assigned then
    if self.request and self.request.contents then
      call_assignment_hook(self.request.contents[1], "on_assigned", false, self.request, "left")
      call_assignment_hook(self.request.contents[2], "on_assigned", false, self.request, "right")
    end
    if self.request then call_assignment_hook(self.request, "on_assigned", false, { view = self }) end
    self.request_assigned = false
  end
end

function DiffView:dirty_confirmation_side_buffers(opts)
  opts = opts or {}
  local buffers = {}
  for i, buffer in ipairs(self.side_buffers or {}) do
    local content = self.request and self.request.contents and self.request.contents[i]
    local needs_confirmation = (self.side_owns and self.side_owns[i]) or (content and (content.kind == "file" or content.requires_dirty_confirmation))
    if needs_confirmation and not (opts.keep and opts.keep[buffer]) then
      buffers[#buffers + 1] = buffer
    end
  end
  return buffers
end

function DiffView:dispose_owned_buffers(opts)
  if self.owned_buffers_disposed then return end
  opts = opts or {}
  self.owned_buffers_disposed = true
  if core.buffer_registry then
    for buffer in pairs(self.retained_buffers or {}) do
      core.buffer_registry:release(buffer, self)
    end
  end
  self.retained_buffers = {}
  for buffer, owned in pairs(self.owned_buffers or {}) do
    if owned and not (opts.keep and opts.keep[buffer]) and buffer.on_close then buffer:on_close() end
  end
end

function DiffView:can_close(approve)
  prompt_dirty_buffers(self:dirty_confirmation_side_buffers(), function(confirmed)
    if not confirmed then return end
    return DiffView.super.can_close(self, approve)
  end)
end

function DiffView:on_close()
  self:dispose_integrations()
  self:dispose_owned_buffers()
  return DiffView.super.on_close(self)
end

local function redraw_thumb(view_scrollbar)
  view_scrollbar:draw_thumb()
end

function DiffView:get_divider_width()
  local connector_min_width = 36 * SCALE
  if config.show_line_numbers == false then return connector_min_width end
  local number_width = math.max(
    self.buffer_view_a:get_line_number_gutter_width(),
    self.buffer_view_b:get_line_number_gutter_width()
  )
  return math.max(connector_min_width, (number_width + style.padding.x * 1.5) * 2)
end

local function line_number_color(buffer, line)
  for _, line1, _, line2 in buffer:get_selections(true) do
    if line1 > line then break end
    if line >= line1 and line <= line2 then return style.line_number2 end
  end
  return style.line_number
end

local function draw_divider_side_line_numbers(buffer_view, folds, x, width)
  if config.show_line_numbers == false or width <= 0 then return end
  local minline, maxline = buffer_view:get_visible_line_range()
  local font = buffer_view:get_font()
  local fold_index = 1
  local fold = folds and folds[fold_index]
  local line = minline
  while line <= maxline do
    while fold and line > fold.hidden_end do
      fold_index = fold_index + 1
      fold = folds[fold_index]
    end
    if fold and line >= fold.hidden_start and line <= fold.hidden_end then
      local _, y = buffer_view:get_line_screen_position(fold.hidden_start)
      local fold_height = buffer_view:get_visual_row_height(
        buffer_view:get_visual_row(fold.hidden_start, 1, false)
      )
      if y + fold_height >= buffer_view.position.y and y <= buffer_view.position.y + buffer_view.size.y then
        common.draw_text(font, style.line_number, "…", "right", x, y, width - style.padding.x, fold_height)
      end
      line = fold.hidden_end + 1
    else
      local y, height = buffer_view:get_position_highlight_geometry(line, 1, false)
      if y + height >= buffer_view.position.y and y <= buffer_view.position.y + buffer_view.size.y then
        common.draw_text(font, line_number_color(buffer_view.buffer, line), line, "right", x, y, width - style.padding.x, height)
      end
      line = line + 1
    end
  end
end

function DiffView:draw_divider_line_numbers(x1, x2)
  if config.show_line_numbers == false then return end
  local center = x1 + (x2 - x1) / 2
  draw_divider_side_line_numbers(self.buffer_view_a, self.diff_folds_a, x1, center - x1)
  draw_divider_side_line_numbers(self.buffer_view_b, self.diff_folds_b, center, x2 - center)
end

function DiffView:draw_divider_changes()
  local left = self.buffer_view_a
  local right = self.buffer_view_b
  local x1 = left.position.x + left.size.x
  local x2 = right.position.x
  if x2 <= x1 then return end
  local started, scope = perf_begin("diffview_divider_draw")

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  renderer.draw_rect(x1, self.position.y, x2 - x1, self.size.y, style.background)

  local function draw_connector(tag, left_start_y, left_end_y, right_start_y, right_end_y)
    draw_curved_trapezium(
      x1, x2,
      left_start_y, left_end_y,
      right_start_y, right_end_y,
      diff_color(tag, true), self.position.y, self.position.y + self.size.y
    )
  end

  local _, a_offset = left:get_content_offset()
  local _, b_offset = right:get_content_offset()
  local top, bottom = self.position.y, self.position.y + self.size.y
  local marker_height = math.max(1, common.round(2 * SCALE))
  for _, entry in ipairs(connector_geometry(self)) do
    local a_start, a_end = entry.a_start + a_offset, entry.a_end + a_offset
    local b_start, b_end = entry.b_start + b_offset, entry.b_end + b_offset
    local a_top, a_bottom = normalize_marker_range(a_start, a_end)
    local b_top, b_bottom = normalize_marker_range(b_start, b_end)
    -- Curves stay between their endpoints. Keep connectors spanning the viewport,
    -- including connectors whose two sides are both outside it.
    if math.max(a_bottom, b_bottom) >= top - 1 and math.min(a_top, b_top) <= bottom + 1 then
      draw_connector(entry.tag, a_start, a_end, b_start, b_end)
    end
    if entry.tag == "delete" and b_start >= top - 1 and b_start - marker_height <= bottom + 1 then
      draw_gap_marker(right, b_start, style.diff_marker_delete)
    elseif entry.tag == "insert" and a_start >= top - 1 and a_start - marker_height <= bottom + 1 then
      draw_gap_marker(left, a_start, style.diff_marker_insert)
    end
  end

  self:draw_divider_line_numbers(x1, x2)

  local divider_width = math.max(1, common.round(style.divider_size or SCALE))
  local center = x1 + (x2 - x1) / 2
  renderer.draw_rect(center - divider_width / 2, self.position.y, divider_width, self.size.y, style.divider)
  core.pop_clip_rect()
  perf_end("diffview_divider_draw", started, scope)
end

function DiffView:draw_scrollbar()
  local started, scope = perf_begin("diffview_overview_draw")
  for _, side in ipairs { "a", "b" } do
    local view = side == "a" and self.buffer_view_a or self.buffer_view_b
    local scrollbar = view.v_scrollbar
    for _, marker in ipairs(overview_geometry(self, side)) do
      local color = overview_marker_color(marker.tag)

      if color then
        local x, marker_y, w, marker_h = scrollbar:get_overview_marker_rect(
          marker.first, marker.last
        )
        if x then
          local marker_w = math.max(
            common.round(2 * SCALE), math.min(w, common.round(5 * SCALE))
          )
          local marker_x = x + w - marker_w
          renderer.draw_rect(marker_x, marker_y, marker_w, marker_h, color)
        end
      end
    end
  end

  redraw_thumb(self.buffer_view_a.v_scrollbar)
  redraw_thumb(self.buffer_view_b.v_scrollbar)
  perf_end("diffview_overview_draw", started, scope)
end

function DiffView:reveal_change(direction)
  local points = self:diff_points_of_interest(false)
  local view, is_a = self.buffer_view_b, false
  if #points == 0 then
    points = self:diff_points_of_interest(true)
    view, is_a = self.buffer_view_a, true
  end
  local point = points[direction == -1 and #points or 1]
  if not point then return false end
  with_textview_selection(view, function()
    view.buffer:set_selection(point.line, point.col or 1, point.line, point.col or 1)
  end)
  if view.scroll_to_line then
    view:scroll_to_line(point.line, false, false)
  else
    view:scroll_to_make_visible(point.line, point.col or 1)
  end
  self:sync_scroll_from(view, is_a)
  core.log_quiet("Diff View revealed boundary change at line %d", point.line)
  return true
end

local function header_stat_items(stats)
  if not stats then return nil end
  if stats.total == 0 then return nil end

  local items = {}
  if stats.deleted > 0 then
    items[#items + 1] = {
      text = string.format("- %d", stats.deleted),
      color = common.blend_colors(style.text, style.diff_marker_delete),
    }
  end
  if stats.inserted > 0 then
    items[#items + 1] = {
      text = string.format("+ %d", stats.inserted),
      color = common.blend_colors(style.text, style.diff_marker_insert),
    }
  end
  if stats.changed > 0 then
    items[#items + 1] = {
      text = string.format("~ %d", stats.changed),
      color = common.blend_colors(style.text, style.diff_marker_modify),
    }
  end
  return items
end

local function header_items_width(font, items, gap)
  local width = 0
  for index, item in ipairs(items or {}) do
    if index > 1 then width = width + gap end
    width = width + font:get_width(item.text)
  end
  return width
end

local function truncate_header_title(font, title, max_width)
  if max_width <= 0 then return "" end
  if font:get_width(title) <= max_width then return title end
  local ellipsis = "..."
  if font:get_width(ellipsis) > max_width then return "" end
  local length = title:ulen()
  local low, high = 0, length
  while low < high do
    local middle = math.ceil((low + high) / 2)
    local prefix = title:usub(1, middle)
    if font:get_width(prefix .. ellipsis) <= max_width then
      low = middle
    else
      high = middle - 1
    end
  end
  return title:usub(1, low) .. ellipsis
end

local function draw_header_items(font, items, x, y, gap)
  local cursor = x
  for index, item in ipairs(items or {}) do
    if index > 1 then cursor = cursor + gap end
    renderer.draw_text(font, item.text, cursor, y, item.color)
    cursor = cursor + font:get_width(item.text)
  end
end

local function draw_diff_header(view)
  local font = style.prose_font
  local stat_font = style.get_small_font(font)
  local header_height = view.diff_header_height or 0
  if header_height <= 0 then return end

  local y = view.position.y + (header_height - font:get_height()) / 2
  local stat_y = view.position.y + (header_height - stat_font:get_height()) / 2
  local padding = style.padding.x
  local title_gap = font:get_width("  ")
  local stat_gap = stat_font:get_width("  ")
  local half_width = view.size.x / 2
  local side_width = math.max(0, half_width - view:get_divider_width() / 2)

  for index, side_view in ipairs { view.buffer_view_a, view.buffer_view_b } do
    local x = side_view.position.x + padding
    local available = math.max(0, side_width - padding * 2)
    local title = view:get_side_title(index)
    local items = index == 2 and header_stat_items(view:get_change_stats()) or nil
    if items then
      local items_width = header_items_width(stat_font, items, stat_gap)
      local title_width = math.max(0, available - items_width - title_gap)
      title = truncate_header_title(font, title, title_width)
      renderer.draw_text(font, title, x, y, style.dim)
      local items_x = x + available - items_width
      if items_width <= available then draw_header_items(stat_font, items, items_x, stat_y, stat_gap) end
    else
      title = truncate_header_title(font, title, available)
      renderer.draw_text(font, title, x, y, style.dim)
    end
  end
end

function DiffView:update()
  local started, scope = perf_begin("diffview_update")
  local super_started, super_scope = perf_begin("diffview_super_update")
  DiffView.super.update(self)
  perf_end("diffview_super_update", super_started, super_scope)
  if self.diff_whitespace_mode ~= config.plugins.diffview.whitespace_mode then
    self:update_diff()
  end
  local divider_half = self:get_divider_width() / 2

  self.buffer_view_a.position.x = self.position.x
  local header_height = style.prose_font:get_height() + style.padding.y
  self.diff_header_height = header_height
  self.buffer_view_a.position.y = self.position.y + header_height
  self.buffer_view_a.size.x = math.max(0, (self.size.x / 2) - divider_half)
  self.buffer_view_a.size.y = math.max(0, self.size.y - header_height)

  self.buffer_view_b.position.x = (self.position.x + self.size.x / 2) + divider_half
  self.buffer_view_b.position.y = self.position.y + header_height
  self.buffer_view_b.size.x = math.max(0, (self.size.x / 2) - divider_half)
  self.buffer_view_b.size.y = math.max(0, self.size.y - header_height)

  local gap_started, gap_scope = perf_begin("diffview_gap_update")
  self:refresh_core_gap_rows(false)
  perf_end("diffview_gap_update", gap_started, gap_scope)
  -- File History updates pending comparisons before placing them in a Pane.
  -- Wait for a usable layout so wrapping cannot move only one revealed side.
  if self.pending_first_change_reveal and self.diff_model
      and self.buffer_view_a.size.x > 0 and self.buffer_view_a.size.y > 0 then
    self.pending_first_change_reveal = false
    self:reveal_change(self.initial_change_direction)
  end
  -- Fast comparisons must not flash a loading message between frames.
  local loading_visible = not self.comparison_message
    and (not self.diff_model or self.pending_first_change_reveal)
    and self.diff_started_at ~= nil and system.get_time() - self.diff_started_at >= 1
  if self.diff_loading_visible ~= loading_visible then
    self.diff_loading_visible = loading_visible
    core.redraw = true
  end
  profile_textview_method(self.buffer_view_a, self.buffer_view_a.update, "diffview_left_update")
  profile_textview_method(self.buffer_view_b, self.buffer_view_b.update, "diffview_right_update")
  perf_end("diffview_update", started, scope)
end

function DiffView:draw()
  local started, scope = perf_begin("diffview_draw")
  local chrome_started, chrome_scope = perf_begin("diffview_draw_chrome")
  DiffView.super.draw(self)
  self:draw_background(style.background)
  draw_diff_header(self)
  if self.comparison_message then
    renderer.draw_text(
      style.prose_font, self.comparison_message,
      self.position.x + style.padding.x,
      self.position.y + (self.diff_header_height or 0) + style.padding.y,
      style.dim
    )
    perf_end("diffview_draw_chrome", chrome_started, chrome_scope)
    perf_end("diffview_draw", started, scope)
    return
  end
  if not self.diff_model or self.pending_first_change_reveal then
    if self.diff_loading_visible then
      renderer.draw_text(
        style.prose_font, "Computing differences...",
        self.position.x + style.padding.x,
        self.position.y + (self.diff_header_height or 0) + style.padding.y,
        style.dim
      )
    end
    perf_end("diffview_draw_chrome", chrome_started, chrome_scope)
    perf_end("diffview_draw", started, scope)
    return
  end
  perf_end("diffview_draw_chrome", chrome_started, chrome_scope)
  profile_textview_method(self.buffer_view_a, self.buffer_view_a.draw, "diffview_left_draw")
  profile_textview_method(self.buffer_view_b, self.buffer_view_b.draw, "diffview_right_draw")
  self:draw_divider_changes()
  self:draw_scrollbar()
  perf_end("diffview_draw", started, scope)
  local user_data = self.request and self.request.user_data
  if user_data and user_data.transition_trace then
    user_data.transition_trace("first_content_draw_complete")
    user_data.transition_trace = nil
  end
end


-- Helper functions to start file to file or string to string diff viewer.
local function start_compare()
  if not element_a or not element_b then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a, element_b, DiffView.type.FILE_FILE)
  panes.place(function() return view end, { placement = "current", focus = true, reason = "diff-compare" })
  element_a = nil
  element_b = nil
end

local function start_compare_string()
  if not element_a_text or not element_b_text then
    core.log("First select something to compare")
    return
  end
  local view = DiffView(element_a_text, element_b_text, DiffView.type.STRING_STRING)
  panes.place(function() return view end, { placement = "current", focus = true, reason = "diff-compare" })
  element_a_text = nil
  element_b_text = nil
end


-- Register file compare commands
local function current_file_text_view()
  local view = core.active_view
  if not (view and view.extends and view:extends(TextView)
      and view.buffer and view.buffer.abs_filename) then
    return nil
  end
  return view
end

command.add(function()
  local view = current_file_text_view()
  return view ~= nil, view
end, {
  ["diff:select_file_for_compare"] = command.palette(function(dv)
    element_a = dv.buffer.abs_filename
  end, {
    keywords = { "compare", "files" },
  }),
})

command.add(
  function()
    local view = element_a and current_file_text_view()
    return view ~= nil, view
  end, {
  ["diff:compare_file_with_selected"] = command.palette(function(dv)
    element_b = dv.buffer.abs_filename
    start_compare()
  end, {
    keywords = { "compare", "files" },
    opens_view = true,
  }),
})

command.add(nil, {
  ["diff:open_from_files"] = command.palette(function()
    command.perform("core:pick_file", "Select File A", function(file_a)
      element_a = file_a
      command.perform("core:pick_file", "Select File B", function(file_b)
        element_b = file_b
        start_compare()
      end)
    end)
  end, {
    keywords = { "compare", "files" },
    opens_view = true,
  })
})

command.add(nil, {
  ["diff:open_from_text"] = command.palette(function()
    element_a_text = ""
    element_b_text = ""
    start_compare_string()
  end, {
    keywords = { "compare", "text", "strings" },
    opens_view = true,
  })
})

local function open_blank_diff()
  local chain = MutableDiffRequestChain({
    title = "Blank Diff View",
    kind = "blank",
    contents = {
      content_blank({ name = "Left" }),
      content_blank({ name = "Right" }),
    },
    content_titles = { "Left", "Right" },
    editable_policy = "editable",
    preferred_focus_side = "right",
    user_data = {
      blank_diff = true,
      suppress_equal_contents_notification = true,
    },
  }, { blank_diff = true })
  return DiffRequestController(chain)
end

command.add(nil, {
  ["diff:open"] = command.palette(function()
    return open_blank_diff()
  end, {
    keywords = { "compare", "blank" },
    opens_view = true,
  }),
})

local function active_diff_controller()
  local view = core.active_view
  local parent = view and view.diff_view_parent or view
  if parent and parent.request_controller then return parent.request_controller end
end

local function replace_diff_side_with_file(side)
  local controller = active_diff_controller()
  if not controller then return end
  command.perform("core:pick_file", side == "left" and "Select Left File" or "Select Right File", function(file)
    if file then controller:replace_content(side, content_file(file), { title = common.basename(file) }) end
  end)
end

command.add(function()
  return active_diff_controller() ~= nil
end, {
  ["diff:replace_left_with_file"] = command.palette(function()
    replace_diff_side_with_file("left")
  end, { keywords = { "compare", "side", "file" } }),
  ["diff:replace_right_with_file"] = command.palette(function()
    replace_diff_side_with_file("right")
  end, { keywords = { "compare", "side", "file" } }),
})


local function navigate_diff_change(dv, direction)
  local poi = require "core.poi"
  local points = poi.points_for_view(dv, { source = "diff-view" }) or {}
  if #points == 0 then return poi.navigate(dv, direction) end
  direction = direction and direction < 0 and -1 or 1
  return with_textview_selection(dv, function()
    local line = dv.buffer:get_selection()
    local selected
    if direction > 0 then
      for _, point in ipairs(points) do
        if point.line > line then selected = point; break end
      end
    else
      for i = #points, 1, -1 do
        if points[i].line < line then selected = points[i]; break end
      end
    end
    if not selected then
      local callback = dv.diff_view_parent and dv.diff_view_parent.request
        and dv.diff_view_parent.request.user_data
        and dv.diff_view_parent.request.user_data.on_change_boundary
      if callback then return callback(direction, dv) end
      diff_status(direction > 0 and "No next change" or "No previous change")
      return true
    end
    dv.buffer:set_selection(selected.line, selected.col or 1, selected.line, selected.col or 1)
    if selected.scroll_to_line and dv.scroll_to_line then
      dv:scroll_to_line(selected.line, false, false)
    elseif dv.scroll_to_make_visible then
      dv:scroll_to_make_visible(selected.line, selected.col or 1)
    end
    return selected
  end)
end

-- Register change navigation commands.
command.add(
  function()
    return core.active_view
        and core.active_view:is(TextView)
        and core.active_view.diff_view_parent,
      core.active_view
  end, {
  ["diff:prev_change"] = function(dv)
    return navigate_diff_change(dv, -1)
  end,

  ["diff:next_change"] = function(dv)
    return navigate_diff_change(dv, 1)
  end
})

command.add(function()
  local view = core.active_view
  if view and view.diff_view_parent then return true, view.diff_view_parent end
  if view and view.is and view:is(DiffView) then return true, view end
  return false
end, {
  ["diff:toggle_folding"] = command.palette(function(view)
    view:toggle_folding()
  end, { keywords = { "compare", "fold", "unchanged" } }),
  ["diff:swap_sides"] = command.palette(function(view)
    if view.request_controller then return view.request_controller:swap_sides() end
    return view:swap_sides()
  end, { keywords = { "compare", "left", "right", "reverse" } }),
})

local function copy_diff_patch(scope_kind)
  local active = core.active_view
  local parent = active.diff_view_parent or (active:is(DiffView) and active)
  local view, source, unavailable, side = active, nil, nil, "right"
  if parent then
    view = active == parent and parent.buffer_view_b or active
    side = view == parent.buffer_view_a and "left" or "right"
    local a, b = parent.buffer_view_a.buffer, parent.buffer_view_b.buffer
    local titles = parent.request.content_titles or {}
    source = { before = a.lines, after = b.lines,
      before_name = titles[1] or a:get_name(), after_name = titles[2] or b:get_name() }
  else
    source, unavailable = require("plugins.gitdiff_highlight").get_patch_source(view.buffer)
  end
  if not source then diff_status(unavailable); return end
  local scope
  if scope_kind ~= "file" then
    scope = { side = side, intervals = {} }
    with_textview_selection(view, function()
      if scope_kind == "cursor" then
        local line = view.buffer:get_selection()
        scope.intervals[1] = { line, line }
      else
        for _, line1, col1, line2, col2 in view.buffer:get_selections(true) do
          if line1 ~= line2 or col1 ~= col2 then
            scope.intervals[#scope.intervals + 1] = { line1, line2 - (col2 == 1 and line2 > line1 and 1 or 0) }
          end
        end
      end
    end)
    if #scope.intervals == 0 then diff_status("Select text to copy its change blocks"); return end
  end
  local patch = require("plugins.diff.patch").build(source.before, source.after,
    source.before_name, source.after_name, scope)
  if not patch then diff_status("No changes to copy"); return end
  system.set_clipboard(patch)
  core.log_quiet("Copied %s diff patch: %d bytes", scope_kind, #patch)
  diff_status("Patch copied to clipboard")
end

command.add(function()
  local view = core.active_view
  return view and (view.diff_view_parent or view:is(DiffView)
    or require("core.file_context").is_editor_view(view)) and true or false
end, {
  ["diff:copy_diff_patch_under_cursor"] = command.palette(function()
    copy_diff_patch("cursor")
  end, { keywords = { "clipboard", "git", "hunk", "block", "caret" } }),
  ["diff:copy_diff_patch_for_selection"] = command.palette(function()
    copy_diff_patch("selection")
  end, { keywords = { "clipboard", "git", "hunk", "block", "selected" } }),
  ["diff:copy_diff_patch_for_file"] = command.palette(function()
    copy_diff_patch("file")
  end, { keywords = { "clipboard", "git", "unified", "share" } }),
})

local whitespace_mode_labels = {
  none = "None",
  trim = "Trim Whitespace",
  ignore = "Ignore All Whitespace",
}

command.add(function()
  local view = core.active_view
  if view and view.diff_view_parent then return true, view.diff_view_parent end
  if view and view.is and view:is(DiffView) then return true, view end
  return false
end, {
  ["diff:cycle_whitespace_mode"] = command.palette(function()
    local current = config.plugins.diffview.whitespace_mode
    local next_mode = current == "none" and "trim"
      or current == "trim" and "ignore"
      or "none"
    config.plugins.diffview.whitespace_mode = next_mode
  end, {
    keywords = { "compare", "spaces", "indentation", "formatting" },
  }),
})

command.set_status("diff:cycle_whitespace_mode", function()
  return whitespace_mode_labels[config.plugins.diffview.whitespace_mode] or "Trim Whitespace"
end)

local function active_diff_side()
  local side_view = core.active_view
  local parent = side_view and side_view.diff_view_parent
  if not parent then return nil end
  local index = side_view == parent.buffer_view_b and 2 or 1
  return parent, side_view, index, parent.request.contents[index]
end

diff_status = function(message)
  if core.status_bar and core.status_bar.show_message then
    core.status_bar:show_message("i", style.dim, message)
  else
    core.log_quiet("Diff View: %s", message)
  end
end

local function open_diff_source_at_caret()
  local _, side_view, _, content = active_diff_side()
  if not content then
    diff_status("This Diff Side has no current file")
    return false
  end
  local path = source_path_for_content(content)
  if not path then
    diff_status("This Diff Side has no current file")
    return false
  end
  local line, col = with_textview_selection(side_view, function()
    return side_view.buffer:get_selection(false)
  end)
  if content.kind == "fragment" then line = FragmentBuffer.map_line(side_view.buffer, line) end
  local buffer = content.kind == "buffer" and content.buffer
    or content.kind == "fragment" and content.buffer
    or core.open_buffer(path)
  local editor = Editor(buffer)
  panes.place(function() return editor end, {
    placement = "current", focus = true, reason = "diff-open-source",
  })
  editor:with_selection_state(function()
    buffer:set_selection(line, col or 1, line, col or 1)
  end)
  core.set_active_view(editor)
  return true
end

command.add(function()
  return active_diff_side() ~= nil
end, {
  ["diff:open_file_at_caret"] = command.palette(open_diff_source_at_caret, {
    keywords = { "compare", "source" },
    opens_view = true,
  }),
})

keymap.add({
  ["ctrl+r"] = "diff:toggle_folding",
  ["ctrl+return"] = "diff:open_file_at_caret",
  ["ctrl+keypad enter"] = "diff:open_file_at_caret",
})


-- Register text compare commands
local function text_select_compare_predicate()
  local is_textview = core.active_view
    and core.active_view:extends(TextView)
    and core.active_view.buffer
  local has_selection = is_textview and core.active_view.buffer:has_any_selection()
  return has_selection, has_selection and core.active_view.buffer
end

local function text_compare_with_predicate()
  local is_textview = (element_a_text and core.active_view)
    and (core.active_view:extends(TextView) and core.active_view.buffer)
  local has_selection = is_textview and core.active_view.buffer:has_any_selection()
  return has_selection, has_selection and core.active_view.buffer
end

command.add(text_select_compare_predicate, {
  ["diff:select_text_for_compare"] = command.palette(function(buffer)
    element_a_text = buffer:get_selection_text()
  end, {
    keywords = { "compare", "text", "selection" },
  }),
})

command.add(text_compare_with_predicate, {
  ["diff:compare_text_with_selected"] = command.palette(function(buffer)
    element_b_text = buffer:get_selection_text()
    start_compare_string()
  end, {
    keywords = { "compare", "text", "selection" },
    opens_view = true,
  }),
})

local function current_selected_text_side()
  local view = core.active_view
  if not (view and view.extends and view:extends(TextView) and view.buffer
      and view.buffer:has_any_selection()) then
    return nil
  end
  return view
end

local function selection_fragment_content(view)
  local line1, col1, line2, col2 = view:with_selection_state(function()
    return view.buffer:get_selection(true)
  end)
  if line2 < line1 or (line1 == line2 and col2 < col1) then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  return content_fragment(view.buffer, line1, col1, line2, col2, {
    name = common.basename(view.buffer.abs_filename or view.buffer:get_name()) .. " selection",
  })
end

local function open_clipboard_comparison(view, selection_only)
  if not view then return false end
  local clipboard = (system.get_clipboard() or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local current = selection_only and selection_fragment_content(view)
    or content_buffer(view.buffer, {
      name = common.basename(view.buffer.abs_filename),
      source_path = view.buffer.abs_filename,
    })
  local chain = MutableDiffRequestChain({
    title = "Clipboard Comparison",
    kind = "clipboard",
    contents = {
      content_text(clipboard, { name = "Clipboard", editable = true }),
      current,
    },
    content_titles = { "Clipboard", current.name },
    editable_policy = "content",
    preferred_focus_side = "left",
    user_data = { clipboard_comparison = true },
  })
  DiffRequestController(chain)
  return true
end

command.add(function()
  local view = current_selected_text_side()
  return view ~= nil, view
end, {
  ["diff:compare_selection_with_clipboard"] = command.palette(function(view)
    return open_clipboard_comparison(view, true)
  end, {
    keywords = { "compare", "selection", "clipboard" },
    opens_view = true,
  }),
})

command.add(function()
  local view = current_file_text_view()
  return view ~= nil, view
end, {
  ["diff:compare_file_with_clipboard"] = command.palette(function(view)
    return open_clipboard_comparison(view, false)
  end, {
    keywords = { "compare", "file", "clipboard" },
    opens_view = true,
  }),
})



local present_diff_view
local diffview

local side_names = { left = 1, right = 2, base = 3, a = 1, b = 2, [1] = 1, [2] = 2, [3] = 3 }

local function side_index(side)
  return side_names[side] or side
end

MutableDiffRequestChain = {}
MutableDiffRequestChain.__index = MutableDiffRequestChain

function MutableDiffRequestChain:new(request, opts)
  opts = opts or {}
  local normalized, err = validate_request(request)
  if not normalized then error(err, 2) end
  local chain = setmetatable({}, self)
  chain.request = normalized
  chain.contents = { normalized.contents[1], normalized.contents[2], normalized.contents[3] }
  chain.content_titles = normalized.content_titles and { normalized.content_titles[1], normalized.content_titles[2], normalized.content_titles[3] } or nil
  chain.user_data = common.merge({}, normalized.user_data or {})
  chain.user_data.blank_diff = opts.blank_diff or chain.user_data.blank_diff
  return chain
end

setmetatable(MutableDiffRequestChain, { __call = function(cls, ...) return cls:new(...) end })

function MutableDiffRequestChain:set_content(side, content, opts)
  opts = opts or {}
  local idx = assert(side_index(side), "invalid diff side")
  self.contents[idx] = content
  if opts.title then
    self.content_titles = self.content_titles or {}
    self.content_titles[idx] = opts.title
  end
end

function MutableDiffRequestChain:put_user_data(key, value)
  self.user_data[key] = value
end

function MutableDiffRequestChain:get_user_data(key)
  return self.user_data[key]
end

function MutableDiffRequestChain:build_request(opts)
  opts = opts or {}
  local request = common.merge({}, self.request)
  request.contents = { self.contents[1], self.contents[2], self.contents[3] }
  request.content_titles = self.content_titles and { self.content_titles[1], self.content_titles[2], self.content_titles[3] } or nil
  request.user_data = common.merge(common.merge({}, self.user_data), opts.user_data or {})
  request.metadata = nil
  return request
end

DiffRequestController = {}
DiffRequestController.__index = DiffRequestController

local function request_owned_buffer_keep_set(request)
  local keep = {}
  for _, content in ipairs(request.contents or {}) do
    if content.kind == "buffer" and content.owns_buffer then keep[content.buffer] = true end
  end
  return keep
end

function DiffRequestController:new(chain, opts)
  opts = opts or {}
  local controller = setmetatable({}, self)
  controller.chain = chain
  controller.disposed = false
  controller:reload(opts)
  return controller
end

setmetatable(DiffRequestController, { __call = function(cls, ...) return cls:new(...) end })

function DiffRequestController:get_view()
  return self.view
end

function DiffRequestController:reload(opts)
  opts = opts or {}
  if self.disposed then return nil, "diff request controller is disposed" end
  local old_view = self.view
  if old_view then
    old_view:save_diff_fold_state()
    self.chain.user_data = common.merge(self.chain.user_data or {}, old_view.request and old_view.request.user_data or {})
  end
  local request = self.chain:build_request(opts)
  request._defer_assignment = old_view ~= nil
  local view, err = diffview.open(request, true)
  if not view then return nil, err end
  view.request_controller = self
  self.view = view

  local attached = false
  local pane = old_view and panes.pane_for_view(old_view)
  if pane then
    panes.place(function() return view end, {
      pane = pane,
      placement = "current",
      focus = true,
      reason = "diff-reload",
    })
    attached = true
  elseif not opts.noshow then
    present_diff_view(view)
    attached = true
  end
  if old_view then
    old_view:dispose_integrations()
    old_view:dispose_owned_buffers({ keep = request_owned_buffer_keep_set(request) })
  end
  view:assign_request()
  if attached and panes.pane_for_view(view) then
    local focus_side = request.preferred_focus_side == "left" and view.buffer_view_a or view.buffer_view_b
    core.set_active_view(focus_side or view)
  elseif attached then
    core.log_quiet("Diff comparison: kept source focus while View placement is pending or canceled")
  end
  return view
end

function DiffRequestController:adopt_current_side(side)
  local idx = side_index(side)
  local view = self.view
  if not (idx and view) then return end
  local buffer = idx == 1 and view.buffer_view_a.buffer or view.buffer_view_b.buffer
  local owns = view.side_owns and view.side_owns[idx]
  local title = view.request.content_titles and view.request.content_titles[idx]
  local old_content = view.request.contents and view.request.contents[idx]
  if old_content and old_content.kind == "fragment" then
    local range = FragmentBuffer.source_range(buffer)
    if range then
      self.chain:set_content(idx, content_fragment(
        old_content.buffer,
        range.line1, range.col1, range.line2, range.col2,
        {
          name = title or buffer:get_name(), editable = old_content.editable,
          read_only_reason = old_content.read_only_reason,
          source_path = old_content.source_path,
        }
      ))
      return
    end
  end
  local adopted = content_buffer(buffer, {
    name = title or buffer:get_name(),
    owns_buffer = owns == true,
    editable = old_content and old_content.editable,
    read_only_reason = old_content and old_content.read_only_reason,
    syntax_hint = old_content and old_content.syntax_hint,
    source_path = old_content and old_content.source_path,
  })
  if old_content and (old_content.kind == "file" or old_content.requires_dirty_confirmation) then
    adopted.requires_dirty_confirmation = true
  end
  self.chain:set_content(idx, adopted)
end

function DiffRequestController:replace_content(side, content, opts)
  opts = opts or {}
  local idx = assert(side_index(side), "invalid diff side")
  local other = idx == 1 and 2 or 1
  local function finish()
    self:adopt_current_side(other)
    self.chain:set_content(idx, content, opts)
    return self:reload(opts)
  end
  local view = self.view
  local buffer = view and view.side_buffers and view.side_buffers[idx]
  local old_content = view and view.request and view.request.contents and view.request.contents[idx]
  local owns = view and view.side_owns and view.side_owns[idx]
  local needs_confirmation = owns or (old_content and (old_content.kind == "file" or old_content.requires_dirty_confirmation))
  if needs_confirmation and buffer_needs_dirty_prompt(buffer) then
    prompt_dirty_buffers({ buffer }, function(confirmed)
      if confirmed then finish() end
    end)
    return nil, "pending-confirmation"
  end
  return finish()
end

function DiffRequestController:try_close(callback)
  local view = self.view
  if not view then if callback then callback(true) end; return end
  view:try_close(function()
    self.disposed = true
    self.view = nil
    if callback then callback(true) end
  end)
end

function DiffRequestController:dispose()
  if self.disposed then return end
  self.disposed = true
  if self.view then
    self.view:dispose_integrations()
    self.view:dispose_owned_buffers()
    self.view = nil
  end
end

---Functionality to view the textual differences of two elements.
---@class plugins.diffview
diffview = {
  ---The differences viewer exposed for extensiblity.
  ---@type plugins.diffview.view
  Viewer = DiffView,
  MutableDiffRequestChain = MutableDiffRequestChain,
  DiffRequestController = DiffRequestController,
  content = {},
}

diffview.content.text = content_text
diffview.content.file = content_file
diffview.content.buffer = content_buffer
diffview.content.fragment = content_fragment
diffview.content.blank = content_blank
diffview.content.empty = content_empty

diffview.normalize_request = normalize_request
diffview.validate_request = validate_request

function diffview.open(request, noshow)
  local normalized, err = validate_request(request)
  if not normalized then return nil, err end
  local view = DiffView(normalized)
  if not noshow then
    present_diff_view(view)
  end
  return view
end

---Present a Diff View in the active Pane.
---@param view plugins.diffview.view
present_diff_view = function(view)
  panes.place(function() return view end, {
    placement = "current",
    focus = true,
    reason = "diff-open",
  })
end

function DiffRequestController:swap_sides()
  if self.disposed then return false end
  self:adopt_current_side(1)
  self:adopt_current_side(2)
  self.chain.contents[1], self.chain.contents[2] = self.chain.contents[2], self.chain.contents[1]
  if self.chain.content_titles then
    self.chain.content_titles[1], self.chain.content_titles[2] =
      self.chain.content_titles[2], self.chain.content_titles[1]
  end
  return self:reload() ~= nil
end

function diffview.from_state(state)
  if not (state and state.kind == "blank_diff") then return nil end
  local chain = MutableDiffRequestChain({
    title = state.title or "Blank Diff View",
    kind = "blank",
    contents = {
      content_blank({
        text = state.left_text or "", name = state.content_titles and state.content_titles[1] or "Left",
        untitled_id = state.left_untitled_id,
      }),
      content_blank({
        text = state.right_text or "", name = state.content_titles and state.content_titles[2] or "Right",
        untitled_id = state.right_untitled_id,
      }),
    },
    content_titles = state.content_titles or { "Left", "Right" },
    editable_policy = "editable",
    preferred_focus_side = state.preferred_focus_side,
    user_data = { blank_diff = true, suppress_equal_contents_notification = true },
  }, { blank_diff = true })
  local controller = DiffRequestController(chain, { noshow = true })
  return controller:get_view()
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
    present_diff_view(view)
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
