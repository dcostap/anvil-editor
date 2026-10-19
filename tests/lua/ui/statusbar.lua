local test = require "core.test"
local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local StatusBar = require "core.statusbar"
local RootPanel = require "core.rootpanel"
local panes = require "core.panes"
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

local function styled_text_string(styled)
  local text = {}
  for _, part in ipairs(styled or {}) do
    if type(part) == "string" then text[#text + 1] = part end
  end
  return table.concat(text)
end

-- The Buffer is clean, so autosave leaves it alone when its Pane loses focus.
local function named_view(filename)
  local buffer = Buffer(nil, nil, false)
  if filename then buffer:set_filename(filename) end
  return TextView(buffer)
end

test.describe("status bar buffer file item", function()
  test.before_each(function(context)
    context.original_projects = core.projects
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
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function status_file_text(abs_filename)
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename(abs_filename, abs_filename)
    local item = StatusBar():get_item("text:file")
    return styled_text_string(item:get_item(TextView(buffer)))
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
    context.original_caret_column_mode = config.caret_column_mode
    config.caret_column_mode = "char"
  end)

  test.after_each(function(context)
    config.caret_column_mode = context.original_caret_column_mode
  end)

  test.it("renders safely when a restored caret is past the current line end", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_selection_list({ 1, 20, 1, 20 }, 1, {
      sanitized = true,
      take_ownership = true,
    })
    local item = StatusBar():get_item("text:position")
    test.equal(styled_text_string(item:get_item(TextView(buffer))), "1:1")
  end)
end)

test.describe("Pane Status Bars", function()
  local saved, root

  test.before_each(function(context)
    panes.reset_for_tests()
    saved = {
      root_panel = core.root_panel,
      status_bar = core.status_bar,
      active_view = core.active_view,
      last_active_view = core.last_active_view,
      perform = command.perform,
      draw_text = renderer.draw_text,
      draw_rect = renderer.draw_rect,
      draw_rounded_rect = renderer.draw_rounded_rect,
      push_clip_rect = core.push_clip_rect,
      pop_clip_rect = core.pop_clip_rect,
      get_time = system.get_time,
    }
    core.status_bar = StatusBar()
    root = RootPanel()
    root.position.x, root.position.y = 0, 0
    root.size.x, root.size.y = 1000, 600
    core.root_panel = root
    context.performed = {}
    command.perform = function(name)
      context.performed[#context.performed + 1] = { name = name, view = core.active_view }
      return true
    end
    context.drawn = {}
    renderer.draw_text = function(font, text, x)
      context.drawn[#context.drawn + 1] = tostring(text)
      return x + font:get_width(tostring(text))
    end
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    core.push_clip_rect = function() end
    core.pop_clip_rect = function() end
  end)

  test.after_each(function()
    panes.reset_for_tests()
    command.perform = saved.perform
    renderer.draw_text = saved.draw_text
    renderer.draw_rect = saved.draw_rect
    renderer.draw_rounded_rect = saved.draw_rounded_rect
    core.push_clip_rect = saved.push_clip_rect
    core.pop_clip_rect = saved.pop_clip_rect
    system.get_time = saved.get_time
    core.root_panel = saved.root_panel
    core.status_bar = saved.status_bar
    core.active_view = saved.active_view
    core.last_active_view = saved.last_active_view
  end)

  local function two_panes()
    local left = panes.create { factory = function() return named_view("left.lua") end }
    local right = panes.split(left, "right", { factory = function() return named_view("right.lua") end })
    root:update()
    return left, right
  end

  local function bar_of(pane)
    return core.status_bar:bar_for_pane(pane)
  end

  local function entry_center(pane, name)
    local bar = bar_of(pane)
    local entry = test.not_nil(bar:get_entry(name))
    return bar.position.x + entry.x + entry.w / 2, bar.position.y + bar.size.y / 2
  end

  local function click(x, y)
    root:on_mouse_moved(x, y, 0, 0)
    root:on_mouse_pressed("left", x, y, 1)
    root:on_mouse_released("left", x, y)
  end

  test.it("docks a bar to the bottom of each Pane showing that Pane's file", function()
    local left, right = two_panes()
    for _, pane in ipairs { left, right } do
      local bar = bar_of(pane)
      test.ok(bar.size.y > 0, "the Pane has no Status Bar")
      test.equal(bar.position.x, pane.position.x)
      test.equal(bar.size.x, pane.size.x)
      test.equal(bar.position.y + bar.size.y, pane.position.y + pane.size.y)
      test.equal(pane.current_view.position.y + pane.current_view.size.y, bar.position.y)
    end
    test.equal(styled_text_string(bar_of(left):get_entry("text:file").styled), "left.lua")
    test.equal(styled_text_string(bar_of(right):get_entry("text:file").styled), "right.lua")
  end)

  test.it("fades every item of the unfocused Panes' bars", function()
    local left, right = two_panes()
    local function text_alphas(pane)
      local alphas = {}
      renderer.draw_text = function(font, text, x, _, color)
        alphas[tostring(text)] = color[4] or 255
        return x + font:get_width(tostring(text))
      end
      bar_of(pane):draw()
      return alphas
    end
    local focused, unfocused = text_alphas(right), text_alphas(left)
    test.ok(unfocused["left.lua"] < focused["right.lua"], "the unfocused file name was not faded")
    panes.focus(left)
    root:update()
    focused, unfocused = text_alphas(left), text_alphas(right)
    test.ok(unfocused["right.lua"] < focused["left.lua"], "focus did not move the fade")
  end)

  test.it("shows only the file in the bars of unfocused Panes", function()
    local left, right = two_panes()
    local function names(pane)
      local result = {}
      for _, entry in ipairs(bar_of(pane).entries) do result[#result + 1] = entry.item.name end
      return table.concat(result, " ")
    end
    test.equal(names(left), "text:file")
    test.ok(bar_of(right):get_entry("text:position"), "the focused Pane lost its caret position")
    panes.focus(left)
    root:update()
    test.equal(names(right), "text:file")
    test.ok(bar_of(left):get_entry("text:position"), "the newly focused Pane shows no caret position")
  end)

  test.it("focuses the Pane when its bar is clicked", function()
    local left, right = two_panes()
    test.equal(panes.active(), right)
    click(entry_center(left, "text:file"))
    test.equal(panes.active(), left)
  end)

  test.it("keeps focus in the Pane's editor when its item is clicked", function(context)
    local _, right = two_panes()
    core.last_active_view = named_view("other.lua")
    click(entry_center(right, "text:position"))
    test.equal(core.active_view, right.current_view)
    test.equal(context.performed[1].name, "editor:go_to_line")
  end)

  test.it("shows a message only in the focused Pane's bar", function(context)
    local left, right = two_panes()
    core.status_bar:show_message("i", style.text, "Saved the file")
    root:update()
    context.drawn = {}
    bar_of(left):draw()
    test.ok(not table.concat(context.drawn):find("Saved the file", 1, true), "the unfocused bar showed the message")
    context.drawn = {}
    bar_of(right):draw()
    test.ok(table.concat(context.drawn):find("Saved the file", 1, true), "the focused bar did not show the message")
  end)

  test.it("does not open the log when empty space is clicked during a message", function(context)
    local _, right = two_panes()
    core.status_bar:show_message("i", style.text, "Saved")
    root:update()
    local bar = bar_of(right)
    local message_end = bar.position.x + bar.message_entry.x + bar.message_entry.w
    local first_right = bar:get_entry("text:position")
    local x = (message_end + bar.position.x + first_right.x) / 2
    click(x, bar.position.y + bar.size.y / 2)
    test.same(context.performed, {})
  end)

  test.it("asks for a line ending instead of toggling it on a click", function(context)
    local _, right = two_panes()
    click(entry_center(right, "text:line-ending"))
    test.equal(#context.performed, 1)
    test.equal(context.performed[1].name, "editor:select_line_ending")
  end)

  test.it("keeps the tooltip of the right-most item inside the window", function()
    local _, right = two_panes()
    local x, y = entry_center(right, "text:line-ending")
    root:on_mouse_moved(x, y, 0, 0)
    local bar = bar_of(right)
    bar.hover_start = system.get_time() - 10
    local boxes, texts = {}, {}
    renderer.draw_rounded_rect = function(rx, ry, rw, rh) boxes[#boxes + 1] = { x = rx, w = rw } end
    renderer.draw_text = function(font, text, tx)
      texts[#texts + 1] = { x = tx, w = font:get_width(tostring(text)) }
      return tx + font:get_width(tostring(text))
    end
    root.deferred_draws = {}
    bar:draw()
    boxes, texts = {}, {}
    while #root.deferred_draws > 0 do
      local item = table.remove(root.deferred_draws)
      item.fn(table.unpack(item, 1, #item))
    end
    test.ok(#boxes > 0, "no tooltip was drawn")
    local right_edge = root.position.x + root.size.x
    for _, box in ipairs(boxes) do
      test.ok(box.x + box.w <= right_edge, string.format("tooltip box ends at %d, past %d", box.x + box.w, right_edge))
    end
    for _, text in ipairs(texts) do
      test.ok(text.x + text.w <= right_edge, string.format("tooltip text ends at %d, past %d", text.x + text.w, right_edge))
    end
  end)

  test.it("clears file hover and its tooltip until the pointer returns from the Project Sidebar", function(context)
    local _, right = two_panes()
    local filename = join_path(USERDIR, "hover.lua")
    right.current_view.buffer:set_filename(filename, filename)
    root:update()
    local bar = bar_of(right)
    local x, y = entry_center(right, "text:file")
    local now = system.get_time()
    system.get_time = function() return now end

    local function shows_path_tooltip()
      context.drawn = {}
      root.deferred_draws = {}
      bar:draw()
      while #root.deferred_draws > 0 do
        local item = table.remove(root.deferred_draws)
        item.fn(table.unpack(item, 1, #item))
      end
      return table.concat(context.drawn):find("Click to copy the full path", 1, true) ~= nil
    end

    root:on_mouse_moved(x, y, 0, 0)
    now = now + 10
    test.ok(shows_path_tooltip(), "the file tooltip did not appear")
    test.equal(bar.cursor, "hand")

    -- The shell sends mouseleft when the pointer enters the Project Sidebar.
    root:on_mouse_left()
    for _ = 1, 3 do root:update() end
    now = now + 10
    test.ok(not shows_path_tooltip(), "the file tooltip returned after mouse exit")
    test.equal(bar.cursor, "arrow")

    root:on_mouse_moved(x, y, 0, 0)
    root:update()
    now = now + 10
    test.ok(shows_path_tooltip(), "the file tooltip did not return on mouse entry")
    test.equal(bar.cursor, "hand")
  end)

  test.it("shortens a long path from the start and keeps the file name", function(context)
    local dirs = {}
    for i = 1, 30 do dirs[i] = "directory" .. i end
    local filename = table.concat(dirs, PATHSEP) .. PATHSEP .. "Type.cpp"
    local pane = panes.create { factory = function() return named_view(filename) end }
    root.size.x = 500
    root:update()
    context.drawn = {}
    bar_of(pane):draw()

    local text = table.concat(context.drawn)
    test.ok(text:find("Type.cpp", 1, true), "the file name was not drawn")
    test.ok(not text:find("directory1" .. PATHSEP, 1, true), "the start of the path was not shortened")
  end)
end)
