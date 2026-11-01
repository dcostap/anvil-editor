local core = require "core"
local common = require "core.common"
local config = require "core.config"
local file_ops = require "core.file_ops"
local fs = require "core.fs"
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
  while file_ops.info(candidate) do
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

---Insert a link to `source` at the selection. Copy files outside the Project into its
---attachment folder. `opts.absolute` links any existing file or folder by file URI.
---`opts.prefix` is inserted before the link.
---For a note on a Machine, the copy uploads the file, and the calling coroutine waits (`file_ops.run`).
---The link goes at the selection of the paste. After an edit or a close during the wait, no link goes in.
function attachments.import_file(view, source, opts)
  opts = opts or {}
  local prefix = opts.prefix or ""
  local source_info = source and system.get_file_info(source)
  if not (view and view.buffer and view.buffer.abs_filename and source_info) then
    return false, "source path unavailable"
  end
  if view.can_edit and not view:can_edit("markdown-attachment", { warn = true }) then
    return false, "Buffer is not editable"
  end
  local target = system.absolute_path(source) or common.normalize_path(source)
  local remote = fs.on_machine(view.buffer.abs_filename)
  local buffer, selection, revision = view.buffer, view:get_selection_state(), view.buffer.text_revision
  local note_path = buffer.abs_filename

  if opts.absolute then
    -- A link to a file of this PC means nothing on the Machine.
    if remote then return false, "the note is on another Machine" end
    local text = serialized_link(file_uri(target), IMAGE_EXTENSIONS[extension(target) or ""] == true, "markdown")
    view:with_selection_state(function() view.buffer:text_input(prefix .. text) end)
    return true, { path = target, text = text, copied = false, absolute = true }
  end

  if source_info.type ~= "file" then return false, "source is not a file" end
  local project = core.current_project(view.buffer.abs_filename)
  if not project then return false, "Project unavailable" end
  local function absolute(path)
    return not remote and system.absolute_path(path) or common.normalize_path(path)
  end
  local project_root = absolute(project.path)
  local source_note = absolute(view.buffer.abs_filename)
  local copied = false

  -- A source file is on this PC, so a note on a Machine always gets a copy.
  if remote or not common.path_belongs_to(target, project_root) then
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
    local info = file_ops.info(directory)
    if not (info and info.type == "dir") then
      local ok, err = file_ops.mkdirp(directory)
      if not ok then return false, err end
    end
    target = unique_destination(directory, common.basename(source))
    local ok, err
    if remote then
      local input = io.open(source, "rb")
      if not input then return false, "cannot read " .. source end
      local bytes = input:read("*a")
      input:close()
      ok, err = file_ops.create(target, bytes)
    else
      ok, err = copy_file(source, target)
    end
    if not ok then return false, err end
    copied = true
  end

  local format = config.markdown_live_attachment_link_format or "wikilink"
  local relative_base = format == "markdown" and common.dirname(source_note) or project_root
  local rel = display_path(common.relative_path(relative_base, target))
  local text = serialized_link(rel, IMAGE_EXTENSIONS[extension(target) or ""] == true, format)
  -- A note with a new name can be in another folder, and a Markdown link is relative to its folder.
  if view.textview_closed or view.buffer ~= buffer or buffer.text_revision ~= revision
      or buffer.abs_filename ~= note_path then
    core.warn("Anvil copied %s, but the note changed during the copy. Anvil did not insert its link.", target)
    return false, "the note changed during the copy"
  end
  if remote then view:set_selection_state(selection) end
  view:with_selection_state(function() view.buffer:text_input(prefix .. text) end)
  -- A Machine's Project has no vault index yet (docs/machines.md, step 9).
  if not remote then
    vault_index.index_for_path(view.buffer.abs_filename):update_path(target, { cooperative = true })
  end
  core.log_quiet("Markdown attachment %s %s -> %s", copied and "copied" or "linked", source, target)
  return true, { path = target, text = text, copied = copied }
end

local CLIPBOARD_IMAGE_FORMATS = {
  { mime = "image/png", extension = "png" },
  { mime = "image/jpeg", extension = "jpg" },
  { mime = "image/bmp", extension = "bmp" },
}

function attachments.paste_provider()
  return {
    on_clipboard_paste = function(_, view)
      if type(system.get_clipboard_data) ~= "function" then return false end
      local text = system.get_clipboard and system.get_clipboard()
      if text and text ~= "" then return false end
      local data, format
      for _, candidate in ipairs(CLIPBOARD_IMAGE_FORMATS) do
        data = system.get_clipboard_data(candidate.mime)
        if data and #data > 0 then format = candidate break end
      end
      if not format then return false end

      local temp_dir = USERDIR .. PATHSEP .. ".markdown-clipboard-"
        .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
      local ok, err = common.mkdirp(temp_dir)
      if not ok then
        core.log_quiet("Markdown clipboard attachment temp directory failed: %s", tostring(err))
        return false
      end
      local temp_path = temp_dir .. PATHSEP .. "pasted-image." .. format.extension
      local file
      file, err = io.open(temp_path, "wb")
      if file then
        local wrote
        wrote, err = file:write(data)
        file:close()
        if not wrote then file = nil end
      end
      if not file then
        common.rm(temp_dir, true)
        core.log_quiet("Markdown clipboard attachment temp write failed: %s", tostring(err))
        return false
      end

      local imported, result
      file_ops.run(view.buffer.abs_filename, function()
        imported, result = attachments.import_file(view, temp_path)
        common.rm(temp_dir, true)
        if not imported then
          core.error("Could not import clipboard image: %s", tostring(result))
          return
        end
        core.log_quiet("Markdown clipboard image imported from %s", format.mime)
      end)
      -- On a Machine the upload continues in the background.
      return imported ~= false
    end,
  }
end

function attachments.drop_provider()
  return {
    on_files_dropped = function(_, view, files, x, y)
      if view.can_edit and not view:can_edit("markdown-attachment", { warn = true }) then
        return false
      end
      if type(x) == "number" and type(y) == "number" then
        local line, col = view:resolve_screen_position(x, y)
        view:set_selection_state({ selections = { line, col, line, col }, last_selection = 1 })
      end
      local absolute = keymap.modkeys["alt"] == true
      local linked
      -- On a Machine each file uploads in the background, so the drop counts as accepted.
      file_ops.run(view.buffer.abs_filename, function()
        linked = 0
        for _, filename in ipairs(files) do
          local prefix = linked > 0 and "\n" or nil
          local ok, err = attachments.import_file(view, filename, { absolute = absolute, prefix = prefix })
          if not ok and not absolute and not fs.on_machine(view.buffer.abs_filename) then
            core.log_quiet("Markdown attachment drop links %s by absolute path: %s", filename, tostring(err))
            ok, err = attachments.import_file(view, filename, { absolute = true, prefix = prefix })
          end
          if ok then
            linked = linked + 1
          elseif fs.on_machine(view.buffer.abs_filename) then
            core.error("Could not upload %s: %s", filename, tostring(err))
          else
            core.log_quiet("Markdown attachment drop declined %s: %s", filename, tostring(err))
          end
        end
      end)
      if linked == nil then return #files > 0 end
      return linked > 0
    end,
  }
end

return attachments
