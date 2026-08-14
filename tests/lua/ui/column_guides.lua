local core = require "core"
local config = require "core.config"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local test = require "core.test"

require "plugins.column_guides"

local function make_view(context, editor)
  local buffer = Buffer()
  local view = editor and Editor(buffer) or TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  context.buffers[#context.buffers + 1] = buffer
  return view
end

local function make_markdown_view(context)
  local buffer = Buffer("column-guides.md", "column-guides.md", true)
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  markdown.live_render.refresh_view(view)
  context.buffers[#context.buffers + 1] = buffer
  return view
end

local function count_guides(view)
  local count = 0
  local content_x = view:get_line_screen_position(1)
  local old_draw_rect = renderer.draw_rect
  local old_push_clip_rect = core.push_clip_rect
  local old_pop_clip_rect = core.pop_clip_rect
  renderer.draw_rect = function(x)
    if x > content_x then count = count + 1 end
  end
  core.push_clip_rect = function() end
  core.pop_clip_rect = function() end
  local ok, err = pcall(view.draw_current_line_highlights, view, 1, 1)
  renderer.draw_rect = old_draw_rect
  core.push_clip_rect = old_push_clip_rect
  core.pop_clip_rect = old_pop_clip_rect
  if not ok then error(err, 0) end
  return count
end

test.describe("Column Guides", function()
  test.before_each(function(context)
    context.buffers = {}
    context.enabled = config.plugins.column_guides.enabled
    context.columns = config.plugins.column_guides.columns
    context.markdown_live_editor = config.markdown_live_editor
    config.plugins.column_guides.enabled = true
    config.plugins.column_guides.columns = { 2 }
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.plugins.column_guides.enabled = context.enabled
    config.plugins.column_guides.columns = context.columns
    config.markdown_live_editor = context.markdown_live_editor
    for _, buffer in ipairs(context.buffers) do buffer:on_close() end
  end)

  test.it("draws guides in Editors but not other Text Views", function(context)
    local editor = make_view(context, true)
    local tool_view = make_view(context, false)

    test.ok(count_guides(editor) > 0, "expected Editors to draw Column Guides")
    test.equal(count_guides(tool_view), 0)
  end)

  test.it("does not draw guides in Markdown Live Preview", function(context)
    local view = make_markdown_view(context)

    test.equal(view.__markdown_live_attached, true)
    test.equal(count_guides(view), 0)
  end)

  test.it("does not draw guides in specialized Editors", function(context)
    local SpecializedEditor = Editor:extend()
    local buffer = Buffer()
    local view = SpecializedEditor(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 400, 200
    context.buffers[#context.buffers + 1] = buffer

    test.equal(count_guides(view), 0)
  end)
end)
