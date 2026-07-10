local core = require "core"
local common = require "core.common"
local config = require "core.config"
local images = require "core.markdown.images"
local keymap = require "core.keymap"
local vault_index = require "core.markdown.vault_index"

local attachments = {}

local IMAGE_EXTENSIONS = {
  avif = true, bmp = true, gif = true, jpeg = true, jpg = true,
  png = true, svg = true, webp = true,
}

local function extension(path)
  local ext = (path or ""):match("%.([^.\\/]+)$")
  return ext and ext:lower() or nil
end

local function is_file(path)
  local info = path and system.get_file_info(path)
  return info and info.type == "file"
end

local function copy_file(source, destination)
  local input, err = io.open(source, "rb")
  if not input then return false, err end
  local output
  output, err = io.open(destination, "wb")
  if not output then input:close(); return false, err end
  while true do
    local chunk = input:read(1024 * 1024)
    if not chunk then break end
    local ok
    ok, err = output:write(chunk)
    if not ok then input:close(); output:close(); os.remove(destination); return false, err end
  end
  input:close()
  output:close()
  return true
end

local function unique_destination(directory, basename)
  local stem, suffix = basename:match("^(.*)(%.[^.]+)$")
  stem, suffix = stem or basename, suffix or ""
  local candidate = directory .. PATHSEP .. basename
  local number = 1
  while system.get_file_info(candidate) do
    candidate = directory .. PATHSEP .. stem .. "-" .. number .. suffix
    number = number + 1
  end
  return candidate
end

local function display_path(path)
  return (path or ""):gsub("\\", "/")
end

local function file_uri(path)
  local value = display_path(common.normalize_path(path))
  if value:match("^%a:/") then return "file:///" .. value end
  return "file://" .. value
end

local function markdown_destination(path)
  return path:find("%s") and "<" .. path .. ">" or path
end

local function serialized_link(target, is_image, format)
  if format == "markdown" then
    local basename = target:match("[^/\\]+$") or target
    local label = is_image and "" or basename:gsub("%.[^.]+$", "")
    return (is_image and "!" or "") .. "[" .. label .. "](" .. markdown_destination(target) .. ")"
  end
  return (is_image and "!" or "") .. "[[" .. target .. "]]"
end

function attachments.import_file(view, source, opts)
  opts = opts or {}
  if not (view and view.doc and view.doc.abs_filename and is_file(source)) then
    return false, "source file unavailable"
  end
  if view.can_edit and not view:can_edit("markdown-attachment", { warn = true }) then
    return false, "Document is not editable"
  end
  local project = core.current_project(view.doc.abs_filename)
  if not project then return false, "Project unavailable" end
  local project_root = system.absolute_path(project.path) or common.normalize_path(project.path)
  local source_note = system.absolute_path(view.doc.abs_filename)
    or common.normalize_path(view.doc.abs_filename)
  local target = system.absolute_path(source) or common.normalize_path(source)
  local copied = false

  if opts.absolute then
    local text = serialized_link(file_uri(target), IMAGE_EXTENSIONS[extension(target) or ""] == true, "markdown")
    view:with_selection_state(function() view.doc:text_input(text) end)
    return true, { path = target, text = text, copied = false, absolute = true }
  end

  if not common.path_belongs_to(target, project_root) then
    local directory = images.attachment_directory({
      source_path = source_note,
      project_root = project_root,
      configured_folder = config.markdown_live_attachment_folder,
    })
    local directory_in_project = directory and (
      common.path_equals(directory, project_root)
      or common.path_belongs_to(directory, project_root)
    )
    if not directory_in_project then return false, "attachment directory is outside Project" end
    local info = system.get_file_info(directory)
    if not (info and info.type == "dir") then
      local ok, err = common.mkdirp(directory)
      if not ok then return false, err end
    end
    target = unique_destination(directory, common.basename(source))
    local ok, err = copy_file(source, target)
    if not ok then return false, err end
    copied = true
  end

  local format = config.markdown_live_attachment_link_format or "wikilink"
  local relative_base = format == "markdown" and common.dirname(source_note) or project_root
  local rel = display_path(common.relative_path(relative_base, target))
  local text = serialized_link(rel, IMAGE_EXTENSIONS[extension(target) or ""] == true, format)
  view:with_selection_state(function() view.doc:text_input(text) end)
  vault_index.index_for_path(view.doc.abs_filename):update_path(target, { cooperative = true })
  core.log_quiet("Markdown attachment %s %s -> %s", copied and "copied" or "linked", source, target)
  return true, { path = target, text = text, copied = copied }
end

function attachments.drop_provider()
  return {
    on_file_dropped = function(_, view, filename, x, y)
      if type(x) == "number" and type(y) == "number" then
        local line, col = view:resolve_screen_position(x, y)
        view:set_selection_state({ selections = { line, col, line, col }, last_selection = 1 })
      end
      local absolute = keymap.modkeys["alt"] == true
      local ok, err = attachments.import_file(view, filename, { absolute = absolute })
      if not ok then core.log_quiet("Markdown attachment drop declined: %s", tostring(err)) end
      return ok
    end,
  }
end

return attachments
