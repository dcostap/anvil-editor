-- mod-version:3
-- Project Git View shell with permanent Log tab.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local file_context = require "core.file_context"
local MouseRouter = require "core.mouse_router"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local View = require "core.view"
local view_icons = require "core.view_icons"
local GitModel = require "plugins.git.model"
local path_tree = require "plugins.path_tree"
local panes = require "core.panes"

local GitView = View:extend()
local FILE_DIFF_LOADING_DELAY = 1
GitView.view_icon = view_icons.register("git", view_icons.file(".gitignore"))

local function reject_read_only_edit()
  return false
end

local function make_pane_buffer(name)
  local buffer = Buffer(nil, nil, true)
  buffer.git_view_pane_read_only = true
  buffer.git_view_pane_name = name
  buffer.apply_edits = reject_read_only_edit
  buffer.text_input = reject_read_only_edit
  buffer.ime_text_editing = reject_read_only_edit
  buffer.insert = reject_read_only_edit
  buffer.remove = reject_read_only_edit
  buffer.replace = reject_read_only_edit
  buffer.replace_cursor = reject_read_only_edit
  buffer.save = reject_read_only_edit
  buffer.is_dirty = function() return false end
  buffer.get_name = function(self) return self.git_view_pane_name or "Git Pane" end
  return buffer
end

