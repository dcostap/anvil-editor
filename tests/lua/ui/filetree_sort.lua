local common = require "core.common"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local test = require "core.test"

local function line_without_newline(line)
  line = line or ""
  return line:sub(-1) == "\n" and line:sub(1, -2) or line
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function find_filetree_line(view, wanted)
  for i, line in ipairs(view.doc.lines) do
    if line_without_newline(line) == wanted then return i end
  end
end

local function assert_filetree_lines(view, expected)
  test.equal(#view.doc.lines, #expected)
  for i, wanted in ipairs(expected) do
    test.equal(line_without_newline(view.doc.lines[i]), wanted)
  end
end

local function patch_modified_times(context, overrides)
  context.original_get_file_info = context.original_get_file_info or system.get_file_info
  system.get_file_info = function(path)
    local info, err = context.original_get_file_info(path)
    if not info then return info, err end

    local modified = overrides[common.normalize_path(path)]
    if modified then
      local copy = {}
      for key, value in pairs(info) do copy[key] = value end
      copy.modified = modified
      return copy
    end
    return info, err
  end
end

local function setup_tree(context)
  local temp_root = core.root_project().path
    .. PATHSEP .. "filetree-sort-tests-"
    .. system.get_process_id() .. "-"
    .. math.floor(system.get_time() * 1000000)
  test.ok(common.mkdirp(temp_root))
  context.temp_root = temp_root

  local paths = {
    old_dir = temp_root .. PATHSEP .. "aaa-old-dir",
    new_dir = temp_root .. PATHSEP .. "zzz-new-dir",
    old_file = temp_root .. PATHSEP .. "aaa-old.txt",
    new_file = temp_root .. PATHSEP .. "zzz-new.txt",
  }
  paths.child_file = paths.old_dir .. PATHSEP .. "child.txt"
  paths.other_file = paths.old_dir .. PATHSEP .. "other.txt"
  test.ok(common.mkdirp(paths.old_dir))
  test.ok(common.mkdirp(paths.new_dir))
  write_file(paths.child_file, "child")
  write_file(paths.other_file, "other")
  write_file(paths.old_file, "old")
  write_file(paths.new_file, "new")

  local overrides = {}
  overrides[common.normalize_path(paths.old_dir)] = 10
  overrides[common.normalize_path(paths.new_dir)] = 20
  overrides[common.normalize_path(paths.child_file)] = 50
  overrides[common.normalize_path(paths.other_file)] = 60
  overrides[common.normalize_path(paths.old_file)] = 30
  overrides[common.normalize_path(paths.new_file)] = 40
  patch_modified_times(context, overrides)

  local filetree = require "plugins.filetree"
  context.filetree = filetree
  context.previous_dir = filetree.current_dir
  context.previous_sort_mode = filetree:get_sort_mode()

  filetree.current_dir = temp_root
  filetree:refresh(false, false)
  filetree:set_sort_mode("name")
  filetree:refresh(false, false)
  return filetree, paths
end

test.describe("File Tree Sorting", function()
  test.after_each(function(context)
    if context.original_get_file_info then
      system.get_file_info = context.original_get_file_info
    end
    if context.filetree then
      context.filetree.current_dir = context.previous_dir or context.filetree.current_dir
      context.filetree:refresh(false, false)
      if context.previous_sort_mode then
        context.filetree:set_sort_mode(context.previous_sort_mode)
      end
      context.filetree:refresh(false, false)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("sorts by name or newest modified time while keeping folders before files", function(context)
    local filetree = setup_tree(context)

    assert_filetree_lines(filetree, {
      "aaa-old-dir/",
      "zzz-new-dir/",
      "aaa-old.txt",
      "zzz-new.txt",
    })

    test.ok(command.perform("filetree:sort-by-date-modified"))
    test.equal(filetree:get_sort_mode(), "modified")
    assert_filetree_lines(filetree, {
      "zzz-new-dir/",
      "aaa-old-dir/",
      "zzz-new.txt",
      "aaa-old.txt",
    })

    test.ok(command.perform("filetree:sort-by-name"))
    test.equal(filetree:get_sort_mode(), "name")
    assert_filetree_lines(filetree, {
      "aaa-old-dir/",
      "zzz-new-dir/",
      "aaa-old.txt",
      "zzz-new.txt",
    })
  end)

  test.it("preserves expanded folders and the selected entry when changing sort mode", function(context)
    local filetree = setup_tree(context)

    local old_dir_line = find_filetree_line(filetree, "aaa-old-dir/")
    test.not_nil(old_dir_line, "expected old directory row before expanding")
    local old_dir_entry = filetree:entry_for_line(old_dir_line)
    test.not_nil(old_dir_entry, "expected old directory entry before expanding")
    filetree:expand_folder(old_dir_line, old_dir_entry, false)

    local selected_line = find_filetree_line(filetree, "aaa-old.txt")
    test.not_nil(selected_line, "expected old file row before sorting")
    filetree:with_selection_state(function()
      filetree.doc:set_selection(selected_line, 2)
    end)

    test.ok(command.perform("filetree:sort-by-date-modified"))

    local moved_old_dir_line = find_filetree_line(filetree, "aaa-old-dir/")
    test.not_nil(moved_old_dir_line, "expected old directory row after sorting")
    test.equal(line_without_newline(filetree.doc.lines[moved_old_dir_line + 1]), "\tother.txt")
    test.equal(line_without_newline(filetree.doc.lines[moved_old_dir_line + 2]), "\tchild.txt")

    local moved_selected_line = find_filetree_line(filetree, "aaa-old.txt")
    test.not_nil(moved_selected_line, "expected selected file row after sorting")
    local line, col = filetree.doc:get_selection()
    test.equal(line, moved_selected_line)
    test.equal(col, 2)
  end)

  test.it("draws a subtle row background only for folder entries", function(context)
    local filetree = setup_tree(context)
    local folder_line = find_filetree_line(filetree, "aaa-old-dir/")
    local file_line = find_filetree_line(filetree, "aaa-old.txt")
    test.not_nil(folder_line, "expected folder row in File Tree")
    test.not_nil(file_line, "expected file row in File Tree")

    filetree.position.x = 100
    filetree.position.y = 50
    filetree.size.x = 500
    filetree.size.y = 300
    filetree.scroll.x = 0
    filetree.scroll.y = 0

    local folder_background = config.plugins.filetree.folder_row_background
    test.equal(folder_background[4], 12.75)
    local background_rects = {}
    local original_draw_rect = renderer.draw_rect
    local original_draw_text = renderer.draw_text
    local original_draw_line_hint = filetree.draw_line_hint

    local ok, err = pcall(function()
      renderer.draw_rect = function(x, y, w, h, color)
        if color == folder_background then
          background_rects[#background_rects + 1] = { x = x, y = y, w = w, h = h }
        end
      end
      renderer.draw_text = function(font, text, x, y, color, opts)
        return x + font:get_width(text or "", opts)
      end
      filetree.draw_line_hint = function() end

      local x, y = filetree:get_line_screen_position(folder_line)
      filetree:draw_line_gutter(folder_line, filetree.position.x, y, filetree:get_gutter_width())
      filetree:draw_line_body(folder_line, x, y)

      x, y = filetree:get_line_screen_position(file_line)
      filetree:draw_line_gutter(file_line, filetree.position.x, y, filetree:get_gutter_width())
      filetree:draw_line_body(file_line, x, y)
    end)

    renderer.draw_rect = original_draw_rect
    renderer.draw_text = original_draw_text
    filetree.draw_line_hint = original_draw_line_hint
    if not ok then error(err, 0) end

    test.equal(#background_rects, 2)
    test.equal(background_rects[1].x, filetree.position.x)
    test.equal(background_rects[2].x, filetree.position.x + filetree:get_gutter_width())
  end)

  test.it("blocks sort changes while File Tree has unapplied text edits", function(context)
    local filetree = setup_tree(context)

    filetree:with_selection_state(function()
      filetree.doc:insert(1, 1, "renamed-")
    end)
    test.equal(line_without_newline(filetree.doc.lines[1]), "renamed-aaa-old-dir/")
    test.ok(filetree.has_possible_edits, "expected edited File Tree to track unapplied edits")

    test.ok(command.perform("filetree:sort-by-date-modified"))

    test.equal(filetree:get_sort_mode(), "name")
    test.equal(line_without_newline(filetree.doc.lines[1]), "renamed-aaa-old-dir/")
  end)
end)
