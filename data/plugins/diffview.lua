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
local MutableDiffRequestChain
local DiffRequestController

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
  return { kind = "text", text = text or "", name = opts.name, editable = opts.editable, owns_doc = true, read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint }
end

local function content_file(path, opts)
  opts = opts or {}
  return { kind = "file", filename = path, name = opts.name or (path and common.basename(path) or nil), editable = opts.editable, owns_doc = false, read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint }
end

local function content_document(doc, opts)
  opts = opts or {}
  return { kind = "document", doc = doc, name = opts.name, editable = opts.editable, owns_doc = opts.owns_doc == true, read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint }
end

local function content_blank(opts)
  opts = opts or {}
  return { kind = "blank", name = opts.name, editable = opts.editable ~= false, owns_doc = true, read_only_reason = opts.read_only_reason, syntax_hint = opts.syntax_hint }
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
  local kind = content.kind
  if kind == "text" then
    if content.text ~= nil and type(content.text) ~= "string" then
      return nil, string.format("diff content %d text must be a string", index)
    end
  elseif kind == "blank" or kind == "empty" then
    -- valid mutable blank-document content
  elseif kind == "file" then
    if type(content.filename) ~= "string" or content.filename == "" then
      return nil, string.format("diff content %d file content requires a filename", index)
    end
  elseif kind == "document" then
    if not content.doc then
      return nil, string.format("diff content %d document content requires a doc", index)
    end
    if not (content.doc.is and content.doc:is(Doc)) then
      return nil, string.format("diff content %d document content requires a Doc", index)
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
  if request.contents[1].kind == "document" and request.contents[2].kind == "document"
      and request.contents[1].doc == request.contents[2].doc then
    return nil, "diff request cannot use the same document on both sides"
  end
  local function comparable_content_path(content)
    local path
    if content.kind == "file" then
      path = content.filename
    elseif content.kind == "document" then
      path = content.doc.abs_filename
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

