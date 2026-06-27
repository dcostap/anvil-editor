-- mod-version:3
-- Project Git View shell with permanent Log tab.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local GitModel = require "plugins.git.model"

local GitView = View:extend()

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
    if self.tool_window then
      self.tool_window:hide()
      return false
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
  local tab = self.model:selected_tab()
  if tab and tab.kind == "commit_diff" and tab.diff_view and tab.diff_view.on_mouse_released then
    return tab.diff_view:on_mouse_released(button, x, y)
  end
  return GitView.super.on_mouse_released(self, button, x, y)
end

function GitView:on_mouse_pressed(button, x, y, clicks)
  self:activate_model_tab(function() core.redraw = true end)
  local selected_tab = self.model:selected_tab()
  local list_width = math.floor(self.size.x * 0.45)
  if selected_tab and selected_tab.kind == "file_history" then
    local list_width = self.size.x
    if button ~= "left" then return true end
    if x < self.position.x or x > self.position.x + list_width then return true end
    if y < self:history_commits_y() then return true end
    self:clamp_history_scroll(selected_tab)
    local index = math.floor((y - self:history_commits_y() + (selected_tab.scroll or 0)) / self:row_height()) + 1
    if index >= 1 and index <= #(selected_tab.commits or {}) then
      selected_tab.selected_commit = index
      selected_tab.selected_commit_hash = selected_tab.commits[index] and selected_tab.commits[index].hash or nil
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
        local result = selected_tab.diff_view:on_mouse_pressed(button, x, y, clicks) ~= false
        if core.active_view and core.active_view.git_owner_view == self then self.focused_diff_doc_view = core.active_view end
        return result
      end
      return true
    end
    if button ~= "left" then return true end
    if x < self.position.x then return true end
    self.focus_pane = "list"
    self.focused_diff_doc_view = nil
    local index = math.floor((y - self:commit_list_y() + (selected_tab.file_scroll or 0)) / self:row_height()) + 1
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
    local commit = self.model:select_log_index(index)
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

local function file_label(file)
  local status = file and (file.status or file.kind or file.raw_status or file.xy) or ""
  local path = file and (file.path or file.new_path or file.old_path) or ""
  return string.format("%s  %s", status, path)
end

