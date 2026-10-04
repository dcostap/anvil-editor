local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local TitleBar = require "core.titlebar"
local test = require "core.test"
local autosave = require "plugins.autosave_fast"
require "plugins.autoreload"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

-- Observe the Tab through the renderer boundary, not the file monitor's state.
local function tab_render(title, view)
  title:update()
  local draw_text, draw_rect = renderer.draw_text, renderer.draw_rect
  local draw_rounded_rect, set_clip_rect = renderer.draw_rounded_rect, renderer.set_clip_rect
  local name, lines = nil, {}
  renderer.draw_text = function(font, text, x, y, color)
    if text == view:get_name() then
      name = { color = color, x = x, y = y,
        w = font:get_width(text), h = font:get_height() }
    end
    return x + font:get_width(text)
  end
  renderer.draw_rect = function(x, y, w, h, color)
    lines[#lines + 1] = { x = x, y = y, w = w, h = h, color = color }
  end
  renderer.draw_rounded_rect, renderer.set_clip_rect = function() end, function() end
  local ok, err = pcall(title.draw, title)
  renderer.draw_text, renderer.draw_rect = draw_text, draw_rect
  renderer.draw_rounded_rect, renderer.set_clip_rect = draw_rounded_rect, set_clip_rect
  if not ok then error(err, 0) end
  test.not_nil(name, "Expected the filename in the Tab")
  name.struck = false
  for _, line in ipairs(lines) do
    if line.x == name.x and line.w == name.w
      and line.y > name.y and line.y < name.y + name.h
      and line.h < name.h and line.color == name.color then
      name.struck = true
    end
  end
  return name
end

local function wait_for(predicate)
  local deadline = system.get_time() + 4
  repeat
    if predicate() then return true end
    coroutine.yield(0.02)
  until system.get_time() >= deadline
  return false
end

test.describe("Missing file Tab feedback", function()
  test.before_each(function(c)
    -- Finish startup callbacks before creating the test Pane.
    coroutine.yield(0.05)
    panes.reset_for_tests()
    c.active_view, c.enabled, c.nag_show = core.active_view, autosave.enabled, core.nag_view.show
    autosave.enabled = false
    c.prompts = 0
    core.nag_view.show = function() c.prompts = c.prompts + 1 end
    c.path = system.absolute_path(USERDIR .. PATHSEP .. "missing-tab.txt")
    write_file(c.path, "original\n")
    c.pane = assert(panes.create { factory = function()
      return Editor(core.open_buffer(c.path))
    end })
    c.view = c.pane.current_view
    c.title = TitleBar()
    c.title.size.x = 1200
    -- Let the load hook attach the file monitor before removing the file.
    coroutine.yield(0.05)
  end)

  test.after_each(function(c)
    panes.reset_for_tests()
    core.active_view, autosave.enabled, core.nag_view.show = c.active_view, c.enabled, c.nag_show
    if c.view then core.buffer_registry:remove(c.view.buffer, true) end
    if c.path then os.remove(c.path) end
    if c.saved_path then os.remove(c.saved_path) end
  end)

  for _, dirty in ipairs({ false, true }) do
    test.it("marks a deleted " .. (dirty and "edited" or "unchanged")
      .. " file without losing its text", function(c)
      local buffer = c.view.buffer
      if dirty then buffer:insert(1, 1, "my edits ") end
      local text = table.concat(buffer.lines)
      local normal = tab_render(c.title, c.view)
      test.not_ok(normal.struck)
      assert(os.remove(c.path))

      test.ok(wait_for(function() return tab_render(c.title, c.view).struck end),
        "The deleted file needs a visible Tab warning")
      local missing = tab_render(c.title, c.view)
      test.not_equal(missing.color, normal.color)
      test.equal(table.concat(buffer.lines), text)
      test.equal(buffer:is_dirty(), dirty)
      test.equal(c.prompts, 0, "Deletion alone must not interrupt editing")
      test.equal(core.active_view, c.view)
    end)
  end

  test.it("clears the warning when the file returns and monitors later deletions", function(c)
    assert(os.remove(c.path))
    test.ok(wait_for(function() return tab_render(c.title, c.view).struck end))
    write_file(c.path, "restored contents\n")
    test.ok(wait_for(function() return not tab_render(c.title, c.view).struck end),
      "The warning must clear when the file returns")
    test.equal(table.concat(c.view.buffer.lines), "restored contents\n")
    assert(os.remove(c.path))
    test.ok(wait_for(function() return tab_render(c.title, c.view).struck end),
      "The file must remain monitored after restoration")
  end)

  test.it("does not mark Untitled Buffers or files that have not been saved", function(c)
    local buffer = Buffer(c.path .. ".new", c.path .. ".new", true)
    panes.replace_view(c.pane, function() return Editor(buffer) end)
    coroutine.yield(1.1)
    test.not_ok(tab_render(c.title, c.pane.current_view).struck)
    panes.replace_view(c.pane, function() return Editor(Buffer()) end)
    test.not_ok(tab_render(c.title, c.pane.current_view).struck)
  end)

  test.it("clears the warning after Save As and monitors the new file", function(c)
    assert(os.remove(c.path))
    test.ok(wait_for(function() return tab_render(c.title, c.view).struck end))
    c.saved_path = c.path .. ".saved"
    c.view.buffer:save(c.saved_path, c.saved_path)
    test.not_ok(tab_render(c.title, c.view).struck)
    assert(os.remove(c.saved_path))
    test.ok(wait_for(function() return tab_render(c.title, c.view).struck end),
      "Save As must monitor the new file instead of the old path")
  end)
end)
