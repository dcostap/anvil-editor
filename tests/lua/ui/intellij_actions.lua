local core = require "core"
local command = require "core.command"
local common = require "core.common"
local project_paths = require "core.project_paths"
local test = require "core.test"
local Editor = require "core.editor"
local panes = require "core.panes"

require "plugins.intellij_actions"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function write_file(path, content)
  local fp = assert(io.open(path, "wb"))
  fp:write(content)
  fp:close()
end

local function open_editor(context, text)
  local buffer = track(context, "buffers", core.open_buffer())
  if text and text ~= "" then buffer:text_input(text) end
  local view = track(context, "views", panes.place(function() return Editor(buffer) end,
    { placement = "new", focus = true }))
  return view, buffer
end

local function set_view_selections(view, selections)
  view:with_selection_state(function()
    view.buffer:set_selection(selections[1], selections[2], selections[3], selections[4])
    for i = 5, #selections, 4 do
      view.buffer:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, 0)
    end
  end)
end

local function view_selections(view)
  return view:with_selection_state(function()
    return { table.unpack(view.buffer.selections) }
  end)
end

test.describe("IntelliJ actions batch behavior", function()
  test.after_each(function(context)
    if context.original_set_clipboard then
      system.set_clipboard = context.original_set_clipboard
      context.original_set_clipboard = nil
    end
    if context.project_paths_configured then
      project_paths.configure_project {}
      context.project_paths_configured = nil
    end
    if context.original_system_exec then
      system.exec = context.original_system_exec
      context.original_system_exec = nil
    end
    if context.original_process_start then
      local process = require "core.process"
      process.start = context.original_process_start
      context.original_process_start = nil
    end

    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers or {}) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end

    if context.temp_root and system.get_file_info(context.temp_root) then
      common.rm(context.temp_root, true)
    end
  end)

  test.it("duplicate current line handles multiple selections in one buffer change", function(context)
    local view, buffer = open_editor(context, "aa\nbb\ncc\ndd")
    set_view_selections(view, {
      1, 1, 1, 1,
      3, 1, 3, 1,
    })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("editor:duplicate_current_line"))

    test.equal(table.concat(buffer.lines), "aa\naa\nbb\ncc\ncc\ndd\n")
    test.equal(changes, 1)
    test.same(view_selections(view), {
      2, 1, 2, 1,
      5, 1, 5, 1,
    })
  end)

  test.it("line comment at start comments selected lines in one buffer change", function(context)
    local view, buffer = open_editor(context, "aa\nbb\ncc")
    set_view_selections(view, { 1, 2, 3, 3 })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("editor:comment_with_line_comment_at_start"))

    test.equal(table.concat(buffer.lines), "//aa\n//bb\n//cc\n")
    test.equal(changes, 1)
    test.same(view_selections(view), { 1, 4, 3, 5 })
  end)

  test.it("line comment at start uncomments selected lines in one buffer change", function(context)
    local view, buffer = open_editor(context, "//aa\n//bb\n//cc")
    set_view_selections(view, { 1, 4, 3, 5 })
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    test.ok(command.perform("editor:comment_with_line_comment_at_start"))

    test.equal(table.concat(buffer.lines), "aa\nbb\ncc\n")
    test.equal(changes, 1)
    test.same(view_selections(view), { 1, 2, 3, 3 })
  end)

  test.it("clone caret below until last line adds carets in one bulk selection update", function(context)
    local view, buffer = open_editor(context, "aa\nbb\ncc\ndd")
    set_view_selections(view, { 2, 2, 2, 2 })

    test.ok(command.perform("editor:clone_caret_below_until_last_line_intellij"))

    test.same(view_selections(view), {
      2, 2, 2, 2,
      3, 2, 3, 2,
      4, 2, 4, 2,
    })
    test.equal(view.selection_state.last_selection, 3)
  end)

  test.it("select all occurrences replaces selections in bulk", function(context)
    local view = open_editor(context, "aa xx aa\naa")
    set_view_selections(view, { 1, 1, 1, 3 })

    test.ok(command.perform("editor:select_all_occurrences"))

    test.same(view_selections(view), {
      1, 3, 1, 1,
      1, 9, 1, 7,
      2, 3, 2, 1,
    })
    test.equal(view.selection_state.last_selection, 1)
  end)

  test.it("select all occurrences builds many selections without per-occurrence set_selections", function(context)
    local lines = {}
    for i = 1, 200 do lines[i] = "aa xx" end
    local view, buffer = open_editor(context, table.concat(lines, "\n"))
    set_view_selections(view, { 1, 1, 1, 3 })

    local original_set_selections = buffer.set_selections
    buffer.set_selections = function()
      error("user:select-all-occurrences should use batched selection replacement")
    end

    local ok, err = pcall(function()
      test.ok(command.perform("editor:select_all_occurrences"))
      local selections = view_selections(view)
      test.equal(#selections / 4, 200)
      test.same({ selections[1], selections[2], selections[3], selections[4] }, { 1, 3, 1, 1 })
      test.same({ selections[#selections - 3], selections[#selections - 2], selections[#selections - 1], selections[#selections] }, { 200, 3, 200, 1 })
      test.equal(view.selection_state.last_selection, 1)
    end)
    buffer.set_selections = original_set_selections
    if not ok then error(err) end
  end)

  test.it("copies the Root Project path regardless of the focused file", function(context)
    context.temp_root = join_path(core.root_project().path, "intellij-actions-project-path")
    local shared_root = join_path(context.temp_root, "shared")
    local external_file_path = join_path(shared_root, "main.lua")
    local project_file_path = join_path(context.temp_root, "project.lua")
    test.ok(common.mkdirp(shared_root))
    write_file(external_file_path, "return true\n")
    write_file(project_file_path, "return true\n")

    project_paths.configure_project {
      external = {
        { path = shared_root, label = "shared" },
      },
    }
    context.project_paths_configured = true

    local copied
    context.original_set_clipboard = system.set_clipboard
    system.set_clipboard = function(text) copied = text end

    local external_buffer = track(context, "buffers", core.open_buffer(external_file_path))
    local external_view = track(context, "views", panes.place(function() return Editor(external_buffer) end, { placement = "new" }))
    core.set_active_view(external_view)
    test.ok(command.perform("editor:copy_project_path"))
    test.equal(copied, core.root_project().path)

    local project_buffer = track(context, "buffers", core.open_buffer(project_file_path))
    local project_view = track(context, "views", panes.place(function() return Editor(project_buffer) end, { placement = "new" }))
    core.set_active_view(project_view)
    test.ok(command.perform("editor:copy_project_path"))
    test.equal(copied, core.root_project().path)
  end)

  test.it("exposes file path copy actions in the Command Palette", function()
    for _, name in ipairs({
      "editor:copy_absolute_filepath",
      "editor:copy_absolute_filepath_with_line",
      "editor:copy_relative_filepath",
      "editor:copy_project_path",
      "editor:copy_filename",
    }) do
      local metadata = command.get_metadata(name)
      test.ok(metadata and metadata.palette == true, name .. " is hidden from the palette")
    end
  end)

  test.it("open terminal command uses the active file directory", function(context)
    context.temp_root = join_path(USERDIR, "intellij-actions-terminal")
    local nested_dir = join_path(context.temp_root, "nested dir")
    test.ok(common.mkdirp(nested_dir))
    local file_path = join_path(nested_dir, "main.lua")
    write_file(file_path, "return true\n")

    local buffer = track(context, "buffers", core.open_buffer(file_path))
    local view = track(context, "views", panes.place(function() return Editor(buffer) end, { placement = "new" }))
    core.set_active_view(view)

    local exec_commands = {}
    context.original_system_exec = system.exec
    system.exec = function(cmd)
      exec_commands[#exec_commands + 1] = cmd
    end

    local start_calls = {}
    local process = require "core.process"
    context.original_process_start = process.start
    process.start = function(args, options)
      start_calls[#start_calls + 1] = { args = args, options = options }
      return {}
    end

    test.ok(command.perform("editor:open_terminal_at_current_file"))

    local expected_dir = common.normalize_path(nested_dir)
    if PLATFORM == "Windows" then
      test.equal(#start_calls, 1)
      test.same(start_calls[1].args, { "wt.exe", "-d", expected_dir })
      test.equal(start_calls[1].options.cwd, expected_dir)
      test.equal(#exec_commands, 0)
    elseif PLATFORM == "Mac OS X" then
      test.equal(#exec_commands, 1)
      test.contains(exec_commands[1], "open -a Terminal")
      test.contains(exec_commands[1], expected_dir)
    else
      test.equal(#start_calls, 1)
      test.equal(start_calls[1].args[1], "x-terminal-emulator")
      test.equal(start_calls[1].options.cwd, expected_dir)
      test.equal(#exec_commands, 0)
    end
  end)

  test.it("open terminal command falls back to cmd when Windows Terminal is unavailable", function(context)
    if PLATFORM ~= "Windows" then return end

    context.temp_root = join_path(USERDIR, "intellij-actions-terminal-fallback")
    test.ok(common.mkdirp(context.temp_root))
    local file_path = join_path(context.temp_root, "main.lua")
    write_file(file_path, "return true\n")

    local buffer = track(context, "buffers", core.open_buffer(file_path))
    local view = track(context, "views", panes.place(function() return Editor(buffer) end, { placement = "new" }))
    core.set_active_view(view)

    local process = require "core.process"
    context.original_process_start = process.start
    process.start = function()
      return nil, "not found"
    end

    local exec_commands = {}
    context.original_system_exec = system.exec
    system.exec = function(cmd)
      exec_commands[#exec_commands + 1] = cmd
    end

    test.ok(command.perform("editor:open_terminal_at_current_file"))
    test.equal(#exec_commands, 1)

    local expected_dir = common.normalize_path(context.temp_root):gsub("/", "\\")
    test.contains(exec_commands[1], "cmd.exe")
    test.contains(exec_commands[1], expected_dir)
    test.not_ok(exec_commands[1]:find(common.basename(file_path), 1, true), exec_commands[1])
  end)
end)
