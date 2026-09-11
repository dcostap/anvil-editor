local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Editor = require "core.editor"
local Project = require "core.project"
local markdown = require "core.markdown"
local preview = require "core.poi_preview"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

test.describe("Markdown link hover previews", function()
  test.before_each(function(c)
    c.projects, c.active_view = core.projects, core.active_view
    c.root = USERDIR .. PATHSEP .. "hover-preview-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(c.root))
    write_file(c.root .. PATHSEP .. "Source.md", "[[Target]]\n\nFollowing paragraph\n")
    write_file(c.root .. PATHSEP .. "Target.md", "# Target\n\n**Rendered body**\n")
    core.projects = { Project(c.root) }
    c.index = markdown.vault_index.get_index(c.root):rebuild("hover-preview-test")
    c.buffer = core.open_buffer(c.root .. PATHSEP .. "Source.md")
    c.view = Editor(c.buffer)
    c.view.size.x, c.view.size.y = 800, 600
    c.view:set_selection_state({ selections = { 3, 1, 3, 1 }, last_selection = 1 })
    markdown.live_render.refresh_view(c.view)
    local deadline = system.get_time() + 5
    repeat
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      local render = c.view:get_line_render(1)
      for _, fragment in ipairs(c.view:iter_line_render_fragments(render)) do
        if fragment.link and fragment.link_resolution.status == "resolved" then c.link_ready = true end
      end
      if c.link_ready then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.ok(c.index:can_resolve())
    test.ok(c.link_ready)
    core.active_view = c.view
    c.view:update()
    c.clock = system.get_time
    c.window_focus = system.window_has_focus
    system.window_has_focus = function() return true end
    c.now = c.clock()
    system.get_time = function() return c.now end
    c.x, c.y = c.view:get_line_screen_position(1, 3)
    c.x, c.y = c.x + 2, c.y + c.view:get_line_height() / 2
  end)

  test.after_each(function(c)
    if c.clock then system.get_time = c.clock end
    if c.window_focus then system.window_has_focus = c.window_focus end
    c.view:on_mouse_left()
    preview.dismiss(c.view)
    c.view:on_close()
    core.buffer_registry:remove(c.buffer, true)
    core.active_view, core.projects = c.active_view, c.projects
    common.rm(c.root, true)
  end)

  test.it("shows a delayed card without moving the text or focus", function(c)
    local _, before_y = c.view:get_line_screen_position(3)
    local rows = c.view:get_total_visual_lines()
    local selection = c.view:get_selection_state()
    local hit = test.not_nil(c.view:get_render_fragment_at_position(c.x, c.y))
    test.not_nil(hit.fragment.link)
    test.equal(hit.fragment.link_resolution.status, "resolved")
    c.view:on_mouse_moved(c.x, c.y, 0, 0)
    test.equal(preview.for_view(c.view), nil)
    c.now = c.now + config.markdown_link_hover_delay / 2
    c.view:update()
    test.equal(preview.for_view(c.view), nil)
    c.now = c.now + config.markdown_link_hover_delay
    c.view:update()
    test.not_nil(preview.for_view(c.view), "hover should show the target note")
    test.equal(c.view:get_total_visual_lines(), rows)
    test.equal(select(2, c.view:get_line_screen_position(3)), before_y)
    test.same(c.view:get_selection_state(), selection)
    test.equal(core.active_view, c.view)
    c.view:on_mouse_left()
    test.equal(preview.for_view(c.view), nil)
  end)

  test.it("requires a new hover delay after the pointer leaves the link", function(c)
    c.view:on_mouse_moved(c.x, c.y, 0, 0)
    c.now = c.now + config.markdown_link_hover_delay * 0.75
    c.view:on_mouse_left()
    c.view:on_mouse_moved(c.x, c.y, 0, 0)
    c.now = c.now + config.markdown_link_hover_delay / 2
    c.view:update()
    test.equal(preview.for_view(c.view), nil)
    c.now = c.now + config.markdown_link_hover_delay
    c.view:update()
    test.not_nil(preview.for_view(c.view))
    c.view:on_mouse_wheel(-1, 0)
    test.equal(preview.for_view(c.view), nil)
  end)

  test.it("keeps a keyboard preview when a pending hover expires", function(c)
    c.view:on_mouse_moved(c.x, c.y, 0, 0)
    preview.location(c.view, { line = 1, path = c.root .. PATHSEP .. "Target.md" })
    local inline = preview.for_view(c.view)
    c.now = c.now + config.markdown_link_hover_delay * 2
    c.view:update()
    test.equal(preview.for_view(c.view), inline)
    c.view:on_mouse_left()
    test.equal(preview.for_view(c.view), inline)
  end)
end)
