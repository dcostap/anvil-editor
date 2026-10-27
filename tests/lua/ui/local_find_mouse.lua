local common = require "core.common"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local panes = require "core.panes"
local test = require "core.test"
local diffview = require "plugins.diffview"
local filetree = require "plugins.filetree"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local footnotes = require "core.markdown.footnotes"
local workers = require "core.worker_pool"

require "plugins.intellij_find"

local function focus_find(host, surface)
  local x, y = surface:get_line_screen_position(1, 1)
  host:on_mouse_pressed("left", x + 1, y + 1, 1)
  host:on_mouse_released("left", x + 1, y + 1)
  test.equal(core.active_view, surface)
  test.ok(command.perform("editor:find"))
  local input = core.active_view
  test.ok(input.local_find_input)
  input:set_text("")
  surface.scroll.x, surface.scroll.to.x = 0, 0
  surface.scroll.y, surface.scroll.to.y = 0, 0
  surface:update()
  core.set_active_view(surface)
  return input, input.position.x + input.size.x / 2, input.position.y + input.size.y / 2
end

local function click_find(host, surface, input, x, y)
  local before = table.concat(surface.buffer.lines)
  -- A double click must not activate the content below Find.
  host:on_mouse_pressed("left", x, y, 2)
  host:on_mouse_released("left", x, y)
  test.equal(core.active_view, input, "the visible Find input must receive the click")
  core.root_panel:on_text_input("query")
  test.equal(input:get_text(), "query")
  test.equal(table.concat(surface.buffer.lines), before, "Find input must not edit the underlying Buffer")
end

test.describe("Local Find mouse routing", function()
  test.before_each(function(context)
    context.layout = config.plugins.diffview.layout
    context.live = config.markdown_live_editor
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    command.perform("editor:find_close")
    panes.reset_for_tests()
    config.plugins.diffview.layout = context.layout
    config.markdown_live_editor = context.live
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)

  test.it("focuses Find in Markdown Live Preview with a margin note", function()
    config.markdown_live_editor = true
    local buffer = core.open_buffer()
    buffer:set_filename("find-mouse.md", nil)
    buffer:text_input("Text^[A margin note.]\n\nMore text.\n")
    local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
    markdown.live_render.refresh_view(view)
    local model = test.not_nil(markdown_model.peek(buffer))
    local deadline = system.get_time() + 15
    while model.status ~= "ready" do
      local pool = workers.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      test.ok(system.get_time() < deadline, "Markdown did not finish parsing")
      coroutine.yield(0.01)
    end
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1400, 600
    local input, x, y = focus_find(view, view)
    local notes = test.not_nil(footnotes.layout(view))
    test.equal(notes.mode, "margin")
    test.equal(#notes.cards, 1)
    local window = renwindow.create("find-mouse-test", 1400, 600)
    renderer.begin_frame(window)
    local ok, err = pcall(view.draw, view)
    renderer.end_frame()
    test.ok(ok, err)

    click_find(view, view, input, x, y)
    buffer:clean()
  end)

  test.it("focuses Find instead of activating the File Tree entry underneath", function(context)
    context.root = USERDIR .. PATHSEP .. "find-mouse-tree"
    test.ok(common.mkdirp(context.root))
    for i = 1, 8 do
      local path = context.root .. PATHSEP .. string.rep("long-name-", 15) .. i .. ".txt"
      local file = assert(io.open(path, "wb"))
      file:write("content\n")
      file:close()
    end
    local view = assert(filetree.open(context.root, { placement = "new", focus = true }))
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 520, 400
    local input, x, y = focus_find(view, view)
    test.not_nil(view:entry_row_at_point(x, y), "the Find card must cover a clickable entry")

    click_find(view, view, input, x, y)
    test.equal(panes.active().current_view, view, "a Find click must not open a file")
  end)

  for _, layout in ipairs { "unified", "side-by-side" } do
    local sides = layout == "unified" and { "unified" } or { "left", "right" }
    for _, side in ipairs(sides) do
      test.it("focuses Find above the " .. side .. " Diff surface", function()
        config.plugins.diffview.layout = layout
        local view = diffview.open({
          contents = {
            diffview.content.text((string.rep("removed ", 30) .. "\n"):rep(12)),
            diffview.content.text((string.rep("added ", 30) .. "\n"):rep(12)),
          },
          auto_reveal_first_change = false,
        }, true)
        panes.place(function() return view end, { placement = "new", focus = true })
        local deadline = system.get_time() + 15
        while view.updater_idx do
          test.ok(system.get_time() < deadline, "comparison did not finish")
          coroutine.yield(0.01)
        end
        view.position.x, view.position.y = 0, 0
        view.size.x, view.size.y = 1200, 600
        view:update()
        local surface = side == "unified" and view.unified_view
          or side == "left" and view.buffer_view_a or view.buffer_view_b
        local input, x, y = focus_find(view, surface)
        if side == "unified" then
          test.ok(surface:resolve_unified_position(x, y).other,
            "the Find card must cover a removed line")
        end

        click_find(view, surface, input, x, y)
      end)
    end
  end
end)
