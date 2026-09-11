local core = require "core"
local common = require "core.common"
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

test.describe("Markdown link previews", function()
  test.before_each(function(c)
    c.projects, c.active_view = core.projects, core.active_view
    c.root = USERDIR .. PATHSEP .. "link-preview-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(c.root))
    write_file(c.root .. PATHSEP .. "Source.md", "[[Target]]\n\nFollowing paragraph\n")
    write_file(c.root .. PATHSEP .. "Target.md", "# Target\n\n**Rendered body**\n")
    core.projects = { Project(c.root) }
    c.index = markdown.vault_index.get_index(c.root):rebuild("link-preview-test")
    c.buffer = core.open_buffer(c.root .. PATHSEP .. "Source.md")
    c.view = Editor(c.buffer)
    c.view.size.x, c.view.size.y = 800, 600
    c.view:set_selection_state({ selections = { 3, 1, 3, 1 }, last_selection = 1 })
    markdown.live_render.refresh_view(c.view)
    local deadline = system.get_time() + 5
    repeat
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      for _, fragment in ipairs(c.view:iter_line_render_fragments(c.view:get_line_render(1))) do
        if fragment.link and fragment.link_resolution.status == "resolved" then c.link_ready = true end
      end
      if c.link_ready then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.ok(c.link_ready)
    core.active_view = c.view
    c.view:update()
    c.clock, c.window_focus = system.get_time, system.window_has_focus
    c.now = c.clock()
    system.get_time = function() return c.now end
    system.window_has_focus = function() return true end
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

  test.it("previews a link through POI navigation, not mouse hover", function(c)
    local x, y = c.view:get_line_screen_position(1, 3)
    x, y = x + 2, y + c.view:get_line_height() / 2
    test.not_nil(c.view:get_render_fragment_at_position(x, y).fragment.link)
    local selection = c.view:get_selection_state()
    c.view:on_mouse_moved(x, y, 0, 0)
    c.now = c.now + 60
    c.view:update()
    test.equal(preview.for_view(c.view), nil, "mouse hover must not open a preview")
    test.same(c.view:get_selection_state(), selection)
    test.ok(require("core.poi").navigate(c.view, -1))
    test.not_nil(preview.for_view(c.view), "POI navigation should keep its preview")
    test.equal(c.view:get_visual_row_entry(2).type, "provider")
  end)

  for _, target in ipairs({ "#Missing heading", "Target#^missing-block" }) do
    test.it("does not replace the broken target " .. target .. " with the start of its note", function(c)
      local link = require("core.markdown.links").from_target("wiki", target)
      test.equal(markdown.live_render.preview_link(c.view, link, 1), false)
      test.equal(preview.for_view(c.view), nil)
      test.equal(core.active_view, c.view)
    end)
  end
end)
