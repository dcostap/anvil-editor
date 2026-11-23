local common = require "core.common"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"
local filetree = assert(require("plugins.filetree").new())
local project_paths = require "core.project_paths"

local function write_file(path, text)
  local handle, err = io.open(path, "wb")
  test.not_nil(handle, err)
  handle:write(text or "")
  handle:close()
end

local function setup_tree(context)
  local root = core.root_project().path .. PATHSEP .. "filetree-entry-tests-"
    .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
  local folder = root .. PATHSEP .. "folder"
  test.ok(common.mkdirp(folder))
  write_file(root .. PATHSEP .. "root.txt", "root")
  write_file(folder .. PATHSEP .. "child.txt", "child")
  context.previous_dir = filetree.current_dir
  context.temp_root = root
  filetree.current_dir = root
  filetree:refresh(false, false)
  return root
end

local function find_entry(name)
  for _, entry in ipairs(filetree:build_entries(false)) do
    if entry.text == name then return entry end
  end
end

local function row_point(name)
  local entry = test.not_nil(find_entry(name))
  filetree.position.x, filetree.position.y = 0, 0
  filetree.size.x, filetree.size.y = 800, 600
  filetree.scroll.x, filetree.scroll.y = 0, 0
  filetree.scroll.to.x, filetree.scroll.to.y = 0, 0
  local x, y = filetree:get_line_screen_position(entry.line, 1)
  return x + filetree:get_font():get_width("r") / 2, y + filetree:get_line_height() / 2, entry
end

local function drag_row(context, name)
  local x, y = row_point(name)
  local before = #context.drags
  test.ok(filetree:on_mouse_pressed("left", x, y, 1))
  filetree:on_mouse_moved(x + 40 * SCALE, y + 40 * SCALE, 40 * SCALE, 40 * SCALE)
  filetree:on_mouse_released("left", x + 40 * SCALE, y + 40 * SCALE)
  return #context.drags > before and context.drags[#context.drags] or nil
end