local function prompt_dirty_docs(docs, callback)
  local dirty = {}
  for _, doc in ipairs(docs or {}) do
    if doc and doc.is_dirty and doc:is_dirty() then dirty[#dirty + 1] = doc end
  end
  if #dirty == 0 then callback(true); return end
  local names = {}
  for _, doc in ipairs(dirty) do names[#names + 1] = doc:get_name() end
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
  core.log_quiet("Diff View close/replacement waiting for dirty owned docs: %s", table.concat(names, ", "))
end

local function doc_for_content(content, title)
  local doc_name = title_for_content(content, title)
  if content.kind == "document" then return assert(content.doc), content.owns_doc == true end
  if content.kind == "file" then return Doc(doc_name, content.filename), false end
  local doc = Doc(nil, nil, true)
  doc.display_name = doc_name
  local text = (content.kind == "empty" or content.kind == "blank") and "" or (content.text or "")
  if text ~= "" then doc:insert(1, 1, text) end
  doc:clear_undo_redo()
  doc:clean()
  doc.new_file = false
  return doc, true
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
  DiffView.super.new(self)

  self.scrollable = true
  local request, request_err = validate_request(type(a) == "table" and a.contents and a or legacy_request(a, b, compare_type, names))
  if not request then error(request_err, 2) end
  self.request = request
  self.compare_type = self.request.compare_type or compare_type or DiffView.type.STRING_STRING
  self.hovered_sync = nil
  self.skip_update_diff = false
  self.diff_generation = 0
  self.disposed = false
  self.request_assigned = false

  local doc_a, owns_a = doc_for_content(self.request.contents[1], self.request.content_titles and self.request.content_titles[1])
  local doc_b, owns_b = doc_for_content(self.request.contents[2], self.request.content_titles and self.request.content_titles[2])
  self.side_docs = { doc_a, doc_b }
  self.side_owns = { owns_a, owns_b }
  self.owned_docs = { [doc_a] = owns_a, [doc_b] = owns_b }

  self.doc_view_a = DocView(doc_a)
  self.doc_view_b = DocView(doc_b)
  self.side_editable = {
    a = content_editable(self.request, self.request.contents[1]),
    b = content_editable(self.request, self.request.contents[2]),
  }

  self.doc_view_a.diff_view_parent = self
  self.doc_view_b.diff_view_parent = self

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

    if self.diff_equal_blocks and self.diff_fold_identity_counts then self:save_diff_fold_state() end
    self.expanded_diff_folds = {}
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
  if to.can_edit and not to:can_edit("diff sync", { warn = true }) then return false end

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
  local a_lines = view.doc_view_a and view.doc_view_a.doc and view.doc_view_a.doc.lines or {}
  local b_lines = view.doc_view_b and view.doc_view_b.doc and view.doc_view_b.doc.lines or {}
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
  local a_lines = view.doc_view_a and view.doc_view_a.doc and view.doc_view_a.doc.lines or {}
  local b_lines = view.doc_view_b and view.doc_view_b.doc and view.doc_view_b.doc.lines or {}
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
  clear_core_diff_folds(self.doc_view_a)
  clear_core_diff_folds(self.doc_view_b)
  self.diff_folds_a = build_diff_folds(self, candidates, identity_counts, "a", opts, state_map)
  self.diff_folds_b = build_diff_folds(self, candidates, identity_counts, "b", opts, state_map)
  install_core_diff_folds(self.doc_view_a, self.diff_folds_a, "a")
  install_core_diff_folds(self.doc_view_b, self.diff_folds_b, "b")
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
    side.view:add_edit_guard(provider_id, function(view, reason)
      local content = self.request.contents[side.is_a and 1 or 2]
      if not self.side_editable[side.id] then
        return false, content_read_only_reason(content)
      end
      return true
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
    side.view:remove_edit_guard("diff-view")
    side.view:remove_visual_row_provider("diff-gaps")
    side.view.doc:remove_text_change_listener("diff-view-" .. side.id .. "-" .. tostring(self))
  end
  self.diff_generation = (self.diff_generation or 0) + 1
  if self.request_assigned then
    if self.request and self.request.contents then
      call_assignment_hook(self.request.contents[1], "on_assigned", false, self.request, "left")
      call_assignment_hook(self.request.contents[2], "on_assigned", false, self.request, "right")
    end
    if self.request then call_assignment_hook(self.request, "on_assigned", false, { view = self }) end
    self.request_assigned = false
  end
end

function DiffView:dirty_confirmation_side_docs(opts)
  opts = opts or {}
  local docs = {}
  for i, doc in ipairs(self.side_docs or {}) do
    local content = self.request and self.request.contents and self.request.contents[i]
    local needs_confirmation = (self.side_owns and self.side_owns[i]) or (content and (content.kind == "file" or content.requires_dirty_confirmation))
    if needs_confirmation and not (opts.keep and opts.keep[doc]) then
      docs[#docs + 1] = doc
    end
  end
  return docs
end

function DiffView:dispose_owned_docs(opts)
  if self.owned_docs_disposed then return end
  opts = opts or {}
  self.owned_docs_disposed = true
  for doc, owned in pairs(self.owned_docs or {}) do
    if owned and not (opts.keep and opts.keep[doc]) and doc.on_close then doc:on_close() end
  end
end

function DiffView:try_close(do_close)
  prompt_dirty_docs(self:dirty_confirmation_side_docs(), function(confirmed)
    if not confirmed then return end
    return DiffView.super.try_close(self, function(...)
      self:dispose_integrations()
      self:dispose_owned_docs()
      return do_close(...)
    end)
  end)
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
    preferred_focus_side = "left",
    user_data = {
      blank_diff = true,
      suppress_equal_contents_notification = true,
    },
  }, { blank_diff = true })
  return DiffRequestController(chain)
end

command.add(nil, {
  ["diff-view:open-blank-diff"] = function()
    return open_blank_diff()
  end,
})

local function active_diff_controller()
  local view = core.active_view
  local parent = view and view.diff_view_parent or view
  if parent and parent.request_controller then return parent.request_controller end
end

local function replace_diff_side_with_file(side)
  local controller = active_diff_controller()
  if not controller then return end
  command.perform("core:open-file", side == "left" and "Select Left File" or "Select Right File", function(file)
    if file then controller:replace_content(side, content_file(file), { title = common.basename(file) }) end
  end)
end

command.add(function()
  return active_diff_controller() ~= nil
end, {
  ["diff-view:replace-left-with-file"] = function()
    replace_diff_side_with_file("left")
  end,
  ["diff-view:replace-right-with-file"] = function()
    replace_diff_side_with_file("right")
  end,
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



local compare_add_to_root_node
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

local function request_owned_doc_keep_set(request)
  local keep = {}
  for _, content in ipairs(request.contents or {}) do
    if content.kind == "document" and content.owns_doc then keep[content.doc] = true end
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

  local node, idx
  if old_view then
    node = core.root_panel.root_node:get_node_for_view(old_view)
    idx = node and node:get_view_idx(old_view)
  end
  local attached = false
  if node and idx then
    node.views[idx] = view
    if node.tab_bar and node.tab_bar.invalidate_layout_cache then node.tab_bar:invalidate_layout_cache() end
    node:set_active_view(view)
    attached = true
  elseif not opts.noshow then
    compare_add_to_root_node(view)
    attached = true
  end
  if old_view then
    old_view:dispose_integrations()
    old_view:dispose_owned_docs({ keep = request_owned_doc_keep_set(request) })
  end
  view:assign_request()
  if attached then
    local focus_side = request.preferred_focus_side == "right" and view.doc_view_b or view.doc_view_a
    core.set_active_view(focus_side or view)
  end
  return view
end

function DiffRequestController:adopt_current_side(side)
  local idx = side_index(side)
  local view = self.view
  if not (idx and view) then return end
  local doc = idx == 1 and view.doc_view_a.doc or view.doc_view_b.doc
  local owns = view.side_owns and view.side_owns[idx]
  local title = view.request.content_titles and view.request.content_titles[idx]
  local old_content = view.request.contents and view.request.contents[idx]
  local adopted = content_document(doc, {
    name = title or doc:get_name(),
    owns_doc = owns == true,
    editable = old_content and old_content.editable,
    read_only_reason = old_content and old_content.read_only_reason,
    syntax_hint = old_content and old_content.syntax_hint,
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
  local doc = view and view.side_docs and view.side_docs[idx]
  local old_content = view and view.request and view.request.contents and view.request.contents[idx]
  local owns = view and view.side_owns and view.side_owns[idx]
  local needs_confirmation = owns or (old_content and (old_content.kind == "file" or old_content.requires_dirty_confirmation))
  if needs_confirmation and doc and doc:is_dirty() then
    prompt_dirty_docs({ doc }, function(confirmed)
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
    self.view:dispose_owned_docs()
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
diffview.content.document = content_document
diffview.content.blank = content_blank
diffview.content.empty = content_empty

diffview.normalize_request = normalize_request
diffview.validate_request = validate_request

function diffview.open(request, noshow)
  local normalized, err = validate_request(request)
  if not normalized then return nil, err end
  local view = DiffView(normalized)
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
