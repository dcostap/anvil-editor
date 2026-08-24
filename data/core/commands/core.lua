local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local LogView = require "core.logview"
local panes = require "core.panes"


local previous_win_mode = "normal"
local previous_win_pos = core.window_size
local restore_title_bar = false

local function suggest_directory(text)
  text = common.home_expand(text)
  local basedir = common.dirname(core.root_project().path)
  return common.home_encode_list((basedir and text == basedir .. PATHSEP or text == "") and
    core.recent_projects or common.dir_path_suggest(
      text, core.root_project().path, config.max_visible_commands
    ))
end

local function check_directory_path(path)
    local abs_path = system.absolute_path(path)
    local info = abs_path and system.get_file_info(abs_path)
    if not info or info.type ~= 'dir' then
      return nil
    end
    return abs_path
end

local function file_prompt_defaults()
  local view = core.active_view
  local default_text, root_dir = "", core.root_project().path
  if view.buffer and view.buffer.abs_filename then
    local dirname = common.dirname(view.buffer.abs_filename)
    if dirname and common.path_belongs_to(dirname, root_dir) then
      dirname = core.normalize_to_project_dir(dirname)
      default_text = dirname == root_dir and "" or common.home_encode(dirname) .. PATHSEP
    elseif dirname then
      root_dir = dirname
    end
  end
  return default_text, root_dir
end

local function path_ends_with_separator(path)
  return PLATFORM == "Windows" and path:match("[/\\]$") ~= nil
    or PLATFORM ~= "Windows" and path:sub(-1) == PATHSEP
end

local function ensure_trailing_separator(path)
  return path_ends_with_separator(path) and path or path .. PATHSEP
end

local function resolve_file_prompt_path(text, root_dir)
  local expanded = common.home_expand(common.sanitize_prompt_path(text))
  if common.is_absolute_path(expanded) then
    return system.absolute_path(expanded) or expanded
  end
  if common.path_equals(root_dir, core.root_project().path) then
    return core.root_project():absolute_path(expanded)
  end
  return system.absolute_path(root_dir .. PATHSEP .. expanded)
    or root_dir .. PATHSEP .. expanded
end

local function is_missing_path_error(err)
  if not err then return true end
  err = err:lower()
  return err:find("no such file", 1, true) ~= nil
    or err:find("cannot find", 1, true) ~= nil
end

local function open_file(label, selection_callback, allow_directories)
  local default_text, root_dir = file_prompt_defaults()
  local filename = ""

  core.global_prompt_bar:enter(label or "Open File", {
    text = default_text,
    submit = function(text)
      if not selection_callback then
        core.open_file(filename)
      else
        selection_callback(filename)
      end
    end,
    suggest = function(text)
      return common.home_encode_list(
        common.path_suggest(
          common.home_expand(common.sanitize_prompt_path(text)), root_dir,
          config.max_visible_commands
        )
      )
    end,
    validate = function(text, suggestion)
      text = suggestion and suggestion.text or text
      text = common.sanitize_prompt_path(text)
      filename = resolve_file_prompt_path(text, root_dir) or filename
      local path_stat, err = system.get_file_info(filename)
      if not path_stat then
        if filename == "" or not is_missing_path_error(err) then
          core.error("Cannot open file %s: %s", text, err or "unknown error")
          return false
        end
        if path_ends_with_separator(text) then
          local created, create_err, failed_path = common.mkdirp(filename)
          if not created then
            core.error("Cannot create folder %s: %s", failed_path or filename, create_err or "unknown error")
            return false
          end
          core.log("Created folder: %s", filename:gsub("[/\\]+$", ""))
          core.global_prompt_bar:set_text(ensure_trailing_separator(text))
          core.global_prompt_bar:update_suggestions()
          return false
        end

        local dirname = common.dirname(filename)
        local dir_stat = dirname and system.get_file_info(dirname)
        if not dirname or (dir_stat and dir_stat.type == "dir") then
          return true
        elseif not dir_stat then
          local created, create_err, failed_path = common.mkdirp(dirname)
          if not created then
            core.error("Cannot create folders %s: %s", failed_path or dirname, create_err or "unknown error")
            return false
          end
          core.log("Created folders: %s", dirname)
          return true
        end
        core.error("Cannot open file %s: parent is not a folder", text)
        return false
      elseif path_stat.type == 'dir' then
        if allow_directories and selection_callback then
          return true
        end
        core.global_prompt_bar:set_text(ensure_trailing_separator(text))
        core.global_prompt_bar:update_suggestions()
        return false
      else
        return true
      end
    end,
  })
