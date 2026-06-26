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
  self.project = project
  self.model = (opts and opts.model) or GitModel.new(project, opts)
  self.scrollable = true
  self:set_refresh_pending()
end

function GitView:__tostring()
  return "GitView"
end

function GitView:get_name()
  local path = type(self.project) == "table" and self.project.path or tostring(self.project or "")
  return "Git: " .. common.basename(path)
end

function GitView:set_refresh_pending()
  if self.refresh_started then return end
  self.refresh_started = true
  self.model:refresh_log(function()
    core.redraw = true
  end)
end

function GitView:get_focus_view()
  return self
end

function GitView:try_close(callback)
  if self.tool_window then
    self.tool_window:hide()
    return false
  end
  if callback then callback() end
  return true
end

function GitView:commit_list_y()
  return self.position.y + style.padding.y
    + style.font:get_height() + style.padding.y
    + style.font:get_height() + style.padding.y
end

function GitView:row_height()
  return style.font:get_height() + 2 * SCALE
end

function GitView:get_scrollable_size()
  local tab = self.model:log_tab()
  local rows = #tab.commits + ((tab.has_more or tab.loading_more) and 1 or 0)
  return self.size.y + math.max(0, rows * self:row_height() - (self.size.y - (self:commit_list_y() - self.position.y)))
end

function GitView:on_mouse_wheel(y, x)
  if y == 0 then return false end
  self.scroll.to.y = self.scroll.to.y + (-y * config.mouse_wheel_scroll)
  return true
end

function GitView:on_mouse_pressed(button, x, y, clicks)
  local scrollbar_handled = GitView.super.on_mouse_pressed(self, button, x, y, clicks)
  if scrollbar_handled then return true end
  if button ~= "left" then return true end
  local tab = self.model:log_tab()
  local list_width = math.floor(self.size.x * 0.45)
  if x < self.position.x or x > self.position.x + list_width then return true end
  local row_height = self:row_height()
  local index = math.floor((y - self:commit_list_y() + self.scroll.y) / row_height) + 1
  if index >= 1 and index <= #tab.commits then
    self.model:select_log_index(index)
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

function GitView:draw()
  self:draw_background(style.background)
  local x = self.position.x + style.padding.x
  local y = self.position.y + style.padding.y
  local tab = self.model:log_tab()
  renderer.draw_text(style.font, self:get_name(), x, y, style.text)
  y = y + style.font:get_height() + style.padding.y
  renderer.draw_text(style.font, "Tabs: [Log]", x, y, style.dim)
  y = y + style.font:get_height() + style.padding.y
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
    local color = i == tab.selected_commit and style.accent or style.text
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

return GitView
