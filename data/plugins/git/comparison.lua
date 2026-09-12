local core = require "core"
local panes = require "core.panes"
local M = {}

function M.owner(source, tab)
  return (source.git_session and source.git_session.key or tostring(source.model)) .. "\0comparison\0" .. tab.id
end

local function read_bytes(path)
  if not path then return nil end
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

function M.attach(view, source, tab, point_source, selected_path)
  point_source = point_source or source:pane_view(source.tab_id == "log" and "details" or "file-list")
  local record = tab.changed_files[tab.selected_file]
  selected_path = selected_path or record and (record.new_path or record.path or record.old_path)
  view.pane_constraint = M.owner(source, tab)
  view.get_module = function() return "plugins.git.comparison" end
  view.get_state = function()
    local state = {
      source = source:get_state(), tab_id = tab.id, title = view:get_name(), selected_path = selected_path,
    }
    if view.buffer_view_a then
      state.contents = {}
      for index, side in ipairs { view.buffer_view_a, view.buffer_view_b } do
        local content = view.request.contents[index]
        state.contents[index] = {
          filename = content.kind == "file" and content.filename or nil,
          text = content.kind ~= "file" and table.concat(side.buffer.lines):gsub("\n$", "") or nil,
          name = content.name, source_path = content.source_path,
        }
      end
      state.content_titles = view.request.content_titles
    else
      local left = view.left_view and view.left_view.path
      local right = view.right_view and view.right_view.path
      state.images = {
        left = read_bytes(left), right = read_bytes(right),
        left_suffix = left and left:match("%.[^.]+$"),
        right_suffix = right and right:match("%.[^.]+$"),
      }
      state.left_title, state.right_title = view.left_title, view.right_title
    end
    return state
  end
  local function capture()
    local text = view:get_name()
    if view.buffer_view_a then
      text = text .. "\n\nBefore\n" .. table.concat(view.buffer_view_a.buffer.lines)
        .. "\nAfter\n" .. table.concat(view.buffer_view_b.buffer.lines)
    end
    return require("core.text_capture").open({ text = text, title = view:get_name() }, {
      pane = panes.pane_for_view(view), owner = view.pane_constraint,
    })
  end
  view.open_text_capture = capture
  if view.buffer_view_a then
    view.buffer_view_a.open_text_capture, view.buffer_view_b.open_text_capture = capture, capture
    local poi = require "core.poi"
    local project = core.root_project()
    local function continue_navigation(_, direction)
      if view.updater_idx or not view.diff_model or poi.get_remote_source(project) ~= point_source then return false end
      local current_tab = source:model_tab()
      if current_tab.kind == "log" then
        local commit = source:detail_commit_for_tab(current_tab)
        if not commit or not tab.commit or commit.hash ~= tab.commit.hash
            or commit.local_scope ~= tab.commit.local_scope then return false end
      elseif current_tab.id ~= tab.id then
        return false
      end
      local points = poi.points_for_view(point_source, { remote = true }) or {}
      for index, point in ipairs(points) do
        if (point.record.new_path or point.record.path or point.record.old_path) == selected_path then
          local next_point = points[index + direction]
          local pane = panes.pane_for_view(view)
          if not next_point or not pane then return false end
          poi.select(point_source, next_point, { remote = true, preview = false })
          core.log_quiet("Git comparison continues to %s", tostring(next_point.record.new_path or next_point.record.old_path))
          return poi.activate(point_source, next_point, {
            pane = pane, placement = "current", remote = true, change_direction = direction,
          })
        end
      end
      return false
    end
    view.buffer_view_a.continue_point_of_interest = continue_navigation
    view.buffer_view_b.continue_point_of_interest = continue_navigation
  end
  return view
end

function M.from_state(state)
  local source = require("plugins.git.view").from_state(state.source)
  local tab = source and source.model:find_tab(state.tab_id)
  if not tab then return nil end
  local view
  if state.contents then
    local diff = require "plugins.diffview"
    local contents = {}
    for index, saved in ipairs(state.contents) do
      contents[index] = saved.filename and diff.content.file(saved.filename)
        or diff.content.text(saved.text or "", { name = saved.name, source_path = saved.source_path, editable = false })
    end
    view = diff.open({ title = state.title, contents = contents, content_titles = state.content_titles }, true)
  elseif state.images then
    local paths = {}
    for _, side in ipairs { "left", "right" } do
      if state.images[side] then
        paths[side] = core.temp_filename(state.images[side .. "_suffix"] or ".png")
        local file = assert(io.open(paths[side], "wb"))
        file:write(state.images[side]); file:close()
      end
    end
    view = require("core.imagecomparisonview") {
      left_path = paths.left, right_path = paths.right,
      left_title = state.left_title, right_title = state.right_title,
    }
    local close = view.on_close
    view.on_close = function(self)
      close(self)
      for _, path in pairs(paths) do os.remove(path) end
    end
  end
  return view and M.attach(view, source, tab, nil, state.selected_path)
end

return M
