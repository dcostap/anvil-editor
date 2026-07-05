local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local test = require "core.test"

local function make_view(text, filename)
  local doc = Doc(filename or "note.md", filename or "note.md", true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 200
  view:set_wrapping_enabled(false)
  return view, doc
end

test.describe("Markdown Live Editor", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.old_markdown_live_editor
  end)

  test.it("attaches only to Markdown DocViews", function()
    local md = make_view("# Title", "note.md")
    local txt = make_view("# Title", "note.txt")
    test.equal(markdown.live_render.refresh_view(md), true)
    test.equal(md.__markdown_live_attached, true)
    markdown.live_render.refresh_view(txt)
    test.equal(txt.__markdown_live_attached, nil)
  end)

  test.it("renders inactive headings with larger row metrics and hidden markers", function()
    local view, doc = make_view("# Title\nbody", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)

    local base_lh = view:get_line_height()
    test.ok(view:get_visual_row_height(1) > base_lh)
    test.equal(view:get_col_x_offset(1, 1), 0)
    test.equal(view:get_col_x_offset(1, 3), 0)
    test.ok(view:get_col_x_offset(1, 8) > 0)
  end)

  test.it("expands active headings to editable rendered Markdown syntax", function()
    local view, doc = make_view("## Title ##", "note.md")
    markdown.live_render.refresh_view(view)
    doc:set_selection(1, 5)
    test.ok(view:get_visual_row_height(1) > view:get_line_height())
    test.ok(view:get_col_x_offset(1, 2) > 0)
    test.ok(view:get_col_x_offset(1, 4) > view:get_font():get_width("##") * 1.2)
    test.ok(view:get_col_x_offset(1, #"## Title ##" + 1) > view:get_font():get_width("## Title ##") * 1.2)
  end)

  test.it("hit-tests inactive headings against their expanded editable rendering", function()
    local view, doc = make_view("## Title ##\nbody", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    test.ok(view:get_x_offset_col(1, 1) < 4)
  end)

  test.it("reveals raw inline Markdown on the active line", function()
    local view, doc = make_view("See [[Note|Alias]]", "note.md")
    markdown.live_render.refresh_view(view)
    doc:set_selection(1, 1)
    local raw_width = view:get_font():get_width("See [[Note|Alias]]")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), raw_width)
  end)

  test.it("leaves inline code spans raw and does not render escaped syntax", function()
    local view, doc = make_view("`[[Note]]` and \\[[Escaped]]\nother", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    local raw_width = view:get_font():get_width("`[[Note]]` and \\[[Escaped]]")
    test.equal(view:get_col_x_offset(1, #"`[[Note]]` and \\[[Escaped]]" + 1), raw_width)
  end)

  test.it("renders short Markdown lines even when line wrapping is enabled", function()
    local view, doc = make_view("# Title\nbody", "note.md")
    view:set_wrapping_enabled(true)
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    test.ok(view:get_visual_row_height(1) > view:get_line_height())
    test.equal(view:get_col_x_offset(1, 3), 0)
  end)

  test.it("keeps actually wrapped Markdown lines on the raw metric path", function()
    local view, doc = make_view("# This is a very long heading that should wrap in a narrow view\nbody", "note.md")
    view.size.x = 90
    view:set_wrapping_enabled(true)
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    test.equal(view:get_visual_row_height(1), view:get_line_height())
  end)

  test.it("hides closing ATX heading markers", function()
    local view, doc = make_view("# Title #\nbody", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    test.equal(view:get_col_x_offset(1, #"# Title #" + 1), view:get_col_x_offset(1, #"# Title" + 1))
    test.ok(view:get_col_x_offset(1, #"# Title #" + 1) < view:get_font():get_width("# Title #"))
  end)

  test.it("renders wikilink aliases when inactive and raw syntax when active", function()
    local view, doc = make_view("See [[Note|Alias]]\nother", "note.md")
    doc:set_selection(1, 1)
    markdown.live_render.refresh_view(view)
    doc:set_selection(2, 1)

    local alias_width = view:get_font():get_width("See Alias")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), alias_width)

    doc:set_selection(1, 1)
    local raw_width = view:get_font():get_width("See [[Note|Alias]]")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), raw_width)
  end)

  test.it("renders project-local image fragments", function(context)
    local image_path = USERDIR .. PATHSEP .. "markdown-live-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()

    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![Alt](" .. image_url .. ")\nother", USERDIR .. PATHSEP .. "note.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    local old_draw_canvas = renderer.draw_canvas
    local old_draw_text = renderer.draw_text
    local drawn = 0
    canvas.load_image = function(path)
      test.equal(path, image_path)
      return {
        get_size = function() return 64, 32 end,
        scaled = function(self) return self end,
      }
    end
    renderer.draw_canvas = function() drawn = drawn + 1 end
    renderer.draw_text = function(font, text, x, y, color, opts) return x + font:get_width(text, opts) end

    markdown.live_render.refresh_view(view)
    test.equal(view:get_visual_row_height(1), 32)
    test.equal(view:get_x_offset_col(1, 1), 1)
    view:draw_line_text(1, 0, 0)

    canvas.load_image = old_load_image
    renderer.draw_canvas = old_draw_canvas
    renderer.draw_text = old_draw_text
    os.remove(image_path)
    test.equal(drawn, 1)
  end)

  test.it("honors disabled live image rendering", function()
    local old = config.markdown_live_render_images
    config.markdown_live_render_images = false
    local view, doc = make_view("![Alt](image.png)\nother", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    local link_width = view:get_font():get_width("Alt")
    test.equal(view:get_col_x_offset(1, #"![Alt](image.png)" + 1), link_width)
    config.markdown_live_render_images = old
  end)

  test.it("detaches when a Markdown document is renamed to non-Markdown", function()
    local view, doc = make_view("# Title", "note.md")
    markdown.live_render.refresh_view(view)
    test.equal(view.__markdown_live_attached, true)
    doc:set_filename("note.txt", "note.txt")
    markdown.live_render.refresh_view(view)
    test.equal(view.__markdown_live_attached, nil)
  end)
end)
