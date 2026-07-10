local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local markdown_parser = require "core.markdown.parser"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local function wait_status(instance, wanted, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == wanted then core.redraw = true return true end
    core.redraw = false
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == wanted
end

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

local function refresh(view)
  local result = markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.doc)
  if instance then
    local deadline = system.get_time() + 5
    while instance.status ~= "ready" and system.get_time() < deadline do
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      if instance.status ~= "ready" then system.sleep(0.001) end
    end
    test.equal(instance.status, "ready", instance.reason)
  end
  return result
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
    test.equal(refresh(md), true)
    test.equal(md.__markdown_live_attached, true)
    refresh(txt)
    test.equal(txt.__markdown_live_attached, nil)
  end)

  test.it("falls back to raw source while the first semantic snapshot is pending", function()
    local view = make_view("# Title\n**bold**", "note.md")
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(view.doc))
    test.equal(instance.status, "pending")
    test.equal(view:get_line_render(1), nil)
    test.equal(view:get_line_render(2), nil)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.not_nil(view:get_line_render(1))
    test.not_nil(view:get_line_render(2))
  end)

  test.it("renders inactive headings with larger row metrics and hidden markers", function()
    local view, doc = make_view("# Title\nbody", "note.md")
    doc:set_selection(2, 1)
    refresh(view)

    local base_lh = view:get_line_height()
    test.ok(view:get_visual_row_height(1) > base_lh)
    test.equal(view:get_col_x_offset(1, 1), 0)
    test.equal(view:get_col_x_offset(1, 3), 0)
    test.ok(view:get_col_x_offset(1, 8) > 0)
  end)

  test.it("adopts published heading and inline semantic identities", function()
    local view, doc = make_view("# **Title**\nText with ***bold***.\nplain", "note.md")
    doc:set_selection(3, 1)
    refresh(view)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_status(instance, "ready"), instance.reason)

    local heading = test.not_nil(view:get_line_render(1))
    test.equal(heading.semantic_generation, instance.generation)
    test.not_nil(heading.semantic_id)
    local heading_semantic_fragment
    for _, fragment in ipairs(heading.fragments or {}) do
      if fragment.semantic_id then heading_semantic_fragment = fragment break end
    end
    test.not_nil(heading_semantic_fragment)
    local inline = test.not_nil(view:get_line_render(2))
    test.equal(inline.semantic_generation, instance.generation)
    local semantic_fragment
    for _, fragment in ipairs(inline.fragments or {}) do
      if fragment.semantic_id then semantic_fragment = fragment break end
    end
    test.not_nil(semantic_fragment)

    local heading_before = heading
    local generation_before = instance.generation
    doc:insert(2, #doc.lines[2], "!")
    test.equal(view:get_line_render(1), heading_before)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(instance.generation > generation_before)
    test.equal(view:get_line_render(1), heading_before)
    test.equal(view:get_line_render(2).semantic_generation, instance.generation)
  end)

  test.it("re-adopts suffix semantics after structural edits rendered while pending", function()
    local view, doc = make_view("# A\nbody\n# B\nplain", "note.md")
    doc:set_selection(4, 1)
    refresh(view)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.not_nil(view:get_line_render(3).semantic_id)

    local previous_generation = instance.generation
    doc:insert(1, 1, "inserted\n")
    test.equal(view:get_line_render(4), nil)
    local split = DocView(doc)
    split.size.x, split.size.y = 500, 200
    split:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(split)
    test.equal(split:get_line_render(4), nil)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(instance.generation > previous_generation)
    local published = test.not_nil(view:get_line_render(4))
    test.equal(published.semantic_generation, instance.generation)
    test.not_nil(published.semantic_id)
    local split_published = test.not_nil(split:get_line_render(4))
    test.equal(split_published.semantic_generation, instance.generation)
    test.not_nil(split_published.semantic_id)
  end)

  test.it("invalidates raw-block-dependent suffix rendering and wrapping", function()
    local target = string.rep("folder/", 24) .. "name"
    local source = "```\n# [[" .. target .. "|Alias]] after\n```\nplain"
    local view, doc = make_view(source, "note.md")
    view.size.x = 500
    view:set_wrapping_enabled(true)
    doc:set_selection(4, 1)
    refresh(view)
    test.equal(view:get_line_render(2), nil)
    local function break_signature()
      local first, _, count = linewrapping.get_line_idx_col_count(view, 2)
      local cols = {}
      for idx = first, first + count - 1 do
        local _, col = linewrapping.get_idx_line_col(view, idx)
        cols[#cols + 1] = col
      end
      return table.concat(cols, ",")
    end
    local raw_breaks = break_signature()
    doc:remove(1, 1, 1, 4)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_status(instance, "ready"), instance.reason)
    local heading = test.not_nil(view:get_line_render(2))
    test.equal(heading.raw_passthrough, nil)
    test.ok(#(heading.fragments or {}) > 0)
    local rendered_breaks = break_signature()
    test.ok(rendered_breaks ~= raw_breaks, raw_breaks .. " -> " .. rendered_breaks)
    doc:raw_insert(1, 1, "```", doc.undo_stack, system.get_time())
    test.equal(view:get_line_render(2), nil)
    test.equal(break_signature(), raw_breaks)
  end)

  test.it("renders core emphasis families directly from semantic nodes", function()
    local view, doc = make_view("**bold** *italic* ***both*** ~~strike~~\nplain", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local old_parse_inline = markdown_parser.parse_inline
    markdown_parser.parse_inline = function() error("ad hoc inline parser must not run") end
    view:invalidate_line_render("markdown-live", 1, 1)
    local render_line = view:get_line_render(1)
    markdown_parser.parse_inline = old_parse_inline
    render_line = test.not_nil(render_line)
    local identities = {}
    for _, fragment in ipairs(render_line.fragments or {}) do
      if fragment.semantic_id then identities[fragment.semantic_id] = true end
    end
    local count = 0
    for _ in pairs(identities) do count = count + 1 end
    test.equal(count, 4)
  end)

  test.it("composes nested semantic formatting instead of suppressing inner styles", function()
    local source = "==mark **bold** and *italic*== plus **outer *inner***\nplain"
    local view, doc = make_view(source, "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local seen = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text and fragment.text ~= "" then seen[fragment.text] = fragment end
    end
    test.equal(seen.bold.background, style.markdown_live_highlight_bg)
    test.equal(seen.bold.overdraw, true)
    test.equal(seen.italic.background, style.markdown_live_highlight_bg)
    test.equal(seen.inner.overdraw, true)
    test.ok(seen.inner.font ~= view:get_font())
  end)

  test.it("preserves enclosing formatting across escapes and comments", function()
    local source = "**bold \\* literal** and **before %%hide%% after**\nplain"
    local view, doc = make_view(source, "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local seen = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text and fragment.text ~= "" then seen[fragment.text] = fragment end
    end
    test.equal(seen["*"].overdraw, true)
    local before, after
    for text, fragment in pairs(seen) do
      if text:find("before", 1, true) then before = fragment end
      if text:find("after", 1, true) then after = fragment end
    end
    test.equal(test.not_nil(before).overdraw, true)
    test.equal(test.not_nil(after).overdraw, true)
    test.equal(seen.hide, nil)
  end)

  test.it("refreshes every cached line of a multiline comment when delimiters change", function()
    local view, doc = make_view("%%hide\nstill hidden%%\nplain", "note.md")
    doc:set_selection(3, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"still hidden%%" + 1), 0)
    doc:remove(1, 1, 1, 2)
    test.equal(view:get_line_render(2), nil)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(
      view:get_col_x_offset(2, #"still hidden%%" + 1),
      view:get_font():get_width("still hidden%%")
    )
  end)

  test.it("refreshes multiline comments when ordinary edits form delimiters", function()
    local view, doc = make_view("before %x%\nsecret\n%%\nplain", "note.md")
    doc:set_selection(4, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"secret" + 1), view:get_font():get_width("secret"))
    doc:remove(1, 9, 1, 10)
    test.equal(view:get_line_render(2), nil)
    local instance = test.not_nil(markdown_model.peek(doc))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(view:get_col_x_offset(2, #"secret" + 1), 0)
  end)

  test.it("applies semantic comments and escapes inside headings", function()
    local view, doc = make_view("# visible %%hidden%% \\*literal*\nplain", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "visible  *literal*")
  end)

  test.it("expands active headings to editable rendered Markdown syntax", function()
    local view, doc = make_view("## Title ##", "note.md")
    refresh(view)
    doc:set_selection(1, 5)
    test.ok(view:get_visual_row_height(1) > view:get_line_height())
    test.ok(view:get_col_x_offset(1, 2) > 0)
    test.ok(view:get_col_x_offset(1, 4) > view:get_font():get_width("##") * 1.2)
    test.ok(view:get_col_x_offset(1, #"## Title ##" + 1) > view:get_font():get_width("## Title ##") * 1.2)
  end)

  test.it("keeps drag-selection heading layout stable until release", function()
    local view, doc = make_view("## Title ##\nbody", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    test.equal(view:get_x_offset_col(1, 1), 4)
    view:begin_line_render_interaction("test")
    doc:set_selection(1, 4)
    test.equal(view:get_x_offset_col(1, 1), 4)
    test.equal(view:get_col_x_offset(1, 4), 0)
    view:end_line_render_interaction("test")
    test.ok(view:get_col_x_offset(1, 4) > 0)
  end)

  test.it("reveals every multi-cursor line without expanding lines between them", function()
    local view, doc = make_view("## One\n## Two\n## Three", "note.md")
    refresh(view)
    doc:set_selections(1, 1, 4, 1, 4)
    doc:set_selections(2, 3, 4, 3, 4, nil, 0)

    test.ok(view:get_col_x_offset(1, 2) > 0)
    test.equal(view:get_col_x_offset(2, 2), 0)
    test.ok(view:get_col_x_offset(3, 2) > 0)
  end)

  test.it("freezes rendered layout for the lifetime of IME composition", function()
    local view, doc = make_view("## Title\nbody", "note.md")
    refresh(view)
    doc:set_selection(1, 4)
    view:on_ime_text_editing("x", 0, 0)
    test.not_nil(view.__line_render_interaction_state)
    test.equal(view.__line_render_interaction_state.reason, "ime-composition")
    view:on_ime_text_editing("", 0, 0)
    test.equal(view.__line_render_interaction_state, nil)
  end)

  test.it("does not live-render Markdown syntax inside code blocks", function()
    local view, doc = make_view("```\n# Not Heading\n**not bold**\n``` not closing\n# Still Not Heading\n```\n# Heading\n", "note.md")
    doc:set_selection(7, 1)
    refresh(view)
    test.equal(view:get_visual_row_height(2), view:get_line_height())
    test.equal(view:get_col_x_offset(2, 3), view:get_font():get_width("# "))
    test.equal(view:get_col_x_offset(3, #"**not bold**" + 1), view:get_font():get_width("**not bold**"))
    test.equal(view:get_col_x_offset(5, 3), view:get_font():get_width("# "))
    test.ok(view:get_visual_row_height(7) > view:get_line_height())
  end)

  test.it("renders emphasis inside heading content", function()
    local view, doc = make_view("## A **bold** and *italic* Heading\nbody", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
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
    refresh(view)
    doc:set_selection(1, 1)
    local raw_width = view:get_font():get_width("See [[Note|Alias]]")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), raw_width)
  end)

  test.it("renders emphasis text with styled fonts and normal text color", function()
    local view, doc = make_view("This is **bold**, *italic*, and ***both*** plus pre**mid**post and x__under__y\nnext", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
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
    test.equal(seen.under, nil)
    test.equal(seen.bold.color, style.text)
    test.equal(seen.italic.color, style.text)
    test.equal(seen.both.color, style.text)
    test.equal(seen.mid.color, style.text)
    test.equal(seen.bold.overdraw, true)
    test.equal(seen.italic.overdraw, nil)
    test.equal(seen.both.overdraw, true)
    test.ok(seen.bold.font ~= view:get_font())
    test.ok(seen.italic.font ~= view:get_font())
    test.ok(seen.both.font ~= view:get_font())
    test.ok(seen.mid.font ~= view:get_font())
    test.equal(view:get_x_offset_col(1, view:get_col_x_offset(1, #"This is **" + 1) + 1), #"This is **" + 1)
  end)

  test.it("expands active-line emphasis syntax before caret movement crosses spans", function()
    local view, doc = make_view("This is **bold** and **more**\nnext", "note.md")
    doc:set_selection(1, 11)
    refresh(view)
    local render_line = view:get_line_render(1)
    test.not_nil(render_line)
    local texts = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      if not fragment.hidden then texts[#texts + 1] = fragment.text or "" end
    end
    test.same({ "This is ", "**", "bold", "**", " and ", "**", "more", "**" }, texts)
  end)

  test.it("renders semantic code, highlight, strikethrough, and escapes", function()
    local source = "`code` ==mark== ~~gone~~ and \\*literal*\nother"
    local view, doc = make_view(source, "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local render_line = test.not_nil(view:get_line_render(1))
    local seen = {}
    for _, fragment in ipairs(render_line.fragments or {}) do
      seen[fragment.text or ""] = fragment
    end
    test.equal(seen.code.background, style.markdown_live_inline_code_bg)
    test.ok(seen.code.font ~= view:get_font())
    test.equal(seen.mark.background, style.markdown_live_highlight_bg)
    test.equal(seen.gone.strikethrough, true)
    test.not_nil(seen["*"])
    local rendered_width = view:get_font():get_width("code mark gone and *literal*")
    test.equal(view:get_col_x_offset(1, #(source:match("[^\n]+")) + 1), rendered_width)
  end)

  test.it("keeps fenced and heading-looking lines hidden inside comments", function()
    local source = "%%\n```\n# hidden heading\n```\n%%\nplain"
    local view, doc = make_view(source, "note.md")
    doc:set_selection(6, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"```" + 1), 0)
    test.equal(view:get_col_x_offset(3, #"# hidden heading" + 1), 0)
    test.equal(view:get_visual_row_height(3), view:get_line_height())
    test.equal(view:get_col_x_offset(4, #"```" + 1), 0)
  end)

  test.it("composes active comment markers with enclosing formatting", function()
    local source = "**before %%hide%% after**\nplain"
    local view, doc = make_view(source, "note.md")
    doc:set_selection(1, 13)
    refresh(view)
    local marker, content
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text and fragment.text:find("%", 1, true) then marker = fragment end
      if fragment.text == "hide" then content = fragment end
    end
    test.equal(test.not_nil(marker).color, style.markdown_live_hidden_syntax)
    test.equal(marker.overdraw, true)
    test.equal(test.not_nil(content).overdraw, true)
  end)

  test.it("hides multiline comments until a touched line reveals source", function()
    local source = "before %%hidden\nstill hidden%% after\nother"
    local view, doc = make_view(source, "note.md")
    doc:set_selection(3, 1)
    refresh(view)
    local function visible_text(line)
      local out = {}
      for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(line))) do
        if not fragment.hidden then out[#out + 1] = fragment.text or "" end
      end
      return table.concat(out)
    end
    test.equal(visible_text(1), "before ")
    test.equal(visible_text(2), " after")
    doc:set_selection(1, 10)
    test.equal(view:get_col_x_offset(1, #"before %%hidden" + 1), view:get_font():get_width("before %%hidden"))
  end)

  test.it("renders short Markdown lines even when line wrapping is enabled", function()
    local view, doc = make_view("# Title\nbody", "note.md")
    view:set_wrapping_enabled(true)
    doc:set_selection(2, 1)
    refresh(view)
    test.ok(view:get_visual_row_height(1) > view:get_line_height())
    test.equal(view:get_col_x_offset(1, 3), 0)
  end)

  test.it("keeps actually wrapped Markdown lines on the raw metric path", function()
    local view, doc = make_view("# This is a very long heading that should wrap in a narrow view\nbody", "note.md")
    view.size.x = 90
    view:set_wrapping_enabled(true)
    doc:set_selection(2, 1)
    refresh(view)
    test.equal(view:get_visual_row_height(1), view:get_line_height())
  end)

  test.it("hides closing ATX heading markers", function()
    local view, doc = make_view("# Title #\nbody", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(1, #"# Title #" + 1), view:get_col_x_offset(1, #"# Title" + 1))
    test.ok(view:get_col_x_offset(1, #"# Title #" + 1) < view:get_font():get_width("# Title #"))
  end)

  test.it("composes enclosing formatting with decoded links", function()
    local view, doc = make_view("**[Label](target.md)**\nplain", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local link
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text == "Label" then link = fragment end
    end
    link = test.not_nil(link)
    test.equal(link.color, style.markdown_live_link)
    test.equal(link.overdraw, true)
    test.equal(view:get_col_x_offset(1, #"**[Label](target.md)**" + 1), view:get_font():get_width("Label"))
  end)

  test.it("keeps heading metrics when only part of the line is commented", function()
    local view, doc = make_view("# Heading %%hidden%%\nplain", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    test.ok(view:get_visual_row_height(1) > view:get_line_height())
  end)

  test.it("renders wikilink aliases when inactive and raw syntax when active", function()
    local view, doc = make_view("See [[Note|Alias]]\nother", "note.md")
    doc:set_selection(1, 1)
    refresh(view)
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

    refresh(view)
    drawn, drawn_text = 0, {}
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

  test.it("invalidates every cached line sharing a completed image entry", function()
    local old_ensure_entry = markdown.images.ensure_entry
    local completion
    markdown.images.ensure_entry = function(_, opts)
      completion = opts.on_done
      return { status = "loading" }
    end
    local ok, err = pcall(function()
      local view, doc = make_view(
        "![A](shared.png)\n![B](shared.png)\nother", "note.md"
      )
      doc:set_selection(3, 1)
      refresh(view)
      view:get_line_render(1)
      view:get_line_render(2)
      local before = view:get_render_cache_diagnostics().line_invalidations
      test.not_nil(completion)
      completion(false, "not found")
      local after = view:get_render_cache_diagnostics().line_invalidations
      test.equal(after - before, 2)
    end)
    markdown.images.ensure_entry = old_ensure_entry
    if not ok then error(err, 0) end
  end)

  test.it("keeps image rows in the draw range when the source text is just off-screen", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-cull-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![[" .. image_url .. "]]\nnext", USERDIR .. PATHSEP .. "note.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    canvas.load_image = function()
      return {
        get_size = function() return 80, 80 end,
        scaled = function(self) return self end,
      }
    end

    refresh(view)
    view.scroll.y = view:get_visual_row_height(1) + style.padding.y + 1
    local minline = view:get_visible_line_range()
    test.equal(minline, 1)

    canvas.load_image = old_load_image
    os.remove(image_path)
  end)

  test.it("draws wrapped-mode image rows while only the rendered image is visible", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-wrapped-cull-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![[" .. image_url .. "]]\nnext", USERDIR .. PATHSEP .. "note.md")
    view:set_wrapping_enabled(true)
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    local old_draw_canvas = renderer.draw_canvas
    local old_draw_rect = renderer.draw_rect
    local drawn = 0
    canvas.load_image = function()
      return {
        get_size = function() return 80, 80 end,
        scaled = function(self) return self end,
      }
    end
    renderer.draw_canvas = function() drawn = drawn + 1 end
    renderer.draw_rect = function() end

    refresh(view)
    drawn = 0
    view.scroll.y = view:get_line_height() + style.padding.y + 1
    view.scroll.to.y = view.scroll.y
    local x, y = view:get_line_screen_position(1)
    view:draw_line_body(1, x, y)
    local final_drawn = drawn

    renderer.draw_rect = old_draw_rect
    renderer.draw_canvas = old_draw_canvas
    canvas.load_image = old_load_image
    os.remove(image_path)
    test.equal(final_drawn, 1)
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

    refresh(view)
    test.ok(view:get_visual_row_height(1) > 40)

    canvas.load_image = old_load_image
    os.remove(image_path)
    common.rm(root, true)
  end)

  test.it("clamps image overlay zoom to renderer-safe scaled dimensions", function()
    local overlay = require "core.markdown.image_overlay"
    local old_root_panel = core.root_panel
    local state = overlay.state
    local max_w, max_h = overlay.max_scaled_size()
    local scaled_called = false
    core.root_panel = {
      position = { x = 0, y = 0 },
      size = { x = 1920, y = 1080 },
    }
    state.visible = true
    state.image = {
      get_size = function() return 20000, 10000 end,
      scaled = function()
        scaled_called = true
      end,
    }
    state.scaled = nil
    state.scale = 100
    state.width, state.height = 0, 0
    state.scroll.x, state.scroll.y = 0, 0

    overlay.actual_size()
    local final_scale, final_w, final_h = state.scale, state.width, state.height
    overlay.close()
    core.root_panel = old_root_panel

    test.equal(scaled_called, false)
    test.ok(final_w <= max_w)
    test.ok(final_h <= max_h)
    test.ok(final_scale < 1)
  end)

  test.it("uses a hand cursor over clickable rendered images", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-hover-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![[" .. image_url .. "]]\nother", USERDIR .. PATHSEP .. "note.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end

    refresh(view)
    local x, y = view:get_line_screen_position(1)
    view:on_mouse_moved(x + 10, y + 10, 0, 0)
    local cursor = view.cursor

    canvas.load_image = old_load_image
    os.remove(image_path)
    test.equal(cursor, "hand")
  end)

  test.it("uses image overlay cursors for pan targets and outside areas", function()
    local overlay = require "core.markdown.image_overlay"
    local old_root_panel = core.root_panel
    local old_request_cursor = core.request_cursor
    local state = overlay.state
    local cursor
    core.root_panel = {
      position = { x = 0, y = 0 },
      size = { x = 500, y = 400 },
    }
    core.request_cursor = function(value) cursor = value end
    state.visible = true
    state.width = 100
    state.height = 100
    state.scroll.x = 0
    state.scroll.y = 0
    state.dragging = false

    overlay.on_mouse_moved(250, 200, 0, 0)
    local image_cursor = cursor
    overlay.on_mouse_moved(10, 10, 0, 0)
    local outside_cursor = cursor
    state.dragging = true
    overlay.on_mouse_moved(250, 200, 1, 1)
    local dragging_cursor = cursor
    overlay.close()

    core.request_cursor = old_request_cursor
    core.root_panel = old_root_panel
    test.equal(image_cursor, "crosshair")
    test.equal(outside_cursor, "arrow")
    test.equal(dragging_cursor, "hand")
  end)

  test.it("closes the image overlay when clicking outside the image", function()
    local overlay = require "core.markdown.image_overlay"
    local old_root_panel = core.root_panel
    local state = overlay.state
    core.root_panel = {
      position = { x = 0, y = 0 },
      size = { x = 500, y = 400 },
    }

    state.visible = true
    state.width = 100
    state.height = 100
    state.scroll.x = 0
    state.scroll.y = 0
    state.dragging = false
    overlay.on_mouse_pressed("left", 250, 200, 1)
    test.equal(state.visible, true)
    test.equal(state.dragging, true)
    overlay.on_mouse_released("left", 250, 200)

    state.visible = true
    state.dragging = false
    overlay.on_mouse_pressed("left", 10, 10, 1)
    test.equal(state.visible, false)
    test.equal(state.dragging, false)

    core.root_panel = old_root_panel
  end)

  test.it("opens the image overlay when clicking a rendered image", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-click-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, doc = make_view("![[" .. image_url .. "]]\nother", USERDIR .. PATHSEP .. "note.md")
    doc:set_selection(2, 1)
    local old_load_image = canvas.load_image
    local overlay = require "core.markdown.image_overlay"
    local old_open = overlay.open
    local opened_path
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    overlay.open = function(path)
      opened_path = path
      return true
    end

    refresh(view)
    local x, y = view:get_line_screen_position(1)
    test.ok(view:on_mouse_pressed("left", x + 10, y + 10, 1))
    test.equal(opened_path, image_path)
    local line = doc:get_selection()
    test.equal(line, 1)

    overlay.open = old_open
    canvas.load_image = old_load_image
    os.remove(image_path)
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

    refresh(view)
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

    refresh(view)
    test.equal(view:get_visual_row_height(1), view:get_line_height())

    canvas.load_image = old_load_image
    os.remove(image_path)
  end)

  test.it("honors disabled live image rendering", function()
    local old = config.markdown_live_render_images
    config.markdown_live_render_images = false
    local view, doc = make_view("![Alt](image.png)\nother", "note.md")
    doc:set_selection(2, 1)
    refresh(view)
    local link_width = view:get_font():get_width("Alt")
    test.equal(view:get_col_x_offset(1, #"![Alt](image.png)" + 1), link_width)
    config.markdown_live_render_images = old
  end)

  test.it("owns lifecycle independently for split views of one Document", function()
    local first, doc = make_view("# Title", "note.md")
    local second = DocView(doc)
    second.position.x, second.position.y = 0, 0
    second.size.x, second.size.y = 500, 200
    refresh(first)
    refresh(second)
    test.equal(first.__markdown_live_attached, true)
    test.equal(second.__markdown_live_attached, true)

    local closed = false
    first:try_close(function() closed = true end)
    test.equal(closed, true)
    test.equal(first.__markdown_live_owner, nil)
    test.equal(first.__markdown_live_attached, nil)
    test.not_nil(second.__markdown_live_owner)

    doc:set_filename("note.txt", "note.txt")
    test.equal(first.__markdown_live_attached, nil)
    test.equal(second.__markdown_live_attached, nil)
  end)

  test.it("releases owned lifecycle state when its Document closes", function()
    local view, doc = make_view("# Title", "note.md")
    refresh(view)
    test.not_nil(view.__markdown_live_owner)
    doc:on_close()
    test.equal(view.__markdown_live_owner, nil)
    test.equal(view.__markdown_live_attached, nil)
  end)

  test.it("automatically follows direct Document filename and syntax changes", function()
    local view, doc = make_view("# Title", "note.md")
    refresh(view)
    test.equal(view.__markdown_live_attached, true)

    doc:set_filename("note.txt", "note.txt")
    test.equal(view.__markdown_live_attached, nil)

    doc:set_filename("note.md", "note.md")
    test.equal(view.__markdown_live_attached, true)

    view.__markdown_live_image_cache = { ["image.png"] = { path = "old/image.png" } }
    doc:set_filename("moved/note.md", "moved/note.md")
    test.equal(view.__markdown_live_attached, true)
    test.equal(view.__markdown_live_image_cache, nil)
  end)
end)