end

local function open_file_with_system_file_picker(label, selection_callback)
  local default_text = file_prompt_defaults()
  core.open_file_dialog(core.window, function(status, result)
    if status == "accept" then
      for _, filename in ipairs(result --[[ @as string[] ]]) do
        if not selection_callback then
          core.open_file(filename)
        else
          selection_callback(filename)
        end
      end
    elseif status == "error" then
      core.error("Error while opening dialog: %s", result or "")
    end
  end, {
    default_location = default_text,
    allow_many = true,
  })
end

local function directory_prompt_default_text()
  local dirname = common.dirname(core.root_project().path)
  return dirname and common.home_encode(dirname) .. PATHSEP or nil
end

local function directory_system_picker_default_location()
  return common.dirname(core.root_project().path)
end

local function open_directory(label, allow_many, callback, select_text)
  core.global_prompt_bar:enter(label, {
    text = directory_prompt_default_text(),
    submit = function(text)
      local path = common.home_expand(common.sanitize_prompt_path(text))
      local abs_path = check_directory_path(path)
      if not abs_path then
        core.error("Cannot open directory %q", path)
        return
      end
      callback({abs_path})
    end,
    suggest = function(text)
      return suggest_directory(common.sanitize_prompt_path(text))
    end,
    select_text = select_text
  })
end

local function open_directory_with_system_file_picker(label, allow_many, callback)
  core.open_directory_dialog(core.window, function(status, result)
    if status == "accept" then
      callback(result)
    elseif status == "error" then
      core.error("Error while opening dialog: %s", result or "")
    end
  end, {
    default_location = directory_system_picker_default_location(),
    allow_many = allow_many,
    title = label,
  })
end

local function change_project_directory()
  open_directory("Change Project Folder", false, function(abs_path)
    if common.path_equals(abs_path[1], core.root_project().path) then return end
    core.confirm_close_buffers(core.buffers, function(dirpath)
      core.open_project_in_same_window(dirpath)
    end, abs_path[1])
  end)
end

local function change_project_directory_with_system_file_picker()
  open_directory_with_system_file_picker("Change Project Folder", false, function(abs_path)
    if common.path_equals(abs_path[1], core.root_project().path) then return end
    core.confirm_close_buffers(core.buffers, function(dirpath)
      core.open_project_in_same_window(dirpath)
    end, abs_path[1])
  end)
end

local function open_project_directory()
  open_directory("Open Project", false, function(abs_path)
    if common.path_equals(abs_path[1], core.root_project().path) then
      core.error("Directory %q is currently opened", abs_path[1])
      return
    end
    core.open_project_in_new_window(abs_path[1])
  end, true)
end

local function open_project_directory_with_system_file_picker()
  open_directory_with_system_file_picker("Open Project", false, function(abs_path)
    if common.path_equals(abs_path[1], core.root_project().path) then
      core.error("Directory %q is currently opened", abs_path[1])
      return
    end
    core.open_project_in_new_window(abs_path[1])
  end)
end

local function add_project_directory()
  open_directory("Add Directory", true, function(abs_path)
    for _, dir in ipairs(abs_path) do
      core.add_project(system.absolute_path(dir))
    end
  end)
end

