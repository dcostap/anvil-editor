-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local range_marker = require "core.range_marker"
local Editor = require "core.editor"
local bookmarks = require "core.bookmarks"

local plugin = {}

local function caret(view)
  return view:with_selection_state(function() return view.buffer:get_selection() end)
end

local function selected_bookmark()
  local picker = core.fuzzy_searcher_active_view
  local result = picker and picker:selected_result()
  if result and result.kind == "bookmark" then return result.bookmark, picker end
  local view = core.active_view
  if view and view:extends(Editor) then return bookmarks.at(view.buffer, caret(view)) end
end

function plugin.rename(mark)
  core.global_prompt_bar:enter("Bookmark name — optional", {
    text = mark.name, select_text = true, show_suggestions = false,
    submit = function(name) bookmarks.rename(mark, name) end,
  })
end

function plugin.remove(mark)
  core.nag_view:show("Remove Bookmark", "Remove this Bookmark: " .. (mark.name ~= "" and mark.name or mark.text) .. "?", {
    { text = "Cancel", default_no = true },
    { text = "Remove", default_yes = true },
  }, function(option)
    if option.default_yes then bookmarks.remove(mark) end
  end)
end

function plugin.actions(mark, source_view)
  local options = { { text = "Rename" }, { text = "Remove" } }
  if source_view and source_view:extends(Editor) and source_view.buffer.abs_filename
      and not source_view.buffer.git_historical_key then
    options[#options + 1] = { text = "Attach to source caret" }
  end
  core.global_prompt_bar:enter("Bookmark action", {
    text = "", suggest = function() return options end,
    submit = function(_, option)
      if not option then return end
      if option.text == "Rename" then plugin.rename(mark)
      elseif option.text == "Remove" then plugin.remove(mark)
      elseif source_view.textview_closed or not core.buffer_registry:identity(source_view.buffer) then
        core.warn("Bookmark source Editor no longer exists")
      else
        local ok, reason = bookmarks.retarget(mark, source_view.buffer, caret(source_view))
        if not ok then core.warn("%s", reason) end
      end
    end,
  })
end

command.add(function()
  local view = core.active_view
  return view and view:extends(Editor) and view.buffer.abs_filename
    and not view.buffer.git_historical_key, view
end, {
  ["bookmark:toggle"] = command.palette(function(view)
    local line = caret(view)
    local mark = bookmarks.at(view.buffer, line)
    if mark then return plugin.remove(mark) end
    local buffer, root = view.buffer, core.root_project().path
    local target = range_marker.new(buffer, {
      line1 = line, col1 = 1,
      line2 = line < #buffer.lines and line + 1 or line,
      col2 = line < #buffer.lines and 1 or #buffer.lines[line],
      greedy_left = true, greedy_right = true, sticky_right_on_newline = true,
      kind = "bookmark-prompt",
    })
    local options = {
      text = "", show_suggestions = false,
      cancel = function() range_marker.remove(target) end,
      submit = function(name)
        local range = target:range()
        range_marker.remove(target)
        if not common.path_equals(root, core.root_project().path) then
          core.warn("Selected Project changed. Add the Bookmark again.")
        elseif not core.buffer_registry:identity(buffer) then
          core.warn("Bookmark source Buffer no longer exists")
        elseif not range then core.warn("Bookmark target no longer exists")
        else
          local mark, reason = bookmarks.add(buffer, range.line1, name)
          if not mark then core.warn("%s", reason) end
        end
      end,
    }
    core.global_prompt_bar:enter("Bookmark name — optional", options)
    if core.global_prompt_bar.state.submit ~= options.submit then range_marker.remove(target) end
  end),
})

command.add(function()
  local mark, picker = selected_bookmark()
  return mark ~= nil, mark, picker
end, {
  ["bookmark:rename"] = command.palette(function(mark, picker)
    if picker then picker:close() end
    plugin.rename(mark)
  end),
  ["bookmark:remove"] = command.palette(function(mark, picker)
    if picker then picker:close() end
    plugin.remove(mark)
  end),
})

keymap.add { ["ctrl+b"] = "bookmark:toggle" }

local exit = core.exit
function core.exit(...)
  bookmarks.flush()
  return exit(...)
end

return plugin
