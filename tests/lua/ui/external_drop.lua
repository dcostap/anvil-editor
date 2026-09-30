local core = require "core"
local panes = require "core.panes"
local RootPanel = require "core.rootpanel"
local TitleBar = require "core.titlebar"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local test = require "core.test"

test.describe("External Title Bar drops", function()
  local saved, root, title, path, original

  test.before_each(function()
    panes.reset_for_tests()
    saved = {
      root_panel = core.root_panel, title_bar = core.title_bar,
      set_active_view = core.set_active_view, active_view = core.active_view,
    }
    core.set_active_view = function(view) core.active_view = view end
    root, title = RootPanel(), TitleBar()
    core.root_panel, core.title_bar = root, title
    root.size.x, root.size.y = 900, 600
    local original_path = core.temp_filename(".txt")
    original = assert(panes.create { factory = function()
      return Editor(Buffer(original_path, original_path, true))
    end })
    original.current_view.buffer:insert(1, 1, "Keep my work")
    root:update()
    path = core.temp_filename(".txt")
    local file = assert(io.open(path, "wb"))
    file:write("Dropped file\n")
    file:close()
    file = assert(io.open(path .. ".second.txt", "wb"))
    file:write("Second file\n")
    file:close()
  end)

  test.after_each(function()
    panes.reset_for_tests()
    os.remove(path)
    os.remove(path .. ".second.txt")
    os.remove(path .. ".png")
    core.root_panel, core.title_bar = saved.root_panel, saved.title_bar
    core.set_active_view, core.active_view = saved.set_active_view, saved.active_view
  end)

  test.it("opens a file over an existing Tab in a separate Pane", function()
    local rect = title.entries[1]
    core.on_event("filedropped", path, rect.x + rect.w / 2, rect.y + rect.h / 2)
    test.equal(panes.count(), 2)
    test.equal(original.current_view.buffer:get_text(1, 1, 1, math.huge), "Keep my work")
    test.not_equal(panes.active().group, original.group)
    test.equal(panes.active().current_view.buffer.abs_filename, system.absolute_path(path))
  end)

  test.it("opens each distinct path from one drop in a separate Pane", function()
    core.on_event("dropbegin")
    core.on_event("dropmoved", 10, title.size.y / 2)
    core.on_event("filedropped", path, 10, title.size.y / 2)
    core.on_event("filedropped", path .. ".second.txt", 10, title.size.y / 2)
    core.on_event("filedropped", path, 10, title.size.y / 2)
    test.equal(panes.count(), 1, "Do not open a partial drop")
    core.on_event("dropcomplete")
    test.equal(panes.count(), 3, "Ignore duplicate paths in one drop")
    local ordered = panes.ordered()
    test.equal(ordered[2].current_view.buffer.abs_filename, system.absolute_path(path))
    test.equal(ordered[3].current_view.buffer.abs_filename, system.absolute_path(path .. ".second.txt"))
    test.not_equal(ordered[2].group, ordered[3].group)
    test.equal(panes.history_length(original), 1)
  end)

  test.it("shows a new-Pane target without changing focus and clears it on leave", function()
    core.on_event("dropbegin")
    core.on_event("dropmoved", 10, title.size.y / 2)
    test.equal(root:get_external_drop_target().kind, "new")
    test.equal(panes.active(), original)
    core.on_event("dropcomplete")
    test.is_nil(root:get_external_drop_target())
    test.equal(panes.count(), 1)
  end)

  test.it("does not open files dropped on window controls", function()
    local close = title.caption_rects[3]
    core.on_event("dropbegin")
    core.on_event("dropmoved", close.x + close.w / 2, close.h / 2)
    test.is_nil(root:get_external_drop_target())
    core.on_event("filedropped", path, close.x + close.w / 2, close.h / 2)
    core.on_event("dropcomplete")
    test.equal(panes.count(), 1)
  end)

  test.it("opens dropped text in one Untitled Editor with blank lines intact", function()
    core.on_event("dropbegin")
    core.on_event("dropmoved", 10, title.size.y / 2)
    core.on_event("textdropped", "first\r\n\r\nλ last\r\n", 10, title.size.y / 2)
    core.on_event("dropcomplete")
    test.equal(panes.count(), 2)
    local buffer = panes.active().current_view.buffer
    test.is_nil(buffer.filename)
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "first\n\nλ last\n")
  end)

  test.it("opens a folder in a new File Tree without adding a Project", function()
    local folder = path:match("^(.*)[/\\]")
    local project_count = #core.projects
    core.on_event("filedropped", folder, 10, title.size.y / 2)
    test.equal(panes.count(), 2)
    test.equal(#core.projects, project_count)
    local filetree = require "plugins.filetree"
    test.ok(panes.active().current_view:is(filetree.View))
  end)

  test.it("does not create an empty Editor for a missing file", function()
    core.on_event("filedropped", path .. ".missing", 10, title.size.y / 2)
    test.equal(panes.count(), 1)
  end)

  test.it("opens an image in a separate Image View", function()
    local image_path = path .. ".png"
    test.ok(canvas.new(8, 8, { 40, 100, 180, 255 }, true):save_image(image_path))
    core.on_event("filedropped", image_path, 10, title.size.y / 2)
    test.equal(panes.count(), 2)
    test.ok(panes.active().current_view:is(require "core.imageview"))
    test.equal(panes.history_length(original), 1)
  end)

  test.it("keeps work-area file drops in their destination Pane", function()
    local x, y = original.position.x + 20, original.position.y + 20
    core.on_event("dropbegin")
    core.on_event("dropmoved", x, y)
    test.equal(root:get_external_drop_target().pane, original)
    core.on_event("filedropped", path, x, y)
    core.on_event("dropcomplete")
    test.equal(panes.count(), 1)
    test.equal(original.current_view.buffer.abs_filename, system.absolute_path(path))
  end)

  test.it("accepts a Title Bar drop when no Panes are open", function()
    panes.reset_for_tests()
    title:update()
    core.on_event("dropbegin")
    core.on_event("filedropped", path, 10, title.size.y / 2)
    core.on_event("dropcomplete")
    test.equal(panes.count(), 1)
    test.equal(panes.active().current_view.buffer.abs_filename, system.absolute_path(path))
  end)

  test.it("accepts a work-area drop when no Panes are open", function()
    panes.reset_for_tests()
    root:update()
    core.on_event("dropbegin")
    core.on_event("filedropped", path, 100, title.size.y + 100)
    core.on_event("dropcomplete")
    test.equal(panes.count(), 1)
    test.equal(panes.active().current_view.buffer.abs_filename, system.absolute_path(path))
  end)

  test.it("blocks drop feedback and opening while a Modal Input Owner is present", function()
    local owner = {}
    root:push_modal_input(owner)
    core.on_event("dropbegin")
    core.on_event("dropmoved", 10, title.size.y / 2)
    test.is_nil(root:get_external_drop_target())
    core.on_event("filedropped", path, 10, title.size.y / 2)
    core.on_event("dropcomplete")
    test.equal(panes.count(), 1)
    root:pop_modal_input(owner)
  end)
end)
