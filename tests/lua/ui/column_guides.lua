local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local file_context = require "core.file_context"
local markdown = require "core.markdown"
local test = require "core.test"

require "plugins.column_guides"

local function make_view(context, editor)
  local doc = Doc()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  if editor then file_context.mark_editor_view(view) end
  context.docs[#context.docs + 1] = doc
  return view
end

local function make_markdown_view(context)
  local doc = Doc("column-guides.md", "column-guides.md", true)
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  file_context.mark_editor_view(view)
  markdown.live_render.refresh_view(view)
  context.docs[#context.docs + 1] = doc
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
    context.docs = {}
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
    for _, doc in ipairs(context.docs) do doc:on_close() end
  end)

  test.it("draws guides in Editors but not other Document Views", function(context)
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

  test.it("does not draw guides in specialized Editor Document Views", function(context)
    local SpecializedEditor = DocView:extend()
    local doc = Doc()
    local view = SpecializedEditor(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 400, 200
    file_context.mark_editor_view(view)
    context.docs[#context.docs + 1] = doc

    test.equal(count_guides(view), 0)
  end)
end)
