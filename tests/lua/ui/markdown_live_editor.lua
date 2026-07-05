local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local style = require "core.style"
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

  test.it("keeps drag-selection heading layout stable until release", function()
    local view, doc = make_view("## Title ##\nbody", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    test.equal(view:get_x_offset_col(1, 1), 4)
    view:begin_line_render_interaction("test")
    doc:set_selection(1, 4)
    test.equal(view:get_x_offset_col(1, 1), 4)
    test.equal(view:get_col_x_offset(1, 4), 0)
    view:end_line_render_interaction("test")
    test.ok(view:get_col_x_offset(1, 4) > 0)
  end)

  test.it("does not live-render Markdown syntax inside code blocks", function()
    local view, doc = make_view("```\n# Not Heading\n**not bold**\n``` not closing\n# Still Not Heading\n```\n# Heading\n", "note.md")
    doc:set_selection(7, 1)
    markdown.live_render.refresh_view(view)
    test.equal(view:get_visual_row_height(2), view:get_line_height())
    test.equal(view:get_col_x_offset(2, 3), view:get_font():get_width("# "))
    test.equal(view:get_col_x_offset(3, #"**not bold**" + 1), view:get_font():get_width("**not bold**"))
    test.equal(view:get_col_x_offset(5, 3), view:get_font():get_width("# "))
    test.ok(view:get_visual_row_height(7) > view:get_line_height())
  end)

  test.it("renders emphasis inside heading content", function()
    local view, doc = make_view("## A **bold** and *italic* Heading\nbody", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    local render_line = view:get_line_render(1)
    test.not_nil(render_line)
    local seen = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      seen[fragment.text or ""] = fragment
    end
    test.not_nil(seen.bold)
    test.not_nil(seen.italic)
    test.equal(seen.bold.color, style.text)
    test.equal(seen.italic.color, style.text)
    test.ok(seen.bold.font ~= view:get_font())
    test.ok(seen.italic.font ~= view:get_font())
    test.ok(seen["**"] == nil)
    test.ok(seen["*"] == nil)
  end)

  test.it("reveals raw inline Markdown on the active line", function()
    local view, doc = make_view("See [[Note|Alias]]", "note.md")
    markdown.live_render.refresh_view(view)
    doc:set_selection(1, 1)
    local raw_width = view:get_font():get_width("See [[Note|Alias]]")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), raw_width)
  end)

  test.it("renders emphasis text with styled fonts and normal text color", function()
    local view, doc = make_view("This is **bold**, *italic*, and ***both*** plus pre**mid**post and x__under__y\nnext", "note.md")
    doc:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    local render_line = view:get_line_render(1)
    test.not_nil(render_line)
    local seen = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      seen[fragment.text or ""] = fragment
    end
    test.not_nil(seen.bold)
    test.not_nil(seen.italic)
    test.not_nil(seen.both)
    test.not_nil(seen.mid)
    test.not_nil(seen.under)
    test.equal(seen.bold.color, style.text)
    test.equal(seen.italic.color, style.text)
    test.equal(seen.both.color, style.text)
    test.equal(seen.mid.color, style.text)
    test.equal(seen.under.color, style.text)
    test.equal(seen.bold.overdraw, true)
    test.equal(seen.italic.overdraw, nil)
    test.equal(seen.both.overdraw, true)
    test.ok(seen.bold.font ~= view:get_font())
    test.ok(seen.italic.font ~= view:get_font())
    test.ok(seen.both.font ~= view:get_font())
    test.ok(seen.mid.font ~= view:get_font())
    test.ok(seen.under.font ~= view:get_font())
    test.equal(view:get_x_offset_col(1, view:get_col_x_offset(1, #"This is **" + 1) + 1), #"This is **" + 1)
  end)

  test.it("expands active-line emphasis syntax before caret movement crosses spans", function()
    local view, doc = make_view("This is **bold** and **more**\nnext", "note.md")
    doc:set_selection(1, 11)
    markdown.live_render.refresh_view(view)
    local render_line = view:get_line_render(1)
    test.not_nil(render_line)
    local texts = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      if not fragment.hidden then texts[#texts + 1] = fragment.text or "" end
    end
    test.same({ "This is ", "**", "bold", "**", " and ", "**", "more", "**" }, texts)
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
    local drawn_text = {}
    canvas.load_image = function(path)
      test.equal(path, image_path)
      return {
        get_size = function() return 64, 32 end,
        scaled = function(self) return self end,
      }
    end
    renderer.draw_canvas = function() drawn = drawn + 1 end
    renderer.draw_text = function(font, text, x, y, color, opts)
      drawn_text[#drawn_text + 1] = text
      return x + font:get_width(text, opts)
    end

    markdown.live_render.refresh_view(view)
    local inactive_height = view:get_visual_row_height(1)
    test.ok(inactive_height > 32)
    doc:set_selection(1, 1)
    test.ok(view:get_visual_row_height(1) > inactive_height)
    view:draw_line_text(1, 0, 0)
    test.equal(drawn_text[1], "![Alt](" .. image_url .. ")")
    doc:set_selection(2, 1)
    test.equal(view:get_visual_row_height(1), inactive_height)
    test.equal(view:get_x_offset_col(1, 1), 1)
    view:draw_line_text(1, 0, 0)

    canvas.load_image = old_load_image
    renderer.draw_canvas = old_draw_canvas
    renderer.draw_text = old_draw_text
    os.remove(image_path)
    test.equal(drawn, 2)
  end)

  test.it("renders wikilink image embeds from Obsidian attachmentFolderPath", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-attachments-" .. system.get_process_id()
    local obsidian = root .. PATHSEP .. ".obsidian"
    local media = root .. PATHSEP .. "configured-media"
    local ok, err = common.mkdirp(obsidian)
    test.ok(ok, err)
    ok, err = common.mkdirp(media)
    test.ok(ok, err)
    local app = io.open(obsidian .. PATHSEP .. "app.json", "wb")
    test.not_nil(app)
    app:write([[{"attachmentFolderPath":"./configured-media"}]])
    app:close()
    local image_path = media .. PATHSEP .. "diagram.png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()

    local view, doc = make_view("![[diagram.png]]\nother", root .. PATHSEP .. "Planificación Fabricación.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    canvas.load_image = function(path)
      test.equal(path, image_path)
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end

    markdown.live_render.refresh_view(view)
    test.ok(view:get_visual_row_height(1) > 40)

    canvas.load_image = old_load_image
    os.remove(image_path)
    common.rm(root, true)
  end)

  test.it("draws image widgets using the resolved visual row height", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-small-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![Small](" .. image_url .. ")\nother", USERDIR .. PATHSEP .. "note.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    local old_draw_canvas = renderer.draw_canvas
    local old_get_visual_row = view.get_visual_row
    local old_get_visual_row_height = view.get_visual_row_height
    local drawn_y
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    renderer.draw_canvas = function(_, _, y) drawn_y = y end
    view.get_visual_row = function(self, line, col, line_end)
      if line == 1 then return 6 end
      return old_get_visual_row(self, line, col, line_end)
    end
    view.get_visual_row_height = function(self, row)
      if row == 1 then return 100 end
      if row == 6 then return 40 end
      return old_get_visual_row_height(self, row)
    end

    markdown.live_render.refresh_view(view)
    view:draw_line_text(1, 0, 10)
    test.equal(drawn_y, 10)

    canvas.load_image = old_load_image
    renderer.draw_canvas = old_draw_canvas
    view.get_visual_row = old_get_visual_row
    view.get_visual_row_height = old_get_visual_row_height
    os.remove(image_path)
  end)

  test.it("keeps tiny image rows at least normal line height", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-tiny-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()

    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![Tiny](" .. image_url .. ")\nother", USERDIR .. PATHSEP .. "note.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    canvas.load_image = function(path)
      test.equal(path, image_path)
      return {
        get_size = function() return 4, 4 end,
        scaled = function(self) return self end,
      }
    end

    markdown.live_render.refresh_view(view)
    test.equal(view:get_visual_row_height(1), view:get_line_height())

    canvas.load_image = old_load_image
    os.remove(image_path)
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
