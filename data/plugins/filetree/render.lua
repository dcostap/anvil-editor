-- mod-version:3
-- Shared File Tree-style rendering helpers for project-relative file rows.

local config = require "core.config"
local style = require "core.style"

local render = {}

function render.stronger_git_kind(a, b)
  local rank = {
    deleted = 7,
    added = 6,
    modified = 5,
    renamed = 5,
    copied = 5,
    typechange = 5,
    unmerged = 5,
    untracked = 2,
    ignored = 1,
  }
  if not a or (rank[b] or 0) > (rank[a] or 0) then return b end
  return a
end

function render.git_text_color(kind)
  if kind == "ignored" then return style.filetree_git_status_ignored end
  if kind == "untracked" then return style.filetree_git_status_untracked end
  if kind == "added" then return style.filetree_git_status_added end
  if kind == "modified" or kind == "renamed" or kind == "copied" or kind == "typechange" or kind == "unmerged" then
    return style.filetree_git_status_modified
  end
  if kind == "deleted" then return style.filetree_git_status_deleted end
end

function render.git_gutter_color(kind)
  if kind == "addition" or kind == "added" or kind == "untracked" then return style.git_change_addition end
  if kind == "modification" or kind == "modified" or kind == "renamed" or kind == "copied" or kind == "typechange" or kind == "unmerged" then
    return style.git_change_modification
  end
  if kind == "deletion" or kind == "deleted" then return style.git_change_deletion end
end

function render.changed_stat_segments(stat, font)
  if not (stat and ((stat.additions or 0) > 0 or (stat.deletions or 0) > 0)) then return nil end
  return {
    { text = string.format("+%d", stat.additions or 0), font = font, color = style.filetree_git_line_additions },
    { text = string.format(" −%d", stat.deletions or 0), font = font, color = style.filetree_git_line_deletions },
  }
end

function render.draw_folder_row_background(view, is_dir, x, y, width)
  local color = config.plugins.filetree and config.plugins.filetree.folder_row_background
  if not (is_dir and color) then return false end
  renderer.draw_rect(x, y, width, view:get_line_height(), color)
  return true
end

function render.row_text_color(kind, is_dir)
  return render.git_text_color(kind)
    or (is_dir and config.plugins.filetree and config.plugins.filetree.folder_color)
    or (is_dir and style.filetree_folder)
    or nil
end

function render.draw_row_text(view, text, x, y, kind, is_dir)
  local color = render.row_text_color(kind, is_dir)
  if not color then return false end
  renderer.draw_text(
    view:get_font(), text, x, y + view:get_line_text_y_offset(), color,
    { tab_offset = 0 }
  )
  return true
end

return render
