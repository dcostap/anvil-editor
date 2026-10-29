local core = require "core"
local config = require "core.config"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local heading_outline = require "core.markdown.heading_outline"
local model = require "core.markdown.model"
local panes = require "core.panes"
local treesitter = require "core.treesitter"
local workers = require "core.worker_pool"
local test = require "core.test"

local function filler(count)
  local lines = {}
  for i = 1, count do lines[i] = "Some prose on line " .. i .. "." end
  return table.concat(lines, "\n\n")
end

local DOCUMENT = table.concat({
  "# Guide",
  filler(3),
  "## Install **now**",
  filler(20),
  "## Use `anvil`",
  filler(20),
  "### Details [link](https://example.com)",
  filler(20),
  "## End",
  "Short.",
}, "\n\n")

-- Headings whose names need the outline's rules: closing hashes, Setext
-- lines, containers, whitespace, inline syntax, and UTF-8.
local EDGE_DOCUMENT = table.concat({
  "# Closed heading ##",
  "",
  "Setext title",
  "spread on two lines",
  "===",
  "",
  "> ## Quoted heading",
  "",
  "- ### Listed heading",
  "",
  "#",
  "",
  "###\tTabs\tand  gaps   ",
  "",
  "Title with *emphasis* and [[Note|alias]]",
  "---",
  "",
  "### Escaped \\# hash #",
  "",
  "  ## Indented heading",
  "",
  "## Ends with hashes#",
  "",
  "## Héllo wörld",
  "",
  "```",
  "# not a heading",
  "```",
}, "\n")

local function wait_until(predicate, message)
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if predicate() then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.ok(false, message)
end

