require "core.strict"
local common = require "core.common"
local config
local style
local cli
local scale
local command
local keymap
local dirwatch
local ime
local RootPanel
local StatusBar
local TitleBar
local GlobalPromptBar
local NagView
local DocView
local ImageView
local MarkdownView
local Doc
local Project

---Core functionality.
---@class core
local core = {}

-- A focus/restored/exposed event can arrive while Windows is still showing the
-- alt-tab/task-switcher transition.  The first D3D present may be accepted but
-- not become the visible DWM contents, so keep repainting briefly after window
-- reactivation instead of relying on one event-time frame.
local WINDOW_REACTIVATION_REPAINT_SECONDS = 0.35
local window_reactivation_repaint_until = 0

function core.request_window_reactivation_repaint(reason, duration)
  local seconds = duration or WINDOW_REACTIVATION_REPAINT_SECONDS
  if seconds <= 0 then seconds = WINDOW_REACTIVATION_REPAINT_SECONDS end
  local repaint_until = system.get_time() + seconds
  if repaint_until > window_reactivation_repaint_until then
    window_reactivation_repaint_until = repaint_until
  end
  core.redraw = true
  if core.log_quiet then
    core.log_quiet(
      "Window repaint burst: scheduled reason=%s until=%.3f",
      tostring(reason or "unknown"), window_reactivation_repaint_until
    )
  end
end

function core.window_reactivation_repaint_pending(now)
  return window_reactivation_repaint_until > (now or system.get_time())
end

local map_new_syntax_colors

local APP_STATE_FILENAME = "appstate.lua"
local LEGACY_SESSION_FILENAME = "session.lua"

local function load_app_state()
  local ok, t = pcall(dofile, USERDIR .. PATHSEP .. APP_STATE_FILENAME)
  if ok and type(t) == "table" then return t end

  -- Compatibility with older Anvil builds that stored global app state in
  -- "session.lua".  New saves write "appstate.lua".
  ok, t = pcall(dofile, USERDIR .. PATHSEP .. LEGACY_SESSION_FILENAME)
  return ok and type(t) == "table" and t or {}
end


local function sane_window_bounds(bounds)
  if type(bounds) ~= "table" then return false end
  local w, h, x, y = bounds[1], bounds[2], bounds[3], bounds[4]
  return type(w) == "number" and type(h) == "number"
     and w >= 160 and h >= 120
     and type(x) == "number" and type(y) == "number"
     and x > -30000 and y > -30000
end

local function save_app_state()
  local fp = io.open(USERDIR .. PATHSEP .. APP_STATE_FILENAME, "w")
  if fp then
    local window = core.window_mode ~= "fullscreen"
      and table.pack(system.get_window_size(core.window)) or core.window_size
    if not sane_window_bounds(window) then window = core.window_size end
    if not sane_window_bounds(window) then window = {800, 600, 0, 0} end
    local app_state = {
      recents = core.recent_projects,
      window = window,
      window_mode = core.window_mode ~= "fullscreen"
        and core.window_mode or core.prev_window_mode,
      previous_find = core.previous_find,
      previous_replace = core.previous_replace
    }
    fp:write("return " .. common.serialize(app_state, {pretty = true}))
    fp:close()
  end
end


local function normalize_project_path(path)
  if type(path) ~= "string" then return end
  local abs_path = system.absolute_path(path)
  return common.normalize_volume(abs_path or path)
end


local function project_arg_path(project)
  if type(project) == "table" then return project.path end
  return project
end


local function find_open_project(project)
  local path = normalize_project_path(project_arg_path(project))
  if not path then return end
  for _, cproject in ipairs(core.projects or {}) do
    if cproject.path and common.path_equals(path, cproject.path) then
      return cproject
    end
  end
end


local function update_recents_project(action, dir_path_abs)
  local dirname = normalize_project_path(dir_path_abs)
  if not dirname then return end
  local recents = core.recent_projects
  for i = #recents, 1, -1 do
    if common.path_equals(dirname, recents[i]) then
      table.remove(recents, i)
    end
  end
  if action == "add" then
    table.insert(recents, 1, dirname)
  end
end


function core.add_project(project)
  project = type(project) == "string" and Project(normalize_project_path(project) or project) or project
  local duplicate = false
  for _, cproject in ipairs(core.projects) do
    if common.path_equals(project.path, cproject.path) then
      duplicate = true
      project = cproject
      core.warn("The project '%s' is already loaded.", common.basename(project.path))
      break
    end
  end
  if not duplicate then
    table.insert(core.projects, project)
    core.redraw = true
  end
  return project
end


function core.remove_project(project, force)
  local project_path = project_arg_path(project)
  for i = (force and 1 or 2), #core.projects do
    if project == core.projects[i] or common.path_equals(project_path, core.projects[i].path) then
      local project = core.projects[i]
      table.remove(core.projects, i)
      if
        core.projects[1]
        and
        common.path_equals(system.getcwd(), project.path)
      then
        system.chdir(core.projects[1].path)
      end
      return project
    end
  end
  return false
end


function core.set_project(project)
  core.visited_files = {}
  while #core.projects > 0 do core.remove_project(core.projects[#core.projects], true) end
  local project_object = core.add_project(project)
  system.chdir(project_object.path)
  return project_object
end


function core.open_project_in_same_window(project)
  local project = core.set_project(project)
  core.root_panel:close_all_docviews()
  update_recents_project("add", project.path)
  command.perform("core:restart")
end

function core.open_project_in_new_window(project)
  local existing_project = find_open_project(project)
  if existing_project then
    core.log_quiet(
      "Project %q is already open in the current window; raising instead of opening another window",
      existing_project.path
    )
    if core.window then system.raise_window(core.window) end
    return true
  end

  local exe = EXEFILE or (EXEDIR and (EXEDIR .. PATHSEP .. "anvil.exe")) or "anvil"

  -- On Windows, launching detached through core.process can create a visible
  -- Anvil window that Windows/SDL does not grant input focus to.  Preserve the
  -- older WinExec-based launch path here so newly-opened project windows are
  -- activated correctly.
  if PLATFORM == "Windows" then
    system.exec(string.format("%q %q", exe, project))
    return true
  end

  local ok, process = pcall(require, "core.process")
  if ok and process and process.start then
    local proc = process.start({ exe, project }, {
      detach = true,
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_DISCARD,
      stderr = process.REDIRECT_DISCARD,
    })
    if proc then return true end
  end
  system.exec(string.format("%q %q", exe, project))
  return true
end

-- Compatibility alias for existing plugins/user configs.
function core.open_project(project)
  return core.open_project_in_same_window(project)
end


function core.view_file_path(view)
  if not view then return nil end
  local doc = view.doc
  if doc and doc.abs_filename then return doc.abs_filename end
  local buffer = view.buffer
  if buffer and type(buffer.path) == "function" then
    local ok, path = pcall(buffer.path, buffer)
    if ok and path then return path end
  end
  if type(view.path) == "string" then return view.path end
end

function core.view_is_dirty(view)
  if not view then return false end
  if type(view.is_dirty) == "function" then return view:is_dirty() end
  local doc = view.doc
  if doc and type(doc.is_dirty) == "function" then return doc:is_dirty() end
  local buffer = view.buffer
  if buffer and type(buffer.is_dirty) == "function" then
    local ok, dirty = pcall(buffer.is_dirty, buffer)
    return ok and dirty or false
  end
  return false
end

function core.set_view_selection(view, line, col, line2, col2)
  if not view then return false end
  if view.doc then
    local function set_doc_selection()
      if line2 and col2 then view.doc:set_selection(line, col, line2, col2) else view.doc:set_selection(line, col) end
    end
    if view.with_selection_state then view:with_selection_state(set_doc_selection) else set_doc_selection() end
    if view.scroll_to_line then view:scroll_to_line(line or 1, true, true) end
    return true
  end
  if view.buffer and view.editor then
    line = math.max(1, line or 1)
    col = math.max(1, col or 1)
    local start_offset = view.buffer:line_col_to_offset(line - 1, col - 1)
    if not start_offset then return false end
    if line2 and col2 then
      local end_offset = view.buffer:line_col_to_offset(math.max(0, line2 - 1), math.max(0, col2 - 1))
      view.editor:set_cursor(end_offset or start_offset, start_offset)
    else
      view.editor:set_cursor(start_offset)
    end
    if view.scroll_to_cursor then view:scroll_to_cursor() end
    core.redraw = true
    return true
  end
  return false
end

---Get project for currently opened file-backed view or given filename path.
---If the given path does not belongs to any of the opened projects a new
---project object will be created and returned using the directory of the
---given filename path.
---@param filename? string
---@return core.project? project
---@return boolean is_open The returned project is open
---@return boolean belongs The file belongs to the returned project
function core.current_project(filename)
  if not filename then
    filename = core.view_file_path(core.active_view)
    if not filename then return core.projects[1], true, false end
  end
  if #core.projects > 1 then
    for _, project in ipairs(core.projects) do
      if project:path_belongs_to(filename) then
        return project, true, true
      end
    end
  end
  if core.projects[1] and core.projects[1]:path_belongs_to(filename) then
    return core.projects[1], true, true
  end
  if not system.get_file_info(filename) then
    return core.projects[1], true, false
  end
  local dirname = common.dirname(filename)
  if dirname then
    return Project(dirname), false, true
  end
end


local function strip_trailing_slash(filename)
  if filename:match("[^:]["..PATHSEP.."]$") then
    return filename:sub(1, -2)
  end
  return filename
end


-- create a directory using mkdir but may need to create the parent
-- directories as well.
local function create_user_directory()
  local success, err = common.mkdirp(USERDIR)
  if not success then
    error("cannot create directory \"" .. USERDIR .. "\": " .. err)
  end
  for _, modname in ipairs {'plugins', 'colors', 'fonts'} do
    local subdirname = USERDIR .. PATHSEP .. modname
    if not system.mkdir(subdirname) then
      error("cannot create directory: \"" .. subdirname .. "\"")
    end
  end
end


local function write_user_init_file(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- put user settings here
-- this module will be loaded after everything else when the application starts
-- it will be automatically reloaded when saved

local core = require "core"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"

------------------------------ Themes ----------------------------------------

-- light theme:
-- core.reload_module("colors.summer")

--------------------------- Key bindings -------------------------------------

-- key binding:
-- keymap.add { ["ctrl+escape"] = "core:quit" }

-- pass 'true' for second parameter to overwrite an existing binding
-- keymap.add({ ["ctrl+pageup"] = "root:switch-to-previous-tab" }, true)
-- keymap.add({ ["ctrl+pagedown"] = "root:switch-to-next-tab" }, true)

------------------------------- Fonts ----------------------------------------

-- customize fonts:
-- style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 14 * SCALE)
-- style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
--
-- DATADIR is the location of the installed Anvil Lua code, default color
-- schemes and fonts.
-- USERDIR is the location of the Anvil configuration directory.
--
-- font names used by anvil:
-- style.font          : user interface
-- style.big_font      : big text in welcome screen
-- style.icon_font     : icons
-- style.icon_big_font : toolbar icons
-- style.code_font     : code
--
-- the function to load the font accept a 3rd optional argument like:
--
-- {antialiasing="grayscale", hinting="full", bold=true, italic=true, underline=true, smoothing=true, strikethrough=true}
--
-- possible values are:
-- antialiasing: grayscale, subpixel
-- hinting: none, slight, full
-- bold: true, false
-- italic: true, false
-- underline: true, false
-- smoothing: true, false
-- strikethrough: true, false

------------------------------ Plugins ----------------------------------------

-- disable plugin loading setting config entries:

-- disable plugin detectindent, otherwise it is enabled by default:
-- config.plugins.detectindent = false

---------------------------- Miscellaneous -------------------------------------

-- modify list of files to ignore when indexing the project:
-- config.ignore_files = {
--   -- folders
--   "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
--   "^node_modules/", "^%.cache/", "^__pycache__/",
--   -- files
--   "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
--   "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
--   "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
--   "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
-- }

]])
  init_file:close()
end


function core.write_init_project_module(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- Put project's module settings here.
-- This module will be loaded when opening a project, after the user module
-- configuration.
-- It will be automatically reloaded when saved.

local config = require "core.config"

-- you can add some patterns to ignore files within the project
-- this will overwrite the default ignored files
-- config.ignore_files = {"^%.", <some-patterns>}

-- this will extend the list of default ignored files
-- for i, v in ipairs({"^%.", <some-patterns>}) do table.insert(config.ignore_files, v) end

-- Patterns are normally applied to the file's or directory's name, without
-- its path. See below about how to apply filters on a path.
--
-- Here some examples:
--
-- "^%." matches any file of directory whose basename begins with a dot.
--
-- When there is an '/' at the end, the pattern will only match directories.
-- When there is an "$" at the end, the pattern will only match files.
--
-- "^%.git/" matches any directory named ".git" anywhere in the project.
-- "somefile$" matches a specific file
-- "%.lua$" matches any lua file
--
-- If a "/" appears anywhere in the pattern (except when it appears at the end or
-- is immediately followed by a '$'), then the pattern will be applied to the full
-- path of the file or directory. An initial "/" will be prepended to the file's
-- or directory's path to indicate the project's root.
--
-- "^/node_modules/" will match a directory named "node_modules" at the project's root.
-- "^/build.*/" will match any top level directory whose name begins with "build".
-- "^/subprojects/.+/" will match any directory inside a top-level folder named "subprojects".

-- You may activate some plugins on a per-project basis to override the user's settings.
-- config.plugins.trimwitespace = true
]]):close()
end


