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

local function rendered_card(view)
  local text = {}
  local old_text, old_rect, old_clip = renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect
  renderer.draw_text = function(font, value, x, y, color, opts)
    text[#text + 1] = value
    return x + font:get_width(value, opts)
  end
  renderer.draw_rect, renderer.set_clip_rect = function() end, function() end
  local ok, err = pcall(preview.draw_floating, view)
  renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect = old_text, old_rect, old_clip
  if not ok then error(err, 0) end
  return table.concat(text, "\n")
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

  for _, target in ipairs({ "#Missing heading", "Target#^missing-block" }) do
    test.it("does not replace the broken target " .. target .. " with the start of its note", function(c)
      local link = require("core.markdown.links").from_target("wiki", target)
      local shown = markdown.live_render.preview_link(c.view, link, {
        line = 1, note_only = true, floating = { x = c.x, top = c.y, bottom = c.y + 20 },
      })
      test.equal(shown, false, "a missing target must not show unrelated note content")
      test.equal(preview.for_view(c.view), nil)
      test.equal(core.active_view, c.view)
    end)
  end

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

  test.it("keeps the card open while the pointer crosses the gap and enters it", function(c)
    c.view:on_mouse_moved(c.x, c.y, 0, 0)
    c.now = c.now + config.markdown_link_hover_delay * 2
    c.view:update()
    local card = test.not_nil(preview.for_view(c.view))
    local x, y, width = preview.floating_rect(c.view)
    local padding = require("core.style").padding.y
    c.view:on_mouse_moved(x + width / 2, y - padding / 2, 0, 0)
    test.equal(preview.for_view(c.view), card, "crossing the gap closed the card")
    c.view:on_mouse_moved(x + width / 2, y + padding, 0, 0)
    test.equal(preview.for_view(c.view), card, "entering the card closed it")
    c.view:on_mouse_moved(0, c.view.size.y, 0, 0)
    test.equal(preview.for_view(c.view), nil)
  end)

  test.it("scrolls the card to its bounds without scrolling the source", function(c)
    write_file(c.root .. PATHSEP .. "Target.md", "# Target\n\nFirst entry\n"
      .. string.rep("Another entry in the note.\n", 50) .. "\nEnd of note\n")
    c.view:on_mouse_moved(c.x, c.y, 0, 0)
    c.now = c.now + config.markdown_link_hover_delay * 2
    c.view:update()
    local card = test.not_nil(preview.for_view(c.view))
    local deadline = c.clock() + 5
    local before
    repeat
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      before = rendered_card(c.view)
      if before:find("First entry", 1, true) then break end
      system.sleep(0.001)
    until c.clock() >= deadline
    test.contains(before, "First entry")
    local x, y, width = preview.floating_rect(c.view)
    c.view:on_mouse_moved(x + width / 2, y + 10, 0, 0)
    local source_scroll = c.view.scroll.y
    test.ok(c.view:on_mouse_wheel(-10000, 0), "card should consume the wheel event")
    test.equal(preview.for_view(c.view), card)
    local bottom = rendered_card(c.view)
    test.contains(bottom, "End of note")
    test.equal(bottom:find("First entry", 1, true), nil)
    c.view:on_mouse_wheel(-10000, 0)
    test.equal(rendered_card(c.view), bottom)
    c.view:on_mouse_wheel(10000, 0)
    test.equal(rendered_card(c.view), before)
    test.equal(c.view.scroll.y, source_scroll)
    test.equal(c.view.scroll.to.y, source_scroll)
  end)

  test.it("covers the document caret without hiding it after the card closes", function(c)
    local RootPanel = require "core.rootpanel"
    local style = require "core.style"
    local root = RootPanel()
    root.size.x, root.size.y = c.view.size.x, c.view.size.y
    -- Render an isolated window containing this Editor.
    root.pane_views = function() return { c.view } end
    root.shell_views = function() return {} end
    local old_root, old_clip_stack = core.root_panel, core.clip_rect_stack
    local old_animated, old_blink = config.animated_caret, config.disable_blink
    local old_text, old_rect, old_clip = renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect
    local old_rounded = renderer.draw_rounded_rect
    local ok, err = pcall(function()
      core.root_panel = root
      core.clip_rect_stack = {{ 0, 0, root.size.x, root.size.y }}
      config.animated_caret, config.disable_blink = true, true
      c.view:set_selection_state({ selections = { 3, 5, 3, 5 }, last_selection = 1 })
      c.view:on_mouse_moved(c.x, c.y, 0, 0)
      c.now = c.now + config.markdown_link_hover_delay * 2
      c.view:update()
      test.not_nil(preview.for_view(c.view))
      local x, y = c.view:get_line_screen_position(3, 5)
      x, y = math.floor(x + 0.5), math.floor(y + c.view:get_line_height() / 2)
      test.ok(preview.contains_floating(c.view, x, y), "caret must sit behind the card")
      local pixel
      renderer.draw_rect = function(left, top, width, height, color)
        if x >= left and x < left + width and y >= top and y < top + height then pixel = color end
      end
      renderer.draw_text = function(font, text, left, top, color, opts)
        return left + font:get_width(text, opts)
      end
      renderer.set_clip_rect = function() end
      renderer.draw_rounded_rect = function() end
      root:draw()
      test.same(pixel, style.background2, "document caret is visible through the card")
      preview.dismiss(c.view)
      root:draw()
      test.same(pixel, style.caret, "document caret should remain visible without the card")
    end)
    renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect = old_text, old_rect, old_clip
    renderer.draw_rounded_rect = old_rounded
    config.animated_caret, config.disable_blink = old_animated, old_blink
    core.root_panel, core.clip_rect_stack = old_root, old_clip_stack
    if not ok then error(err, 0) end
  end)
end)