local function set_buffer_lines(view, lines)
  local buffer = view.buffer
  local text = table.concat(lines or {}, "\n")
  if text ~= "" then text = text .. "\n" end
  if buffer.git_view_pane_text == text then return end
  local old_line_count = #buffer.lines
  buffer.git_view_pane_text = text
  buffer.lines = {}
  if text == "" then
    buffer.lines[1] = "\n"
  else
    for line in text:gmatch("[^\n]*\n") do buffer.lines[#buffer.lines + 1] = line end
  end
  if view.invalidate_path_tree_buffer then
    view:invalidate_path_tree_buffer(old_line_count)
  else
    if buffer.highlighter then buffer.highlighter:soft_reset() end
    buffer:clear_cache(1, math.max(old_line_count, #buffer.lines))
    buffer.text_revision = (buffer.text_revision or 0) + 1
    buffer:sanitize_selection()
    view:invalidate_line_render("git-pane-buffer")
    view:invalidate_visual_metrics("git-pane-buffer")
  end
  buffer:clear_undo_redo()
  buffer:clean()
  local current_line = buffer:get_selection()
  local line = math.max(1, math.min(#buffer.lines, current_line or 1))
  buffer:set_selection(line, 1, line, 1)
  if view.scroll_to_make_visible then view:scroll_to_make_visible(line, 1, true) end
end

local function draw_segments(view, x, y, segments)
  local default_font = view:get_font()
  local tx = x
  for _, segment in ipairs(segments or {}) do
    local font = segment.font or default_font
    local ty = y + (view:get_line_height() - font:get_height()) / 2
    tx = renderer.draw_text(font, segment.text or "", tx, ty, segment.color or style.text, {
      tab_offset = tx - x,
    })
  end
  return view:get_line_height()
end

local COMMIT_LINE_RENDER_PROVIDER = {
  line_generation = function(_, view, line)
    return view.git_commit_line_meta and view.git_commit_line_meta[line]
  end,
  render_line = function(_, view, line)
    local meta = view.git_commit_line_meta and view.git_commit_line_meta[line]
    if not (meta and meta.role == "commit") then return nil end
    local hash = meta.hash or ""
    local subject = meta.subject or ""
    local subject_col = #hash + 3
    return {
      fragments = {
        {
          source_col1 = 1, source_col2 = #hash + 1,
          text = hash, color = style.accent, font = style.code_font,
        },
        {
          source_col1 = #hash + 1, source_col2 = subject_col,
          text = "  ", color = style.dim,
        },
        {
          source_col1 = subject_col, source_col2 = subject_col + #subject,
          text = subject, color = style.text,
        },
      },
    }
  end,
}

local function commit_line_hint(view, line)
  local meta = view.git_commit_line_meta and view.git_commit_line_meta[line]
  if not (meta and meta.role == "commit") then return nil end
  local font = style.get_small_font(view:get_font())
  local date_font = style.get_small_font(style.code_font)
  local segments = { truncate = "left", gap_spaces = 2 }
  if meta.author and meta.author ~= "" then
    segments[#segments + 1] = { text = meta.author, font = font, color = style.dim }
  end
  if meta.date and meta.date ~= "" then
    if #segments > 0 then
      segments[#segments + 1] = { text = "   ", font = font, color = style.dim }
    end
    segments[#segments + 1] = { text = meta.date, font = date_font, color = style.dim }
  end
  return #segments > 0 and segments or nil
end

function GitView:new(project, opts)
  self.__hide_right_pane_on_focus = true
  GitView.super.new(self)
  self.mouse_router = MouseRouter(self, function(owner, x, y)
    return owner:mouse_surface_at(x, y)
  end)
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
    local ViewType = (name == "file-list" or name == "details") and path_tree.View or TextView
    view = ViewType(make_pane_buffer("Git " .. name))
    view.font = "prose_font"
    view:set_wrapping_enabled(false)
    view.git_owner_view = self
    view.git_pane = name
    view.get_path_target = function(v) return self:path_target_for_pane(v) end
    view.get_point_of_interest_at = function(v, line)
      return self:point_of_interest_for_pane(v, line)
    end
    if ViewType == TextView then
      view.get_gutter_width = function() return 0 end
      view.draw_line_gutter = function(v) return v:get_line_height() end
      view.get_line_hint = commit_line_hint
      view:add_line_render_provider("git-commit-line", COMMIT_LINE_RENDER_PROVIDER)
    end
    local draw_line_text = view.draw_line_text
    view.draw_line_text = function(v, line, x, y)
      local commit_meta = v.git_commit_line_meta and v.git_commit_line_meta[line]
      if commit_meta and commit_meta.role == "message" then
        return draw_segments(v, x, y, { { text = commit_meta.text or "", color = commit_meta.error and style.error or style.dim } })
      end
      local detail_meta = v.git_detail_line_meta and v.git_detail_line_meta[line]
      if detail_meta then
        if detail_meta.role == "heading" then
          return draw_segments(v, x, y, { { text = detail_meta.text or "", color = style.accent } })
        elseif detail_meta.role == "subject" then
          return draw_segments(v, x, y, { { text = detail_meta.text or "", color = style.text } })
        elseif detail_meta.role == "field" then
          return draw_segments(v, x, y, {
            { text = detail_meta.label or "", color = style.dim },
            {
              text = detail_meta.value or "",
              color = detail_meta.value_color or style.text,
              font = detail_meta.value_is_code and style.code_font or nil,
            },
          })
        elseif detail_meta.role == "message" then
          return draw_segments(v, x, y, { { text = detail_meta.text or "", color = detail_meta.error and style.error or style.dim } })
        end
      end
      return draw_line_text(v, line, x, y)
    end
    self.pane_views[name] = view
  end
  view.git_owner_view = self
  return view
end

function GitView:set_pane_lines(name, lines)
  local view = self:pane_view(name)
  set_buffer_lines(view, lines)
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

function GitView:set_refresh_pending(callback, force)
  if callback then
    self.refresh_callbacks = self.refresh_callbacks or {}
    self.refresh_callbacks[#self.refresh_callbacks + 1] = callback
  end
  if self.refresh_inflight then return end
  if self.refresh_started and not callback and not force then return end
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
  self:update_pane_buffers()
  local active = core.active_view
  if active and active.git_owner_view == self then return active end
  if self.focused_pane_name and self.pane_views and self.pane_views[self.focused_pane_name] then
    return self.pane_views[self.focused_pane_name]
  end
  local tab = self.model and self:model_tab()
  if self.focus_pane == "diff" and tab and tab.kind == "commit_diff" then
    if tab.loading_file or tab.file_error or (tab.left_text == nil and tab.right_text == nil) then
      self.focused_diff_buffer_view = nil
      return self:pane_view("file-list")
    end
    local diff = self:ensure_diff_view(tab)
    if core.active_view and (core.active_view == diff.buffer_view_a or core.active_view == diff.buffer_view_b) then
      return core.active_view
    end
    if self.focused_diff_buffer_view == diff.buffer_view_a or self.focused_diff_buffer_view == diff.buffer_view_b then
      return self.focused_diff_buffer_view
    end
    self.focused_diff_buffer_view = nil
    return diff and diff.get_focus_view and diff:get_focus_view() or self:pane_view("file-list")
  end
  if tab and tab.kind == "file_history" then
    if self.focus_pane == "diff" and not tab.preview_loading and not tab.preview_error
        and (tab.preview_left_text ~= nil or tab.preview_right_text ~= nil) then
      local diff = self:ensure_history_diff_view(tab)
      return self.focused_diff_buffer_view == diff.buffer_view_b and diff.buffer_view_b or diff.buffer_view_a
    end
    return self:pane_view("history-list")
  end
  if tab and tab.kind == "commit_diff" then return self:pane_view("file-list") end
  return self:pane_view("log-list")
end

function GitView:on_suspend()
  self.refresh_after_resume = true
end

function GitView:on_resume()
  if self.git_session and self.git_session.syncing_tabs then return end
  if not self.refresh_after_resume then return end
  self.refresh_after_resume = false
  self:set_refresh_pending(nil, true)
end

function GitView:file_loading_indicator_visible(tab, now)
  if not (tab and tab.loading_file and tab.file_loading_started_at) then return false end
  return (now or system.get_time()) - tab.file_loading_started_at >= FILE_DIFF_LOADING_DELAY
end

function GitView:get_state()
  local session = self.git_session
  return {
    project_path = self.project and self.project.path,
    tab_id = self.tab_id,
    session = session and session.git_model and {
      kind = "git",
      hidden = self.git_session and self.git_session.hidden == true or false,
      model = session.git_model:get_state(),
    } or nil,
  }
end

function GitView.from_state(state)
  if not (state and state.project_path) then return nil end
  local project
  for _, candidate in ipairs(core.projects or {}) do
    if candidate.path == state.project_path then project = candidate; break end
  end
  if not project then return nil end
  local manager = require "plugins.git_view"
  local session = manager.restore_state(project, state.session or {}, { focus = false })
  if not session then return nil end
  local tab = session.git_model and session.git_model:find_tab(state.tab_id or "log")
  return tab and manager.ensure_tab_view(session, tab, false) or session.git_view
end

function GitView:dispose_tab_resources(tab)
  if not tab then return end
  for _, child in ipairs { tab.diff_view, tab.history_diff_view } do
    if child then
      child:dispose_integrations()
      child:dispose_owned_buffers()
    end
  end
  tab.diff_view, tab.history_diff_view = nil, nil
end

function GitView:on_close()
  if self.tab_id == "log" then
    if self.git_session then
      local session = self.git_session
      session.hidden = true
      core.log_quiet("Git Log hidden for Project %s", tostring(session.project_key))
      return true
    end
    return true
  end
  for i, tab in ipairs(self.model.tabs) do
    if tab.id == self.tab_id and tab.closable then
      self:dispose_tab_resources(tab)
      self.model:dispose_tab(tab)
      table.remove(self.model.tabs, i)
      if self.git_session and self.git_session.git_tab_views then
        self.git_session.git_tab_views[self.tab_id] = nil
      end
      if self.model.active_tab == self.tab_id then
        local active = core.active_view and (core.active_view.git_owner_view or core.active_view)
        if not (active and active.model == self.model and active.tab_id and self.model:find_tab(active.tab_id)) then
          local session = self.git_session
          local selected = session and session.git_model and session.git_model:selected_tab()
          active = selected and session.git_tab_views and session.git_tab_views[selected.id]
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
  return true
end

function GitView:commit_list_y()
  return self.position.y + style.prose_font:get_height() + style.padding.y * 2
end

function GitView:row_height()
  local tab = self:model_tab()
  local pane = tab and tab.kind == "file_history" and "history-list"
    or tab and tab.kind == "commit_diff" and "file-list"
    or "log-list"
  return self:pane_view(pane):get_line_height()
end

function GitView:get_scrollable_size()
  local active = self:model_tab()
  if active and (active.kind == "commit_diff" or active.kind == "file_history") then return self.size.y end
  local tab = self.model:log_tab()
  local rows = #tab.commits + ((tab.has_more or tab.loading_more) and 1 or 0)
  return self.size.y + math.max(0, rows * self:row_height() - (self.size.y - (self:commit_list_y() - self.position.y)))
end

local function scroll_pane_view(view, y, x)
  local handled = view:on_mouse_wheel(y, x)
  if handled ~= nil then return handled end
  if not view.scrollable then return false end
  if y ~= 0 then
    local max_y = math.max(0, view:get_scrollable_size() - view.size.y)
    view.scroll.to.y = common.clamp(view.scroll.to.y + (-y * config.mouse_wheel_scroll), 0, max_y)
  end
  if x ~= 0 and view.get_h_scrollable_size then
    local max_x = math.max(0, view:get_h_scrollable_size() - view.size.x)
    view.scroll.to.x = common.clamp(view.scroll.to.x + (-x * config.mouse_wheel_scroll), 0, max_x)
  end
  return y ~= 0 or x ~= 0
end

local function point_in_view(view, x, y)
  return view and x >= view.position.x and y >= view.position.y
    and x < view.position.x + view.size.x
    and y < view.position.y + view.size.y
end

function GitView:mouse_surface_at(x, y)
  local tab = self:model_tab()
  if not tab then return nil end
  local list_name = tab.kind == "commit_diff" and "file-list"
    or tab.kind == "file_history" and "history-list"
    or "log-list"
  local list = self:pane_view(list_name)
  if point_in_view(list, x, y) then return list end
  if tab.kind == "commit_diff" then
    local diff = tab.diff_view
    if tab.loading_file then return nil end
    return point_in_view(diff, x, y) and diff or nil
  end
  if tab.kind == "file_history" then
    local diff = tab.history_diff_view
    if tab.preview_loading then return nil end
    return point_in_view(diff, x, y) and diff or nil
  end
  local details = self:pane_view("details")
  return point_in_view(details, x, y) and details or nil
end

function GitView:on_mouse_wheel(y, x)
  self:activate_model_tab(function() core.redraw = true end)
  local tab = self:model_tab()
  local has_pointer = self.mouse_router:has_pointer()
  local surface = self.mouse_router:wheel_target()
  if surface then
    if tab and (tab.kind == "commit_diff" and surface == tab.diff_view
        or tab.kind == "file_history" and surface == tab.history_diff_view) then
      surface:on_mouse_wheel(y, x)
      return y ~= 0 or x ~= 0
    end
    local handled = scroll_pane_view(surface, y, x)
    if tab and tab.kind == "commit_diff" and surface.git_pane == "file-list" then
      tab.file_scroll = surface.scroll.to.y
    end
    return handled
  end
  if has_pointer then return false end
  local active = core.active_view
  if active and active.git_owner_view == self and active.git_pane and active.on_mouse_wheel then
    return scroll_pane_view(active, y, x)
  end
  tab = self:model_tab()
  if tab and tab.kind == "file_history" then
    if y == 0 then return false end
    self:clamp_history_scroll(tab)
    local visible = self:history_visible_height()
    local pending_row = tab.has_more or (tab.loading and not tab.refreshing)
    local max_scroll = math.max(0, (#(tab.commits or {}) + (pending_row and 1 or 0)) * self:row_height() - visible)
    tab.scroll = common.clamp((tab.scroll or 0) + (-y * config.mouse_wheel_scroll), 0, max_scroll)
    return true
  end
  if tab and tab.kind == "commit_diff" then
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
  local handled, surface = self.mouse_router:move(x, y, dx, dy)
  if surface then
    return handled ~= false
  end
  self.cursor = "arrow"
  return GitView.super.on_mouse_moved(self, x, y, dx, dy)
end

function GitView:on_mouse_released(button, x, y)
  self:activate_model_tab(function() core.redraw = true end)
  if self.mouse_router:captured_target() then
    local result = self.mouse_router:release(button, x, y)
    return result ~= false
  end
  return GitView.super.on_mouse_released(self, button, x, y)
end

function GitView:on_mouse_left()
  self.mouse_router:leave()
  return GitView.super.on_mouse_left(self)
end

function GitView:on_mouse_pressed(button, x, y, clicks)
  self:activate_model_tab(function() core.redraw = true end)
  self:update_pane_buffers()
  local hovered = self.mouse_router:press_target(x, y)
  local pane = hovered and hovered.git_pane and hovered or nil
  if pane then
    self.focused_pane_name = pane.git_pane
    self.focus_pane = "buffer"
    core.set_active_view(pane)
    local scrollbar, handled = self.mouse_router:press_scrollbar(pane, button, x, y, clicks)
    if scrollbar then
      core.redraw = true
      return handled == true
    end
    local content_click = false
    if button == "left" and pane.buffer and pane.resolve_screen_position then
      local cmd = clicks == 2 and "core:set_cursor_word" or clicks and clicks >= 3 and "core:set_cursor_line" or "core:set_cursor"
      content_click = command.perform(cmd, x, y, clicks)
    end
    self.mouse_router:capture(pane)
    if not content_click then pane:on_mouse_pressed(button, x, y, clicks) end
    self:sync_selection_from_pane()
    local toggled_details_folder = clicks and clicks > 1 and pane.git_pane == "details"
      and self:toggle_details_tree_folder(pane, pane.buffer:get_selection())
    if clicks and clicks > 1 and pane.git_pane ~= "history-list"
        and not toggled_details_folder and self.activate_selected then
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
    local diff = selected_tab.history_diff_view
    if diff and point_in_view(diff, x, y) then
      local side = x >= diff.position.x + diff.size.x / 2 and "right" or "left"
      if not self:focus_diff_pane(side) then return true end
      self.mouse_router:capture(diff)
      local result = diff:on_mouse_pressed(button, x, y, clicks)
      if core.active_view and core.active_view.git_owner_view == self then
        self.focused_diff_buffer_view = core.active_view
      end
      return result == true
    end
    local list_width = math.floor(self.size.x * 0.34)
    if button ~= "left" then return true end
    if x < self.position.x or x > self.position.x + list_width then return true end
    if y < self:history_commits_y() then return true end
    self:clamp_history_scroll(selected_tab)
    local index = math.floor((y - self:history_commits_y() + (selected_tab.scroll or 0)) / self:row_height()) + 1
    if index >= 1 and index <= #(selected_tab.commits or {}) then
      self.model:select_history_index(selected_tab, index, function() core.redraw = true end)
      core.redraw = true
    elseif index == #(selected_tab.commits or {}) + 1 and selected_tab.has_more then
      self.model:load_file_history(selected_tab, function() core.redraw = true end)
    end
    return true
  end

  if selected_tab and selected_tab.kind == "commit_diff" then
    list_width = math.floor(self.size.x * 0.28)
    if x > self.position.x + list_width then
      local diff = selected_tab.diff_view
      local side = diff and x >= diff.position.x + diff.size.x / 2 and "right" or "left"
      if not self:focus_diff_pane(side) then return true end
      if selected_tab.diff_view and selected_tab.diff_view.on_mouse_pressed then
        self.mouse_router:capture(selected_tab.diff_view)
        local result = selected_tab.diff_view:on_mouse_pressed(button, x, y, clicks)
        if core.active_view and core.active_view.git_owner_view == self then self.focused_diff_buffer_view = core.active_view end
        return result == true
      end
      return true
    end
    if button ~= "left" then return true end
    if x < self.position.x then return true end
    self.focus_pane = "list"
    self.focused_diff_buffer_view = nil
    local list = self:pane_view("file-list")
    local line = math.floor((y - self:commit_list_y() + (list.scroll.y or 0)) / self:row_height()) + 1
    local index = selected_tab.file_line_to_index and selected_tab.file_line_to_index[line]
    if not selected_tab.file_line_to_index then index = line end
    if index and index >= 1 and index <= #(selected_tab.changed_files or {}) then
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

local function commit_line_metadata(commit)
  local timestamp = tonumber(commit.commit_time or commit.author_time)
  local date = timestamp and timestamp > 0 and os.date("%Y-%m-%d %H:%M", timestamp) or ""
  return {
    role = "commit",
    hash = commit.short_hash or commit.hash or "",
    subject = commit.subject or "",
    author = commit.author_name or "",
    date = date,
  }
end

local function tab_label(tab)
  return (tab.id == "log" and "Log" or tab.title or tab.kind or "Tab")
end

local function changed_file_path(file)
  return file and (file.path or file.new_path or file.old_path) or ""
end

local function changed_file_side_path(file, side)
  if not file then return nil end
  if side == "left" then return file.old_path or file.path or file.new_path end
  return file.new_path or file.path or file.old_path
end

function GitView:absolute_repo_path(path)
  if not path or path == "" then return nil end
  if common.is_absolute_path(path) then return common.normalize_path(path) end
  local repo = self.model and self.model.repo
  local root = repo and repo.root or self.project and self.project.path
  if not root or root == "" then return nil end
  return common.normalize_path(root .. PATHSEP .. path)
end

function GitView:path_target_for_pane(view)
  if not (view and view.git_owner_view == self and view.git_pane) then return nil end
  local tab = self:model_tab()
  if view.git_pane == "history-list" and tab and tab.kind == "file_history" then
    local path = self:absolute_repo_path(tab.relpath)
    return path and { path = path } or nil
  end
  if view.git_pane ~= "file-list" and view.git_pane ~= "details" then return nil end

  local line = view.buffer and view.buffer:get_selection() or 1
  local row = view.path_tree_row and view:path_tree_row(line)
  local record = view.path_tree_record_for_line and view:path_tree_record_for_line(line)
  local relpath = record and changed_file_path(record) or row and row.path
  local path = self:absolute_repo_path(relpath)
  return path and { path = path } or nil
end

function GitView:get_path_target()
  local focus = self:get_focus_view()
  if not focus or focus == self then return nil end
  return file_context.view_path_target(focus)
end

local function changed_file_tree(files, collapsed)
  return path_tree.build(files or {}, {
    record_path = changed_file_path,
    collapsed = collapsed,
    compact_directories = true,
  })
end

local function refresh_changed_file_tree_cache(cache)
  local tree = cache and cache.tree
  if not tree then return cache end
  cache.lines = tree:lines()
  cache.line_to_index = tree.line_to_record
  cache.index_to_line = tree.record_to_line
  cache.index_to_visible_line = {}
  for index = 1, #tree.records do
    cache.index_to_visible_line[index] = tree:visible_line_for_record(index)
  end
  cache.line_meta = tree.rows
  return cache
end

local function changed_file_tree_cache(view, files, collapsed)
  files = files or {}
  local cache = view.git_changed_file_tree_cache
  if cache and cache.files == files
      and (cache.collapsed_source == collapsed or cache.tree.collapsed == collapsed) then
    return cache
  end
  cache = refresh_changed_file_tree_cache({
    files = files,
    collapsed_source = collapsed,
    tree = changed_file_tree(files, collapsed),
  })
  view.git_changed_file_tree_cache = cache
  core.log_quiet("Git View rebuilt %s Path Tree with %d changed files", view.git_pane or "changed-file", #files)
  return cache
end

local function refresh_view_changed_file_tree_cache(view)
  local cache = view and view.git_changed_file_tree_cache
  if not (cache and cache.tree == view.path_tree) then return nil end
  cache.collapsed_source = cache.tree.collapsed
  return refresh_changed_file_tree_cache(cache)
end

local function sync_changed_file_tree_mappings(tab, cache)
  tab.file_line_to_index = cache and cache.line_to_index or nil
  tab.file_index_to_line = cache and cache.index_to_line or nil
  tab.file_index_to_visible_line = cache and cache.index_to_visible_line or nil
  tab.file_line_meta = cache and cache.line_meta or nil
end

local function commit_details_lines(commit, view)
  local lines, line_meta = {}, {}
  local tree, tree_offset
  local function add(text, meta)
    lines[#lines + 1] = text
    line_meta[#lines] = meta
  end
  add("Details", { role = "heading", text = "Details" })
  if not commit then
    add("Select a commit", { role = "message", text = "Select a commit" })
    return lines, line_meta
  end
  add(commit.subject or "", { role = "subject", text = commit.subject or "" })
  add("Hash: " .. tostring(commit.hash or ""), {
    role = "field",
    label = "Hash: ",
    value = tostring(commit.hash or ""),
    value_color = style.accent,
    value_is_code = true,
  })
  if commit.author_name and commit.author_name ~= "" then
    add("Author: " .. commit.author_name, { role = "field", label = "Author: ", value = commit.author_name })
  end
  if commit.author_email and commit.author_email ~= "" then
    add("Email: " .. commit.author_email, { role = "field", label = "Email: ", value = commit.author_email })
  end
  local timestamp = tonumber(commit.commit_time or commit.author_time)
  if timestamp and timestamp > 0 then
    local date = os.date("%Y-%m-%d %H:%M:%S", timestamp)
    add("Date: " .. date, { role = "field", label = "Date: ", value = date })
  end
  if commit.committer_name and commit.committer_name ~= ""
      and commit.committer_name ~= commit.author_name then
    add("Committer: " .. commit.committer_name, { role = "field", label = "Committer: ", value = commit.committer_name })
  end
  if commit.refs and commit.refs ~= "" then
    add("Refs: " .. commit.refs, { role = "field", label = "Refs: ", value = commit.refs, value_color = style.good })
  end
  if commit.body and commit.body ~= "" then
    add("", nil)
    for line in (commit.body .. "\n"):gmatch("(.-)\n") do
      add(line, { role = "message", text = line })
    end
  end
  add("", nil)
  add("Changed files", { role = "heading", text = "Changed files" })
  if commit.changed_files_loading then
    add("Loading changed files...", { role = "message", text = "Loading changed files..." })
  elseif commit.changed_files_error then
    local text = "Git error: " .. tostring(commit.changed_files_error.message or commit.changed_files_error.kind or commit.changed_files_error)
    add(text, { role = "message", text = text, error = true })
  elseif #(commit.changed_files or {}) == 0 then
    local text = commit.changed_files_loaded and "No changed files" or "Select a commit to load changed files"
    add(text, { role = "message", text = text })
  else
    local cache = changed_file_tree_cache(view, commit.changed_files, commit.details_tree_collapsed)
    tree = cache.tree
    tree_offset = #lines
    for _, text in ipairs(cache.lines) do add(text, nil) end
  end
  return lines, line_meta, tree, tree_offset
end

function GitView:detail_commit_for_tab(tab)
  if not tab then return nil end
  local commit
  if tab.kind == "file_history" then
    commit = tab.commits and tab.commits[tab.selected_commit]
    if tab.selected_commit_hash and (not commit or commit.hash ~= tab.selected_commit_hash) then return nil end
  else
    local log_tab = self.model:log_tab()
    commit = log_tab.commits and log_tab.commits[log_tab.selected_commit]
    if log_tab.selected_commit_hash and (not commit or commit.hash ~= log_tab.selected_commit_hash) then return nil end
  end
  local key = commit and (commit.kind == "working_tree" and "WORKING_TREE" or commit.hash)
  local collapsed = key and self.model.details_tree_collapsed and self.model.details_tree_collapsed[key]
  if collapsed then commit.details_tree_collapsed = collapsed end
  return commit
end

local function sync_inactive_pane_line(view, line)
  if core.active_view == view then return end
  line = math.max(1, math.min(#view.buffer.lines, tonumber(line) or 1))
  local current_line, current_col = view.buffer:get_selection()
  if current_line ~= line then
    view.buffer:set_selection(line, math.max(1, math.min(current_col or 1, #view.buffer.lines[line])))
  end
end

function GitView:details_tree_item(view, line)
  if not (view and view.git_pane == "details" and view.path_tree_row) then return nil end
  local row = view:path_tree_row(line)
  if not row then return nil end
  local commit = self:detail_commit_for_tab(self:model_tab())
  local record = view:path_tree_record_for_line(line)
  return commit, row, record
end

function GitView:toggle_details_tree_folder(view, line)
  local commit, row = self:details_tree_item(view, line)
  if not (commit and row and row.type == "dir" and view:toggle_path_tree_folder(line)) then return false end
  refresh_view_changed_file_tree_cache(view)
  commit.details_tree_collapsed = view.path_tree.collapsed
  local key = commit.kind == "working_tree" and "WORKING_TREE" or commit.hash
  if key then
    self.model.details_tree_collapsed = self.model.details_tree_collapsed or {}
    self.model.details_tree_collapsed[key] = commit.details_tree_collapsed
  end
  core.log_quiet("Git View details Path Tree folder %s", view:path_tree_row(line).expanded and "expanded" or "collapsed")
  core.redraw = true
  return true
end

function GitView:sync_selection_from_pane()
  local active = core.active_view
  if not (active and active.git_owner_view == self and active.git_pane) then return end
  local line = active.buffer and active.buffer:get_selection() or 1
  local tab = self:model_tab()
  if active.git_pane == "log-list" then
    local log_tab = self.model:log_tab()
    if line >= 1 and line <= #(log_tab.commits or {}) and line ~= log_tab.selected_commit then
      self.model:select_log_index(line, function() core.redraw = true end)
    end
  elseif active.git_pane == "history-list" and tab and tab.kind == "file_history" then
    if line >= 1 and line <= #(tab.commits or {}) and line ~= tab.selected_commit then
      self.model:select_history_index(tab, line, function() core.redraw = true end)
    end
  elseif active.git_pane == "file-list" and tab and tab.kind == "commit_diff" then
    local index = active.git_file_line_to_index and active.git_file_line_to_index[line]
    if not index and not active.git_file_line_to_index then index = line end
    if index and index >= 1 and index <= #(tab.changed_files or {}) and index ~= tab.selected_file then
      self.model:select_diff_file(tab, index, function() core.redraw = true end)
    end
  elseif active.git_pane == "details" then
    local commit, _, record = self:details_tree_item(active, line)
    if commit and record then commit.selected_changed_file_path = changed_file_path(record) end
  end
end

function GitView:activate_selected(callback)
  self:sync_selection_from_pane()
  local active = core.active_view
  local details_commit, details_row, details_record = self:details_tree_item(
    active, active and active.buffer and active.buffer:get_selection() or 1
  )
  if details_row and details_row.type == "dir" then
    self:toggle_details_tree_folder(active, active.buffer:get_selection())
    return nil
  end
  local details_path = details_record and changed_file_path(details_record)
  self:activate_model_tab(function() core.redraw = true end)
  local tab = self.model:selected_tab()
  if tab.kind == "file_history" then
    self.model:load_history_preview(tab, callback or function() core.redraw = true end)
    return tab
  end
  if tab.kind == "commit_diff" then
    local active = core.active_view
    if active and active.git_owner_view == self and active.git_pane == "file-list" then
      local line = active.buffer and active.buffer:get_selection() or 1
      if active.git_file_line_to_index and not active.git_file_line_to_index[line] then
        if active.toggle_path_tree_folder and active:toggle_path_tree_folder(line) then
          tab.file_tree_collapsed = active.path_tree.collapsed
          local cache = refresh_view_changed_file_tree_cache(active)
          sync_changed_file_tree_mappings(tab, cache)
          active.git_file_line_to_index = tab.file_line_to_index or {}
          active.git_file_index_to_line = tab.file_index_to_line or {}
          active.git_file_index_to_visible_line = tab.file_index_to_visible_line or {}
          active.git_file_line_meta = tab.file_line_meta or {}
          core.log_quiet("Git View Path Tree folder %s", active.path_tree_row(line).expanded and "expanded" or "collapsed")
          core.redraw = true
          return tab
        end
        return nil
      end
    end
    self.model:load_selected_diff_file(tab, callback or function() core.redraw = true end)
    return tab
  end
  if details_commit then
    return self.model:open_commit_diff(details_commit, callback or function() core.redraw = true end, {
      selected_file_path = details_path or details_commit.selected_changed_file_path,
    })
  end
  return self.model:open_selected_commit_diff(callback or function() core.redraw = true end)
end

function GitView:activate_selected_point(callback)
  local active_tab = self.model:selected_tab()
  local diff_tab, err = self:activate_selected(callback)
  if active_tab.kind == "log" and diff_tab and self.on_model_tab_open then
    self:on_model_tab_open(diff_tab)
  end
  return diff_tab, err
end

function GitView:point_of_interest_for_pane(view, line)
  local tab = self:model_tab()
  if not tab then return nil end
  local kind
  if view.git_pane == "log-list" then
    if not self.model:log_tab().commits[line] then return nil end
    kind = "git-commit"
  elseif view.git_pane == "history-list" then
    if tab.kind ~= "file_history" or not (tab.commits and tab.commits[line]) then return nil end
    kind = "git-commit"
  elseif view.git_pane == "file-list" then
    if tab.kind ~= "commit_diff" then return nil end
    local index = view.git_file_line_to_index and view.git_file_line_to_index[line]
    if not index or not (tab.changed_files and tab.changed_files[index]) then return nil end
    kind = "git-changed-file"
  elseif view.git_pane == "details" then
    local _, row, record = self:details_tree_item(view, line)
    if not (row and row.type == "file" and record) then return nil end
    kind = "git-changed-file"
  else
    return nil
  end
  local text = (view.buffer:get_utf8_line(line) or ""):gsub("\n$", "")
  return {
    kind = kind,
    line = line,
    col = 1,
    line2 = line,
    col2 = math.max(2, #text + 1),
    text_bounds = true,
    activate = function()
      local opened, err = self:activate_selected_point(function() core.redraw = true end)
      if not opened and err then
        core.log_quiet("Git View: Point of Interest Activation skipped: %s", err.message or err.kind)
      end
      return opened ~= nil
    end,
  }
end

function GitView:update_pane_buffers()
  local tab = self:model_tab()
  if not tab then return end
  if tab.kind == "file_history" then
    local lines = {}
    local line_meta = {}
    if tab.loading and #(tab.commits or {}) == 0 then
      lines[1] = "Loading file history..."
      line_meta[1] = { role = "message", text = lines[1] }
    elseif tab.error then
      lines[1] = "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error)
      line_meta[1] = { role = "message", text = lines[1], error = true }
    elseif #(tab.commits or {}) == 0 then
      lines[1] = "No file history"
      line_meta[1] = { role = "message", text = lines[1] }
    else
      for _, commit in ipairs(tab.commits or {}) do
        lines[#lines + 1] = commit_label(commit)
        line_meta[#lines] = commit_line_metadata(commit)
      end
      if tab.loading and not tab.refreshing then
        lines[#lines + 1] = "Loading more commits..."
        line_meta[#lines] = { role = "message", text = lines[#lines] }
      elseif tab.has_more then
        lines[#lines + 1] = "Load more commits..."
        line_meta[#lines] = { role = "message", text = lines[#lines] }
      end
    end
    local list_view = self:set_pane_lines("history-list", lines)
    list_view.git_commit_line_meta = line_meta
    sync_inactive_pane_line(list_view, tab.selected_commit)
  elseif tab.kind == "commit_diff" then
    local lines = {}
    local cache
    tab.file_line_to_index = nil
    tab.file_index_to_line = nil
    tab.file_index_to_visible_line = nil
    tab.file_line_meta = nil
    if tab.loading and #(tab.changed_files or {}) == 0 then
      lines[1] = "Loading changed files..."
    elseif tab.error then
      lines[1] = "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error)
    elseif #(tab.changed_files or {}) == 0 then
      lines[1] = "No changed files"
    else
      cache = changed_file_tree_cache(self:pane_view("file-list"), tab.changed_files, tab.file_tree_collapsed)
      lines = cache.lines
      sync_changed_file_tree_mappings(tab, cache)
    end
    local list_view = self:set_pane_lines("file-list", lines)
    local tree = cache and cache.tree or nil
    if list_view.path_tree ~= tree or list_view.path_tree_line_offset ~= 0 then
      list_view:set_path_tree(tree, 0)
    end
    list_view.git_file_line_to_index = tab.file_line_to_index or {}
    list_view.git_file_index_to_line = tab.file_index_to_line or {}
    list_view.git_file_index_to_visible_line = tab.file_index_to_visible_line or {}
    list_view.git_file_line_meta = tab.file_line_meta or {}
    list_view.git_file_records = tab.changed_files or {}
    sync_inactive_pane_line(
      list_view,
      list_view.git_file_index_to_line[tab.selected_file]
        or list_view.git_file_index_to_visible_line[tab.selected_file]
        or tab.selected_file
    )
  else
    local log_tab = self.model:log_tab()
    local lines = {}
    local line_meta = {}
    if log_tab.loading and #log_tab.commits == 0 then
      lines[1] = "Loading Git log..."
      line_meta[1] = { role = "message", text = lines[1] }
    elseif log_tab.error then
      lines[1] = "Git error: " .. tostring(log_tab.error.message or log_tab.error.kind or log_tab.error)
      line_meta[1] = { role = "message", text = lines[1], error = true }
    elseif #log_tab.commits == 0 then
      lines[1] = "No commits"
      line_meta[1] = { role = "message", text = lines[1] }
    else
      for _, commit in ipairs(log_tab.commits) do
        lines[#lines + 1] = commit_label(commit)
        line_meta[#lines] = commit_line_metadata(commit)
      end
      if log_tab.loading_more then
        lines[#lines + 1] = "Loading more commits..."
        line_meta[#lines] = { role = "message", text = lines[#lines] }
      elseif log_tab.has_more then
        lines[#lines + 1] = "Load more commits..."
        line_meta[#lines] = { role = "message", text = lines[#lines] }
      end
    end
    local list_view = self:set_pane_lines("log-list", lines)
    list_view.git_commit_line_meta = line_meta
    sync_inactive_pane_line(list_view, log_tab.selected_commit)
    local details = self:pane_view("details")
    local detail_lines, detail_meta, detail_tree, detail_tree_offset = commit_details_lines(
      self:detail_commit_for_tab(log_tab), details
    )
    self:set_pane_lines("details", detail_lines)
    details.git_detail_line_meta = detail_meta
    if details.path_tree ~= detail_tree or details.path_tree_line_offset ~= (detail_tree_offset or 0) then
      details:set_path_tree(detail_tree, detail_tree_offset or 0)
    end
  end
end

function GitView:update()
  self:update_pane_buffers()
  self:sync_selection_from_pane()
  local tab = self:model_tab()
  local diff_view
  if tab and tab.kind == "commit_diff" then
    diff_view = select(7, self:layout_diff_tab(tab, self.position.x + style.padding.x))
    if tab.loading_file and not self:file_loading_indicator_visible(tab) then
      core.redraw = true
    end
  elseif tab and tab.kind == "file_history" and not tab.preview_loading and not tab.preview_error
      and (tab.preview_left_text ~= nil or tab.preview_right_text ~= nil) then
    diff_view = self:ensure_history_diff_view(tab)
  end
  for _, view in pairs(self.pane_views or {}) do view:update() end
  if diff_view then diff_view:update() end
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
    self:update_pane_buffers()
    local list = self:pane_view("log-list")
    list.buffer:set_selection(index, 1, index, 1)
    local row_y = (index - 1) * self:row_height()
    local visible = self.size.y - (self:commit_list_y() - self.position.y) - style.padding.y
    self.scroll.to.y = common.clamp(self.scroll.to.y, math.max(0, row_y - visible + self:row_height()), row_y)
    self.scroll.y = self.scroll.to.y
    core.redraw = true
    return commit
  elseif tab.kind == "file_history" then
    if #(tab.commits or {}) == 0 then return nil end
    local index = common.clamp((tab.selected_commit or 1) + delta, 1, #tab.commits)
    self.model:select_history_index(tab, index, function() core.redraw = true end)
    self:update_pane_buffers()
    local list = self:pane_view("history-list")
    list.buffer:set_selection(index, 1, index, 1)
    local row_y = (index - 1) * self:row_height()
    local visible = self:history_visible_height()
    tab.scroll = common.clamp(tab.scroll or 0, math.max(0, row_y - visible + self:row_height()), row_y)
    core.redraw = true
    return tab.commits[index]
  elseif tab.kind == "commit_diff" then
    if #(tab.changed_files or {}) == 0 then return nil end
    local index = tab.selected_file or 1
    local line = tab.file_index_to_line and tab.file_index_to_line[index]
    if not line then
      local list = self:pane_view("file-list")
      line = list.buffer and list.buffer:get_selection() or nil
    end
    local direction = delta < 0 and -1 or 1
    local remaining = math.abs(delta)
    while line and remaining > 0 do
      repeat line = line + direction until not tab.file_line_to_index or tab.file_line_to_index[line] or line < 1 or line > #(tab.file_line_meta or {})
      local candidate = tab.file_line_to_index and tab.file_line_to_index[line]
      if not candidate then break end
      index = candidate
      remaining = remaining - 1
    end
    if not line then index = index + delta end
    local file = self.model:select_diff_file(tab, index, function() core.redraw = true end)
    self:update_pane_buffers()
    local list = self:pane_view("file-list")
    local line = list.git_file_index_to_line and list.git_file_index_to_line[tab.selected_file]
      or list.git_file_index_to_visible_line and list.git_file_index_to_visible_line[tab.selected_file]
      or tab.selected_file or 1
    list.buffer:set_selection(line, 1, line, 1)
    list:scroll_to_make_visible(line, 1, true)
    tab.file_scroll = list.scroll.y
    core.redraw = true
    return file
  end
end

function GitView:tab_rects(x, y)
  local rects = {}
  local font = style.prose_font
  local cursor = x + font:get_width("Tabs: ")
  for _, tab in ipairs(self.model.tabs) do
    local label = tab_label(tab)
    if tab.id == self.model.active_tab then label = "[" .. label .. "]" end
    local width = font:get_width(label)
    rects[#rects + 1] = { tab = tab, x = cursor, y = y, w = width, h = font:get_height() }
    cursor = cursor + width + font:get_width(" ")
  end
  return rects
end

function GitView:tab_at_point(px, py)
  local x = self.position.x + style.padding.x
  local y = self.position.y + style.padding.y + style.prose_font:get_height() + style.padding.y
  for _, rect in ipairs(self:tab_rects(x, y)) do
    if px >= rect.x and px <= rect.x + rect.w and py >= rect.y and py <= rect.y + rect.h then
      return rect.tab
    end
  end
end

function GitView:draw_tabs(x, y)
  local font = style.prose_font
  renderer.draw_text(font, "Tabs:", x, y, style.dim)
  for _, rect in ipairs(self:tab_rects(x, y)) do
    local color = rect.tab.id == self.model.active_tab and style.accent or style.dim
    local label = tab_label(rect.tab)
    if rect.tab.id == self.model.active_tab then label = "[" .. label .. "]" end
    renderer.draw_text(font, label, rect.x, y, color)
  end
end

function GitView:draw_commit_details(commit, x, y, width)
  local font = style.prose_font
  renderer.draw_text(font, "Details", x, y, style.text)
  y = y + font:get_height() + style.padding.y
  if not commit then
    renderer.draw_text(font, "Select a commit", x, y, style.dim)
    return
  end
  renderer.draw_text(font, commit.subject or "", x, y, style.text)
  y = y + font:get_height() + 2 * SCALE
  local hash_label = "Hash: "
  local hash_x = renderer.draw_text(font, hash_label, x, y, style.dim)
  local hash_y = y + math.max(0, (font:get_height() - style.code_font:get_height()) / 2)
  renderer.draw_text(style.code_font, tostring(commit.hash or ""), hash_x, hash_y, style.accent)
  y = y + font:get_height() + 2 * SCALE
  if commit.author_name and commit.author_name ~= "" then
    renderer.draw_text(font, "Author: " .. commit.author_name, x, y, style.dim)
    y = y + font:get_height() + 2 * SCALE
  end
  if commit.refs and commit.refs ~= "" then
    renderer.draw_text(font, "Refs: " .. commit.refs, x, y, style.dim)
    y = y + font:get_height() + 2 * SCALE
  end
  y = y + style.padding.y
  renderer.draw_text(font, "Changed files", x, y, style.text)
  y = y + font:get_height() + style.padding.y
  if commit.changed_files_loading then
    renderer.draw_text(font, "Loading changed files...", x, y, style.dim)
    return
  end
  if commit.changed_files_error then
    renderer.draw_text(font, "Git error: " .. tostring(commit.changed_files_error.message or commit.changed_files_error.kind or commit.changed_files_error), x, y, style.error)
    return
  end
  local files = commit.changed_files or {}
  if #files == 0 then
    renderer.draw_text(font, commit.changed_files_loaded and "No changed files" or "Select a commit to load changed files", x, y, style.dim)
    return
  end
  for _, file in ipairs(files) do
    local label = file.path or file.new_path or file.old_path or ""
    renderer.draw_text(font, string.format("%s  %s", file.kind or file.status or file.xy or "", label), x, y, style.text)
    y = y + font:get_height() + 2 * SCALE
    if y > self.position.y + self.size.y - font:get_height() then break end
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
  local header_height = top - self.position.y
  local header_y = self.position.y + (header_height - style.prose_font:get_height()) / 2
  renderer.draw_rect(self.position.x, self.position.y, list_width, header_height, style.background2)
  renderer.draw_text(style.prose_font, "Commits", x, header_y, style.text)
  local status = string.format("%d commits", #tab.commits)
  renderer.draw_text(
    style.prose_font, status,
    list.position.x + list.size.x - style.prose_font:get_width(status) - style.padding.x,
    header_y,
    style.dim
  )
  list:draw()
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)
  details:draw()
end

function GitView:ensure_diff_view(tab)
  if tab.diff_view and tab.diff_view_seen_generation == tab.diff_generation then
    if tab.diff_view.buffer_view_a then tab.diff_view.buffer_view_a.git_owner_view = self end
    if tab.diff_view.buffer_view_b then tab.diff_view.buffer_view_b.git_owner_view = self end
    if self.focused_diff_buffer_view ~= tab.diff_view.buffer_view_a and self.focused_diff_buffer_view ~= tab.diff_view.buffer_view_b then
      self.focused_diff_buffer_view = nil
    end
    return tab.diff_view
  end
  if tab.diff_view then
    tab.diff_view:dispose_integrations()
    tab.diff_view:dispose_owned_buffers()
  end
  local diffview = require "plugins.diffview"
  local selected_file = tab.changed_files and tab.changed_files[tab.selected_file]
  local left_source_path = self:absolute_repo_path(changed_file_side_path(selected_file, "left"))
  local right_source_path = self:absolute_repo_path(changed_file_side_path(selected_file, "right"))
  local function source(text, current_path, name, source_path)
    if current_path then
      return diffview.content.file(self:absolute_repo_path(current_path), {
        name = name,
        editable = true,
        source_path = self:absolute_repo_path(current_path),
      })
    end
    return diffview.content.text(text or "", {
      name = name,
      editable = false,
      read_only_reason = "Historical Git content is read-only",
      source_path = source_path,
    })
  end
  local view = diffview.open({
    title = tab.title or "Commit Diff View",
    kind = "git",
    compare_type = diffview.Viewer.type.STRING_STRING,
    contents = {
      left = source(tab.left_text, tab.left_current_path, tab.left_name, left_source_path),
      right = source(tab.right_text, tab.right_current_path, tab.right_name, right_source_path),
    },
    content_titles = { left = tab.left_name, right = tab.right_name },
    editable_policy = "content",
    user_data = {
      source = "git",
      tab = tab,
      selected_file = selected_file,
      selected_file_index = tab.selected_file,
      selected_file_path = tab.selected_file_path or selected_file and changed_file_path(selected_file),
      left_revision = tab.left,
      right_revision = tab.right,
      read_only_reason = "Historical Git content is read-only",
      on_change_boundary = function(direction, side_view)
        return self:handle_change_boundary(tab, direction, side_view)
      end,
      on_navigation_state_change = function()
        tab.change_boundary_arm = nil
      end,
    },
  }, true)
  tab.diff_view = view
  tab.diff_view_seen_generation = tab.diff_generation
  if view.buffer_view_a then view.buffer_view_a.git_owner_view = self end
  if view.buffer_view_b then view.buffer_view_b.git_owner_view = self end
  if self.focused_diff_buffer_view ~= view.buffer_view_a and self.focused_diff_buffer_view ~= view.buffer_view_b then
    self.focused_diff_buffer_view = nil
  end
  return view
end

function GitView:show_navigation_feedback(message)
  if core.status_bar and core.status_bar.show_message then
    core.status_bar:show_message("i", style.dim, message)
  else
    core.log_quiet("Git navigation: %s", message)
  end
end

function GitView:handle_change_boundary(tab, direction, side_view)
  direction = direction < 0 and -1 or 1
  local index = tab.selected_file or 1
  local arm = tab.change_boundary_arm
  if not (arm and arm.direction == direction and arm.file_index == index) then
    tab.change_boundary_arm = { direction = direction, file_index = index }
    self:show_navigation_feedback(direction > 0
      and "Repeat Next Change to continue to the next file"
      or "Repeat Previous Change to continue to the previous file")
    return true
  end
  local target_index = index + direction
  if target_index < 1 or target_index > #(tab.changed_files or {}) then
    self:show_navigation_feedback(direction > 0 and "No next changed file" or "No previous changed file")
    return true
  end
  local side = side_view == tab.diff_view.buffer_view_b and "right" or "left"
  tab.change_boundary_arm = nil
  self.model:select_diff_file(tab, target_index, function()
    local diff = self:ensure_diff_view(tab)
    local target = side == "right" and diff.buffer_view_b or diff.buffer_view_a
    local points = diff:diff_points_of_interest(target == diff.buffer_view_a)
    local point = direction > 0 and points[1] or points[#points]
    if point then
      target:with_selection_state(function()
        target.buffer:set_selection(point.line, point.col or 1)
      end)
    end
    self.focused_diff_buffer_view = target
    core.set_active_view(target)
    core.redraw = true
  end)
  return true
end

function GitView:ensure_history_diff_view(tab)
  if tab.history_diff_view
      and tab.history_diff_view_seen_generation == tab.preview_generation_value then
    return tab.history_diff_view
  end
  if tab.history_diff_view then
    tab.history_diff_view:dispose_integrations()
    tab.history_diff_view:dispose_owned_buffers()
  end
  local diffview = require "plugins.diffview"
  local function source(text, current_path, fragment, name)
    if fragment then
      local path = self:absolute_repo_path(tab.relpath)
      local buffer = core.open_buffer(path)
      local end_line = math.min(#buffer.lines, fragment.end_line)
      local end_col = #(buffer.lines[end_line] or "")
      return diffview.content.fragment(
        buffer, fragment.start_line, 1, end_line, end_col,
        { name = name, source_path = path }
      )
    end
    if current_path then
      local path = self:absolute_repo_path(current_path)
      return diffview.content.file(path, {
        name = name, editable = true, source_path = path,
      })
    end
    return diffview.content.text(text or "", {
      name = name, editable = false,
      read_only_reason = "Historical Git content is read-only",
      source_path = self:absolute_repo_path(tab.relpath),
      source_line = tab.preview_source_line,
    })
  end
  local view = diffview.open({
    title = tab.title or "File History View",
    kind = "git-history",
    contents = {
      source(tab.preview_left_text, nil, nil, tab.preview_left_name),
      source(tab.preview_right_text, tab.preview_right_current_path, tab.preview_right_fragment, tab.preview_right_name),
    },
    content_titles = { tab.preview_left_name, tab.preview_right_name },
    editable_policy = "content",
    user_data = { source = "git-history", tab = tab },
  }, true)
  tab.history_diff_view = view
  tab.history_diff_view_seen_generation = tab.preview_generation_value
  view.buffer_view_a.git_owner_view = self
  view.buffer_view_b.git_owner_view = self
  return view
end

local function with_git_session_event_window(session, fn)
  local previous_event_window = core.event_window
  local previous_active_window = core.active_window
  local window = session and session.window
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
  if not tab then return false end
  local view
  if tab.kind == "commit_diff" then
    if tab.loading_file or tab.file_error or (tab.left_text == nil and tab.right_text == nil) then return false end
    view = self:ensure_diff_view(tab)
  elseif tab.kind == "file_history" then
    if tab.preview_loading or tab.preview_error
        or (tab.preview_left_text == nil and tab.preview_right_text == nil) then return false end
    view = self:ensure_history_diff_view(tab)
  else
    return false
  end
  local focus
  if side == "right" or side == "b" or side == 2 then
    focus = view and view.buffer_view_b
  elseif side == "left" or side == "a" or side == 1 then
    focus = view and view.buffer_view_a
  else
    focus = self.focused_diff_buffer_view or view and view.get_focus_view and view:get_focus_view()
  end
  if not focus then return false end
  self.focused_pane_name = nil
  self.focus_pane = "diff"
  self.focused_diff_buffer_view = focus
  focus.git_owner_view = self
  if panes.pane_for_view(self) then panes.register_focus_target(self, focus) end
  return with_git_session_event_window(self.git_session, function()
    core.set_active_view(focus)
    if core.active_view then core.active_view.git_owner_view = self end
    return true
  end)
end

function GitView:focus_pane_view(name)
  self:update_pane_buffers()
  local view = self:pane_view(name)
  self.focused_pane_name = name
  self.focus_pane = "buffer"
  view.git_owner_view = self
  if panes.pane_for_view(self) then panes.register_focus_target(self, view) end
  return with_git_session_event_window(self.git_session, function()
    core.set_active_view(view)
    return true
  end)
end

function GitView:get_surface_focus_targets()
  self:update_pane_buffers()
  local tab = self:model_tab()
  if not tab then return {} end
  if tab.kind == "commit_diff" then
    local targets = { self:pane_view("file-list") }
    if not tab.loading_file and not tab.file_error
        and (tab.left_text ~= nil or tab.right_text ~= nil) then
      local diff = self:ensure_diff_view(tab)
      targets[#targets + 1] = diff.buffer_view_a
      targets[#targets + 1] = diff.buffer_view_b
    end
    return targets
  elseif tab.kind == "file_history" then
    local targets = { self:pane_view("history-list") }
    if not tab.preview_loading and not tab.preview_error
        and (tab.preview_left_text ~= nil or tab.preview_right_text ~= nil) then
      local diff = self:ensure_history_diff_view(tab)
      targets[#targets + 1] = diff.buffer_view_a
      targets[#targets + 1] = diff.buffer_view_b
    end
    return targets
  end
  return { self:pane_view("log-list"), self:pane_view("details") }
end

function GitView:focus_surface_target(target)
  self:activate_model_tab(function() core.redraw = true end)
  if target and target.git_owner_view == self and target.git_pane then
    return self:focus_pane_view(target.git_pane)
  end
  local tab = self:model_tab()
  if tab and tab.kind == "commit_diff" and tab.diff_view then
    if target == tab.diff_view.buffer_view_a then return self:focus_diff_pane("left") end
    if target == tab.diff_view.buffer_view_b then return self:focus_diff_pane("right") end
  end
  if tab and tab.kind == "file_history" and tab.history_diff_view then
    if target == tab.history_diff_view.buffer_view_a then return self:focus_diff_pane("left") end
    if target == tab.history_diff_view.buffer_view_b then return self:focus_diff_pane("right") end
  end
  return false
end

function GitView:focus_list_pane()
  local tab = self:model_tab()
  self.focus_pane = "list"
  if tab and tab.kind == "file_history" then return self:focus_pane_view("history-list") end
  if tab and tab.kind == "commit_diff" then return self:focus_pane_view("file-list") end
  return self:focus_pane_view("log-list")
end

function GitView:history_commits_y()
  return self:commit_list_y()
end

function GitView:history_visible_height()
  return self.size.y - (self:history_commits_y() - self.position.y) - style.padding.y
end

function GitView:clamp_history_scroll(tab)
  if not tab then return end
  local rows = #(tab.commits or {}) + ((tab.has_more or (tab.loading and not tab.refreshing)) and 1 or 0)
  local max_scroll = math.max(0, rows * self:row_height() - self:history_visible_height())
  tab.scroll = common.clamp(tab.scroll or 0, 0, max_scroll)
end

function GitView:draw_history_tab(tab, x, y)
  local list_width = math.floor(self.size.x * 0.34)
  local diff_x = self.position.x + list_width + style.padding.x
  local list_right = diff_x - style.padding.x
  local top = self:history_commits_y()
  local list = self:pane_view("history-list")
  list.position.x, list.position.y = x, top
  list.size.x, list.size.y = math.max(0, list_width - style.padding.x), self.position.y + self.size.y - top - style.padding.y
  list:draw()
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)
  if tab.error then
    renderer.draw_text(
      style.prose_font,
      "Git error: " .. tostring(tab.error.message or tab.error.kind or tab.error),
      diff_x + style.padding.x, top, style.error
    )
    return
  end
  if tab.preview_loading and not tab.history_diff_view then
    renderer.draw_text(style.prose_font, "Loading file comparison...", diff_x + style.padding.x, top, style.dim)
    return
  end
  if tab.preview_error then
    renderer.draw_text(style.prose_font,
      "Git error: " .. tostring(tab.preview_error.message or tab.preview_error.kind or tab.preview_error),
      diff_x + style.padding.x, top, style.error)
    return
  end
  if tab.preview_left_text == nil and tab.preview_right_text == nil then
    renderer.draw_text(style.prose_font, "Select a revision", diff_x + style.padding.x, top, style.dim)
    return
  end
  local view = self:ensure_history_diff_view(tab)
  view.position.x, view.position.y = diff_x, top
  view.size.x = self.position.x + self.size.x - diff_x - style.padding.x
  view.size.y = self.position.y + self.size.y - top - style.padding.y
  view:update()
  view:draw()
end

function GitView:layout_diff_tab(tab, x)
  local list_width = math.floor(self.size.x * 0.28)
  local diff_x = self.position.x + list_width + style.padding.x
  local list_right = diff_x - style.padding.x
  local diff_y = self:commit_list_y()
  local list = self:pane_view("file-list")
  list.position.x, list.position.y = x, diff_y
  list.size.x, list.size.y = math.max(0, list_width - style.padding.x),
    self.position.y + self.size.y - diff_y - style.padding.y
  if not tab.file_scroll_applied then
    list.scroll.y = tab.file_scroll or 0
    list.scroll.to.y = list.scroll.y
    tab.file_scroll_applied = true
  end
  local diff_w = self.position.x + self.size.x - diff_x - style.padding.x
  local diff_h = self.position.y + self.size.y - diff_y - style.padding.y
  local view
  if tab.diff_view or (not tab.loading_file and not tab.file_error
    and (tab.left_text ~= nil or tab.right_text ~= nil))
  then
    view = self:ensure_diff_view(tab)
    view.position.x, view.position.y = diff_x, diff_y
    view.size.x, view.size.y = diff_w, diff_h
  end
  return list, diff_x, list_right, diff_y, diff_w, diff_h, view
end

local function draw_diff_status(text, color, x, y)
  local font = style.prose_font
  local pad_x = style.padding.x * 0.75
  local pad_y = style.padding.y * 0.5
  local width = font:get_width(text) + pad_x * 2
  local height = font:get_height() + pad_y * 2
  renderer.draw_rect(x, y, width, height, style.background)
  renderer.draw_rect(x, y + height - SCALE, width, SCALE, style.divider)
  renderer.draw_text(font, text, x + pad_x, y + pad_y, color)
end

function GitView:draw_diff_tab(tab, x, y)
  local list, diff_x, list_right, diff_y, _, _, view =
    self:layout_diff_tab(tab, x)
  list:draw()
  renderer.draw_rect(list_right, self.position.y, 1 * SCALE, self.size.y, style.divider)

  if view then view:draw() end

  if tab.loading_file then
    if self:file_loading_indicator_visible(tab) then
      draw_diff_status(
        "Loading file diff...", style.dim,
        diff_x + style.padding.x, diff_y + style.padding.y
      )
    end
    return
  end
  if tab.file_error then
    draw_diff_status(
      "Git error: " .. tostring(tab.file_error.message or tab.file_error.kind or tab.file_error),
      style.error, diff_x + style.padding.x, diff_y + style.padding.y
    )
    return
  end
  if tab.non_text then
    draw_diff_status(
      tab.non_text.message or "This file cannot use the text Diff View",
      style.dim, diff_x + style.padding.x, diff_y + style.padding.y
    )
    return
  end
  if tab.left_text == nil and tab.right_text == nil then
    renderer.draw_text(style.prose_font, "Select a changed file", diff_x + style.padding.x, diff_y, style.dim)
    return
  end
end

function GitView:draw()
  self:draw_background(style.background)
  local x = self.position.x + style.padding.x
  local y = self.position.y + style.padding.y
  local tab = self:model_tab()
  if not tab then
    renderer.draw_text(style.prose_font, "Git tab is no longer available", x, y, style.dim)
  elseif tab.kind == "commit_diff" then
    self:draw_diff_tab(tab, x, y)
  elseif tab.kind == "file_history" then
    self:draw_history_tab(tab, x, y)
  else
    self:draw_log_tab(self.model:log_tab(), x, y)
  end
end

return GitView