local function record_drags(context)
  context.drags = {}
  context.drag_files = system.drag_files
  system.drag_files = function(window, paths)
    test.equal(window, core.window)
    context.drags[#context.drags + 1] = paths
    return true
  end
end

test.describe("File Tree entry snapshots", function()
  test.after_each(function(context)
    if context.drag_files then system.drag_files = context.drag_files end
    if context.original_open_file then core.open_file = context.original_open_file end
    if context.scroll_context_lines then
      config.scroll_context_lines = context.scroll_context_lines
    end
    if context.original_resolve then
      project_paths.resolve = context.original_resolve
    end
    if context.previous_dir then
      filetree.current_dir = context.previous_dir
      filetree:refresh(false, false)
    end
    if context.temp_root then test.ok(test.remove_tree(context.temp_root)) end
  end)

  test.it("invalidates resolved entries after an editable tree change", function(context)
    local root = setup_tree(context)
    local original = find_entry("root.txt")
    test.not_nil(original)

    filetree:with_selection_state(function()
      filetree.buffer:insert(original.line, 1, "renamed-")
    end)

    local renamed = filetree:entry_for_line(original.line)
    test.ok(common.path_equals(renamed.abs, root .. PATHSEP .. "renamed-root.txt"))
  end)

  test.it("invalidates resolved entries when a folder expands", function(context)
    local root = setup_tree(context)
    local folder = find_entry("folder")
    test.not_nil(folder)

    filetree:expand_folder(folder.line, folder, false)

    local child = find_entry("child.txt")
    test.not_nil(child)
    test.ok(common.path_equals(child.abs, root .. PATHSEP .. "folder" .. PATHSEP .. "child.txt"))
  end)

  test.it("activates the selected entry through Point of Interest Activation", function(context)
    local root = setup_tree(context)
    local entry = find_entry("root.txt")
    test.not_nil(entry)
    filetree.buffer:set_selection(entry.line, 1)
    core.set_active_view(filetree)
    local opened
    local original_open_file = core.open_file
    core.open_file = function(path, opts)
      opened = { path = path, opts = opts }
      return {}
    end
    local ok, result = pcall(command.perform, "core:activate_point_of_interest")
    core.open_file = original_open_file
    if not ok then error(result, 0) end

    test.ok(result)
    test.ok(common.path_equals(opened.path, root .. PATHSEP .. "root.txt"))
    test.equal(opened.opts.placement, "current")

    core.open_file = function(path, opts)
      opened = { path = path, opts = opts }
      return {}
    end
    ok, result = pcall(command.perform, "core:activate_point_of_interest_alternate")
    core.open_file = original_open_file
    if not ok then error(result, 0) end
    test.ok(result)
    test.equal(opened.opts.placement, "split")
  end)

  test.it("creates and opens a single new file through Point of Interest Activation", function(context)
    local root = setup_tree(context)
    filetree.buffer:insert(1, 1, "created.txt\n")
    filetree.buffer:set_selection(1, 1)
    core.set_active_view(filetree)
    context.original_open_file = core.open_file
    local opened
    core.open_file = function(path, opts)
      opened = { path = path, opts = opts }
      return {}
    end

    test.ok(command.perform("core:activate_point_of_interest"))

    local created = root .. PATHSEP .. "created.txt"
    local info = system.get_file_info(created)
    test.not_nil(info, "expected the File Tree edit to create the file")
    test.equal(info.type, "file")
    test.ok(opened, "expected the created file to open")
    test.ok(common.path_equals(opened.path, created))
    test.equal(opened.opts.placement, "current")
  end)

  test.it("does not apply multiple File Tree edits through Point of Interest Activation", function(context)
    local root = setup_tree(context)
    filetree.buffer:insert(1, 1, "first.txt\nsecond.txt\n")
    filetree.buffer:set_selection(1, 1)
    core.set_active_view(filetree)
    context.original_open_file = core.open_file
    local opened
    core.open_file = function(path, opts)
      opened = { path = path, opts = opts }
      return {}
    end

    command.perform("core:activate_point_of_interest")
    test.ok(not system.get_file_info(root .. PATHSEP .. "first.txt"))
    test.ok(not system.get_file_info(root .. PATHSEP .. "second.txt"))
    test.equal(opened, nil)
  end)

  test.it("selects a hovered file row with one click and opens it with two", function(context)
    local root = setup_tree(context)
    local entry = test.not_nil(find_entry("root.txt"))
    filetree.position.x, filetree.position.y = 0, 0
    filetree.size.x, filetree.size.y = 800, 600
    filetree.scroll.x, filetree.scroll.y = 0, 0
    filetree.scroll.to.x, filetree.scroll.to.y = 0, 0
    local x, y = filetree:get_line_screen_position(entry.line, 1)
    x = x + math.max(1, filetree:get_font():get_width("r") / 2)
    y = y + filetree:get_line_height() / 2
    local original_line = entry.line == 1 and 2 or 1
    filetree.buffer:set_selection(original_line, 1)

    filetree:on_mouse_moved(x, y, 0, 0)

    test.equal(filetree.buffer:get_selection(true), original_line)
    test.equal(filetree.cursor, "hand")
    test.equal(filetree.hovered_entry_line, entry.line)

    local opened
    local original_open_file = core.open_file
    core.open_file = function(path, opts)
      opened = { path = path, opts = opts }
      return {}
    end
    local ok, err = pcall(function()
      test.ok(filetree:on_mouse_pressed("left", x, y, 1))
      filetree:on_mouse_released("left", x, y)
      test.is_nil(opened)
      local line1, col1, line2, col2 = filetree.buffer:get_selection(true)
      test.same({ line1, col1, line2, col2 }, {
        entry.line, 1, entry.line, #(filetree.buffer.lines[entry.line] or ""),
      })

      test.ok(filetree:on_mouse_pressed("left", x, y, 2))
      filetree:on_mouse_released("left", x, y)
    end)
    core.open_file = original_open_file
    if not ok then error(err, 0) end

    test.ok(common.path_equals(opened.path, root .. PATHSEP .. "root.txt"))
  end)

  test.it("drags the pressed row out of the editor after the pointer moves", function(context)
    local root = setup_tree(context)
    record_drags(context)
    context.original_open_file = core.open_file
    local opened
    core.open_file = function(path) opened = path return {} end

    local x, y = row_point("root.txt")
    test.ok(filetree:on_mouse_pressed("left", x, y, 1))
    filetree:on_mouse_moved(x + 1, y, 1, 0)
    filetree:on_mouse_released("left", x + 1, y)
    test.same(context.drags, {}, "a click with a small move does not drag")

    local paths = test.not_nil(drag_row(context, "folder"))
    test.equal(#paths, 1)
    test.ok(common.path_equals(paths[1], root .. PATHSEP .. "folder"))
    test.equal(filetree.buffer:get_selection(true), find_entry("folder").line)
    test.is_nil(opened)
  end)

  test.it("drags all selected rows when the drag starts on one of them", function(context)
    local root = setup_tree(context)
    record_drags(context)
    local file, folder = find_entry("root.txt"), find_entry("folder")
    local first, last = math.min(file.line, folder.line), math.max(file.line, folder.line)
    filetree.buffer:set_selection(first, 1, last, #filetree.buffer.lines[last])

    local paths = test.not_nil(drag_row(context, "folder"))
    test.equal(#paths, 2)
    local line1, _, line2 = filetree.buffer:get_selection(true)
    test.same({ line1, line2 }, { first, last }, "a drag keeps the selection")

    local x, y = row_point("folder")
    test.ok(filetree:on_mouse_pressed("left", x, y, 1))
    filetree:on_mouse_released("left", x, y)
    line1, _, line2 = filetree.buffer:get_selection(true)
    test.same({ line1, line2 }, { folder.line, folder.line }, "a click on a selected row selects only it")

    local dropped = drag_row(context, "root.txt")
    test.equal(#dropped, 1, "a drag from another row takes only that row")
    test.ok(common.path_equals(dropped[1], root .. PATHSEP .. "root.txt"))
  end)

  test.it("ignores a drop of its own drag", function(context)
    local root = setup_tree(context)
    record_drags(context)
    local paths = test.not_nil(drag_row(context, "folder"))
    local before = #project_paths.entries()

    test.ok(filetree:on_drop({ files = paths, text = "" }))
    test.equal(#project_paths.entries(), before)
    test.ok(common.path_equals(paths[1], root .. PATHSEP .. "folder"))
  end)

  test.it("toggles a folder from a double click", function(context)
    setup_tree(context)
    local entry = test.not_nil(find_entry("folder"))
    filetree.position.x, filetree.position.y = 0, 0
    filetree.size.x, filetree.size.y = 800, 600
    filetree.scroll.x, filetree.scroll.y = 0, 0
    filetree.scroll.to.x, filetree.scroll.to.y = 0, 0
    local x, y = filetree:get_line_screen_position(entry.line, 1)
    x = x + math.max(1, filetree:get_font():get_width("f") / 2)
    y = y + filetree:get_line_height() / 2

    test.ok(filetree:on_mouse_pressed("left", x, y, 2))
    filetree:on_mouse_released("left", x, y)

    test.ok(filetree.line_meta[entry.line].expanded)
    test.not_nil(find_entry("child.txt"))
  end)

  for _, clicks in ipairs { 1, 2 } do
    test.it("keeps the File Tree still after " .. clicks .. " file-row clicks near the viewport edge", function(context)
      local root = setup_tree(context)
      for i = 1, 60 do
        write_file(root .. PATHSEP .. string.format("file-%02d.txt", i), "file")
      end
      filetree:refresh(false, false)
      context.scroll_context_lines = config.scroll_context_lines
      config.scroll_context_lines = 3
      core.set_active_view(filetree)
      filetree.position.x, filetree.position.y = 0, 0
      filetree.size.x, filetree.size.y = 800, 12 * filetree:get_line_height()
      filetree.buffer:set_selection(1, 1)
      filetree:update()
      filetree.scroll.x, filetree.scroll.to.x = 0, 0
      filetree.scroll.y, filetree.scroll.to.y = 0, 0
      local entry = test.not_nil(find_entry("file-08.txt"))
      local x, y = filetree:get_line_screen_position(entry.line, 1)
      x = x + filetree:get_font():get_width("f") / 2
      y = y + filetree:get_line_height() / 2
      local opened
      context.original_open_file = core.open_file
      core.open_file = function(path)
        opened = path
        return {}
      end
      test.ok(filetree:on_mouse_pressed("left", x, y, clicks))
      filetree:update()
      test.equal(filetree.scroll.to.y, 0, "mouse press must not add scroll context")
      filetree:on_mouse_released("left", x, y)
      filetree:update()
      test.equal(filetree.scroll.to.y, 0, "mouse release must not add scroll context")
      test.equal(filetree.buffer:get_selection(true), entry.line)
      if clicks == 2 then
        test.ok(common.path_equals(opened, entry.abs))
      else
        test.is_nil(opened)
      end

      filetree.buffer:set_selection(find_entry("file-50.txt").line, 1)
      filetree:update()
      test.ok(filetree.scroll.to.y > 0, "non-mouse selection must still reveal the file")
    end)
  end
end)
