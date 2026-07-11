local core = require "core"
local command = require "core.command"
local common = require "core.common"
local file_context = require "core.file_context"
local config = require "core.config"
local DocView = require "core.docview"
local MarkdownView = require "core.markdownview"
local markdown_completion = require "core.markdown.completion"
local markdown_live = require "core.markdown.live_render"
local markdown_tables = require "core.markdown.tables"
local markdown_rename_links = require "core.markdown.rename_links"
local markdown_vault_index = require "core.markdown.vault_index"

command.add(function()
  local view = core.active_view
  if view and view:extends(DocView) and markdown_live.is_markdown_doc(view.doc) then
    return true, view
  end
  return false
end, {
  ["markdown-live-preview:toggle-source-mode"] = function(view)
    markdown_live.toggle_source_mode(view, "command-toggle")
  end,
  ["markdown-live-preview:source-mode"] = function(view)
    markdown_live.set_source_mode(view, true, "command-source")
  end,
  ["markdown-live-preview:live-mode"] = function(view)
    markdown_live.set_source_mode(view, false, "command-live")
  end,
  ["markdown-live-preview:open-link"] = function(view)
    markdown_live.open_link(view)
  end,
  ["markdown-live-preview:create-link-target"] = function(view)
    markdown_live.create_link_target(view)
  end,
  ["markdown-live-preview:complete-link"] = function(view)
    markdown_completion.open(view)
  end,
  ["markdown-live-preview:load-remote-image"] = function(view)
    markdown_live.allow_remote_image_once(view)
  end,
  ["markdown-live-preview:trust-project-remote-images"] = function(view)
    markdown_live.set_project_remote_image_trust(view, true)
  end,
  ["markdown-live-preview:untrust-project-remote-images"] = function(view)
    markdown_live.set_project_remote_image_trust(view, false)
  end,
  ["markdown-live-preview:table-insert-row"] = function(view)
    markdown_tables.insert_row(view)
  end,
  ["markdown-live-preview:table-delete-row"] = function(view)
    markdown_tables.delete_row(view)
  end,
  ["markdown-live-preview:table-move-row-up"] = function(view)
    markdown_tables.move_row(view, -1)
  end,
  ["markdown-live-preview:table-move-row-down"] = function(view)
    markdown_tables.move_row(view, 1)
  end,
  ["markdown-live-preview:table-insert-column"] = function(view)
    markdown_tables.insert_column(view)
  end,
  ["markdown-live-preview:table-delete-column"] = function(view)
    markdown_tables.delete_column(view)
  end,
  ["markdown-live-preview:table-move-column-left"] = function(view)
    markdown_tables.move_column(view, -1)
  end,
  ["markdown-live-preview:table-move-column-right"] = function(view)
    markdown_tables.move_column(view, 1)
  end,
  ["markdown-live-preview:review-rename-link-updates"] = function(view)
    markdown_rename_links.present(markdown_vault_index.pending_rename(view.doc.abs_filename))
  end,
})

local markdown_preview_split_directions = {
  bottom = "down",
  top = "up",
  left = "left",
  right = "right"
}

local markdown_raw_split_directions = {
  bottom = "up",
  top = "down",
  left = "right",
  right = "left"
}

local function get_doc_preview(dv)
  local doc = dv.doc
  for _, view in ipairs(core.root_panel.root_node:get_children()) do
    if view:extends(MarkdownView) and view.linked_doc == doc then
      return view
    end
  end
end

local function get_raw_doc_view(path)
  for _, view in ipairs(core.root_panel.root_node:get_children()) do
    if view:extends(DocView) and view.doc and common.path_equals(view.doc.abs_filename, path) then
      return view
    end
  end
end

local function bind_preview_to_raw_view(mv, raw_view)
  if not (raw_view and raw_view:extends(DocView)) then
    return
  end
  mv.linked_doc = raw_view.doc
  mv.path = raw_view.doc.abs_filename
  mv.title = raw_view.doc:get_name()
  mv:refresh_from_doc()
end

local function open_raw_doc_view(path, mv)
  local doc = core.open_doc(path)
  local node = core.root_panel.root_node:get_node_for_view(mv)
    or core.root_panel:get_active_node_default()
  if config.markdown_preview_mode == "newtab" then
    for _, view in ipairs(node.views) do
      if view:extends(DocView) and view.doc == doc then
        file_context.mark_editor_view(view)
        node:set_active_view(view)
        return view
      end
    end
    local view = file_context.mark_editor_view(DocView(doc))
    node:add_view(view)
    core.root_panel.root_node:update_layout()
    view:scroll_to_line(view.doc:get_selection(), true, true)
    return view
  end

  local view = file_context.mark_editor_view(DocView(doc))
  local split_direction = markdown_raw_split_directions[config.markdown_preview_mode] or "left"
  node:split(split_direction, view)
  core.root_panel.root_node:update_layout()
  view:scroll_to_line(view.doc:get_selection(), true, true)
  return view
end

command.add(function()
  if not core.active_view:extends(DocView) then
    return false
  end
  local dv = core.active_view
  return MarkdownView.is_supported(dv.doc.filename or ""), dv
end, {
  ["markdown-view:preview"] = function(dv)
    local view = get_doc_preview(dv)
    if view then
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then
        node:set_active_view(view)
      end
      return
    end

    local node = core.root_panel.root_node:get_node_for_view(dv)
      or core.root_panel:get_active_node_default()
    view = MarkdownView({
      linked_doc = dv.doc,
      path = dv.doc.abs_filename,
      title = dv.doc:get_name()
    })
    local mode = config.markdown_preview_mode
    local split_direction = markdown_preview_split_directions[mode]
    if mode == "newtab" then
      node:add_view(view)
    else
      (split_direction and node or core.root_panel:get_active_node_default()):split(
        split_direction or "right",
        view
      )
    end
    core.root_panel.root_node:update_layout()
  end
})

command.add(function()
  if core.active_view:extends(MarkdownView) and core.active_view:has_selection() then
    return true, core.active_view
  end
  return false
end, {
  ["markdown-view:copy"] = function(mv)
    mv:copy_selection()
  end
})

local function markdown_context_target_predicate(kind)
  return function()
    local mv = core.active_view
    local target = mv and mv.markdown_context_target
    local url = target and target[kind .. "_url"]
    if mv and mv:extends(MarkdownView) and url then
      return true, mv, target
    end
    return false
  end
end

command.add(markdown_context_target_predicate("link"), {
  ["markdown-view:copy-link"] = function(_, target)
    system.set_clipboard(target.link_url)
  end
})

command.add(markdown_context_target_predicate("image"), {
  ["markdown-view:copy-image-link"] = function(_, target)
    system.set_clipboard(target.image_url)
  end
})

command.add(function()
  if not core.active_view:extends(MarkdownView) then
    return false
  end
  local mv = core.active_view
  local path = mv.path
  return type(path) == "string" and path ~= "" and MarkdownView.is_supported(path), mv
end, {
  ["markdown-view:view-raw"] = function(mv)
    local raw_view = get_raw_doc_view(mv.path)
    if raw_view then
      local node = core.root_panel.root_node:get_node_for_view(raw_view)
      if node then
        node:set_active_view(raw_view)
      end
    else
      raw_view = open_raw_doc_view(mv.path, mv)
    end
    bind_preview_to_raw_view(mv, raw_view)
  end
})
