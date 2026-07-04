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

  test.it("reveals raw Markdown on the active line", function()
    local view, doc = make_view("# Title", "note.md")
    markdown.live_render.refresh_view(view)
    doc:set_selection(1, 1)
    test.equal(view:get_col_x_offset(1, 3), view:get_font():get_width("# "))
  end)

  test.it("does not render links inside code spans or escaped syntax", function()
    local view, doc = make_view("`[[Note]]` and \\[[Escaped]]\nother", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    local rendered_width = view:get_font():get_width("[[Note]] and \\[[Escaped]]")
    test.equal(view:get_col_x_offset(1, #"`[[Note]]` and \\[[Escaped]]" + 1), rendered_width)
  end)

  test.it("keeps wrapped Markdown on the raw metric path", function()
    local view, doc = make_view("# Title\nbody", "note.md")
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

  test.it("detaches when a Markdown document is renamed to non-Markdown", function()
    local view, doc = make_view("# Title", "note.md")
    markdown.live_render.refresh_view(view)
    test.equal(view.__markdown_live_attached, true)
    doc:set_filename("note.txt", "note.txt")
    markdown.live_render.refresh_view(view)
    test.equal(view.__markdown_live_attached, nil)
  end)
end)
