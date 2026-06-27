-- mod-version:3
-- Project Git View shell with permanent Log tab.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"
local GitModel = require "plugins.git.model"
local filetree_render = require "plugins.filetree.render"

local GitView = View:extend()

local function reject_read_only_edit()
  return false
end

local function make_pane_doc(name)
  local doc = Doc(nil, nil, true)
  doc.git_view_pane_read_only = true
  doc.git_view_pane_name = name
  doc.apply_edits = reject_read_only_edit
  doc.text_input = reject_read_only_edit
  doc.ime_text_editing = reject_read_only_edit
  doc.insert = reject_read_only_edit
  doc.remove = reject_read_only_edit
  doc.replace = reject_read_only_edit
  doc.replace_cursor = reject_read_only_edit
  doc.save = reject_read_only_edit
  doc.is_dirty = function() return false end
  doc.get_name = function(self) return self.git_view_pane_name or "Git Pane" end
  return doc
end

local function set_doc_lines(doc, lines)
  local text = table.concat(lines or {}, "\n")
  if text ~= "" then text = text .. "\n" end
  if doc.git_view_pane_text == text then return end
  doc.git_view_pane_text = text
  doc.lines = {}
  if text == "" then
    doc.lines[1] = "\n"
  else
    for line in text:gmatch("[^\n]*\n") do doc.lines[#doc.lines + 1] = line end
  end
  doc:clear_undo_redo()
  doc:clean()
  local current_line = doc:get_selection()
  local line = math.max(1, math.min(#doc.lines, current_line or 1))
  doc:set_selection(line, 1, line, 1)
end

function GitView:new(project, opts)
  GitView.super.new(self)
  opts = opts or {}
  self.project = project
  self.model = opts.model or GitModel.new(project, opts)
  self.tab_id = opts.tab_id or "log"
  if opts.on_update then
    self.model.on_update = opts.on_update
  elseif not opts.model or not self.model.on_update then
    self.model.on_update = function() core.redraw = true end
  end
  self.scrollable = true
  if not opts.defer_refresh and self.tab_id == "log" then self:set_refresh_pending() end
end

function GitView:__tostring()
  return "GitView"
end

function GitView:model_tab()
  return self.model:find_tab(self.tab_id) or (self.tab_id == "log" and self.model:log_tab() or nil)
end

function GitView:pane_view(name)
  self.pane_views = self.pane_views or {}
  local view = self.pane_views[name]
  if not view then
    view = DocView(make_pane_doc("Git " .. name))
    view.git_owner_view = self
    view.git_pane = name
    view.get_gutter_width = function() return 0 end
    view.draw_line_gutter = function(v) return v:get_line_height() end
    local draw_line_text = view.draw_line_text
    view.draw_line_text = function(v, line, x, y)
      if v.git_pane == "file-list" then
        local meta = v.git_file_line_meta and v.git_file_line_meta[line]
        if meta then
          local text = (v.doc:get_utf8_line(line) or ""):gsub("\n$", "")
          if filetree_render.draw_row_text(v, text, x, y, meta.kind, meta.type == "dir") then
            return v:get_line_height()
          end
        end
      end
      return draw_line_text(v, line, x, y)
    end
    local draw_line_body = view.draw_line_body
    view.draw_line_body = function(v, line, x, y)
      if v.git_pane == "file-list" then
        local meta = v.git_file_line_meta and v.git_file_line_meta[line]
        local gw = v:get_gutter_width()
        filetree_render.draw_folder_row_background(v, meta and meta.type == "dir", x + v.scroll.x, y, math.max(0, v.size.x - gw))
      end
      return draw_line_body(v, line, x, y)
    end
    view.get_line_hint = function(v, line)
      if v.git_pane ~= "file-list" then return nil end
      local meta = v.git_file_line_meta and v.git_file_line_meta[line]
      if not meta then return nil end
      if meta.type == "dir" and meta.stat then
        return filetree_render.changed_stat_segments(meta.stat, v:get_font())
      end
      local index = v.git_file_line_to_index and v.git_file_line_to_index[line]
      local file = index and v.git_file_records and v.git_file_records[index]
      return filetree_render.changed_stat_segments(file and file.stat, v:get_font())
    end
    self.pane_views[name] = view
  end
  view.git_owner_view = self
  return view
end

function GitView:set_pane_lines(name, lines)
  local view = self:pane_view(name)
  set_doc_lines(view.doc, lines)
  return view
end

function GitView:activate_model_tab(callback)
  local tab = self:model_tab()
  if tab and self.model.active_tab ~= tab.id then self.model:select_tab(tab.id, callback) end
  return tab
end

function GitView:get_name()
  local tab = self:model_tab()
  if not tab then return "Git" end
  if tab and tab.id ~= "log" then return tab.title or tab.kind or "Git" end
  local path = type(self.project) == "table" and self.project.path or tostring(self.project or "")
  return "Git Log: " .. common.basename(path)
end

function GitView:set_refresh_pending(callback)
  if callback then
    self.refresh_callbacks = self.refresh_callbacks or {}
    self.refresh_callbacks[#self.refresh_callbacks + 1] = callback
  end
  if self.refresh_inflight then return end
  if self.refresh_started and not callback then return end
  self.refresh_started = true
  self.refresh_inflight = true
  self.model:refresh_log(function(_, err)
    self.refresh_inflight = false
    local callbacks = self.refresh_callbacks or {}
    self.refresh_callbacks = nil
    for _, cb in ipairs(callbacks) do cb(self, err) end
    core.redraw = true
  end)
end

function GitView:get_focus_view()
  local active = core.active_view
  if active and active.git_owner_view == self then return active end
  if self.focused_pane_name and self.pane_views and self.pane_views[self.focused_pane_name] then
    return self.pane_views[self.focused_pane_name]
  end
  local tab = self.model and self:model_tab()
  if self.focus_pane == "diff" and tab and tab.kind == "commit_diff" then
    if tab.loading_file or tab.file_error or (tab.left_text == nil and tab.right_text == nil) then
      self.focused_diff_doc_view = nil
      return self
    end
    local diff = self:ensure_diff_view(tab)
    if core.active_view and (core.active_view == diff.doc_view_a or core.active_view == diff.doc_view_b) then
      return core.active_view
    end
    if self.focused_diff_doc_view == diff.doc_view_a or self.focused_diff_doc_view == diff.doc_view_b then
      return self.focused_diff_doc_view
    end
    self.focused_diff_doc_view = nil
    return diff and diff.get_focus_view and diff:get_focus_view() or self
  end
  return self
end

local function active_leaf_view(node)
  if not node then return nil end
  if node.type == "leaf" then return node.active_view or node.views and node.views[1] end
  return active_leaf_view(node.a) or active_leaf_view(node.b)
end

function GitView:try_close(callback)
  if self.tab_id == "log" then
    if self.tool_window and not self.tool_window.__main_tabs then
      self.tool_window:hide()
      return false
    end
    if self.tool_window and self.tool_window.__main_tabs then
      local tw = self.tool_window
      local active_before = core.active_view
      local active_owner_before = active_before and (active_before.git_owner_view or active_before)
      local active_was_session_view = false
      for _, session_view in pairs(tw.git_tab_views or {}) do
        if active_owner_before == session_view then active_was_session_view = true; break end
      end
      if callback then callback() end
      local function remove_from_node(node, view)
        if not (node and view) then return false end
        if node.type == "leaf" then
          for i = #(node.views or {}), 1, -1 do
            if node.views[i] == view then
              table.remove(node.views, i)
              if node.active_view == view then node.active_view = node.views[i] or node.views[#node.views] end
              return true
            end
          end
          return false
        end
        return remove_from_node(node.a, view) or remove_from_node(node.b, view)
      end
      local root = tw.root and tw.root.root_node
      for _, view in pairs(tw.git_tab_views or {}) do
        if view ~= self then remove_from_node(root, view) end
      end
      tw.git_tab_views = {}
      tw.git_view = nil
      tw.git_model = nil
      tw.hidden = true
      if core.main_tabs and core.main_tabs.git_sessions then core.main_tabs.git_sessions[tw.project_key] = nil end
      if active_was_session_view then
        local main = core.root_panel and core.root_panel.get_main_panel and core.root_panel:get_main_panel()
        if main and main.active_view and main.active_view ~= self then
          core.set_active_view(main.active_view)
        elseif core.main_tabs and tw.root == core.root_panel then
          core.main_tabs.blank_main_editor(true)
        else
          core.active_view = nil
        end
      end
      return true
    end
    if callback then callback() end
    return true
  end
  for i, tab in ipairs(self.model.tabs) do
    if tab.id == self.tab_id and tab.closable then
      table.remove(self.model.tabs, i)
      if self.tool_window and self.tool_window.git_tab_views then
        self.tool_window.git_tab_views[self.tab_id] = nil
      end
      if callback then callback() end
      if self.model.active_tab == self.tab_id then
        local active = core.active_view and (core.active_view.git_owner_view or core.active_view)
        if not (active and active.model == self.model and active.tab_id and self.model:find_tab(active.tab_id)) then
          active = active_leaf_view(self.tool_window and self.tool_window.root and self.tool_window.root.root_node)
        end
        if active and active.model == self.model and active.tab_id and self.model:find_tab(active.tab_id) then
          self.model.active_tab = active.tab_id
        else
          self.model.active_tab = "log"
        end
      end
      core.redraw = true
      return true
    end
  end
  if callback then callback() end
  return true
end

function GitView:commit_list_y()
  return self.position.y + style.padding.y
    + style.font:get_height() + style.padding.y
end

function GitView:row_height()
  return style.font:get_height() + 2 * SCALE
end

function GitView:get_scrollable_size()
  local active = self:model_tab()
  if active and (active.kind == "commit_diff" or active.kind == "file_history") then return self.size.y end
  local tab = self.model:log_tab()
  local rows = #tab.commits + ((tab.has_more or tab.loading_more) and 1 or 0)
  return self.size.y + math.max(0, rows * self:row_height() - (self.size.y - (self:commit_list_y() - self.position.y)))
end

function GitView:on_mouse_wheel(y, x)
  self:activate_model_tab(function() core.redraw = true end)
  local active = core.active_view
  if active and active.git_owner_view == self and active.git_pane and active.on_mouse_wheel then
    return active:on_mouse_wheel(y, x) ~= false
  end
  local tab = self.model:selected_tab()
  if tab and tab.kind == "file_history" then
    if y == 0 then return false end
    self:clamp_history_scroll(tab)
    local visible = self:history_visible_height()
    local max_scroll = math.max(0, (#(tab.commits or {}) + ((tab.has_more or tab.loading) and 1 or 0)) * self:row_height() - visible)
    tab.scroll = common.clamp((tab.scroll or 0) + (-y * config.mouse_wheel_scroll), 0, max_scroll)
    return true
  end
  if tab and tab.kind == "commit_diff" then
    if tab.file_list_hover then
      if y == 0 then return false end
      local visible = self.size.y - (self:commit_list_y() - self.position.y) - style.padding.y
      local max_scroll = math.max(0, #(tab.changed_files or {}) * self:row_height() - visible)
      tab.file_scroll = common.clamp((tab.file_scroll or 0) + (-y * config.mouse_wheel_scroll), 0, max_scroll)
      return true
    end
    if tab.diff_view and tab.diff_view.on_mouse_wheel then
      return tab.diff_view:on_mouse_wheel(y, x) ~= false
    end
    return false
  end
  if y == 0 then return false end
  self.scroll.to.y = self.scroll.to.y + (-y * config.mouse_wheel_scroll)
  return true
end

function GitView:on_mouse_moved(x, y, dx, dy)
  self:activate_model_tab(function() core.redraw = true end)
  if self.mouse_pane and self.mouse_pane.on_mouse_moved then
    return self.mouse_pane:on_mouse_moved(x, y, dx, dy)
  end
  local tab = self.model:selected_tab()
  if tab and tab.kind == "commit_diff" then
    local list_width = math.floor(self.size.x * 0.28)
    tab.file_list_hover = x <= self.position.x + list_width
    if not tab.file_list_hover and tab.diff_view and tab.diff_view.on_mouse_moved then
      return tab.diff_view:on_mouse_moved(x, y, dx, dy)
    end
    return true
  end
  return GitView.super.on_mouse_moved(self, x, y, dx, dy)
end

function GitView:on_mouse_released(button, x, y)
  self:activate_model_tab(function() core.redraw = true end)
  if self.mouse_pane then
    local pane = self.mouse_pane
    self.mouse_pane = nil
    if pane.on_mouse_released then return pane:on_mouse_released(button, x, y) end
    return true
  end
  local tab = self.model:selected_tab()
  if tab and tab.kind == "commit_diff" and tab.diff_view and tab.diff_view.on_mouse_released then
    return tab.diff_view:on_mouse_released(button, x, y)
  end
  return GitView.super.on_mouse_released(self, button, x, y)
end

function GitView:pane_at_point(x, y)
  for _, view in pairs(self.pane_views or {}) do
    if x >= view.position.x and x <= view.position.x + view.size.x
      and y >= view.position.y and y <= view.position.y + view.size.y
    then
      return view
    end
  end
end

function GitView:on_mouse_pressed(button, x, y, clicks)
  self:activate_model_tab(function() core.redraw = true end)
  self:update_pane_docs()
  local pane = self:pane_at_point(x, y)
  if pane then
    self.focused_pane_name = pane.git_pane
    self.focus_pane = "doc"
    core.set_active_view(pane)
    local content_click = false
    if button == "left" and pane.doc and pane.resolve_screen_position then
      local cmd = clicks == 2 and "doc:set-cursor-word" or clicks and clicks >= 3 and "doc:set-cursor-line" or "doc:set-cursor"
      content_click = command.perform(cmd, x, y, clicks)
    end
    self.mouse_pane = pane
    if not content_click then pane:on_mouse_pressed(button, x, y, clicks) end
    self:sync_selection_from_pane()
    if clicks and clicks > 1 and pane.git_pane ~= "details" and self.activate_selected then
      local active_tab = self.model:selected_tab()
      local diff_tab = self:activate_selected(function() core.redraw = true end)
      if active_tab.kind ~= "commit_diff" and diff_tab and self.on_model_tab_open then self:on_model_tab_open(diff_tab) end
    end
    core.redraw = true
    return true
  end
  local selected_tab = self.model:selected_tab()
  local list_width = math.floor(self.size.x * 0.45)
  if selected_tab and selected_tab.kind == "file_history" then
    local list_width = math.floor(self.size.x * 0.45)
    if button ~= "left" then return true end
    if x < self.position.x or x > self.position.x + list_width then return true end
    if y < self:history_commits_y() then return true end
    self:clamp_history_scroll(selected_tab)
    local index = math.floor((y - self:history_commits_y() + (selected_tab.scroll or 0)) / self:row_height()) + 1
    if index >= 1 and index <= #(selected_tab.commits or {}) then
      selected_tab.selected_commit = index
      selected_tab.selected_commit_hash = selected_tab.commits[index] and selected_tab.commits[index].hash or nil
      self.model:load_selected_commit_changed_files(function() core.redraw = true end)
      if clicks and clicks > 1 then
        local tab = self.model:open_commit_diff(selected_tab.commits[index], function() core.redraw = true end)
        if tab and self.on_model_tab_open then self:on_model_tab_open(tab) end
      end
      core.redraw = true
    elseif index == #(selected_tab.commits or {}) + 1 and selected_tab.has_more then
      self.model:load_file_history(selected_tab, function() core.redraw = true end)
    end
    return true
  end

  if selected_tab and selected_tab.kind == "commit_diff" then
    list_width = math.floor(self.size.x * 0.28)
    if x > self.position.x + list_width then
      if not self:focus_diff_pane() then return true end
      if selected_tab.diff_view and selected_tab.diff_view.on_mouse_pressed then
        local result = selected_tab.diff_view:on_mouse_pressed(button, x, y, clicks)
        if core.active_view and core.active_view.git_owner_view == self then self.focused_diff_doc_view = core.active_view end
        return result == true
      end
      return true
    end
    if button ~= "left" then return true end
    if x < self.position.x then return true end
    self.focus_pane = "list"
    self.focused_diff_doc_view = nil
    local line = math.floor((y - self:commit_list_y() + (selected_tab.file_scroll or 0)) / self:row_height()) + 1
    local index = selected_tab.file_line_to_index and selected_tab.file_line_to_index[line] or line
    if index >= 1 and index <= #(selected_tab.changed_files or {}) then
      self.model:select_diff_file(selected_tab, index, function() core.redraw = true end)
      core.redraw = true
    end
    return true
  end

  if button ~= "left" then return true end
  local scrollbar_handled = GitView.super.on_mouse_pressed(self, button, x, y, clicks)
  if scrollbar_handled then return true end
  local tab = self.model:log_tab()
  if x < self.position.x or x > self.position.x + list_width then return true end
  local row_height = self:row_height()
  local index = math.floor((y - self:commit_list_y() + self.scroll.y) / row_height) + 1
  if index >= 1 and index <= #tab.commits then
    local commit = self.model:select_log_index(index, function() core.redraw = true end)
    if clicks and clicks > 1 and commit then
      local tab = self.model:open_commit_diff(commit, function() core.redraw = true end)
      if tab and self.on_model_tab_open then self:on_model_tab_open(tab) end
      self.scroll.to.y, self.scroll.y = 0, 0
    end
    core.redraw = true
  elseif index == #tab.commits + 1 and tab.has_more then
    self.model:load_more_log(function() core.redraw = true end)
  end
  return true
end

local function commit_label(commit)
  local hash = commit.short_hash or commit.hash or ""
  local subject = commit.subject or ""
  return string.format("%s  %s", hash, subject)
end

local function tab_label(tab)
  return (tab.id == "log" and "Log" or tab.title or tab.kind or "Tab")
end

local function file_label(file, path)
  local status = file and (file.status or file.kind or file.raw_status or file.xy) or ""
  path = path or (file and (file.path or file.new_path or file.old_path) or "")
  return string.format("%s  %s", status, path)
end

local function changed_file_path(file)
  return file and (file.path or file.new_path or file.old_path) or ""
end

local function changed_file_kind(file)
  return file and (file.status or file.kind or file.raw_status or file.xy) or nil
end

local function split_path(path)
  local parts = {}
  path = tostring(path or "")
  for part in path:gmatch("[^/\\]+") do parts[#parts + 1] = part end
  if #parts == 0 and path ~= "" then parts[1] = path end
  return parts
end

local function clone_stat(stat)
  if not stat then return nil end
  return { additions = stat.additions or 0, deletions = stat.deletions or 0 }
end

local function add_stat(total, stat)
  if not stat then return total end
  total = total or { additions = 0, deletions = 0 }
  total.additions = total.additions + (stat.additions or 0)
  total.deletions = total.deletions + (stat.deletions or 0)
  return total
end

local function changed_file_tree_lines(files)
  local lines = {}
  local line_to_index = {}
  local index_to_line = {}
  local line_meta = {}
  local open_folders = {}
  local folder_lines = {}
  for index, file in ipairs(files or {}) do
    local path = changed_file_path(file)
    local parts = split_path(path)
    local kind = changed_file_kind(file)
    if #parts == 0 then
      lines[#lines + 1] = file_label(file)
      line_to_index[#lines] = index
      index_to_line[index] = #lines
      line_meta[#lines] = { type = "file", kind = kind }
    else
      local prefix = ""
      for depth = 1, #parts - 1 do
        prefix = prefix == "" and parts[depth] or (prefix .. "/" .. parts[depth])
        if not open_folders[depth] or open_folders[depth] ~= prefix then
          for i = depth, #open_folders do open_folders[i] = nil end
          lines[#lines + 1] = string.rep("\t", depth - 1) .. parts[depth]
          line_meta[#lines] = { type = "dir", kind = kind, stat = clone_stat(file and file.stat) }
          folder_lines[prefix] = #lines
          open_folders[depth] = prefix
        else
          local line = folder_lines[prefix]
          if line and line_meta[line] then
            line_meta[line].stat = add_stat(line_meta[line].stat, file and file.stat)
            line_meta[line].kind = filetree_render.stronger_git_kind(line_meta[line].kind, kind)
          end
        end
      end
      lines[#lines + 1] = string.rep("\t", math.max(0, #parts - 1)) .. parts[#parts]
      line_to_index[#lines] = index
      index_to_line[index] = #lines
      line_meta[#lines] = { type = "file", kind = kind }
    end
  end
  return lines, line_to_index, index_to_line, line_meta
end

local function append_changed_file_tree_lines(lines, files)
  local tree = changed_file_tree_lines(files)
  for _, line in ipairs(tree) do lines[#lines + 1] = line end
end

local function commit_details_lines(commit)
  local lines = { "Details" }
  if not commit then
    lines[#lines + 1] = "Select a commit"
    return lines
  end
  lines[#lines + 1] = commit.subject or ""
  lines[#lines + 1] = "Hash: " .. tostring(commit.hash or "")
  if commit.author_name and commit.author_name ~= "" then lines[#lines + 1] = "Author: " .. commit.author_name end
  if commit.refs and commit.refs ~= "" then lines[#lines + 1] = "Refs: " .. commit.refs end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Changed files"
  if commit.changed_files_loading then
    lines[#lines + 1] = "Loading changed files..."
  elseif commit.changed_files_error then
    lines[#lines + 1] = "Git error: " .. tostring(commit.changed_files_error.message or commit.changed_files_error.kind or commit.changed_files_error)
  elseif #(commit.changed_files or {}) == 0 then
    lines[#lines + 1] = commit.changed_files_loaded and "No changed files" or "Select a commit to load changed files"
  else
    append_changed_file_tree_lines(lines, commit.changed_files or {})
  end
  return lines
end

function GitView:detail_commit_for_tab(tab)
  if not tab then return nil end
  if tab.kind == "file_history" then
    local commit = tab.commits and tab.commits[tab.selected_commit]
    if tab.selected_commit_hash and (not commit or commit.hash ~= tab.selected_commit_hash) then return nil end
    return commit
  end
  local log_tab = self.model:log_tab()
  local commit = log_tab.commits and log_tab.commits[log_tab.selected_commit]
  if log_tab.selected_commit_hash and (not commit or commit.hash ~= log_tab.selected_commit_hash) then return nil end
  return commit
end

local function sync_inactive_pane_line(view, line)
  if core.active_view == view then return end
  line = math.max(1, math.min(#view.doc.lines, tonumber(line) or 1))
  local current_line, current_col = view.doc:get_selection()
  if current_line ~= line then
    view.doc:set_selection(line, math.max(1, math.min(current_col or 1, #view.doc.lines[line])))
  end
end

function GitView:sync_selection_from_pane()
  local active = core.active_view
  if not (active and active.git_owner_view == self and active.git_pane) then return end
  local line = active.doc and active.doc:get_selection() or 1
  local tab = self:model_tab()
  if active.git_pane == "log-list" then
    local log_tab = self.model:log_tab()
    if line >= 1 and line <= #(log_tab.commits or {}) and line ~= log_tab.selected_commit then
      self.model:select_log_index(line, function() core.redraw = true end)
    end
  elseif active.git_pane == "history-list" and tab and tab.kind == "file_history" then
    if line >= 1 and line <= #(tab.commits or {}) and line ~= tab.selected_commit then
      tab.selected_commit = line
      tab.selected_commit_hash = tab.commits[line] and tab.commits[line].hash or nil
      self.model:load_selected_commit_changed_files(function() core.redraw = true end)
    end
  elseif active.git_pane == "file-list" and tab and tab.kind == "commit_diff" then
    local index = active.git_file_line_to_index and active.git_file_line_to_index[line]
    if not index and not active.git_file_line_to_index then index = line end
    if index and index >= 1 and index <= #(tab.changed_files or {}) and index ~= tab.selected_file then
      self.model:select_diff_file(tab, index, function() core.redraw = true end)
    end
  end
end

function GitView:activate_selected(callback)
  self:sync_selection_from_pane()
  self:activate_model_tab(function() core.redraw = true end)
  local tab = self.model:selected_tab()
  if tab.kind == "commit_diff" then
    local active = core.active_view
    if active and active.git_owner_view == self and active.git_pane == "file-list" then
      local line = active.doc and active.doc:get_selection() or 1
      if active.git_file_line_to_index and not active.git_file_line_to_index[line] then return nil end
    end
    self.model:load_selected_diff_file(tab, callback or function() core.redraw = true end)
    return tab
  end
  return self.model:open_selected_commit_diff(callback or function() core.redraw = true end)
end

function GitView:update_pane_docs()
  local tab = self:model_tab()
  if not tab then return end
  if tab.kind == "file_history" then
    local lines = {}
    if tab.loading and #(tab.commits or {}) == 0 then
      lines[1] = "Loading file history..."
    elseif tab.error then
      lines[1] = "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error)
    elseif #(tab.commits or {}) == 0 then
      lines[1] = "No file history"
    else
      for _, commit in ipairs(tab.commits or {}) do lines[#lines + 1] = commit_label(commit) end
      if tab.loading then lines[#lines + 1] = "Loading more commits..." elseif tab.has_more then lines[#lines + 1] = "Load more commits..." end
    end
    local list_view = self:set_pane_lines("history-list", lines)
    sync_inactive_pane_line(list_view, tab.selected_commit)
    self:set_pane_lines("details", commit_details_lines(self:detail_commit_for_tab(tab)))
  elseif tab.kind == "commit_diff" then
    local lines = {}
    tab.file_line_to_index = nil
    tab.file_index_to_line = nil
    tab.file_line_meta = nil
    if tab.loading then
      lines[1] = "Loading changed files..."
    elseif tab.error then
      lines[1] = "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error)
    elseif #(tab.changed_files or {}) == 0 then
      lines[1] = "No changed files"
    else
      local line_to_index, index_to_line, line_meta
      lines, line_to_index, index_to_line, line_meta = changed_file_tree_lines(tab.changed_files or {})
      tab.file_line_to_index = line_to_index
      tab.file_index_to_line = index_to_line
      tab.file_line_meta = line_meta
    end
    local list_view = self:set_pane_lines("file-list", lines)
    list_view.git_file_line_to_index = tab.file_line_to_index or {}
    list_view.git_file_index_to_line = tab.file_index_to_line or {}
    list_view.git_file_line_meta = tab.file_line_meta or {}
    list_view.git_file_records = tab.changed_files or {}
    sync_inactive_pane_line(list_view, list_view.git_file_index_to_line[tab.selected_file] or tab.selected_file)
  else
    local log_tab = self.model:log_tab()
    local lines = {}
    if log_tab.loading then
      lines[1] = "Loading Git log..."
    elseif log_tab.error then
      lines[1] = "Git error: " .. tostring(log_tab.error.message or log_tab.error.kind or log_tab.error)
    elseif #log_tab.commits == 0 then
      lines[1] = "No commits"
    else
      for _, commit in ipairs(log_tab.commits) do lines[#lines + 1] = commit_label(commit) end
      if log_tab.loading_more then lines[#lines + 1] = "Loading more commits..." elseif log_tab.has_more then lines[#lines + 1] = "Load more commits..." end
    end
    local list_view = self:set_pane_lines("log-list", lines)
    sync_inactive_pane_line(list_view, log_tab.selected_commit)
    self:set_pane_lines("details", commit_details_lines(self:detail_commit_for_tab(log_tab)))
  end
end

function GitView:update()
  self:update_pane_docs()
  self:sync_selection_from_pane()
  for _, view in pairs(self.pane_views or {}) do view:update() end
  GitView.super.update(self)
end

function GitView:select_relative(delta)
  self:activate_model_tab(function() core.redraw = true end)
  local tab = self.model:selected_tab()
  delta = tonumber(delta) or 0
  if tab.kind == "log" then
    if #tab.commits == 0 then return nil end
    local index = common.clamp((tab.selected_commit or 1) + delta, 1, #tab.commits)
    local commit = self.model:select_log_index(index, function() core.redraw = true end)
    local row_y = (index - 1) * self:row_height()
    local visible = self.size.y - (self:commit_list_y() - self.position.y) - style.padding.y
    self.scroll.to.y = common.clamp(self.scroll.to.y, math.max(0, row_y - visible + self:row_height()), row_y)
    self.scroll.y = self.scroll.to.y
    core.redraw = true
    return commit
  elseif tab.kind == "file_history" then
    if #(tab.commits or {}) == 0 then return nil end
    local index = common.clamp((tab.selected_commit or 1) + delta, 1, #tab.commits)
    tab.selected_commit = index
    tab.selected_commit_hash = tab.commits[index] and tab.commits[index].hash or nil
    self.model:load_selected_commit_changed_files(function() core.redraw = true end)
    local row_y = (index - 1) * self:row_height()
    local visible = self:history_visible_height()
    tab.scroll = common.clamp(tab.scroll or 0, math.max(0, row_y - visible + self:row_height()), row_y)
    core.redraw = true
    return tab.commits[index]
  elseif tab.kind == "commit_diff" then
    if #(tab.changed_files or {}) == 0 then return nil end
    local file = self.model:select_diff_file(tab, (tab.selected_file or 1) + delta, function() core.redraw = true end)
    self:update_pane_docs()
    local list = self:pane_view("file-list")
    local line = list.git_file_index_to_line and list.git_file_index_to_line[tab.selected_file] or tab.selected_file or 1
    if core.active_view == list then list.doc:set_selection(line, 1, line, 1) end
    local row_y = (line - 1) * self:row_height()
    local visible = self.size.y - (self:commit_list_y() - self.position.y) - style.padding.y
    tab.file_scroll = common.clamp(tab.file_scroll or 0, math.max(0, row_y - visible + self:row_height()), row_y)
    core.redraw = true
    return file
  end
end

function GitView:tab_rects(x, y)
  local rects = {}
  local cursor = x + style.font:get_width("Tabs: ")
  for _, tab in ipairs(self.model.tabs) do
    local label = tab_label(tab)
    if tab.id == self.model.active_tab then label = "[" .. label .. "]" end
    local width = style.font:get_width(label)
    rects[#rects + 1] = { tab = tab, x = cursor, y = y, w = width, h = style.font:get_height() }
    cursor = cursor + width + style.font:get_width(" ")
  end
  return rects
end

function GitView:tab_at_point(px, py)
  local x = self.position.x + style.padding.x
  local y = self.position.y + style.padding.y + style.font:get_height() + style.padding.y
  for _, rect in ipairs(self:tab_rects(x, y)) do
    if px >= rect.x and px <= rect.x + rect.w and py >= rect.y and py <= rect.y + rect.h then
      return rect.tab
    end
  end
end

function GitView:draw_tabs(x, y)
  renderer.draw_text(style.font, "Tabs:", x, y, style.dim)
  for _, rect in ipairs(self:tab_rects(x, y)) do
    local color = rect.tab.id == self.model.active_tab and style.accent or style.dim
    local label = tab_label(rect.tab)
    if rect.tab.id == self.model.active_tab then label = "[" .. label .. "]" end
    renderer.draw_text(style.font, label, rect.x, y, color)
  end
end

function GitView:draw_commit_details(commit, x, y, width)
  renderer.draw_text(style.font, "Details", x, y, style.text)
  y = y + style.font:get_height() + style.padding.y
  if not commit then
    renderer.draw_text(style.font, "Select a commit", x, y, style.dim)
    return
  end
  renderer.draw_text(style.font, commit.subject or "", x, y, style.text)
  y = y + style.font:get_height() + 2 * SCALE
  renderer.draw_text(style.font, "Hash: " .. tostring(commit.hash or ""), x, y, style.dim)
  y = y + style.font:get_height() + 2 * SCALE
  if commit.author_name and commit.author_name ~= "" then
    renderer.draw_text(style.font, "Author: " .. commit.author_name, x, y, style.dim)
    y = y + style.font:get_height() + 2 * SCALE
  end
  if commit.refs and commit.refs ~= "" then
    renderer.draw_text(style.font, "Refs: " .. commit.refs, x, y, style.dim)
    y = y + style.font:get_height() + 2 * SCALE
  end
  y = y + style.padding.y
  renderer.draw_text(style.font, "Changed files", x, y, style.text)
  y = y + style.font:get_height() + style.padding.y
  if commit.changed_files_loading then
    renderer.draw_text(style.font, "Loading changed files...", x, y, style.dim)
    return
  end
  if commit.changed_files_error then
    renderer.draw_text(style.font, "Git error: " .. tostring(commit.changed_files_error.message or commit.changed_files_error.kind or commit.changed_files_error), x, y, style.error)
    return
  end
  local files = commit.changed_files or {}
  if #files == 0 then
    renderer.draw_text(style.font, commit.changed_files_loaded and "No changed files" or "Select a commit to load changed files", x, y, style.dim)
    return
  end
  for _, file in ipairs(files) do
    local label = file.path or file.new_path or file.old_path or ""
    renderer.draw_text(style.font, string.format("%s  %s", file.kind or file.status or file.xy or "", label), x, y, style.text)
    y = y + style.font:get_height() + 2 * SCALE
    if y > self.position.y + self.size.y - style.font:get_height() then break end
  end
end

function GitView:draw_log_tab(tab, x, y)
  local list_width = math.floor(self.size.x * 0.45)
  local detail_x = self.position.x + list_width + style.padding.x
  local list_right = detail_x - style.padding.x
  local top = self:commit_list_y()
  local list = self:pane_view("log-list")
  local details = self:pane_view("details")
  list.position.x, list.position.y = x, top
  list.size.x, list.size.y = math.max(0, list_width - style.padding.x), self.position.y + self.size.y - top - style.padding.y
  details.position.x, details.position.y = detail_x + style.padding.x, self.position.y + style.padding.y
  details.size.x, details.size.y = self.position.x + self.size.x - details.position.x - style.padding.x, self.size.y - style.padding.y * 2
  list:draw()
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)
  details:draw()
end

function GitView:ensure_diff_view(tab)
  if tab.diff_view and tab.diff_view_seen_generation == tab.diff_generation then
    if tab.diff_view.doc_view_a then tab.diff_view.doc_view_a.git_owner_view = self end
    if tab.diff_view.doc_view_b then tab.diff_view.doc_view_b.git_owner_view = self end
    if self.focused_diff_doc_view ~= tab.diff_view.doc_view_a and self.focused_diff_doc_view ~= tab.diff_view.doc_view_b then
      self.focused_diff_doc_view = nil
    end
    return tab.diff_view
  end
  local diffview = require "plugins.diffview"
  local view = diffview.string_to_string(tab.left_text or "", tab.right_text or "", tab.left_name, tab.right_name, true)
  tab.diff_view = view
  tab.diff_view_seen_generation = tab.diff_generation
  if view.doc_view_a then view.doc_view_a.git_owner_view = self end
  if view.doc_view_b then view.doc_view_b.git_owner_view = self end
  if self.focused_diff_doc_view ~= view.doc_view_a and self.focused_diff_doc_view ~= view.doc_view_b then
    self.focused_diff_doc_view = nil
  end
  return view
end

local function with_tool_window_event_window(tw, fn)
  local previous_event_window = core.event_window
  local previous_active_window = core.active_window
  local window = tw and tw.window
  local ok = false
  if window and system.get_window_id then ok = pcall(system.get_window_id, window) end
  if ok then
    core.event_window = window
  else
    core.event_window = core.window
    if previous_active_window == window then core.active_window = core.window end
  end
  local result = fn()
  core.event_window = previous_event_window
  return result
end

function GitView:focus_diff_pane(side)
  local tab = self:activate_model_tab(function() core.redraw = true end) or self:model_tab()
  if not (tab and tab.kind == "commit_diff") then return false end
  if tab.loading_file or tab.file_error or (tab.left_text == nil and tab.right_text == nil) then return false end
  local view = self:ensure_diff_view(tab)
  local focus
  if side == "right" or side == "b" or side == 2 then
    focus = view and view.doc_view_b
  elseif side == "left" or side == "a" or side == 1 then
    focus = view and view.doc_view_a
  else
    focus = self.focused_diff_doc_view or view and view.get_focus_view and view:get_focus_view()
  end
  if not focus then return false end
  self.focused_pane_name = nil
  self.focus_pane = "diff"
  self.focused_diff_doc_view = focus
  focus.git_owner_view = self
  return with_tool_window_event_window(self.tool_window, function()
    core.set_active_view(focus)
    if core.active_view then core.active_view.git_owner_view = self end
    return true
  end)
end

function GitView:can_focus_next_pane()
  local tab = self:model_tab()
  if not tab then return false end
  if tab.kind == "commit_diff" then return true end
  return tab.kind == "log" or tab.kind == "file_history"
end

function GitView:focus_pane_view(name)
  self:update_pane_docs()
  local view = self:pane_view(name)
  self.focused_pane_name = name
  self.focus_pane = "doc"
  view.git_owner_view = self
  return with_tool_window_event_window(self.tool_window, function()
    core.set_active_view(view)
    return true
  end)
end

function GitView:focus_next_pane()
  local tab = self:activate_model_tab(function() core.redraw = true end) or self:model_tab()
  if not tab then return false end
  local active = core.active_view
  if active ~= self and not (active and active.git_owner_view == self) then active = nil end
  if tab.kind == "commit_diff" then
    local list = self:pane_view("file-list")
    if tab.loading_file or tab.file_error or (tab.left_text == nil and tab.right_text == nil) then
      return active == list and false or self:focus_pane_view("file-list")
    end
    local diff = self:ensure_diff_view(tab)
    if active == self then
      return self:focus_pane_view("file-list")
    elseif active == list then
      return self:focus_diff_pane("left")
    elseif active == diff.doc_view_a then
      return self:focus_diff_pane("right")
    elseif active == diff.doc_view_b then
      return self:focus_pane_view("file-list")
    end
    return self:focus_pane_view("file-list")
  elseif tab.kind == "file_history" then
    local list, details = self:pane_view("history-list"), self:pane_view("details")
    return self:focus_pane_view(active == list and "details" or "history-list")
  else
    local list, details = self:pane_view("log-list"), self:pane_view("details")
    return self:focus_pane_view(active == list and "details" or "log-list")
  end
end

function GitView:focus_list_pane()
  local tab = self:model_tab()
  self.focus_pane = "list"
  if tab and tab.kind == "file_history" then return self:focus_pane_view("history-list") end
  if tab and tab.kind == "commit_diff" then return self:focus_pane_view("file-list") end
  return self:focus_pane_view("log-list")
end

function GitView:history_commits_y()
  return self:commit_list_y() + style.font:get_height() + style.padding.y
end

function GitView:history_visible_height()
  return self.size.y - (self:history_commits_y() - self.position.y) - style.padding.y
end

function GitView:clamp_history_scroll(tab)
  if not tab then return end
  local rows = #(tab.commits or {}) + ((tab.has_more or tab.loading) and 1 or 0)
  local max_scroll = math.max(0, rows * self:row_height() - self:history_visible_height())
  tab.scroll = common.clamp(tab.scroll or 0, 0, max_scroll)
end

function GitView:draw_history_tab(tab, x, y)
  local list_width = math.floor(self.size.x * 0.45)
  local detail_x = self.position.x + list_width + style.padding.x
  local list_right = detail_x - style.padding.x
  local top = self:history_commits_y()
  renderer.draw_text(style.font, tab.relpath or "", x, y, style.text)
  local list = self:pane_view("history-list")
  local details = self:pane_view("details")
  list.position.x, list.position.y = x, top
  list.size.x, list.size.y = math.max(0, list_width - style.padding.x), self.position.y + self.size.y - top - style.padding.y
  details.position.x, details.position.y = detail_x + style.padding.x, self.position.y + style.padding.y
  details.size.x, details.size.y = self.position.x + self.size.x - details.position.x - style.padding.x, self.size.y - style.padding.y * 2
  list:draw()
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)
  details:draw()
end

function GitView:draw_diff_tab(tab, x, y)
  local list_width = math.floor(self.size.x * 0.28)
  local diff_x = self.position.x + list_width + style.padding.x
  local list_right = diff_x - style.padding.x
  local diff_y = self:commit_list_y()
  local list = self:pane_view("file-list")
  list.position.x, list.position.y = x, diff_y
  list.size.x, list.size.y = math.max(0, list_width - style.padding.x), self.position.y + self.size.y - diff_y - style.padding.y
  list:draw()
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)

  local diff_w = self.position.x + self.size.x - diff_x - style.padding.x
  local diff_h = self.position.y + self.size.y - diff_y - style.padding.y
  if tab.loading_file then
    renderer.draw_text(style.font, "Loading file diff...", diff_x + style.padding.x, diff_y, style.dim)
    return
  end
  if tab.file_error then
    renderer.draw_text(style.font, "Git error: " .. tostring(tab.file_error.message or tab.file_error.kind or tab.file_error), diff_x + style.padding.x, diff_y, style.error)
    return
  end
  if tab.left_text == nil and tab.right_text == nil then
    renderer.draw_text(style.font, "Select a changed file", diff_x + style.padding.x, diff_y, style.dim)
    return
  end
  local view = self:ensure_diff_view(tab)
  view.position.x, view.position.y = diff_x, diff_y
  view.size.x, view.size.y = diff_w, diff_h
  view:update()
  view:draw()
end

function GitView:draw()
  self:draw_background(style.background)
  local x = self.position.x + style.padding.x
  local y = self.position.y + style.padding.y
  local tab = self:model_tab()
  renderer.draw_text(style.font, self:get_name(), x, y, style.text)
  y = y + style.font:get_height() + style.padding.y
  if not tab then
    renderer.draw_text(style.font, "Git tab is no longer available", x, y, style.dim)
  elseif tab.kind == "commit_diff" then
    self:draw_diff_tab(tab, x, y)
  elseif tab.kind == "file_history" then
    self:draw_history_tab(tab, x, y)
  else
    self:draw_log_tab(self.model:log_tab(), x, y)
  end
end

return GitView