function core.ensure_user_directory()
  return core.try(function()
    if not system.get_file_info(USERDIR) then
      create_user_directory()
    end
    local init_filename = USERDIR .. PATHSEP .. "init.lua"
    if not system.get_file_info(init_filename) then
      write_user_init_file(init_filename)
    end
  end)
end


function core.refresh_display_timing(reason)
  local hz = core.window and core.window:get_refresh_rate() or DEFAULT_FPS
  if hz and hz >= 30 then
    DEFAULT_FPS = hz
    if config.auto_fps then config.fps = DEFAULT_FPS end
    core.fps = config.fps
    core.co_max_time = math.max(0.001, math.min(0.004, (1 / config.fps) * 0.25))
  end
  return DEFAULT_FPS
end

function core.configure_borderless_window()
  local using_native_frame = false
  if PLATFORM == "Windows" and system.set_window_native_frame then
    if config.borderless then
      using_native_frame = system.set_window_native_frame(core.window, true) or false
    else
      system.set_window_native_frame(core.window, false)
    end
  end
  if not using_native_frame then
    system.set_window_bordered(core.window, not config.borderless)
  end
  core.title_bar:configure_hit_test(config.borderless)
  core.title_bar.visible = config.borderless
end


function core.init()
  DEFAULT_SCALE, DEFAULT_FPS = system.get_display_info()
  SCALE = tonumber(os.getenv("ANVIL_SCALE")) or DEFAULT_SCALE

  -- load config after scale detection for flags that depend on it
  config = require "core.config"

  -- log functions depend on config so initialize after loading config
  core.log_items = {}
  core.log_quiet("Anvil version %s - mod-version %s", VERSION, MOD_VERSION_STRING)
  if config.plugins and config.plugins.ipc and config.plugins.ipc.single_instance == false and system.set_native_single_instance_enabled then
    system.set_native_single_instance_enabled(false)
    core.log_quiet("Native single-instance handoff disabled by config.plugins.ipc.single_instance=false")
  end

  style = require "colors.default"
  cli = require "core.cli"
  command = require "core.command"
  keymap = require "core.keymap"
  dirwatch = require "core.dirwatch"
  ime = require "core.ime"
  RootPanel = require "core.rootpanel"
  StatusBar = require "core.statusbar"
  TitleBar = require "core.titlebar"
  GlobalPromptBar = require "core.global_prompt_bar"
  NagView = require "core.nagview"
  Project = require "core.project"
  DocView = require "core.docview"
  ImageView = require "core.imageview"
  MarkdownView = require "core.markdownview"
  Doc = require "core.doc"

  -- apply to default color scheme
  map_new_syntax_colors()

  if PATHSEP == '\\' then
    USERDIR = common.normalize_volume(USERDIR)
    DATADIR = common.normalize_volume(DATADIR)
    EXEDIR  = common.normalize_volume(EXEDIR)
  end

  local app_state = load_app_state()
  core.recent_projects = app_state.recents or {}
  core.previous_find = app_state.previous_find or {}
  core.previous_replace = app_state.previous_replace or {}
  if not sane_window_bounds(app_state.window) then
    app_state.window = {800, 600, 0, 0}
    if app_state.window_mode == "normal" then app_state.window_mode = nil end
  end
  core.window_mode = app_state.window_mode or "normal"
  core.prev_window_mode = core.window_mode
  core.window_size = app_state.window or {800, 600, 0, 0}

  -- remove projects that don't exist any longer and collapse path-identity
  -- duplicates such as Windows paths that differ only by case.
  local recent_projects, seen_recent_projects = {}, {}
  for _, project_dir in ipairs(core.recent_projects) do
    local normalized_project_dir = normalize_project_path(project_dir)
    local key = common.path_compare_key(normalized_project_dir)
    if
      normalized_project_dir
      and not seen_recent_projects[key]
      and system.get_file_info(normalized_project_dir)
    then
      recent_projects[#recent_projects + 1] = normalized_project_dir
      seen_recent_projects[key] = true
    end
  end
  core.recent_projects = recent_projects

  local project_dir = core.recent_projects[1] or "."
  local project_dir_explicit = false
  local files = {}
  if not RESTARTED then
    for i = 2, #ARGS do
      local arg_filename = strip_trailing_slash(ARGS[i])
      local info = system.get_file_info(arg_filename) or {}
      if info.type == "dir" then
        project_dir = arg_filename
        project_dir_explicit = true
      else
        -- on macOS we can get an argument like "-psn_0_52353" that we just ignore.
        if not ARGS[i]:match("^-psn") then
          local filename = common.normalize_path(arg_filename)
          local abs_filename = system.absolute_path(filename or "")
          local file_abs
          if common.path_equals(filename, abs_filename) then
            file_abs = abs_filename
          else
            file_abs = system.absolute_path(".") .. PATHSEP .. filename
          end
          if file_abs then
            table.insert(files, file_abs)
            project_dir = file_abs:match("^(.+)[/\\].+$")
          end
        end
      end
    end
  end
  -- Ensure that we have a user directory.
  core.ensure_user_directory()

  --Set the maximum fps from display refresh rate.
  config.fps = DEFAULT_FPS

  ---The process exit status used when the application quits.
  ---@type integer
  core.exit_status = 0

  ---The actual maximum frames per second that can be rendered.
  ---@type number
  core.fps = config.fps

  ---The maximum time coroutines have to run on a per frame iteration basis.
  ---This value is automatically updated on each core.step().
  ---@type number
  core.co_max_time = 1 / config.fps - 0.004

  core.frame_start = 0
  core.clip_rect_stack = {{ 0,0,0,0 }}
  core.docs = {}
  core.projects = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  core.threads = setmetatable({}, { __mode = "k" })
  core.background_threads = 0
  core.blink_start = system.get_time()
  core.blink_timer = core.blink_start
  core.active_file_dialogs = {}
  core.redraw = true
  core.visited_files = {}
  core.restart_request = false
  core.quit_request = false
  core.init_working_dir = system.getcwd()
  core.collect_garbage = false

  -- We load core views before plugins that may need them.
  ---@type core.rootpanel
  core.root_panel = RootPanel()
  ---@type core.global_prompt_bar
  core.global_prompt_bar = GlobalPromptBar()
  ---@type core.statusbar
  core.status_bar = StatusBar()
  ---@type core.nagview
  core.nag_view = NagView()
  ---@type core.titlebar
  core.title_bar = TitleBar()

  -- Deprecated compatibility aliases for external plugins/user modules written
  -- against older UI names. Built-in code should use the canonical names above.
  core.root_view = core.root_panel
  core.command_view = core.global_prompt_bar
  core.status_view = core.status_bar
  core.title_view = core.title_bar

  -- Some plugins (eg: console) require the Root Panel layout tree to be initialized to defaults.
  local cur_node = core.root_panel.root_node
  cur_node.is_main_panel_node = true
  cur_node.is_primary_node = true -- deprecated compatibility alias
  cur_node:split("up", core.title_bar, {y = true})
  cur_node = cur_node.b
  cur_node:split("up", core.nag_view, {y = true})
  cur_node = cur_node.b
  cur_node = cur_node:split("down", core.global_prompt_bar, {y = true})
  cur_node = cur_node:split("down", core.status_bar, {y = true})

  -- Load default commands first so plugins/core features can override them.
  command.add_defaults()

  -- Core right-side panel manager. It is initialized before plugins so panels
  -- can register views into the shared side node during plugin loading.
  require "core.sidepanel"

  local project_dir_abs = system.absolute_path(project_dir)
  -- We prevent set_project below to effectively add and scan the directory because the
  -- project module and its ignore files is not yet loaded.
  if project_dir_abs and pcall(core.set_project, project_dir_abs) then
    if project_dir_explicit then
      update_recents_project("add", project_dir_abs)
    end
  else
    if not project_dir_explicit then
      update_recents_project("remove", project_dir)
    end
    project_dir_abs = system.absolute_path(".")
    local status, err = pcall(core.set_project, project_dir_abs)
  end

  -- Load core and user plugins giving preference to user ones with same name.
  local plugins_success, plugins_refuse_list = core.load_plugins()

  -- Parse commandline arguments
  cli.parse(ARGS)

  -- Update the files to open
  if cli.last_command ~= "default" then
    files = {}
    system.chdir(core.init_working_dir)
    for _, argument in ipairs(cli.unhandled_arguments) do
      local arg_filename = strip_trailing_slash(argument)
      local info = system.get_file_info(arg_filename) or {}
      if info.type ~= "dir" then
        local filename = common.normalize_path(arg_filename)
        local abs_filename = system.absolute_path(filename or "")
        local file_abs
        if common.path_equals(filename, abs_filename) then
          file_abs = abs_filename
        else
          file_abs = system.absolute_path(".") .. PATHSEP .. filename
        end
        if file_abs then
          table.insert(files, file_abs)
        end
      end
    end
  end

  local restored_window = core.window or renwindow._restore()
  core.window = restored_window or renwindow.create("", table.unpack(app_state.window or {}))

  -- Refresh-rate detection before the window exists only sees the primary
  -- display. Re-query from the real window so high-refresh secondary displays
  -- do not stay capped at the primary display rate.
  core.refresh_display_timing("window_create")

  -- Maximizing the window makes it lose the hidden attribute on Windows
  -- so we delay this to keep window hidden until args parsed. Also, on
  -- Wayland we have issues applying the mode before showing the window
  -- so we delay it on all platforms, except macOS. On macOS setting the
  -- mode to maximized seems to cause issues resetting its size so setting
  -- the size is all we need on that platform.
  if app_state.window_mode == "maximized" and PLATFORM ~= "Mac OS X" and not restored_window then
    core.add_thread(function()
      system.set_window_mode(core.window, "maximized")
    end)
  end


  do
    local pdir, pname = project_dir_abs:match("(.*)[/\\\\](.*)")
    core.log_quiet("Opening project %q from directory %s", pname, pdir)
  end

  if #files > 0 then
    -- defer file loading to ensure all plugins are loaded first,
    -- fixes issues like with linewrapping been enabled by default
    -- but not applied when opening editor with "open with"
    -- see: https://github.com/dcostap/anvil-editor/issues/423
    core.add_thread(function()
      -- allow workspace plugin to do its thing first to prevent duplicate files
      coroutine.yield()
      for _, filename in ipairs(files) do
        core.open_file(filename)
      end
    end)
  end

  if not plugins_success then
    -- defer LogView to after everything is initialized,
    -- so that EmptyView won't be added after LogView.
    core.add_thread(function()
      command.perform("core:open-log")
    end)
  end

  core.configure_borderless_window()

  -- On Windows with Anvil's custom native frame, saved bounds must be applied
  -- after the frame is enabled. Applying them before borderless setup treats the
  -- saved outer HWND height as SDL client height, which can push the titlebar
  -- above the monitor when restoring a screen-height window.
  if app_state.window and not restored_window then
    system.set_window_size(core.window, table.unpack(app_state.window))
  end

  if #plugins_refuse_list.userdir.plugins > 0 or #plugins_refuse_list.datadir.plugins > 0 then
    local opt = {
      { text = "Exit", default_no = true },
      { text = "Continue", default_yes = true }
    }
    local msg = {}
    for _, entry in pairs(plugins_refuse_list) do
      if #entry.plugins > 0 then
        local msg_list = {}
        for _, p in pairs(entry.plugins) do
          table.insert(msg_list, string.format("%s[%s]", p.file, p.version_string))
        end
        msg[#msg + 1] = string.format("Plugins from directory \"%s\":\n%s", common.home_encode(entry.dir), table.concat(msg_list, "\n"))
      end
    end
    core.nag_view:show(
      "Refused Plugins",
      string.format(
        "Some plugins are not loaded due to version mismatch. Expected version %s.\n\n%s.\n\n" ..
        "Please update or disable those plugins.",
        MOD_VERSION_STRING, table.concat(msg, ".\n\n")),
      opt, function(item)
        if item.text == "Exit" then os.exit(1) end
      end)
  end
end


local function dirty_view_owner(view)
  if not core.view_is_dirty(view) then return nil end
  return view.doc or view.buffer or view
end

function core.confirm_close_views(views, close_fn, ...)
  local dirty_count = 0
  local dirty_name
  local seen = {}
  for _, view in ipairs(views or {}) do
    local owner = dirty_view_owner(view)
    if owner and not seen[owner] then
      seen[owner] = true
      dirty_count = dirty_count + 1
      dirty_name = view.get_name and view:get_name() or tostring(view)
    end
  end
  if dirty_count > 0 then
    local text
    if dirty_count == 1 then
      text = string.format("\"%s\" has unsaved changes. Close anyway?", dirty_name)
    else
      text = string.format("%d views have unsaved changes. Close anyway?", dirty_count)
    end
    local args = {...}
    local opt = {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }
    core.nag_view:show("Unsaved Changes", text, opt, function(item)
      if item.text == "Yes" then close_fn(table.unpack(args)) end
    end)
  else
    close_fn(...)
  end
end

function core.confirm_close_docs(docs, close_fn, ...)
  local dirty_count = 0
  local dirty_name
  for _, doc in ipairs(docs or core.docs) do
    if doc:is_dirty() then
      dirty_count = dirty_count + 1
      dirty_name = doc:get_name()
    end
  end
  if dirty_count > 0 then
    local text
    if dirty_count == 1 then
      text = string.format("\"%s\" has unsaved changes. Quit anyway?", dirty_name)
    else
      text = string.format("%d docs have unsaved changes. Quit anyway?", dirty_count)
    end
    local args = {...}
    local opt = {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }
    core.nag_view:show("Unsaved Changes", text, opt, function(item)
      if item.text == "Yes" then close_fn(table.unpack(args)) end
    end)
  else
    close_fn(...)
  end
end

local temp_uid = math.floor(system.get_time() * 1000) % 0xffffffff
local temp_file_prefix = string.format(".anvil_temp_%08x", tonumber(temp_uid))
local temp_file_counter = 0

function core.delete_temp_files(dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:find(temp_file_prefix, 1, true) == 1 then
      os.remove(dir .. PATHSEP .. filename)
    end
  end
end

function core.temp_filename(ext, dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  temp_file_counter = temp_file_counter + 1
  return dir .. PATHSEP .. temp_file_prefix
      .. string.format("%06x", temp_file_counter) .. (ext or "")
end


function core.exit(quit_fn, force)
  if force then
    core.delete_temp_files()
    while #core.projects > 1 do core.remove_project(core.projects[#core.projects]) end
    save_app_state()
    quit_fn()
  else
    core.confirm_close_docs(core.docs, core.exit, quit_fn, true)
  end
end


function core.quit(force, exit_code)
  if type(exit_code) == "number" then
    core.exit_status = exit_code
  end
  core.exit(function() core.quit_request = true end, force)
end


function core.restart()
  core.exit(function()
    core.restart_request = true
    core.window:_persist()
  end)
end


local function require_lua_plugin(plugin)
  return require("plugins." .. plugin.name)
end


local function load_lua_plugin_if_exists(plugin)
  return system.get_file_info(plugin.file) and dofile(plugin.file)
end


function core.parse_plugin_details(path, file, mod_version_regex, priority_regex)
  local f = io.open(file, "r")
  if not f then return false end
  local priority = false
  local version_match = false
  local major, minor, patch

  for line in f:lines() do
    local header_found = false

    major, minor, patch = mod_version_regex:match(line)
    major = tonumber(major)
    if major then
      minor, patch = tonumber(minor) or 0, tonumber(patch) or 0

      if
        major == MOD_VERSION_MAJOR
        and
        minor <= MOD_VERSION_MINOR
        and
        (minor < MOD_VERSION_MINOR or patch <= MOD_VERSION_PATCH)
      then
        version_match = true
      end

      priority = priority_regex:match(line)
      if priority then priority = tonumber(priority) end

      header_found = true
    end

    if header_found then
      break
    end
  end
  f:close()
  local version = major and {major, minor, patch} or {}
  return {
    name = common.basename(path),
    file = file,
    version_match = version_match,
    version = version,
    priority = priority or 100,
    version_string = major and table.concat(version, ".") or "unknown"
  }
end


local mod_version_regex =
  regex.compile([[--.*mod-version:\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:$|\s)]])
local priority_regex = regex.compile([[\-\-.*priority\s*:\s*(\-?[\d\.]+)]])
function core.get_plugin_details(path)
  local info = system.get_file_info(path)
  local file = path
  if info ~= nil and info.type == "dir" then
    file = path .. PATHSEP .. "init.lua"
    info = system.get_file_info(file)
  end
  local details = info and core.parse_plugin_details(path:gsub("%.lua$", ""), file, mod_version_regex, priority_regex)
  if details then details.load = require_lua_plugin end
  return details
end


core.plugin_list = {}
-- Can be called from within plugins; don't insert things lower than your own priority.
function core.add_plugins(plugins)
  for i,v in ipairs(plugins) do table.insert(core.plugin_list, v) end

  -- sort by priority or name for plugins that have same priority
  table.sort(core.plugin_list, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.name < b.name
  end)
end


local function env_disabled_plugin_names()
  local value = os.getenv("ANVIL_DISABLE_PLUGINS") or os.getenv("ANVIL_TEST_DISABLE_PLUGINS")
  if not value or value == "" then return {} end
  local disabled = {}
  for name in value:gmatch("[^,;]+") do
    name = name:lower():match("^%s*(.-)%s*$")
    if name ~= "" then disabled[name] = true end
  end
  return disabled
end

function core.load_plugins()
  local no_errors = true
  local env_disabled_plugins = env_disabled_plugin_names()
  local refused_list = {
    userdir = {dir = USERDIR, plugins = {}},
    datadir = {dir = DATADIR, plugins = {}},
  }
  local defaults_plugin = core.get_plugin_details(
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "anvil_defaults.lua"
  )
  local files, ordered = {}, {
    { priority = -2, load = load_lua_plugin_if_exists, version_match = true, file = USERDIR .. PATHSEP .. "init.lua", name = "User Module" },
    { priority = -1, load = load_lua_plugin_if_exists, version_match = true, file = core.root_project().path .. PATHSEP .. ".anvil_project.lua", name = "Project Module" }
  }
  for _, root_dir in ipairs {DATADIR, USERDIR} do
    local plugin_dir = root_dir .. PATHSEP .. "plugins"
    for _, filename in ipairs(system.list_dir(plugin_dir) or {}) do
      if not files[filename] then
        local details = core.get_plugin_details(plugin_dir .. PATHSEP .. filename)
        if details and details.name ~= "anvil_defaults" then table.insert(ordered, details) end
      end
      -- user plugins will always replace system plugins
      files[filename] = plugin_dir
    end
  end
  core.add_plugins(ordered)

  local function reject_plugin_version(plugin)
    core.log_quiet(
      "Version mismatch for plugin %q[%s] from %s",
      plugin.name,
      plugin.version_string,
      common.dirname(plugin.file)
    )
    local rlist = plugin.file:find(USERDIR, 1, true) == 1
      and 'userdir' or 'datadir'
    table.insert(refused_list[rlist].plugins, plugin)
  end

  local function load_plugin(plugin, plugin_config)
    local start = system.get_time()
    local ok, loaded_plugin = core.try(plugin.load, plugin)
    if ok then
      local plugin_version = ""
      if plugin.version_string and  plugin.version_string ~= MOD_VERSION_STRING then
        plugin_version = "["..plugin.version_string.."]"
      end
      core.log_quiet(
        "Loaded plugin %q%s from %s in %.1fms",
        plugin.name,
        plugin_version,
        common.dirname(plugin.file),
        (system.get_time() - start) * 1000
      )
      if plugin_config and plugin_config.onload then
        core.try(plugin_config.onload, loaded_plugin)
      end
    else
      no_errors = false
    end
    return ok, loaded_plugin
  end

  local function load_defaults_plugin()
    if not defaults_plugin then
      core.error("Mandatory first-party defaults plugin is missing: %s", DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "anvil_defaults.lua")
      no_errors = false
      return false
    end
    if not defaults_plugin.version_match then
      reject_plugin_version(defaults_plugin)
      core.error("Mandatory first-party defaults plugin has an incompatible mod-version")
      no_errors = false
      return false
    end

    defaults_plugin.load = load_lua_plugin_if_exists
    local ok, loaded_plugin = load_plugin(defaults_plugin)
    if ok then
      package.loaded["plugins.anvil_defaults"] = loaded_plugin or true
    else
      core.error("Mandatory first-party defaults plugin failed to load")
    end
    return ok
  end

  local load_start = system.get_time()
  local defaults_loaded = false
  for i = 1, #core.plugin_list do
    local plugin = core.plugin_list[i]
    if not defaults_loaded and plugin.priority >= 0 then
      if not load_defaults_plugin() then return false, refused_list end
      defaults_loaded = true
    end

    if not plugin.version_match then
      reject_plugin_version(plugin)
    elseif env_disabled_plugins[plugin.name:lower()] then
      core.log_quiet("Skipped plugin %q from ANVIL_DISABLE_PLUGINS", plugin.name)
    else
      local plugin_config = config.plugins[plugin.name]
      if plugin_config ~= false then
        load_plugin(plugin, plugin_config)
      end
    end
  end
  if not defaults_loaded and not load_defaults_plugin() then return false, refused_list end
  core.log_quiet(
    "Loaded all plugins in %.1fms",
    (system.get_time() - load_start) * 1000
  )
  return no_errors, refused_list
end


---Map newly introduced syntax symbols when missing from current color scheme.
---@param clear_new? boolean Only perform removal of new syntax symbols
map_new_syntax_colors = function(clear_new)
  ---New syntax symbols that may not be defined by all color schemes
  local symbols_map = {
    -- symbols related to doc comments
    ["annotation"]            = { alt = "keyword",  dec=30 },
    ["annotation.string"]     = { alt = "string",   dec=30 },
    ["annotation.param"]      = { alt = "symbol",   dec=30 },
    ["annotation.type"]       = { alt = "keyword2", dec=30 },
    ["annotation.operator"]   = { alt = "operator", dec=30 },
    ["annotation.function"]   = { alt = "function", dec=30 },
    ["annotation.number"]     = { alt = "number",   dec=30 },
    ["annotation.keyword2"]   = { alt = "keyword2", dec=30 },
    ["annotation.literal"]    = { alt = "literal",  dec=30 },
    ["attribute"]             = { alt = "keyword",  dec=30 },
    -- Keywords like: true or false
    ["boolean"]               = { alt = "literal"   },
    -- Single quote sequences like: 'a'
    ["character"]             = { alt = "string"    },
    -- can be escape sequences like: \t, \r, \n
    ["character.special"]     = {                   },
    -- Keywords like: if, else, elseif
    ["conditional" ]          = { alt = "keyword"   },
    -- conditional ternary as: condition ? value1 : value2
    ["conditional.ternary"]   = { alt = "operator"  },
    -- keywords like: nil, null
    ["constant"]              = { alt = "number"    },
    ["constant.builtin"]      = {                   },
    -- a macro constant as in: #define MYVAL 1
    ["constant.macro"]        = {                   },
    -- constructor declarations as in: __constructor() or myclass::myclass()
    ["constructor"]           = { alt = "function"  },
    ["debug"]                 = { alt = "comment"   },
    ["define"]                = { alt = "keyword"   },
    ["error"]                 = { alt = "keyword"   },
    -- keywords like: try, catch, finally
    ["exception"]             = { alt = "keyword"   },
    -- class or table fields
    ["field"]                 = { alt = "normal"    },
    -- a numerical constant that holds a float
    ["float"]                 = { alt = "number"    },
    -- function name in a call
    ["function.call"]         = {                   },
    -- a function call that was declared as a macro like in: #define myfunc()
    ["function.macro"]        = {                   },
    -- keywords like: include, import, require
    ["include"]               = { alt = "keyword"   },
    -- keywords like: return
    ["keyword.return"]        = {                   },
    -- keywords like: func, function
    ["keyword.function"]      = {                   },
    -- keywords like: and, or
    ["keyword.operator"]      = {                   },
    -- a goto label name like in: label: or ::label::
    ["label"]                 = { alt = "function"  },
    -- class method declaration
    ["method"]                = { alt = "function"  },
    -- class method call
    ["method.call"]           = {                   },
    -- namespace name like in namespace::subelement or namespace\subelement
    ["namespace"]             = { alt = "literal"   },
    -- parameters in a function declaration
    ["parameter"]             = { alt = "operator"  },
    -- keywords like: #if, #elif, #endif
    ["preproc"]               = { alt = "keyword"   },
    -- any type of punctuation
    ["punctuation"]           = { alt = "normal"    },
    -- punctuation like: (), {}, []
    ["punctuation.brackets"]  = {                   },
    -- punctuation like: , or :
    ["punctuation.delimiter"] = { alt = "operator"  },
    -- puctuation like: # or @
    ["punctuation.special"]   = { alt = "operator"  },
    -- keywords like: while, for
    ["repeat"]                = { alt = "keyword"   },
    -- keywords like: static, const, constexpr
    ["storageclass"]          = { alt = "keyword"   },
    ["storageclass.lifetime"] = {                   },
    -- tags in HTML and JSX
    ["tag"]                   = { alt = "function"  },
    -- tag delimeters <>
    ["tag.delimiter"]         = { alt = "operator"  },
    -- tag attributes eg: id="id-attr"
    ["tag.attribute"]         = { alt = "keyword"   },
    -- additions on diff or patch
    ["text.diff.add"]         = { alt = style.good  },
    -- deletions on diff or patch
    ["text.diff.delete"]      = { alt = style.error },
    -- a language standard library support types
    ["type"]                  = { alt = "keyword2"  },
    -- a language builtin types like: char, double, int
    ["type.builtin"]          = {                   },
    -- a custom type defininition like ssize_t on typedef long int ssize_t
    ["type.definition"]       = {                   },
    -- keywords like: private, public
    ["type.qualifier"]        = {                   },
    -- any variable defined or accessed on the code
    ["variable"]              = { alt = "normal"    },
    -- keywords like: this, self, parent
    ["variable.builtin"]      = { alt = "keyword2"  },
  }

  if clear_new then
    for symbol_name in pairs(symbols_map) do
      if style.syntax[symbol_name] then
        style.syntax[symbol_name] = nil
      end
    end
    return
  end

  --- map symbols not defined on syntax
  for symbol_name in pairs(symbols_map) do
    if not style.syntax[symbol_name] then
      local sections = {};
      for match in (symbol_name.."."):gmatch("(.-)%.") do
        table.insert(sections, match);
      end
      for i=#sections, 1, -1 do
        local section = table.concat(sections, ".", 1, i)
        local parent = symbols_map[section]
        if parent and parent.alt then
          -- copy the color
          local color = table.pack(
            table.unpack(style.syntax[parent.alt] or parent.alt)
          )
          if parent.dec then
            color = common.darken_color(color, parent.dec)
          elseif parent.inc then
            color = common.lighten_color(color, parent.inc)
          end
          style.syntax[symbol_name] = color
          break
        end
      end
    end
  end

  -- metatable to automatically map custom symbol types to the nearest parent
  setmetatable(style.syntax, {
    __index = function(syntax, type_name)
      if type(type_name) ~= "string" then
        return rawget(syntax, type_name)
      end
      if not rawget(syntax, type_name) and type(type_name) == "string" then
        local sections = {};
        for match in (type_name.."."):gmatch("(.-)%.") do
          table.insert(sections, match);
        end
        if #sections > 1 then
          for i=#sections, 1, -1 do
            local section = table.concat(sections, ".", 1, i)
            local parent = rawget(syntax, section)
            if parent then
              -- copy the color
              local color = table.pack(table.unpack(parent))
              rawset(syntax, type_name, color)
              return color
            end
          end
        end
      end
      return rawget(syntax, type_name)
    end
  })
end


function core.reload_module(name)
  local old = package.loaded[name]
  local is_color_scheme = name:match("^colors%..*")

  -- Every color scheme is layered over colors.default so first-party style
  -- keys always have baseline values when users switch themes.
  if is_color_scheme then
    setmetatable(style.syntax, nil)
    map_new_syntax_colors(true)
    if name ~= "colors.default" then
      package.loaded["colors.default"] = nil
      require "colors.default"
    end
  end

  package.loaded[name] = nil
  local new = require(name)
  if type(old) == "table" then
    for k, v in pairs(new) do old[k] = v end
    package.loaded[name] = old
  end
  -- map colors that may be missing on the new color scheme
  if is_color_scheme then
    map_new_syntax_colors()
  end
end


function core.reload_absolute_module(filename)
  if system.get_file_info(filename) then
    return core.try(function()
      local fn, err = loadfile(filename)
      if not fn then error("Error when loading file:\n\t" .. err) end
      fn()
      core.project_module_loaded = true
      if filename:match("%.anvil_project") then
        core.log_quiet("Reloaded project module")
      elseif common.path_equals(filename, USERDIR .. PATHSEP .. "init.lua") then
        core.log_quiet("Reloaded user module")
      else
        core.log_quiet("Reloaded module '%s'", filename)
      end
    end)
  end
  return true
end


function core.set_visited(filename)
  for i = 1, #core.visited_files do
    if common.path_equals(core.visited_files[i], filename) then
      table.remove(core.visited_files, i)
      break
    end
  end
  table.insert(core.visited_files, 1, filename)
  if #core.visited_files > config.max_visited_files then
    local remove = #core.visited_files - config.max_visited_files
    common.splice(core.visited_files, config.max_visited_files, remove)
  end
end


function core.set_active_view(view)
  assert(view, "Tried to set active view to nil")
  -- Reset the IME even if the focus didn't change
  ime.stop()
  if view ~= core.active_view then
    if core.window then system.text_input(core.window, view:supports_text_input()) end
    if core.active_view and core.active_view.force_focus then
      core.next_active_view = view
      return
    end
    core.next_active_view = nil
    local old_active_view = core.active_view
    if old_active_view and old_active_view.extends and old_active_view:extends(DocView)
    and old_active_view.doc and old_active_view.owns_doc_selection_mirror
    and old_active_view:owns_doc_selection_mirror()
    and not old_active_view.doc.bound_selection_view then
      old_active_view:capture_selection_state()
    end
    local filename = core.view_file_path(view)
    if filename then core.set_visited(filename) end
    core.last_active_view = old_active_view
    core.active_view = view
    if view.extends and view:extends(DocView) and view.doc and view.become_selection_mirror_owner then
      view:become_selection_mirror_owner()
    end
  end
  local active_filename = core.view_file_path(core.active_view)
  if active_filename then
    local project = core.current_project(active_filename)
    if project then system.chdir(project.path) end
  end
end


function core.show_title_bar(show)
  core.title_bar.visible = show
end

local function add_thread(f, weak_ref, background, ...)
  local key = weak_ref or #core.threads + 1
  local args = {...}
  local fn = function() return core.try(f, table.unpack(args)) end
  local info = debug.getinfo(2, "Sl")
  local loc = string.format("%s:%d", info.short_src, info.currentline)
  core.threads[key] = {
    cr = coroutine.create(fn), wake = 0, background = background, loc = loc
  }
  if background then
    core.background_threads = core.background_threads + 1
  end
  return key
end

function core.add_thread(f, weak_ref, ...)
  return add_thread(f, weak_ref, nil, ...)
end

function core.add_background_thread(f, weak_ref, ...)
  return add_thread(f, weak_ref, true, ...)
end


function core.push_clip_rect(x, y, w, h)
  local x2, y2, w2, h2 = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  local r, b, r2, b2 = x+w, y+h, x2+w2, y2+h2
  x, y = math.max(x, x2), math.max(y, y2)
  b, r = math.min(b, b2), math.min(r, r2)
  w, h = r-x, b-y
  table.insert(core.clip_rect_stack, { x, y, w, h })
  renderer.set_clip_rect(x, y, w, h)
end


function core.pop_clip_rect()
  table.remove(core.clip_rect_stack)
  local x, y, w, h = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  renderer.set_clip_rect(x, y, w, h)
end

-- legacy interface
function core.root_project() return core.projects[1] end
function core.normalize_to_project_dir(path) return core.root_project():normalize_path(path) end
function core.project_absolute_path(path) return core.root_project():absolute_path(path) end

local function close_doc_view(doc)
  core.add_thread(function()
    local views = core.root_panel.root_node:get_children()
    for _, view in ipairs(views) do
      if view.doc == doc then
        local node = core.root_panel.root_node:get_node_for_view(view)
        node:close_view(core.root_panel.root_node, view)
      end
    end
  end)
end

function core.open_doc(filename)
  local new_file = true
  local abs_filename
  local close_docview = false
  if filename then
    -- normalize filename and set absolute filename then
    -- try to find existing doc for filename
    filename = core.root_project():normalize_path(filename)
    abs_filename = core.root_project():absolute_path(filename)
    local file_info = system.get_file_info(abs_filename)
    new_file = not file_info
    if file_info and file_info.size > config.file_size_limit * 1e6 then
      local size = file_info.size / 1024 / 1024
      core.error(
        "File '%s' with size %0.2fMB exceeds config.file_size_limit of %sMB",
        filename, size, config.file_size_limit
      )
      close_docview = true
      filename = nil
      abs_filename = nil
      new_file = true
    end
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename and common.path_equals(abs_filename, doc.abs_filename) then
        if close_docview then close_doc_view(doc) end
        return doc
      end
    end
  end
  -- no existing doc for filename; create new
  local doc = Doc(filename, abs_filename, new_file)
  table.insert(core.docs, doc)
  core.log_quiet(filename and "Opened doc \"%s\"" or "Opened new doc", filename)
  if close_docview then close_doc_view(doc) end
  return doc
end


function core.get_views_referencing_doc(doc)
  local res = {}
  local views = core.root_panel.root_node:get_children()
  for _, view in ipairs(views) do
    if view.doc == doc then table.insert(res, view) end
  end
  return res
end


---@param filename string
---@return core.imageview? image_view
function core.open_image(filename)
  ---@cast ImageView core.imageview
  if ImageView.is_supported(filename) then
    local abs_filename = core.root_project():absolute_path(filename)
    local file = io.open(abs_filename)
    if not file then return false end
    file:close()

    local node = core.root_panel:get_active_node_default()
    for i, view in ipairs(node.views) do
      if common.path_equals(view.path, abs_filename) then
        node:set_active_view(node.views[i])
        return view
      end
    end
    local view = ImageView(abs_filename)
    if view.image then
      node:add_view(view)
      core.root_panel.root_node:update_layout()
      return view
    else
      core.error(
        "Image could not be loaded.%s",
        view.errmsg and " Error: " .. view.errmsg or ""
      )
    end
  end
end


---@param filename string
---@return core.markdownview? markdown_view
function core.open_markdown(filename)
  ---@cast MarkdownView core.markdownview
  if MarkdownView.is_supported(filename) then
    local file = io.open(filename)
    if not file then
      return false
    end
    file:close()

    local node = core.root_panel:get_active_node_default()
    for i, view in ipairs(node.views) do
      if common.path_equals(view.path, filename) then
        node:set_active_view(node.views[i])
        return view
      end
    end

    local view = MarkdownView(filename)
    node:add_view(view)
    core.root_panel.root_node:update_layout()
    return view
  end
end


---Opens the given file path in the Root Panel.
---If the given file is a supported image, it will open it in the image viewer;
---otherwise, it will open it as a normal text file.
---@param filename string Path to the file to open
---@return core.imageview|core.docview
function core.open_file(filename)
  local view = core.open_image(filename)
  if not view then
    return core.root_panel:open_doc(core.open_doc(filename))
  end
  return view
end


function core.custom_log(level, show, backtrace, fmt, ...)
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then
    local parts = { tostring(fmt) }
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    text = table.concat(parts, " ") .. " (log format error: " .. tostring(text) .. ")"
  end
  if show then
    local s = style.log[level]
    if core.status_bar then
      core.status_bar:show_message(s.icon, s.color, text)
    end
  end

  local info = debug.getinfo(2, "Sl")
  local at = string.format("%s:%d", info.short_src, info.currentline)
  local item = {
    level = level,
    text = text,
    time = os.time(),
    at = at,
    info = backtrace and debug.traceback("", 2):gsub("\t", "")
  }
  table.insert(core.log_items, item)
  if #core.log_items > config.max_log_items then
    table.remove(core.log_items, 1)
  end
  return item
end


function core.log(...)
  return core.custom_log("INFO", true, false, ...)
end


function core.log_quiet(...)
  return core.custom_log("INFO", false, false, ...)
end

function core.warn(...)
  return core.custom_log("WARN", true, true, ...)
end

function core.error(...)
  return core.custom_log("ERROR", true, true, ...)
end


function core.get_log(i)
  if i == nil then
    local r = {}
    for _, item in ipairs(core.log_items) do
      table.insert(r, core.get_log(item))
    end
    return table.concat(r, "\n")
  end
  local item = type(i) == "number" and core.log_items[i] or i
  local text = string.format("%s [%s] %s at %s", os.date(nil, item.time), item.level, item.text, item.at)
  if item.info then
    text = string.format("%s\n%s\n", text, item.info)
  end
  return text
end


function core.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    local item = core.error("%s", msg)
    item.info = debug.traceback("", 2):gsub("\t", "")
    err = msg
  end, ...)
  if ok then
    return true, res
  end
  return false, err
end

---This function rescales the interface to the system default scale
---by incrementing or decrementing current user scale.
---@param new_scale number
local function update_scale(new_scale)
  local prev_default = DEFAULT_SCALE
  DEFAULT_SCALE = new_scale
  if SCALE == prev_default or config.plugins.scale.autodetect then
    if new_scale == SCALE then return end
    local target, target_code
    if new_scale > prev_default then
      target = scale.get() + (new_scale - prev_default)
      target_code = scale.get_code() + (new_scale - prev_default)
    else
      target = scale.get() - (prev_default - new_scale)
      target_code = scale.get_code() - (prev_default - new_scale)
    end
    -- do not scale smaller than new_scale
    scale.set(target < new_scale and new_scale or target)
    scale.set_code(target_code < new_scale and new_scale or target_code)
  end
end

function core.on_event(type, ...)
  local did_keymap = false
  local active = core.active_view
  local active_type = active and active.type_name
  local fuzzy_input_debug = active_type == "plugins.fuzzy_searcher"
  if type == "textinput" then
    if fuzzy_input_debug then
      local text = (...)
      core.log_quiet("Fuzzy input event: textinput active=%s supports_text_input=%s bytes=%d text=%s", tostring(active_type), tostring(active and active:supports_text_input()), #tostring(text or ""), tostring(text or ""))
    end
    core.root_panel:on_text_input(...)
  elseif type == "textediting" then
    if fuzzy_input_debug then
      local text, start, len = ...
      core.log_quiet("Fuzzy input event: textediting active=%s supports_text_input=%s bytes=%d text=%s start=%s len=%s", tostring(active_type), tostring(active and active:supports_text_input()), #tostring(text or ""), tostring(text or ""), tostring(start), tostring(len))
    end
    ime.on_text_editing(...)
  elseif type == "keypressed" then
    -- In some cases during IME composition input is still sent to us
    -- so we just ignore it.
    if ime.editing then return false end
    if fuzzy_input_debug then
      local key = (...)
      core.log_quiet("Fuzzy input event: keypressed active=%s supports_text_input=%s key=%s", tostring(active_type), tostring(active and active:supports_text_input()), tostring(key))
    end
    did_keymap = keymap.on_key_pressed(...)
  elseif type == "keyreleased" then
    keymap.on_key_released(...)
  elseif type == "mousemoved" then
    core.root_panel:on_mouse_moved(...)
  elseif type == "mousepressed" then
    if not core.root_panel:on_mouse_pressed(...) then
      did_keymap = keymap.on_mouse_pressed(...)
    end
  elseif type == "mousereleased" then
    core.root_panel:on_mouse_released(...)
  elseif type == "mouseleft" then
    core.root_panel:on_mouse_left()
  elseif type == "mousewheel" then
    if not core.root_panel:on_mouse_wheel(...) then
      did_keymap = keymap.on_mouse_wheel(...)
    end
  elseif type == "touchpressed" then
    core.root_panel:on_touch_pressed(...)
  elseif type == "touchreleased" then
    core.root_panel:on_touch_released(...)
  elseif type == "touchmoved" then
    core.root_panel:on_touch_moved(...)
  elseif type == "resized" then
    core.window_resizing_until = system.get_time() + 0.20
    local window_mode = system.get_window_mode(core.window)
    if window_mode ~= "fullscreen" and window_mode ~= "maximized" then
      core.window_size = table.pack(system.get_window_size(core.window))
    -- check needed because fullscreen can be triggered twice
    elseif core.window_mode ~= "fullscreen" then
      core.prev_window_mode = core.window_mode
    end
    core.window_mode = window_mode
  elseif type == "minimized" or type == "maximized" or type == "restored" then
    local window_mode = system.get_window_mode(core.window)
    core.window_mode = window_mode
    if window_mode == "normal" then
      core.window_size = table.pack(system.get_window_size(core.window))
    end
    if type == "restored" then core.request_window_reactivation_repaint("restored") end
  elseif type == "exposed" then
    core.request_window_reactivation_repaint("exposed")
  elseif type == "filedropped" then
    core.root_panel:on_file_dropped(...)
  elseif type == "singleinstanceopen" then
    local filename, secondary_elapsed_ms, transport_ms = ...
    core.log_quiet("Native single-instance open: file=%s sender_elapsed=%.1fms transport=%.1fms", tostring(filename), tonumber(secondary_elapsed_ms) or -1, tonumber(transport_ms) or -1)
    if filename and system.get_file_info(filename) then
      system.raise_window(core.window)
      core.open_file(filename)
    end
  elseif type == "dialogfinished" then
    local id, status, result = ...
    local callback = core.active_file_dialogs[id]
    if not callback then
      core.error("Invalid dialog id %d", id)
    else
      core.active_file_dialogs[id] = nil
      callback(status, result)
    end
  elseif type == "focusgained" then
    core.log_quiet(
      "Focus diagnostics: received focusgained event active=%s window_has_focus=%s",
      tostring(core.active_view), tostring(core.window and system.window_has_focus(core.window))
    )
    core.request_window_reactivation_repaint("focusgained")
  elseif type == "focuslost" then
    core.log_quiet(
      "Focus diagnostics: received focuslost event active=%s window_has_focus=%s",
      tostring(core.active_view), tostring(core.window and system.window_has_focus(core.window))
    )
    core.root_panel:on_focus_lost(...)
  elseif type == "quit" then
    core.quit()
  end
  return did_keymap
end


function core.get_view_title(view)
  local title = ""
  local project = core.projects[1]
  if view.get_filename and view:get_filename() then
    local filename = core.view_file_path(view)
    if filename then
      local prj, is_open, belongs = core.current_project(filename)
      if prj and is_open and belongs then
        project = prj
        title = common.relative_path(project.path, filename)
        if core.view_is_dirty(view) then title = title .. "*" end
      else
        title = view:get_filename()
      end
    else
      title = view:get_filename()
    end
  else
    project = {path = ""}
    title = view:get_name()
  end
  if title and title ~= "---" then
    return title .. (
      project.path ~= "" and " - " .. common.basename(project.path) or ""
    )
  end
  return ""
end


function core.compose_window_title(title)
  return (title == "" or title == nil) and "Anvil" or title .. " - Anvil"
end

local draw_stats_fps = 0
local draw_stats_avg = "0"
local draw_stats_co_max = "0"
local draw_stats_co_count = 0
local draw_stats_frames = {}
local draw_stats_cotimes = {}
local draw_stats_last_time = system.get_time()
local draw_stats_overlay_width = 0

---Draw some stats useful for troubleshooting.
---Called when config.draw_stats is enabled.
local function draw_stats()
  local x, y = 20 * SCALE, 30 * SCALE
  local font = style.font
  local c1, c2 = style.syntax.keyword, style.syntax.string
  local h = font:get_height()
  local color = {table.unpack(style.background)} color[4] = 200
  renderer.draw_rect(0, y - (10*SCALE), draw_stats_overlay_width, h * 4 + y, color)
  local x2 = renderer.draw_text(font, "FPS: ", x, y, c1)
  renderer.draw_text(font, draw_stats_fps, x2, y, c2)
  y = y + h + 3 * SCALE
  x2 = renderer.draw_text(font, "AVG: ", x, y, c1)
  renderer.draw_text(font, draw_stats_avg, x2, y, c2)
  y = y + h
  x2 = renderer.draw_text(font, "COTIME: ", x, y, c1)
  x2 = renderer.draw_text(font, draw_stats_co_max, x2, y, c2)
  y = y + h + 3 * SCALE
  draw_stats_overlay_width = x2 + x
  x2 = renderer.draw_text(font, "COCOUNT: ", x, y, c1)
  renderer.draw_text(font, draw_stats_co_count, x2, y, c2)
end

---Time it takes to render a single frame (value will be cap to 1000fps).
---@type number
local rendering_speed = 0.004

---Each second there is time assigned to drawing the amount of config.fps
---and for executing the coroutine tasks, this value represents the time
---that coroutines should not exceed for each 1s cycle.
---@type number
local cycle_end_time = 0

---Keep track of frame drops in order to decide if we should adjust the timings.
---@type integer
local fps_drops = 0

---Maximum amount of coroutines to execute on a frame iteration that not exceed
---the maximum allowed time. Value is adjusted on each run_threads as needed.
---@type integer
local max_coroutines = 1000

---Amount of time spent running the main loop without the time it takes to
---run the coroutines. (resets at very cycle end)
---@type number
local main_loop_time = 0

local function env_truthy(name)
  local value = os.getenv(name)
  if not value or value == "" then return false end
  value = value:lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

local function rad_frame_pacing_enabled()
  if env_truthy("ANVIL_NO_POST_PRESENT_SLEEP") then return true end

  local value = os.getenv("ANVIL_RAD_PACING")
  if not value or value == "" then return true end
  value = value:lower():match("^%s*(.-)%s*$")
  return value ~= "0" and value ~= "false" and value ~= "no" and value ~= "off"
end

local function renderer_present_paced()
  return renderer.is_present_paced and renderer.is_present_paced() or false
end

local last_core_step_stats = {}

local function perf_stats_enabled()
  local perf = package.loaded["core.perf"]
  return os.getenv("ANVIL_DOCVIEW_STATS") or (perf and perf.is_recording and perf.is_recording())
end

local function new_perf_frame_stats()
  return {
    draw_ms = 0,
    prepare_ms = 0,
    prepare_highlight_ms = 0,
    prepare_caret_ms = 0,
    prepare_selection_ms = 0,
    prepare_merge_ms = 0,
    gutter_ms = 0,
    body_ms = 0,
    text_ms = 0,
    overlay_ms = 0,
    highlighter_get_line_ms = 0,
    token_loop_ms = 0,
    renderer_draw_text_ms = 0,
    visible_lines = 0,
    text_lines = 0,
    tokens = 0,
    draw_text_calls = 0,
    caret_draw_calls = 0,
    selection_rect_calls = 0,
    prepare_highlight_iters = 0,
    prepare_caret_scan_count = 0,
    visible_carets = 0,
    prepare_selection_iters = 0,
    visible_selection_ranges = 0,
    selection_cache_lines = 0,
    selection_cache_ranges = 0,
    selection_cache_merged_ranges = 0,
    doc_get_selections_calls = 0,
    doc_get_selections_iters = 0,
    doc_set_selections_calls = 0,
    doc_set_selections_ms = 0,
    doc_add_selection_calls = 0,
    doc_add_selection_ms = 0,
    doc_merge_cursors_calls = 0,
    doc_merge_cursors_ms = 0,
    doc_sanitize_selection_calls = 0,
    doc_sanitize_selection_ms = 0,
    doc_apply_edits_calls = 0,
    doc_apply_edits_ms = 0,
    command_calls = 0,
    command_total_ms = 0,
    command_predicate_ms = 0,
    command_body_ms = 0,
    slowest_command_ms = 0,
    slowest_command_name = "",
    statusbar_selection_ms = 0,
    statusbar_selection_cache_hits = 0,
    statusbar_selection_cache_misses = 0,
  }
end

function core.step(next_frame_time, options)
  options = options or {}
  local step_stats = {
    event_ms = 0,
    update_ms = 0,
    pre_draw_ms = 0,
    draw_emit_ms = 0,
    renderer_end_ms = 0,
    frame_time_ms = 0,
    event_count = 0,
  }
  last_core_step_stats = step_stats
  core.perf_frame_stats = perf_stats_enabled() and new_perf_frame_stats() or nil
  core.docview_frame_stats = nil

  -- handle events
  local did_keymap = false

  local event_start_time = system.get_time()
  local event_received = false
  local event_type_counts = {}
  local event_type_order = {}
  local function note_event(event_type, event_item_start)
    if not event_type_counts[event_type] then
      event_type_order[#event_type_order + 1] = event_type
      event_type_counts[event_type] = 0
    end
    event_type_counts[event_type] = event_type_counts[event_type] + 1
    local elapsed = (system.get_time() - event_item_start) * 1000
    if elapsed > (step_stats.slowest_event_ms or 0) then
      step_stats.slowest_event_ms = elapsed
      step_stats.slowest_event_type = event_type
    end
  end
  for type, a,b,c,d in system.poll_event do
    local event_item_start = system.get_time()
    step_stats.event_count = step_stats.event_count + 1
    if type == "textinput" and did_keymap then
      did_keymap = false
    elseif type == "mousemoved" then
      core.try(core.on_event, type, a, b, c, d)
    elseif type == "enteringforeground" then
      -- to break our frame refresh in two if we get entering/entered at the same time.
      -- required to avoid flashing and refresh issues on mobile
      event_received = type
      note_event(type, event_item_start)
      break
    elseif type == "displaychanged" then
      core.refresh_display_timing("displaychanged")
    elseif type == "moved" then
      core.refresh_display_timing("moved")
    elseif type == "scalechanged" then
      update_scale(a)
      core.refresh_display_timing("scalechanged")
    else
      local _, res = core.try(core.on_event, type, a, b, c, d)
      did_keymap = res or did_keymap
    end
    note_event(type, event_item_start)
    event_received = type
  end
  step_stats.event_ms = (system.get_time() - event_start_time) * 1000
  if #event_type_order > 0 then
    local event_types = {}
    for i, event_type in ipairs(event_type_order) do
      event_types[i] = string.format("%s:%d", event_type, event_type_counts[event_type])
    end
    step_stats.event_types = table.concat(event_types, " ")
  end

  local width, height = core.window:get_size()

  -- update
  local update_start_time = system.get_time()
  local stats_config = config.draw_stats
  local uncapped = stats_config == "uncapped"
  local priority_event = event_received and event_received ~= "mousemoved"
  local resizing = options.live_resize or (core.window_resizing_until and core.window_resizing_until > system.get_time())
  core.root_panel.size.x, core.root_panel.size.y = width, height
  if uncapped or resizing or priority_event or options.immediate or next_frame_time < system.get_time() then
    core.root_panel:update()
  end
  step_stats.update_ms = (system.get_time() - update_start_time) * 1000

  -- Skip drawing if there is time left before next frame, unless, an event is
  -- received or benchmarking. Skipping helps keep FPS near to the value set on
  ---config.fps when core.redraw is set from a coroutine and not by user
  ---interaction. Otherwise, rendering is prioritized on user events and
  ---config.fps not obeyed.
  if
    not uncapped and not resizing and not options.immediate and ((not event_received and not core.redraw) or
      -- time left before next frame so we can skip
      next_frame_time > system.get_time()
    )
  then
    return false
  end
  core.redraw = false

  local pre_draw_start_time = system.get_time()

  -- close unreferenced docs
  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if #core.get_views_referencing_doc(doc) == 0 then
      table.remove(core.docs, i)
      doc:on_close()
      core.collect_garbage = true
      if #core.docs == 0 then
        system.chdir(core.projects[1].path)
      end
    end
  end

  -- update window title
  local current_title = core.get_view_title(core.active_view)
  if current_title ~= nil and current_title ~= core.window_title then
    system.set_window_title(core.window, core.compose_window_title(current_title))
    core.window_title = current_title
  end

  -- draw
  step_stats.pre_draw_ms = (system.get_time() - pre_draw_start_time) * 1000
  local start_time = system.get_time()
  renderer.begin_frame(core.window)
  core.clip_rect_stack[1] = { 0, 0, width, height }
  renderer.set_clip_rect(table.unpack(core.clip_rect_stack[1]))
  local draw_emit_start_time = system.get_time()
  core.docview_frame_stats = core.perf_frame_stats
  core.root_panel:draw()
  step_stats.draw_emit_ms = (system.get_time() - draw_emit_start_time) * 1000
  local renderer_end_start_time = system.get_time()
  renderer.end_frame()
  step_stats.renderer_end_ms = (system.get_time() - renderer_end_start_time) * 1000

  local frame_time = system.get_time() - start_time
  step_stats.frame_time_ms = frame_time * 1000
  rendering_speed = math.max(0.001, frame_time)

  if rad_frame_pacing_enabled() and renderer_present_paced() then
    -- D3D/SDL vsync present time is already the active frame clock. Do not
    -- treat that wait as CPU render cost and downshift the animation target.
    local frame_budget = 1 / config.fps
    core.co_max_time = math.max(0.001, math.min(0.004, frame_budget * 0.25))
    core.fps = config.fps
    fps_drops = 0
    max_coroutines = 1000
  else
    local meets_fps = rendering_speed * config.fps < 1

    if meets_fps or fps_drops < 3 then
      -- Calculate max allowed coroutines run time based on rendering speed.
      -- verbose formula: (1s - (rendering_speed * config.fps)) / config.fps
      core.co_max_time = 1 / config.fps - rendering_speed
      core.fps = config.fps

      if meets_fps then
        fps_drops = math.max(fps_drops - 1, 0)
      else
        fps_drops = fps_drops + 1
        core.co_max_time = rendering_speed / 3
        max_coroutines = 1
      end
    else
      -- If fps rendering dropped from config target we set the max time to
      -- to consume a fourth of the time that would be spent rendering.
      -- For example, if fps dropped from 60 to 25 then we use 1/4 of that time
      -- to run coroutines, which leaves us with a total of 18.75fps and a
      -- maximum time for coroutines of 0.013333333333333 per iteration.
      -- verbose formula: (rendering_speed * (fps / 4)) / (fps - (fps / 4))
      core.co_max_time = rendering_speed / 3
      max_coroutines = 1

      -- current frames per second substracting portion given to coroutines
      core.fps = 1 / (rendering_speed + core.co_max_time)

      -- reset cycle end time
      cycle_end_time = 0
    end
  end

  if stats_config then
    table.insert(draw_stats_frames, frame_time)
    table.insert(draw_stats_cotimes, core.co_max_time)
    if system.get_time() - draw_stats_last_time >= 1 then
      draw_stats_fps = #draw_stats_frames
      local sumftime = 0
      local sumctime = 0
      for i, time in ipairs(draw_stats_frames) do
        sumftime = sumftime + time
        sumctime = sumctime + draw_stats_cotimes[i]
      end
      local average = sumftime / draw_stats_fps
      local average_co = sumctime / draw_stats_fps
      draw_stats_avg = tostring(math.floor(
        (average * 1000) * 100 + 0.5) / 100
      ) .. "ms"
      draw_stats_co_max = tostring(math.floor(
        (average_co * 1000) * 100 + 0.5) / 100
      ) .. "ms"
      draw_stats_co_count = 0
      for _, _ in pairs(core.threads) do
        draw_stats_co_count = draw_stats_co_count + 1
      end
      draw_stats_last_time = system.get_time()
      draw_stats_frames = {}
      draw_stats_cotimes = {}
    end
    core.root_panel:defer_draw(draw_stats)
  end

  return true
end

---Flag that indicates which coroutines should be ran by run_threads().
---@type "all" | "background"
local run_threads_mode = "all"
local last_run_threads_slowest_loc = ""
local last_run_threads_slowest_ms = 0
local last_run_threads_runs = 0

local run_threads = coroutine.wrap(function()
  while true do
    -- Wait time until next run_threads iteration
    local minimal_time_to_wake = math.huge
    -- a count on the amount of threads that ran
    local runs = 0
    local slowest_loc = ""
    local slowest_time = 0
    -- used to re-adjust the minimal_time_to_wake to prioritize recurrent threads
    local run_start = system.get_time()

    for k, thread in pairs(core.threads) do
      -- run thread
      local end_time = 0
      if run_threads_mode == "all" or thread.background then
        if thread.wake < system.get_time() then
          local start_time = system.get_time()
          -- if the avg time of running the thread exceeds cycle_end_time
          -- execute the thread on next run
          if
            thread.avg_time
            and
            start_time + thread.avg_time > cycle_end_time - main_loop_time
          then
              coroutine.yield(thread.avg_time)
              start_time = system.get_time()
          end
          local _, wait = assert(coroutine.resume(thread.cr))
          end_time = system.get_time() - start_time
          runs = runs + 1
          if end_time > slowest_time then
            slowest_time = end_time
            slowest_loc = thread.loc or ""
          end
          if coroutine.status(thread.cr) == "dead" then
            if type(k) == "number" then
              table.remove(core.threads, k)
            else
              core.threads[k] = nil
            end
            if thread.background then
              core.background_threads = core.background_threads - 1
            end
          else
            -- store coroutine stats
            if not thread.time then
              thread.time = end_time
              thread.calls = 1
              thread.avg_time = end_time
            else
              -- keep numbers small
              thread.time = thread.calls < 1000
                and thread.time + end_time
                or end_time
              thread.calls = thread.calls < 1000 and thread.calls + 1 or 1
              thread.avg_time = thread.calls > 1
                and thread.time / thread.calls
                or thread.avg_time
            end
            -- penalize slow coroutines by setting their wait time to the
            -- same time it took to execute them.
            if not wait or wait < 0 then
              wait = math.max(end_time, 0.002)
            elseif end_time > wait or end_time > core.co_max_time then
              wait = end_time
            end
            thread.wake = system.get_time() + wait
            minimal_time_to_wake = math.min(minimal_time_to_wake, wait)
            if config.log_slow_threads and end_time > core.co_max_time then
              core.log_quiet(
                "Slow co-routine took %fs of max %fs at: \n%s",
                end_time, core.co_max_time, thread.loc
              )
            end
          end
        else
          minimal_time_to_wake =  math.min(
            minimal_time_to_wake, thread.wake - system.get_time()
          )
        end
      end

      -- stop running threads if we're about to hit the end of frame
      local yield_time = system.get_time()
      if yield_time - core.frame_start > core.co_max_time then
        -- set the maximum amount of coroutines to prevent exceeding max_time
        if max_coroutines > 1 then
          max_coroutines = math.max(runs-1, 1)
        end
        coroutine.yield(0)
      elseif runs >= max_coroutines then
        coroutine.yield(
          yield_time - run_start > minimal_time_to_wake
            and 0
            or (minimal_time_to_wake > yield_time
              and minimal_time_to_wake - yield_time
              or minimal_time_to_wake
            )
        )
      end
    end

    last_run_threads_slowest_loc = slowest_loc
    last_run_threads_slowest_ms = slowest_time * 1000
    last_run_threads_runs = runs

    -- if we reached here it means it was able to run coroutines without
    -- slow downs so we reset the maximum coroutines to amount it ran
    max_coroutines = math.max(max_coroutines, runs)

    local yield_time = system.get_time() - run_start
    coroutine.yield(
      yield_time > minimal_time_to_wake
        and 0
        or (minimal_time_to_wake > yield_time
          and minimal_time_to_wake - yield_time
          or minimal_time_to_wake
        )
    )
  end
end)

-- Increase garbage collection frequency to make collections smaller
-- in order to improves editor responsiveness.
if LUA_VERSION < 5.4 then
  collectgarbage("setpause", 150)
  collectgarbage("setstepmul", 150)
end

-- Override default collectgarbage function to prevent users from performing
-- a system stalling garbage collection, instead a new forcecollect option
-- can be used.
local collectgarbage_lua = collectgarbage

---This function is a generic interface to the garbage collector.
---It performs different functions according to its first argument, `opt`.
---@param opt? gcoptions | "forcecollect"
---@param ... any
---@return any
function collectgarbage(opt, ...)
  local ret
  if not opt or opt == "collect" then
    ret = collectgarbage_lua("step", 10*1024)
  elseif opt == "forcecollect" then
    ret = collectgarbage_lua("collect")
  else
    ret = collectgarbage_lua(opt, ...)
  end
  return ret
end

local resize_stats_file = nil
local resize_stats_seq = 0
local resize_stats_enabled = not not (
  os.getenv("ANVIL_RESIZE_STATS") or os.getenv("ANVIL_LIVE_RESIZE_STATS") or os.getenv("ANVIL_LUA_RESIZE_STATS")
)

local function csv_field(value)
  value = tostring(value or "")
  return '"' .. value:gsub('"', '""') .. '"'
end

local function resize_stats_log(fields)
  if not resize_stats_enabled then return end
  if not resize_stats_file then
    local path = os.getenv("ANVIL_LUA_RESIZE_STATS_FILE")
    if not path or path == "" then
      local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."
      path = tmp .. PATHSEP .. "anvil_lua_resize_stats.csv"
    end
    resize_stats_file = io.open(path, "wb")
    if not resize_stats_file then
      resize_stats_enabled = false
      return
    end
    resize_stats_file:write("time,seq,immediate,reason,live_resizing,did_redraw,pending_events,run_threads_ms,core_step_ms,sleep_requested_ms,sleep_actual_ms,total_ms,run_mode\n")
    resize_stats_file:flush()
  end
  resize_stats_seq = resize_stats_seq + 1
  resize_stats_file:write(table.concat({
    string.format("%.6f", system.get_time()),
    tostring(resize_stats_seq),
    fields.immediate and "1" or "0",
    csv_field(fields.reason),
    fields.live_resizing and "1" or "0",
    fields.did_redraw and "1" or "0",
    fields.pending_events and "1" or "0",
    string.format("%.3f", fields.run_threads_ms or 0),
    string.format("%.3f", fields.core_step_ms or 0),
    string.format("%.3f", fields.sleep_requested_ms or 0),
    string.format("%.3f", fields.sleep_actual_ms or 0),
    string.format("%.3f", fields.total_ms or 0),
    csv_field(fields.run_mode)
  }, ",") .. "\n")
  if os.getenv("ANVIL_RESIZE_STATS_FLUSH") or os.getenv("ANVIL_LUA_RESIZE_STATS_FLUSH") then
    resize_stats_file:flush()
  end
end

local frame_pacing_stats_file = nil
local frame_pacing_stats_seq = 0
local frame_pacing_stats_enabled = not not os.getenv("ANVIL_FRAME_PACING_STATS")

local function frame_pacing_stats_log(fields)
  if not frame_pacing_stats_enabled then return end
  if not frame_pacing_stats_file then
    local path = os.getenv("ANVIL_FRAME_PACING_STATS_FILE")
    if not path or path == "" then
      local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."
      path = tmp .. PATHSEP .. "anvil_frame_pacing_stats.csv"
    end
    frame_pacing_stats_file = io.open(path, "wb")
    if not frame_pacing_stats_file then
      frame_pacing_stats_enabled = false
      return
    end
    frame_pacing_stats_file:write("time,seq,rad_pacing,immediate,reason,target_fps,core_fps,present_paced,active_present_paced,did_redraw,pending_events,queue_depth,event_count,event_ms,update_ms,pre_draw_ms,draw_emit_ms,renderer_end_ms,frame_time_ms,run_threads_ms,core_step_ms,present_ms,sync_interval,renderer_path,draw_calls,quad_instances,texture_quads,texture_uploads,texture_upload_bytes,rencache_commands,rencache_text_commands,rencache_rect_commands,rencache_set_clip_commands,rencache_command_bytes,rencache_text_bytes,rencache_draw_text_ms,rencache_draw_text_width_ms,docview_draw_ms,docview_gutter_ms,docview_body_ms,docview_text_ms,docview_highlighter_get_line_ms,docview_token_loop_ms,docview_renderer_draw_text_ms,docview_visible_lines,docview_text_lines,docview_tokens,docview_draw_text_calls,sleep_requested_ms,sleep_actual_ms,skipped_post_present_sleep,total_ms,run_mode\n")
    frame_pacing_stats_file:flush()
  end
  frame_pacing_stats_seq = frame_pacing_stats_seq + 1
  frame_pacing_stats_file:write(table.concat({
    string.format("%.6f", system.get_time()),
    tostring(frame_pacing_stats_seq),
    fields.rad_pacing and "1" or "0",
    fields.immediate and "1" or "0",
    csv_field(fields.reason),
    string.format("%.3f", fields.target_fps or 0),
    string.format("%.3f", fields.core_fps or 0),
    fields.present_paced and "1" or "0",
    fields.active_present_paced and "1" or "0",
    fields.did_redraw and "1" or "0",
    fields.pending_events and "1" or "0",
    tostring(fields.queue_depth or 0),
    tostring(fields.event_count or 0),
    string.format("%.3f", fields.event_ms or 0),
    string.format("%.3f", fields.update_ms or 0),
    string.format("%.3f", fields.pre_draw_ms or 0),
    string.format("%.3f", fields.draw_emit_ms or 0),
    string.format("%.3f", fields.renderer_end_ms or 0),
    string.format("%.3f", fields.frame_time_ms or 0),
    string.format("%.3f", fields.run_threads_ms or 0),
    string.format("%.3f", fields.core_step_ms or 0),
    string.format("%.3f", fields.present_ms or 0),
    tostring(fields.sync_interval or 0),
    csv_field(fields.renderer_path),
    tostring(fields.draw_calls or 0),
    tostring(fields.quad_instances or 0),
    tostring(fields.texture_quads or 0),
    tostring(fields.texture_uploads or 0),
    tostring(fields.texture_upload_bytes or 0),
    tostring(fields.rencache_commands or 0),
    tostring(fields.rencache_text_commands or 0),
    tostring(fields.rencache_rect_commands or 0),
    tostring(fields.rencache_set_clip_commands or 0),
    tostring(fields.rencache_command_bytes or 0),
    tostring(fields.rencache_text_bytes or 0),
    string.format("%.3f", fields.rencache_draw_text_ms or 0),
    string.format("%.3f", fields.rencache_draw_text_width_ms or 0),
    string.format("%.3f", fields.docview_draw_ms or 0),
    string.format("%.3f", fields.docview_gutter_ms or 0),
    string.format("%.3f", fields.docview_body_ms or 0),
    string.format("%.3f", fields.docview_text_ms or 0),
    string.format("%.3f", fields.docview_highlighter_get_line_ms or 0),
    string.format("%.3f", fields.docview_token_loop_ms or 0),
    string.format("%.3f", fields.docview_renderer_draw_text_ms or 0),
    tostring(fields.docview_visible_lines or 0),
    tostring(fields.docview_text_lines or 0),
    tostring(fields.docview_tokens or 0),
    tostring(fields.docview_draw_text_calls or 0),
    string.format("%.3f", fields.sleep_requested_ms or 0),
    string.format("%.3f", fields.sleep_actual_ms or 0),
    fields.skipped_post_present_sleep and "1" or "0",
    string.format("%.3f", fields.total_ms or 0),
    csv_field(fields.run_mode)
  }, ",") .. "\n")
  if os.getenv("ANVIL_FRAME_PACING_STATS_FLUSH") then
    frame_pacing_stats_file:flush()
  end
end

-- Run-loop state shared between core.run() (setup) and core.run_step() (per-frame).
local run_next_step       = nil
local run_skip_no_focus   = 0
local run_burst_events    = 0
local run_has_focus       = true
local run_next_frame_time = 0
local perf_last_redraw_time = nil
local perf_smoothed_fps = 0
local focus_diag_last_state = nil
local focus_diag_last_anomaly_log = 0

---Set up the run-loop state.  Called once from C (SDL_AppInit → init_lua_state)
---via the init_code that also calls core.init().  SDL_AppIterate then drives the
---loop by calling core.run_step() on every frame.
function core.run()
  scale = require "plugins.scale"
  run_next_step       = nil
  run_skip_no_focus   = 0
  run_burst_events    = 0
  run_has_focus       = true
  run_next_frame_time = system.get_time() + 1 / config.fps
end

---Execute one frame of the main loop.
---
---Called by C's SDL_AppIterate on every frame.
---
---@return boolean  true to keep running, false to quit or restart.
function core.run_step(options)
  options = options or {}
  local immediate = not not options.immediate
  local immediate_reason = options.reason or ""
  local previous_live_resize_frame = core.in_live_resize_frame
  core.in_live_resize_frame = immediate and options.live_resize or false
  local run_step_start = system.get_time()
  local sleep_requested_ms = 0
  local sleep_actual_ms = 0
  local pending_events_at_start = system.has_pending_events()
  local now     = run_step_start
  local uncapped = config.draw_stats == "uncapped"
  local rad_pacing = rad_frame_pacing_enabled()
  local present_paced = renderer_present_paced()
  local active_present_paced = false
  local skipped_post_present_sleep = false
  local reactivation_repaint_active = core.window_reactivation_repaint_pending(now)
  if reactivation_repaint_active then
    core.redraw = true
    run_next_step = nil
    if run_burst_events < window_reactivation_repaint_until then
      run_burst_events = window_reactivation_repaint_until
    end
  end
  core.frame_start = now

  local function run_step_sleep(seconds)
    seconds = seconds or 0
    if seconds <= 0 then return end
    sleep_requested_ms = sleep_requested_ms + seconds * 1000
    if immediate then return end
    local sleep_start = system.get_time()
    system.sleep(seconds)
    sleep_actual_ms = sleep_actual_ms + (system.get_time() - sleep_start) * 1000
  end

  -- start a new 1s cycle
  if core.frame_start >= cycle_end_time then
    cycle_end_time  = core.frame_start + (core.co_max_time * core.fps)
    main_loop_time  = 0
    run_has_focus   = system.window_has_focus(core.window)
  end

  -- run all coroutine tasks. Immediate resize frames are inside the Win32
  -- modal sizing loop, so skip background coroutine work and draw the latest
  -- layout without adding scheduler latency.
  local threads_start = system.get_time()
  local time_to_wake = 0
  local threads_end_time = 0
  if not immediate then
    time_to_wake = run_threads()
    threads_end_time = system.get_time() - threads_start
    now = now + threads_end_time
  end
  local run_threads_ms = threads_end_time * 1000

  -- respect coroutines redraw requests
  if run_has_focus or core.redraw then
    run_skip_no_focus = core.frame_start + 5
    run_next_step     = nil
  end

  -- detect events that arrived via SDL_AppEvent before this iteration
  -- and use them to enable burst-rendering mode
  if system.has_pending_events() then
    run_next_step     = nil
    run_burst_events  = now + 3
  end

  active_present_paced = rad_pacing and present_paced and (
    immediate or pending_events_at_start or core.redraw or run_burst_events > now
  )

  -- set the run mode
  if immediate then
    run_threads_mode = "all"
  elseif
    not run_has_focus
    and run_skip_no_focus < core.frame_start
    and core.background_threads > 0
  then
    run_threads_mode = "background"
  else
    run_threads_mode = "all"
  end

  local did_redraw = false
  local core_step_ms = 0

  if run_threads_mode == "background" then
    -- run background threads, no drawing or events processing
    run_next_step = nil
    -- Cap sleep to 100 ms so focus / event changes are noticed quickly
    run_step_sleep(math.min(time_to_wake, 0.1))
    -- allow normal rendering when the mouse moves over the window
    if system.has_pending_events() then
      run_skip_no_focus = now + 5
    end
  else
    -- listen events and perform drawing as needed
    if immediate or not run_next_step or now >= run_next_step then
      local core_step_start = system.get_time()
      did_redraw    = core.step(run_next_frame_time, options)
      core_step_ms  = (system.get_time() - core_step_start) * 1000
      now           = system.get_time()
      run_next_step = nil
    end
    if core.restart_request or core.quit_request then
      core.in_live_resize_frame = previous_live_resize_frame
      return false
    end
    if not did_redraw then
      if run_has_focus or core.background_threads > 0 or run_skip_no_focus > now then
        if not run_next_step then -- compute the time until the next blink
          local t  = now - core.blink_start
          local h  = config.blink_period / 2
          local dt = math.ceil(t / h) * h - t
          local cursor_time_to_wake = dt + 1 / core.fps
          run_next_step = now + cursor_time_to_wake
        end
        local nframe = run_next_frame_time - system.get_time()
        nframe = nframe > 0 and nframe or (1/core.fps)
        local b = (uncapped and run_burst_events > now) and rendering_speed or nframe
        -- Sleep instead of SDL_WaitEvent: SDL3 callbacks prohibit blocking waits
        -- inside SDL_AppIterate.  Any events that arrive during this sleep will
        -- be delivered via SDL_AppEvent on the next callback iteration.
        local sleep_time = math.min(run_next_step - now, time_to_wake, b)
        if sleep_time > 0 then
          run_step_sleep(sleep_time)
        end
      else
        -- No focus and nothing to do: sleep briefly to avoid spinning.
        -- SDL will call SDL_AppEvent when input arrives.
        run_step_sleep(0.1)
        -- allow normal rendering for up to 5 seconds after receiving event
        -- to let any animations render smoothly
        run_skip_no_focus = system.get_time() + 5
        -- perform a step when we're not in focus in case we get an event
        run_next_step = nil
      end
    else -- if we redrew, then make sure we only draw at most FPS/sec
      if active_present_paced then
        -- A present-paced renderer already waited for vsync inside
        -- renderer.end_frame(). Do not add SDL_Delay jitter after it.
        run_next_frame_time = now
        run_next_step = nil
        skipped_post_present_sleep = true
      else
        local elapsed    = now - core.frame_start
        local next_frame = math.max(0, 1 / core.fps - elapsed)
        run_next_frame_time = now + next_frame
        run_next_step = run_next_step or run_next_frame_time
        run_step_sleep(math.min(uncapped and 0 or 1, next_frame, time_to_wake))
      end
    end
  end

  -- run the garbage collector on request
  local gc_ms = 0
  if core.collect_garbage then
    local gc_start = system.get_time()
    collectgarbage("collect")
    gc_ms = (system.get_time() - gc_start) * 1000
    core.collect_garbage = false
  end

  -- Update the loop run time
  main_loop_time = main_loop_time + (
    (system.get_time() - core.frame_start) - threads_end_time
  )

  local renderer_stats = renderer.get_last_frame_stats and renderer.get_last_frame_stats() or {}
  local step_stats = did_redraw and last_core_step_stats or {}
  step_stats.event_count = step_stats.event_count or 0
  step_stats.event_ms = step_stats.event_ms or 0
  step_stats.update_ms = step_stats.update_ms or 0
  step_stats.pre_draw_ms = step_stats.pre_draw_ms or 0
  step_stats.draw_emit_ms = step_stats.draw_emit_ms or 0
  step_stats.renderer_end_ms = step_stats.renderer_end_ms or 0
  step_stats.frame_time_ms = step_stats.frame_time_ms or 0
  local live_resizing = core.window_resizing_until and core.window_resizing_until > system.get_time()
  resize_stats_log {
    immediate = immediate,
    reason = immediate_reason,
    live_resizing = live_resizing,
    did_redraw = did_redraw,
    pending_events = pending_events_at_start,
    run_threads_ms = run_threads_ms,
    core_step_ms = core_step_ms,
    sleep_requested_ms = sleep_requested_ms,
    sleep_actual_ms = sleep_actual_ms,
    total_ms = (system.get_time() - run_step_start) * 1000,
    run_mode = run_threads_mode,
  }
  local docview_stats = core.perf_frame_stats or core.docview_frame_stats or {}
  local total_ms = (system.get_time() - run_step_start) * 1000
  if did_redraw then
    local t = system.get_time()
    if perf_last_redraw_time and t > perf_last_redraw_time then
      local instant_fps = 1 / (t - perf_last_redraw_time)
      perf_smoothed_fps = perf_smoothed_fps > 0
        and (perf_smoothed_fps * 0.85 + instant_fps * 0.15)
        or instant_fps
    end
    perf_last_redraw_time = t
  end
  local active_view = core.active_view
  local active_doc = active_view and active_view.doc
  local active_view_name = active_view and tostring(active_view) or ""
  local active_view_is_docview = active_view and active_view.extends and active_view:extends(DocView) or false
  local window_has_focus = core.window and system.window_has_focus(core.window) or false
  local queue_depth = system.pending_event_count and system.pending_event_count() or (system.has_pending_events() and 1 or 0)
  local selection_count = active_doc and active_doc.selections and (#active_doc.selections / 4) or 0
  local search_selection_count = 0
  if active_doc and active_doc.search_selections then
    for _ in pairs(active_doc.search_selections) do
      search_selection_count = search_selection_count + 1
    end
  end

  if focus_diag_last_state == nil or focus_diag_last_state ~= window_has_focus then
    core.log_quiet(
      "Focus diagnostics: window_has_focus=%s active=%s docview=%s redraw=%s event_count=%d pending=%s queue=%d run_mode=%s native={%s}",
      tostring(window_has_focus), active_view_name, tostring(active_view_is_docview),
      tostring(did_redraw), step_stats.event_count, tostring(pending_events_at_start),
      queue_depth, tostring(run_threads_mode),
      system.window_focus_diagnostics and core.window and system.window_focus_diagnostics(core.window) or "unavailable"
    )
    focus_diag_last_state = window_has_focus
  end

  if active_view_is_docview and not window_has_focus then
    local now = system.get_time()
    if now - focus_diag_last_anomaly_log >= 2 then
      local line1, col1, line2, col2
      if active_doc then
        line1, col1, line2, col2 = active_doc:get_selection()
      end
      core.log_quiet(
        "Focus diagnostics: active DocView while window_has_focus=false file=%s selection_count=%s selection=%s,%s-%s,%s redraw=%s blink=%.3f event_count=%d pending=%s queue=%d native={%s}",
        tostring(active_doc and (active_doc.abs_filename or active_doc.filename) or ""),
        tostring(selection_count), tostring(line1), tostring(col1), tostring(line2), tostring(col2),
        tostring(did_redraw), core.blink_timer or 0, step_stats.event_count,
        tostring(pending_events_at_start), queue_depth,
        system.window_focus_diagnostics and core.window and system.window_focus_diagnostics(core.window) or "unavailable"
      )
      focus_diag_last_anomaly_log = now
    end
  end

  core.performance_snapshot = {
    time = system.get_time(),
    rad_pacing = rad_pacing,
    immediate = immediate,
    reason = immediate_reason,
    target_fps = config.fps,
    core_fps = core.fps,
    fps = perf_smoothed_fps,
    present_paced = present_paced,
    active_present_paced = active_present_paced,
    did_redraw = did_redraw,
    window_has_focus = window_has_focus,
    active_view_name = active_view_name,
    active_view_is_docview = active_view_is_docview,
    selection_count = selection_count,
    search_selection_count = search_selection_count,
    pending_events = pending_events_at_start,
    queue_depth = queue_depth,
    event_count = step_stats.event_count,
    event_ms = step_stats.event_ms,
    event_types = step_stats.event_types,
    slowest_event_type = step_stats.slowest_event_type,
    slowest_event_ms = step_stats.slowest_event_ms,
    update_ms = step_stats.update_ms,
    pre_draw_ms = step_stats.pre_draw_ms,
    draw_emit_ms = step_stats.draw_emit_ms,
    renderer_end_ms = step_stats.renderer_end_ms,
    frame_ms = step_stats.frame_time_ms,
    frame_time_ms = step_stats.frame_time_ms,
    run_threads_ms = run_threads_ms,
    run_threads_runs = last_run_threads_runs,
    run_threads_slowest_ms = last_run_threads_slowest_ms,
    run_threads_slowest_loc = last_run_threads_slowest_loc,
    core_step_ms = core_step_ms,
    gc_ms = gc_ms,
    present_ms = renderer_stats.present_ms,
    sync_interval = renderer_stats.sync_interval,
    renderer_path = renderer_stats.path,
    draw_calls = renderer_stats.draw_calls,
    quad_instances = renderer_stats.quad_instances,
    texture_quads = renderer_stats.texture_quads,
    texture_uploads = renderer_stats.texture_uploads,
    texture_upload_bytes = renderer_stats.texture_upload_bytes,
    docview_draw_ms = docview_stats.draw_ms,
    docview_prepare_ms = docview_stats.prepare_ms,
    docview_prepare_highlight_ms = docview_stats.prepare_highlight_ms,
    docview_prepare_caret_ms = docview_stats.prepare_caret_ms,
    docview_prepare_selection_ms = docview_stats.prepare_selection_ms,
    docview_prepare_merge_ms = docview_stats.prepare_merge_ms,
    docview_gutter_ms = docview_stats.gutter_ms,
    docview_body_ms = docview_stats.body_ms,
    docview_text_ms = docview_stats.text_ms,
    docview_overlay_ms = docview_stats.overlay_ms,
    docview_highlighter_get_line_ms = docview_stats.highlighter_get_line_ms,
    docview_token_loop_ms = docview_stats.token_loop_ms,
    docview_renderer_draw_text_ms = docview_stats.renderer_draw_text_ms,
    docview_visible_lines = docview_stats.visible_lines,
    docview_text_lines = docview_stats.text_lines,
    docview_tokens = docview_stats.tokens,
    docview_draw_text_calls = docview_stats.draw_text_calls,
    docview_caret_draw_calls = docview_stats.caret_draw_calls,
    docview_selection_rect_calls = docview_stats.selection_rect_calls,
    docview_prepare_highlight_iters = docview_stats.prepare_highlight_iters,
    docview_prepare_caret_scan_count = docview_stats.prepare_caret_scan_count,
    docview_visible_carets = docview_stats.visible_carets,
    docview_prepare_selection_iters = docview_stats.prepare_selection_iters,
    docview_visible_selection_ranges = docview_stats.visible_selection_ranges,
    docview_selection_cache_lines = docview_stats.selection_cache_lines,
    docview_selection_cache_ranges = docview_stats.selection_cache_ranges,
    docview_selection_cache_merged_ranges = docview_stats.selection_cache_merged_ranges,
    doc_get_selections_calls = docview_stats.doc_get_selections_calls,
    doc_get_selections_iters = docview_stats.doc_get_selections_iters,
    doc_set_selections_calls = docview_stats.doc_set_selections_calls,
    doc_set_selections_ms = docview_stats.doc_set_selections_ms,
    doc_add_selection_calls = docview_stats.doc_add_selection_calls,
    doc_add_selection_ms = docview_stats.doc_add_selection_ms,
    doc_merge_cursors_calls = docview_stats.doc_merge_cursors_calls,
    doc_merge_cursors_ms = docview_stats.doc_merge_cursors_ms,
    doc_sanitize_selection_calls = docview_stats.doc_sanitize_selection_calls,
    doc_sanitize_selection_ms = docview_stats.doc_sanitize_selection_ms,
    doc_apply_edits_calls = docview_stats.doc_apply_edits_calls,
    doc_apply_edits_ms = docview_stats.doc_apply_edits_ms,
    command_calls = docview_stats.command_calls,
    command_total_ms = docview_stats.command_total_ms,
    command_predicate_ms = docview_stats.command_predicate_ms,
    command_body_ms = docview_stats.command_body_ms,
    slowest_command_ms = docview_stats.slowest_command_ms,
    slowest_command_name = docview_stats.slowest_command_name,
    statusbar_selection_ms = docview_stats.statusbar_selection_ms,
    statusbar_selection_cache_hits = docview_stats.statusbar_selection_cache_hits,
    statusbar_selection_cache_misses = docview_stats.statusbar_selection_cache_misses,
    sleep_requested_ms = sleep_requested_ms,
    sleep_actual_ms = sleep_actual_ms,
    skipped_post_present_sleep = skipped_post_present_sleep,
    total_ms = total_ms,
    over_budget = did_redraw and (total_ms > (1000 / config.fps)),
    run_mode = run_threads_mode,
  }
  local perf = package.loaded["core.perf"]
  if perf and perf.on_frame then perf.on_frame(core.performance_snapshot) end
  frame_pacing_stats_log {
    rad_pacing = rad_pacing,
    immediate = immediate,
    reason = immediate_reason,
    target_fps = config.fps,
    core_fps = core.fps,
    present_paced = present_paced,
    active_present_paced = active_present_paced,
    did_redraw = did_redraw,
    pending_events = pending_events_at_start,
    queue_depth = system.pending_event_count and system.pending_event_count() or (system.has_pending_events() and 1 or 0),
    event_count = step_stats.event_count,
    event_ms = step_stats.event_ms,
    update_ms = step_stats.update_ms,
    pre_draw_ms = step_stats.pre_draw_ms,
    draw_emit_ms = step_stats.draw_emit_ms,
    renderer_end_ms = step_stats.renderer_end_ms,
    frame_time_ms = step_stats.frame_time_ms,
    run_threads_ms = run_threads_ms,
    run_threads_runs = last_run_threads_runs,
    run_threads_slowest_ms = last_run_threads_slowest_ms,
    run_threads_slowest_loc = last_run_threads_slowest_loc,
    core_step_ms = core_step_ms,
    gc_ms = gc_ms,
    present_ms = renderer_stats.present_ms,
    sync_interval = renderer_stats.sync_interval,
    renderer_path = renderer_stats.path,
    draw_calls = renderer_stats.draw_calls,
    quad_instances = renderer_stats.quad_instances,
    texture_quads = renderer_stats.texture_quads,
    texture_uploads = renderer_stats.texture_uploads,
    texture_upload_bytes = renderer_stats.texture_upload_bytes,
    rencache_commands = renderer_stats.rencache_commands,
    rencache_text_commands = renderer_stats.rencache_text_commands,
    rencache_rect_commands = renderer_stats.rencache_rect_commands,
    rencache_set_clip_commands = renderer_stats.rencache_set_clip_commands,
    rencache_command_bytes = renderer_stats.rencache_command_bytes,
    rencache_text_bytes = renderer_stats.rencache_text_bytes,
    rencache_draw_text_ms = renderer_stats.rencache_draw_text_ms,
    rencache_draw_text_width_ms = renderer_stats.rencache_draw_text_width_ms,
    docview_draw_ms = docview_stats.draw_ms,
    docview_gutter_ms = docview_stats.gutter_ms,
    docview_body_ms = docview_stats.body_ms,
    docview_text_ms = docview_stats.text_ms,
    docview_highlighter_get_line_ms = docview_stats.highlighter_get_line_ms,
    docview_token_loop_ms = docview_stats.token_loop_ms,
    docview_renderer_draw_text_ms = docview_stats.renderer_draw_text_ms,
    docview_visible_lines = docview_stats.visible_lines,
    docview_text_lines = docview_stats.text_lines,
    docview_tokens = docview_stats.tokens,
    docview_draw_text_calls = docview_stats.draw_text_calls,
    sleep_requested_ms = sleep_requested_ms,
    sleep_actual_ms = sleep_actual_ms,
    skipped_post_present_sleep = skipped_post_present_sleep,
    total_ms = (system.get_time() - run_step_start) * 1000,
    run_mode = run_threads_mode,
  }

  core.in_live_resize_frame = previous_live_resize_frame
  return true
end


function core.blink_reset()
  core.blink_start = system.get_time()
end


local last_file_dialog_tag = 0
local function open_dialog(type, window, callback, options)
  local types = {
    ["openfile"] = system.open_file_dialog,
    ["opendirectory"] = system.open_directory_dialog,
    ["savefile"] = system.save_file_dialog,
  }

  local dialog_fn = types[type]
  assert(dialog_fn, "Invalid dialog type")

  last_file_dialog_tag = last_file_dialog_tag + 1
  core.active_file_dialogs[last_file_dialog_tag] = callback
  dialog_fn(window, last_file_dialog_tag, options)
end

---Open the system file picker.
---
---Returns immediately.
---The callback will be called with the result.
---
---@param window renwindow
---@param callback fun(status: "accept"|"cancel"|"error"|"unknown", result: string[]|string|nil)
---@param options? system.dialogoptions.openfile
function core.open_file_dialog(window, callback, options)
  return open_dialog("openfile", window, callback, options)
end

---Open the system directory picker.
---
---Returns immediately.
---The callback will be called with the result.
---
---@param window renwindow
---@param callback fun(status: "accept"|"cancel"|"error"|"unknown", result: string[]|string|nil)
---@param options? system.dialogoptions.opendirectory
function core.open_directory_dialog(window, callback, options)
  return open_dialog("opendirectory", window, callback, options)
end

---Open the system save file picker.
---
---Returns immediately.
---The callback will be called with the result.
---
---@param window renwindow
---@param callback fun(status: "accept"|"cancel"|"error"|"unknown", result: string[]|string|nil)
---@param options? system.dialogoptions.savefile
function core.save_file_dialog(window, callback, options)
  return open_dialog("savefile", window, callback, options)
end


function core.request_cursor(value)
  core.cursor_change_req = value
end


function core.on_error(err)
  -- write error to file
  local fp = io.open(USERDIR .. PATHSEP .. "error.txt", "wb")
  fp:write("Error: " .. tostring(err) .. "\n")
  fp:write(debug.traceback("", 4) .. "\n")
  fp:close()
  -- save copy of all unsaved documents
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() and doc.filename then
      pcall(doc.save, doc, doc.filename .. "~", doc.abs_filename and (doc.abs_filename .. "~"))
    end
  end
end


local alerted_deprecations = {}
---Show deprecation notice once per `kind`.
---
---@param kind string
function core.deprecation_log(kind)
  if alerted_deprecations[kind] then return end
  alerted_deprecations[kind] = true
  core.warn("Used deprecated functionality [%s]. Check if your plugins are up to date.", kind)
end


---A pre-processed config.ignore_files entry.
---@class core.ignore_file_rule
---A lua pattern.
---@field pattern string
---Match a full path including path separators, otherwise match filename only.
---@field use_path boolean
---Match directories only.
---@field match_dir boolean

---Gets a list of pre-processed config.ignore_files patterns for usage in
---combination of common.match_ignore_rule()
---@return core.ignore_file_rule[]
function core.get_ignore_file_rules()
  local ipatterns = config.ignore_files
  local compiled = {}
  -- config.ignore_files could be a simple string...
  if type(ipatterns) ~= "table" then ipatterns = {ipatterns} end
  for _, pattern in ipairs(ipatterns) do
    -- we ignore malformed pattern that raise an error
    if pcall(string.match, "a", pattern) then
      table.insert(compiled, {
        use_path = pattern:match("/[^/$]"), -- contains a slash but not at the end
        -- An '/' or '/$' at the end means we want to match a directory.
        match_dir = pattern:match(".+/%$?$"), -- to be used as a boolen value
        pattern = pattern -- get the actual pattern
      })
    end
  end
  return compiled
end


return core
