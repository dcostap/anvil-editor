local test = require "core.test"
local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local StatusBar = require "core.statusbar"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function styled_text_string(item)
  local text = {}
  for _, part in ipairs(item or {}) do
    if type(part) == "string" then text[#text + 1] = part end
  end
  return table.concat(text)
end

test.describe("status bar buffer file item", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "statusbar-project-paths-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.root = join_path(context.temp_root, "app")
    context.external = join_path(context.temp_root, "jdk-src")
    mkdirp(join_path(context.root, "src", "vendor", "library1", "foo"))
    mkdirp(join_path(context.external, "java", "lang"))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_workspace {
      external = {
        { path = "../jdk-src", label = "Java Sources" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
    }
  end)

  test.after_each(function(context)
    project_paths.configure_workspace {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function status_file_text(abs_filename)
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename(abs_filename, abs_filename)
    core.active_view = TextView(buffer)
    local status_bar = StatusBar()
    return styled_text_string(status_bar:get_item("text:file"):get_item())
  end

  test.it("uses Project Path labels like fuzzy file results", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    write_file(external_file)
    write_file(vendored_file)

    test.equal(status_file_text(external_file), "Java Sources" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "String.java")
    test.equal(status_file_text(vendored_file), "library1" .. PATHSEP .. "foo" .. PATHSEP .. "Baz.java")
  end)
end)

test.describe("status bar caret position item", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
    context.original_caret_column_mode = config.caret_column_mode
    config.caret_column_mode = "char"
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    config.caret_column_mode = context.original_caret_column_mode
  end)

  test.it("renders safely when a restored caret is past the current line end", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_selection_list({ 1, 20, 1, 20 }, 1, {
      sanitized = true,
      take_ownership = true,
    })
    core.active_view = TextView(buffer)

    local item = StatusBar():get_item("text:position")
    test.equal(styled_text_string(item:get_item()), "1:1")
  end)

  test.it("renders safely when the active view clears after layout", function()
    core.active_view = TextView(Buffer(nil, nil, true))
    local status_bar = StatusBar()
    status_bar.size.x = 800
    status_bar:update_active_items()

    core.active_view = nil
    local originals = { renderer.draw_text, renderer.draw_rect, core.push_clip_rect, core.pop_clip_rect }
    renderer.draw_text = function(_, _, x) return x end
    renderer.draw_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    local ok, err = pcall(status_bar.draw, status_bar)
    renderer.draw_text, renderer.draw_rect, core.push_clip_rect, core.pop_clip_rect = table.unpack(originals)
    test.ok(ok, err)
  end)
end)

test.describe("status bar placed right of the Sidebar", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
    context.original_draw_text = renderer.draw_text
    context.original_draw_rect = renderer.draw_rect
    context.original_push_clip_rect = core.push_clip_rect
    context.original_pop_clip_rect = core.pop_clip_rect
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    renderer.draw_text = context.original_draw_text
    renderer.draw_rect = context.original_draw_rect
    core.push_clip_rect = context.original_push_clip_rect
    core.pop_clip_rect = context.original_pop_clip_rect
  end)

  test.it("draws the file name beside the caret position, not over the items after it", function(context)
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("src" .. PATHSEP .. "game" .. PATHSEP .. "Type.cpp")
    core.active_view = TextView(buffer)
    local status_bar = StatusBar()
    status_bar.position.x, status_bar.position.y = 240, 600
    status_bar.size.x, status_bar.size.y = 1000, 24
    status_bar:update_active_items()

    local drawn = {}
    renderer.draw_text = function(font, text, x, y, color)
      drawn[#drawn + 1] = { text = tostring(text), x = x, w = font:get_width(tostring(text)) }
      return x + font:get_width(tostring(text))
    end
    renderer.draw_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    status_bar:draw()

    local file, position
    for _, item in ipairs(drawn) do
      if item.text:find("Type.cpp", 1, true) then file = item end
      if item.text == ":" then position = item end
    end
    test.ok(file and position, "the file name and caret position were not drawn")
    test.ok(file.x >= status_bar.position.x, "the file name started left of the Status Bar")
    test.ok(file.x + file.w <= position.x,
      string.format("the file name ended at %d, past the caret position at %d", file.x + file.w, position.x))
  end)
end)

test.describe("status bar pointer right of the Sidebar", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
  end)

  test.it("hovers the item under the pointer", function()
    core.active_view = TextView(Buffer(nil, nil, true))
    local status_bar = StatusBar()
    status_bar.position.x, status_bar.position.y = 240, 600
    status_bar.size.x, status_bar.size.y = 1000, 24
    status_bar:update_active_items()

    local position = status_bar:get_item("text:position")
    local x = status_bar.position.x + position.x + position.w / 2
    status_bar:on_mouse_moved(x, 610, 0, 0)
    test.equal(status_bar.hovered_item, position)
  end)
end)

test.describe("status bar clicks", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
    context.original_last_active_view = core.last_active_view
    context.original_perform = command.perform
    context.performed = {}
    command.perform = function(name, ...)
      context.performed[#context.performed + 1] = name
      return true
    end
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    core.last_active_view = context.original_last_active_view
    command.perform = context.original_perform
  end)

  local function make_status_bar()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("src" .. PATHSEP .. "Type.cpp")
    local view = TextView(buffer)
    core.active_view = view
    core.last_active_view = view
    local status_bar = StatusBar()
    status_bar.position.x, status_bar.position.y = 0, 600
    status_bar.size.x, status_bar.size.y = 1000, 24
    status_bar:update_active_items()
    return status_bar, buffer
  end

  local function click(status_bar, x)
    local y = status_bar.position.y + status_bar.size.y / 2
    status_bar:on_mouse_moved(x, y, 0, 0)
    status_bar:on_mouse_pressed("left", x, y, 1)
    status_bar:on_mouse_released("left", x, y)
  end

  local function item_center(status_bar, name)
    local item = test.not_nil(status_bar:get_item(name))
    return status_bar.position.x + item.x + item.w / 2
  end

  test.it("does not open the log when empty space is clicked during a message", function(context)
    local status_bar = make_status_bar()
    status_bar:show_message("i", style.text, "Saved")
    status_bar:update_active_items()
    click(status_bar, status_bar.position.x + status_bar.size.x / 2)
    test.same(context.performed, {})
  end)

  test.it("opens Go To Line from the caret position", function(context)
    local status_bar = make_status_bar()
    click(status_bar, item_center(status_bar, "text:position"))
    test.same(context.performed, { "editor:go_to_line" })
  end)

  test.it("asks for a line ending instead of toggling it on a click", function(context)
    local status_bar = make_status_bar()
    click(status_bar, item_center(status_bar, "text:line-ending"))
    test.same(context.performed, { "editor:select_line_ending" })
  end)
end)

test.describe("status bar narrow width", function()
  test.before_each(function(context)
    context.original_active_view = core.active_view
    context.originals = { renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect, core.push_clip_rect, core.pop_clip_rect }
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect, core.push_clip_rect, core.pop_clip_rect =
      table.unpack(context.originals)
  end)

  test.it("shortens a long path from the start and keeps the file name", function()
    local dirs = {}
    for i = 1, 30 do dirs[i] = "directory" .. i end
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename(table.concat(dirs, PATHSEP) .. PATHSEP .. "Type.cpp")
    core.active_view = TextView(buffer)
    local status_bar = StatusBar()
    status_bar.position.x, status_bar.position.y = 0, 600
    status_bar.size.x, status_bar.size.y = 500, 24
    status_bar:update_active_items()

    local drawn = {}
    renderer.draw_text = function(font, text, x)
      drawn[#drawn + 1] = tostring(text)
      return x + font:get_width(tostring(text))
    end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
    status_bar:draw()

    local text = table.concat(drawn)
    test.ok(text:find("Type.cpp", 1, true), "the file name was not drawn")
    test.ok(not text:find("directory1" .. PATHSEP, 1, true), "the start of the path was not shortened")
  end)
end)