local function open_view(context, width, text)
  local buffer = core.open_buffer()
  buffer:set_filename("outline.md", nil)
  buffer:insert(1, 1, text or DOCUMENT)
  buffer:clear_undo_redo()
  context.buffer = buffer
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  buffer:set_selection(1, 1)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(buffer))
  wait_until(function() return instance.status == "ready" end, "Markdown model did not become ready")
  wait_until(function()
    treesitter.poll_buffer(buffer)
    return buffer.treesitter and buffer.treesitter.status == "ready"
  end, "Markdown tree did not become ready")
  core.set_active_view(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = width or 1400, 600
  view:update()
  return view, buffer
end

local function line_of(buffer, prefix)
  for line, text in ipairs(buffer.lines) do
    if text:sub(1, #prefix) == prefix then return line end
  end
end

-- Put a line at the top of the view, as a scroll does.
local function scroll_line_to_top(view, line)
  local _, y = view:get_line_screen_position(line)
  local _, oy = view:get_content_offset()
  view.scroll.y = y - oy
  view.scroll.to.y = view.scroll.y
  view:update()
end

local function titles(layout)
  local result = {}
  for _, entry in ipairs(layout.entries) do result[#result + 1] = entry.title end
  return result
end

local function entry_titled(layout, title)
  for _, entry in ipairs(layout.entries) do
    if entry.title == title then return entry end
  end
end

local function current_title(layout)
  local entry = layout.entries[layout.current or 0]
  return entry and entry.title
end

test.describe("Markdown Heading Outline", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.live = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    local buffer = context.buffer
    if buffer then
      if buffer:is_dirty() then buffer:clean() end
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == buffer then table.remove(core.buffers, i) end
      end
    end
    config.markdown_live_editor = context.live
  end)

  test.it("lists the headings as plain text left of the text, nested by level", function(context)
    local view = open_view(context)
    local layout = test.not_nil(heading_outline.layout(view))
    test.same(titles(layout), { "Guide", "Install now", "Use anvil", "Details link", "End" })
    local text_x = view:get_line_screen_position(1, 1)
    test.ok(layout.x + layout.w < text_x, "the outline stays left of the text")
    local guide, use, details = entry_titled(layout, "Guide"), entry_titled(layout, "Use anvil"),
      entry_titled(layout, "Details link")
    test.ok(guide.text_x < use.text_x and use.text_x < details.text_x, "deeper headings are indented further")
  end)

  test.it("lists the headings that Current Buffer Symbol Search finds, at their names", function(context)
    local view, buffer = open_view(context, nil, EDGE_DOCUMENT)
    local layout = test.not_nil(heading_outline.layout(view))
    test.same(titles(layout), {
      "Closed heading", "Setext title spread on two lines", "Quoted heading", "Listed heading",
      "Tabs and gaps", "Title with emphasis and alias", "Escaped # hash", "Indented heading",
      "Ends with hashes#", "Héllo wörld",
    })
    local symbols = {}
    for _, symbol in ipairs(treesitter.get_buffer_outline(buffer)) do symbols[symbol.start_line] = symbol end
    for _, entry in ipairs(layout.entries) do
      local symbol = test.not_nil(symbols[entry.line], entry.title)
      test.equal(entry.col, symbol.name_range.start.col, entry.title)
    end
  end)

  test.it("shows a heading that the user adds", function(context)
    local view, buffer = open_view(context)
    buffer:insert(#buffer.lines, math.huge, "\n\n## Added later")
    wait_until(function()
      treesitter.poll_buffer(buffer)
      view:update()
      local layout = heading_outline.layout(view)
      return layout and entry_titled(layout, "Added later") ~= nil
    end, "the added heading did not show")
  end)

  test.it("follows a heading that the user renames or moves to another level", function(context)
    local view, buffer = open_view(context)
    buffer:insert(line_of(buffer, "## Use"), 1, "#")
    buffer:insert(line_of(buffer, "## Install"), math.huge, " today")
    wait_until(function()
      treesitter.poll_buffer(buffer)
      view:update()
      local layout = heading_outline.layout(view)
      return layout and entry_titled(layout, "Install now today") ~= nil
    end, "the renamed heading did not show")
    local layout = heading_outline.layout(view)
    test.same(titles(layout), { "Guide", "Install now today", "Use anvil", "Details link", "End" })
    test.equal(entry_titled(layout, "Use anvil").text_x, entry_titled(layout, "Details link").text_x,
      "a heading at the level of Details has its indent")
  end)

  test.it("marks the section at the top of the view as current", function(context)
    local view, buffer = open_view(context)
    test.equal(current_title(heading_outline.layout(view)), "Guide")
    scroll_line_to_top(view, line_of(buffer, "## Use") + 4)
    test.equal(current_title(heading_outline.layout(view)), "Use anvil")
  end)

  test.it("marks the caret's section as current after the caret moves, until the user scrolls", function(context)
    local view, buffer = open_view(context)
    local use = line_of(buffer, "## Use")
    -- The heading shows below the reading line, so the section above it is current.
    scroll_line_to_top(view, use - 10)
    test.equal(current_title(heading_outline.layout(view)), "Install now")
    buffer:set_selection(use, 1)
    view:update()
    test.equal(current_title(heading_outline.layout(view)), "Use anvil")
    buffer:set_selection(use + 2, 3)
    view:update()
    test.equal(current_title(heading_outline.layout(view)), "Use anvil")
    view:on_mouse_wheel(1, 0)
    view.scroll.y = view.scroll.to.y
    view:update()
    test.equal(current_title(heading_outline.layout(view)), "Install now")
  end)

  test.it("moves the caret and the view to a heading when its entry is clicked", function(context)
    local view, buffer = open_view(context)
    local entry = test.not_nil(entry_titled(heading_outline.layout(view), "Details link"))
    test.ok(view:on_mouse_pressed("left", entry.x + 2, entry.y + 2, 1))
    view:on_mouse_released("left", entry.x + 2, entry.y + 2)
    local details = line_of(buffer, "### Details")
    test.equal((buffer:get_selection()), details)
    view.scroll.y = view.scroll.to.y
    view:update()
    local _, y = view:get_line_screen_position(details)
    test.ok(y >= view.position.y and y < view.position.y + view.size.y / 4, "the heading shows near the top")
    test.equal(current_title(heading_outline.layout(view)), "Details link")
  end)

  test.it("marks a clicked heading near the end as current", function(context)
    local view = open_view(context)
    local entry = test.not_nil(entry_titled(heading_outline.layout(view), "End"))
    view:on_mouse_pressed("left", entry.x + 2, entry.y + 2, 1)
    view:on_mouse_released("left", entry.x + 2, entry.y + 2)
    view.scroll.y = view.scroll.to.y
    view:update()
    test.equal(current_title(heading_outline.layout(view)), "End")
  end)

  test.it("keeps a clicked heading current until the user scrolls, also before a short section", function(context)
    local view = open_view(context, nil, table.concat({
      "# Top", filler(20), "## Short", "One line.", "## Next", filler(20), "## Last", filler(20),
    }, "\n\n"))
    local entry = test.not_nil(entry_titled(heading_outline.layout(view), "Short"))
    view:on_mouse_pressed("left", entry.x + 2, entry.y + 2, 1)
    view:on_mouse_released("left", entry.x + 2, entry.y + 2)
    -- A frame before the view scrolls to the heading.
    test.equal(current_title(heading_outline.layout(view)), "Short")
    view.scroll.y = view.scroll.to.y
    view:update()
    test.equal(current_title(heading_outline.layout(view)), "Short")
    view:on_mouse_wheel(-1, 0)
    view.scroll.y = view.scroll.to.y
    view:update()
    test.equal(current_title(heading_outline.layout(view)), "Next")
  end)

  test.it("shows no outline when the margin has no room or the source shows", function(context)
    local view = open_view(context, 900)
    test.equal(heading_outline.layout(view), nil)
    view.size.x = 1400
    view:update()
    test.not_nil(heading_outline.layout(view))
    markdown.live_render.set_source_mode(view, true, "test")
    view:update()
    test.equal(heading_outline.layout(view), nil)
  end)
end)