function GitView:select_relative(delta)
  self:activate_model_tab(function() core.redraw = true end)
  local tab = self.model:selected_tab()
  delta = tonumber(delta) or 0
  if tab.kind == "log" then
    if #tab.commits == 0 then return nil end
    local index = common.clamp((tab.selected_commit or 1) + delta, 1, #tab.commits)
    local commit = self.model:select_log_index(index)
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
    local row_y = (index - 1) * self:row_height()
    local visible = self:history_visible_height()
    tab.scroll = common.clamp(tab.scroll or 0, math.max(0, row_y - visible + self:row_height()), row_y)
    core.redraw = true
    return tab.commits[index]
  elseif tab.kind == "commit_diff" then
    if #(tab.changed_files or {}) == 0 then return nil end
    local file = self.model:select_diff_file(tab, (tab.selected_file or 1) + delta, function() core.redraw = true end)
    local row_y = ((tab.selected_file or 1) - 1) * self:row_height()
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
  local files = commit.changed_files or {}
  if #files == 0 then
    renderer.draw_text(style.font, "Changed files load in diff/history tabs", x, y, style.dim)
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
  if tab.loading then
    renderer.draw_text(style.font, "Loading Git log...", x, y, style.dim)
    return
  end
  if tab.error then
    renderer.draw_text(style.font, "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error), x, y, style.error)
    return
  end
  if #tab.commits == 0 then
    renderer.draw_text(style.font, "No commits", x, y, style.dim)
    return
  end
  local list_width = math.floor(self.size.x * 0.45)
  local detail_x = self.position.x + list_width + style.padding.x
  local list_right = detail_x - style.padding.x
  local row_height = self:row_height()
  local first = math.max(1, math.floor(self.scroll.y / row_height) + 1)
  y = self:commit_list_y() + (first - 1) * row_height - self.scroll.y
  for i = first, #tab.commits do
    local commit = tab.commits[i]
    local color = (i == tab.selected_commit and (not tab.selected_commit_hash or commit.hash == tab.selected_commit_hash)) and style.accent or style.text
    renderer.draw_text(style.font, commit_label(commit), x, y, color)
    y = y + row_height
    if y > self.position.y + self.size.y - style.font:get_height() then break end
  end
  if y <= self.position.y + self.size.y - style.font:get_height() then
    if tab.loading_more then
      renderer.draw_text(style.font, "Loading more commits...", x, y, style.dim)
    elseif tab.has_more then
      renderer.draw_text(style.font, "Load more commits...", x, y, style.dim)
    end
  end
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)
  self:draw_commit_details(self.model:selected_commit(), detail_x + style.padding.x, self.position.y + style.padding.y, self.size.x - list_width)
  self:draw_scrollbar()
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

function GitView:focus_diff_pane()
  local tab = self:activate_model_tab(function() core.redraw = true end) or self:model_tab()
  if not (tab and tab.kind == "commit_diff") then return false end
  if tab.loading_file or tab.file_error or (tab.left_text == nil and tab.right_text == nil) then return false end
  local view = self:ensure_diff_view(tab)
  local focus = view and view.get_focus_view and view:get_focus_view()
  if not focus then return false end
  self.focus_pane = "diff"
  self.focused_diff_doc_view = focus
  focus.git_owner_view = self
  return with_tool_window_event_window(self.tool_window, function()
    core.set_active_view(focus)
    if core.active_view then core.active_view.git_owner_view = self end
    return true
  end)
end

function GitView:focus_list_pane()
  self.focus_pane = "list"
  return with_tool_window_event_window(self.tool_window, function()
    core.set_active_view(self)
    return true
  end)
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
  if tab.loading and #tab.commits == 0 then
    renderer.draw_text(style.font, "Loading file history...", x, y, style.dim)
    return
  end
  if tab.error then
    renderer.draw_text(style.font, "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error), x, y, style.error)
    return
  end
  renderer.draw_text(style.font, tab.relpath or "", x, y, style.text)
  y = self:history_commits_y()
  if #tab.commits == 0 then
    renderer.draw_text(style.font, "No file history", x, y, style.dim)
    return
  end
  self:clamp_history_scroll(tab)
  local row_height = self:row_height()
  local first = math.max(1, math.floor((tab.scroll or 0) / row_height) + 1)
  y = y + (first - 1) * row_height - (tab.scroll or 0)
  for i = first, #tab.commits do
    local commit = tab.commits[i]
    local color = (i == tab.selected_commit and (not tab.selected_commit_hash or commit.hash == tab.selected_commit_hash)) and style.accent or style.text
    renderer.draw_text(style.font, commit_label(commit), x, y, color)
    y = y + row_height
    if y > self.position.y + self.size.y - style.font:get_height() then break end
  end
  if tab.loading then
    renderer.draw_text(style.font, "Loading more commits...", x, y, style.dim)
  elseif tab.has_more then
    renderer.draw_text(style.font, "Load more commits...", x, y, style.dim)
  end
end

function GitView:draw_diff_tab(tab, x, y)
  local list_width = math.floor(self.size.x * 0.28)
  local diff_x = self.position.x + list_width + style.padding.x
  local list_right = diff_x - style.padding.x
  if tab.loading then
    renderer.draw_text(style.font, "Loading changed files...", x, y, style.dim)
  elseif tab.error then
    renderer.draw_text(style.font, "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error), x, y, style.error)
  elseif #(tab.changed_files or {}) == 0 then
    renderer.draw_text(style.font, "No changed files", x, y, style.dim)
  else
    local row_height = self:row_height()
    local first = math.max(1, math.floor((tab.file_scroll or 0) / row_height) + 1)
    y = y + (first - 1) * row_height - (tab.file_scroll or 0)
    for i = first, #tab.changed_files do
      local file = tab.changed_files[i]
      local color = i == tab.selected_file and style.accent or style.text
      renderer.draw_text(style.font, file_label(file), x, y, color)
      y = y + row_height
      if y > self.position.y + self.size.y - style.font:get_height() then break end
    end
  end
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)

  local diff_y = self:commit_list_y()
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