local function add_project_directory_with_system_file_picker()
  open_directory_with_system_file_picker("Add Directory", true, function(abs_path)
    for _, dir in ipairs(abs_path) do
      core.add_project(system.absolute_path(dir))
    end
  end)
end

command.add(nil, {
  ["core:quit"] = command.palette(function()
    core.quit()
  end),

  ["core:restart"] = command.palette(function()
    core.restart()
  end),

  ["core:new_anvil_window"] = command.palette(function()
    return core.open_new_window()
  end),

  ["core:force_quit"] = function()
    core.quit(true)
  end,

  ["core:toggle_fullscreen"] = command.palette(function()
    local current_mode = system.get_window_mode(core.window)
    local fullscreen = current_mode == "fullscreen"
    if current_mode ~= "fullscreen" then
      previous_win_mode = current_mode
      if current_mode == "normal" then
        previous_win_pos = table.pack(system.get_window_size(core.window))
      end
    end
    if not fullscreen then
      restore_title_bar = core.title_bar.visible
    end
    system.set_window_mode(core.window, fullscreen and previous_win_mode or "fullscreen")
    core.show_title_bar(fullscreen and restore_title_bar)
    core.title_bar:configure_hit_test(fullscreen and restore_title_bar)
    if fullscreen and previous_win_mode == "normal" then
      system.set_window_size(core.window, table.unpack(previous_win_pos))
    end
  end),

  ["core:reload_module"] = function()
    core.global_prompt_bar:enter("Reload Module", {
      submit = function(text, item)
        text = item and item.text or text
        core.reload_module(text)
        core.log("Reloaded module %q", text)
      end,
      suggest = function(text)
        local items = {}
        for name in pairs(package.loaded) do
          table.insert(items, name)
        end
        return common.fuzzy_match(items, text)
      end
    })
  end,

  ["core:pick_file"] = function(label, selection_callback, allow_directories)
    if type(label) ~= "string" then
      label, selection_callback, allow_directories = nil, nil, nil
    end
    open_file(label, selection_callback, allow_directories)
  end,

  ["core:pick_file_with_system_picker"] = function(label, selection_callback)
    open_file_with_system_file_picker(label, selection_callback)
  end,

  ["log:open"] = command.palette(function()
    panes.place(function() return LogView() end, {
      placement = "current",
      focus = true,
      reason = "open-log",
    })
  end, {
    keywords = { "messages", "diagnostics" },
    opens_view = true,
  }),

  ["core:open_user_module"] = function()
    core.open_file(USERDIR .. "/init.lua", { placement = "current", focus = true })
  end,

  ["core:open_project_module"] = function()
    if not system.get_file_info(".anvil_project.lua") then
      core.try(core.write_init_project_module, ".anvil_project.lua")
    end
    core.open_file(".anvil_project.lua", { placement = "current", focus = true })
  end,

  ["core:change_project_folder"] = function()
    change_project_directory()
  end,

  ["core:change_project_folder_system_file_picker"] = function()
    change_project_directory_with_system_file_picker()
  end,

  ["core:open_project_folder"] = function()
    open_project_directory()
  end,

  ["core:open_project_folder_system_file_picker"] = function()
    open_project_directory_with_system_file_picker()
  end,

  ["core:add_directory"] = function()
    add_project_directory()
  end,

  ["core:add_directory_system_file_picker"] = function()
    add_project_directory_with_system_file_picker()
  end,

  ["core:open_project_github_page"] = command.palette(function()
    common.open_in_system("https://github.com/dcostap/anvil-editor")
  end),
})

command.add_toggle("core:toggle_tabs", {
  palette = true,
  get = function()
    return not config.hide_tabs
  end,
  set = function(enabled)
    config.hide_tabs = not enabled
  end,
})

command.add_toggle("core:toggle_line_numbers", {
  palette = true,
  get = function()
    return config.show_line_numbers
  end,
  set = function(enabled)
    config.show_line_numbers = enabled
  end,
})
