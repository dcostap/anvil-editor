local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_completion = require "core.markdown.completion"
local fence_highlight = require "core.markdown.fence_highlight"
local markdown_model = require "core.markdown.model"
local linewrapping = require "core.linewrapping"
local markdown_rename_links = require "core.markdown.rename_links"
local Project = require "core.project"
local style = require "core.style"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

require "plugins.drawwhitespace"
require "plugins.indent_guides"

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

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() and system.get_time() < deadline do
    coroutine.yield(0.01)
  end
  return predicate()
end

local test_buffer_id = 0
local function make_view(text, filename)
  test_buffer_id = test_buffer_id + 1
  local buffer
  if filename then
    local stem, extension = filename:match("^(.*)(%.[^./\\]+)$")
    local identity = (stem or filename) .. ".anvil-test-" .. test_buffer_id .. (extension or "")
    buffer = Buffer(filename, identity, true)
  else
    buffer = Buffer(nil, nil, true)
    buffer:set_filename("note.md", nil)
  end
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 200
  view:set_wrapping_enabled(false)
  return view, buffer
end

local function refresh(view)
  local result = markdown.live_render.refresh_view(view)
  local instance = markdown_model.peek(view.buffer)
  if instance then
    local deadline = system.get_time() + 5
    while instance.status ~= "ready" and system.get_time() < deadline do
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      if instance.status ~= "ready" then system.sleep(0.001) end
    end
    test.equal(instance.status, "ready", instance.reason)
    linewrapping.complete_async_reconstruction(view)
  end
  return result
end

local function live_body_font(view)
  local font = style.prose_font
  local size = view:get_font():get_size()
  return font:get_size() == size and font or font:copy(size)
end

local function with_inline_image_text_fixture(callback)
  local image_path = USERDIR .. PATHSEP .. "markdown-live-caret-rows-" .. system.get_process_id() .. ".png"
  local fp = test.not_nil(io.open(image_path, "wb"))
  fp:write("png")
  fp:close()
  local image_url = common.basename and common.basename(image_path)
    or image_path:match("[^" .. PATHSEP .. "]+$")
  local prefix, image_source, suffix = "aaaa ", "![[" .. image_url .. "]]", " Testing this change"
  local source = prefix .. image_source .. suffix
  local image_end = #prefix + #image_source + 1
  local view, buffer = make_view(source .. "\nnext", USERDIR .. PATHSEP .. "caret-rows-note.md")
  view:set_wrapping_enabled(true)
  buffer:set_selection(2, 1)

  local old_load_image = canvas.load_image
  canvas.load_image = function()
    return {
      get_size = function() return 320, 240 end,
      scaled = function(self) return self end,
    }
  end
  local ok, err = pcall(function()
    refresh(view)
    callback(view, buffer, {
      source = source,
      image_end = image_end,
      suffix = suffix,
    })
  end)
  canvas.load_image = old_load_image
  os.remove(image_path)
  if not ok then error(err, 0) end
end

local function visible_render_text(view, line)
  local rendered = test.not_nil(view:get_line_render(line))
  local visible = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(rendered)) do
    if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
  end
  return table.concat(visible)
end

local function collect_render_fragments(view, line)
  local render_line = test.not_nil(view:get_line_render(line))
  local fragments = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
    fragments[#fragments + 1] = fragment
  end
  return render_line, fragments
end

local function fragment_shape(fragments)
  local shape = {}
  for _, fragment in ipairs(fragments) do
    shape[#shape + 1] = {
      source_col1 = fragment.source_col1,
      source_col2 = fragment.source_col2,
      text = fragment.text,
      hidden = fragment.hidden,
      text_source_col1 = fragment.text_source_col1,
      text_source_col2 = fragment.text_source_col2,
      link = fragment.link ~= nil,
    }
  end
  return shape
end

local function is_utf8_boundary(text, col)
  if col <= 1 or col > #text then return true end
  local byte = text:byte(col)
  return byte < 0x80 or byte >= 0xC0
end

test.describe("Markdown Live Preview", function()
  test.before_each(function(context)
    context.old_markdown_live_editor = config.markdown_live_editor
    context.old_markdown_live_interactive_tables = config.markdown_live_interactive_tables
    config.markdown_live_editor = true
  end)

  test.after_each(function(context)
    config.markdown_live_editor = context.old_markdown_live_editor
    config.markdown_live_interactive_tables = context.old_markdown_live_interactive_tables
  end)

  test.it("attaches only to Markdown Editors", function()
    local md = make_view("# Title", "note.md")
    local txt = make_view("# Title", "note.txt")
    test.equal(refresh(md), true)
    test.equal(md.__markdown_live_attached, true)
    refresh(txt)
    test.equal(txt.__markdown_live_attached, nil)
  end)

  test.it("hides gutter line numbers in Live Preview", function()
    local view, buffer = make_view("one\ntwo\nthree\nfour", "sparse-gutter.md")
    buffer:set_selections(1, 2, 1, 1, 1)
    buffer:set_selections(2, 4, 1, 4, 1, nil, 0)
    refresh(view)

    local old_show_line_numbers = config.show_line_numbers
    local old_draw_text = common.draw_text
    config.show_line_numbers = true
    local drawn = {}
    common.draw_text = function(_, _, text)
      drawn[#drawn + 1] = tostring(text)
    end
    local ok, err = pcall(function()
      local width = view:get_gutter_width()
      for line = 1, 4 do
        view:draw_line_gutter(line, 0, 0, width)
      end
      test.same(drawn, {})

      markdown.live_render.set_source_mode(view, true, "test-sparse-gutter")
      drawn = {}
      for line = 1, 4 do
        view:draw_line_gutter(line, 0, 0, width)
      end
      test.same(drawn, { "1", "2", "3", "4" })
    end)
    common.draw_text = old_draw_text
    config.show_line_numbers = old_show_line_numbers
    if not ok then error(err, 0) end
  end)

  test.it("toggles and persists view-local Source Mode without moving editor state", function()
    local view, buffer = make_view(
      "# Title\n[[folder/with/a/very/long/target/name/that/keeps/going/for/horizontal/scrolling/example|A]]\nplain", "note.md"
    )
    buffer:set_selection(3, 1)
    refresh(view)
    view.scroll.x, view.scroll.to.x = 7, 7
    view.scroll.y, view.scroll.to.y = 11, 11
    local selection = view:get_selection_state()
    local live_width = view:get_h_scrollable_size()
    local old_active = core.active_view
    core.active_view = view

    test.equal(command.perform("markdown-live-preview:source-mode"), true)
    test.equal(markdown.live_render.is_source_mode(view), true)
    test.equal(view:get_line_render(1), nil)
    test.equal(view:get_line_render(2), nil)
    test.same(view:get_selection_state().selections, selection.selections)
    test.equal(view.scroll.y, 11)
    test.ok(
      wait_until(function()
        return view:get_h_scrollable_size() > live_width
      end),
      "expected Source Mode horizontal extent scan to complete"
    )
    local feature_state = test.not_nil(view:get_state().owned_features)

    local split = Editor(buffer)
    split.size.x, split.size.y = 500, 200
    split:set_wrapping_enabled(false)
    refresh(split)
    test.equal(markdown.live_render.is_source_mode(split), false)
    test.equal(split:get_h_scrollable_size(), live_width)
    split:restore_owned_feature_state(feature_state)
    test.equal(markdown.live_render.is_source_mode(split), true)
    test.equal(split:get_line_render(1), nil)

    test.equal(command.perform("markdown-live-preview:live-mode"), true)
    test.equal(markdown.live_render.is_source_mode(view), false)
    test.not_nil(view:get_line_render(1))
    core.active_view = old_active
  end)

  test.it("keeps formatted source presentation while the first semantic snapshot is pending", function()
    local view = make_view("# Title\n**bold**", "note.md")
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(view.buffer))
    test.equal(instance.status, "pending")
    test.equal(visible_render_text(view, 1), "Title")
    test.equal(visible_render_text(view, 2), "bold")
    test.equal(view:get_line_render(1).markdown_provenance, "unavailable")
    test.equal(view:get_line_render(2).markdown_provenance, "unavailable")
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.not_nil(view:get_line_render(1))
    test.not_nil(view:get_line_render(2))
  end)

  test.it("keeps an edited formatted paragraph rendered while semantics are pending", function()
    local view, buffer = make_view("Before **bold** after\nplain", "pending-edit.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local instance = test.not_nil(markdown_model.peek(buffer))

    buffer:set_selection(1, #buffer.lines[1])
    test.equal(visible_render_text(view, 1), "Before bold after")
    view:on_text_input("!")
    test.equal(instance.status, "pending")
    test.equal(visible_render_text(view, 1), "Before bold after!")

    view:on_text_input("?")
    test.equal(instance.status, "pending")
    test.not_nil(view:get_line_render(1))
    test.equal(visible_render_text(view, 1), "Before bold after!?")
  end)

  test.it("uses current-source presentation and atomically adopts wrapping after reload", function()
    local path = USERDIR .. PATHSEP .. "markdown-live-external-reload-"
      .. tostring(system.get_process_id()) .. ".md"
    local function write(text)
      local fp = test.not_nil(io.open(path, "wb"))
      fp:write(text)
      fp:close()
    end
    local function fixture(prefix, repetitions)
      local lines = {
        "# " .. prefix .. " heading",
        "- [ ] " .. prefix .. " task",
        "**" .. prefix .. " text**",
      }
      for index = 1, 180 do
        lines[#lines + 1] = "- [ ] stable "
          .. string.rep("wrapped content ", repetitions) .. tostring(index)
      end
      return table.concat(lines, "\n") .. "\n"
    end
    write(fixture("Old", 10))
    local buffer = Buffer("markdown-live-external-reload.md", path)
    local view = Editor(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 300, 200
    view:set_wrapping_enabled(true)
    buffer:set_selection(#buffer.lines, 1)
    refresh(view)
    local old_stable_row = view:get_visual_row(100, 1)

    write(fixture("New", 2))
    buffer:load(path)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(view:get_visual_row(100, 1), old_stable_row)
    local line1 = test.not_nil(view:get_line_render(1))
    local line2 = test.not_nil(view:get_line_render(2))
    local line3 = test.not_nil(view:get_line_render(3))
    test.equal(instance.status, "pending")
    test.equal(line1.raw_passthrough, nil)
    test.equal(line2.raw_passthrough, nil)
    test.equal(line3.raw_passthrough, nil)
    test.equal(visible_render_text(view, 1), "New heading")
    test.equal(visible_render_text(view, 2), "New task")
    test.equal(visible_render_text(view, 3), "New text")

    test.ok(wait_status(instance, "ready"), instance.reason)
    linewrapping.complete_async_reconstruction(view)
    test.not_equal(view:get_visual_row(100, 1), old_stable_row)
    os.remove(path)
  end)

  test.it("does not apply pre-reload semantics to unchanged text in a new fence", function()
    local path = USERDIR .. PATHSEP .. "markdown-live-reload-context-"
      .. tostring(system.get_process_id()) .. ".md"
    local function write(text)
      local fp = test.not_nil(io.open(path, "wb"))
      fp:write(text)
      fp:close()
    end
    write("before\nsame body\nafter\n")
    local buffer = Buffer("markdown-live-reload-context.md", path)
    local view = Editor(buffer)
    refresh(view)
    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then
        markdown_decoration = entry.provider
        break
      end
    end

    write("```lua\nsame body\n```\n")
    buffer:load(path)

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    local render = test.not_nil(view:get_line_render(2))
    test.equal(render.source_text, "same body")
    test.equal(render.markdown_buffer_revision, buffer.text_revision)
    test.not_nil(render.x_offset)
    test.equal(
      test.not_nil(markdown_decoration):line_background(view, 2),
      style.markdown_live_code_background
    )
    test.equal(markdown_decoration:line_background(view, 4), nil)

    buffer:insert(2, #(buffer.lines[2] or ""), "!")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(test.not_nil(view:get_line_render(2)).source_text, "same body!")
    test.equal(
      markdown_decoration:line_background(view, 2),
      style.markdown_live_code_background
    )
    test.equal(markdown_decoration:line_background(view, 4), nil)
    os.remove(path)
  end)

  test.it("presents a newly completed highlight without a raw-source frame", function()
    local view, buffer = make_view("mark\nplain", "pending-highlight.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:apply_edits({
      { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "==" },
      { line1 = 1, col1 = 5, line2 = 1, col2 = 5, text = "==" },
    }, { type = "highlight", merge_cursors = false })

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "mark")
    local pending = test.not_nil(view:get_line_render(1))
    test.equal(pending.source_text, "==mark==")
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 1), "mark")
  end)

  test.it("presents a newly completed Markdown link without a raw-source frame", function()
    local view, buffer = make_view("Alias\nplain", "pending-link.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:apply_edits({
      { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "[" },
      { line1 = 1, col1 = 6, line2 = 1, col2 = 6, text = "](Target.md)" },
    }, { type = "link", merge_cursors = false })

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "Alias")
    local pending = test.not_nil(view:get_line_render(1))
    test.equal(pending.source_text, "[Alias](Target.md)")
    for _, fragment in ipairs(pending.fragments or {}) do
      test.equal(fragment.on_mouse_pressed, nil)
    end
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 1), "Alias")
  end)

  test.it("reprojects references before a removed definition while pending", function()
    local view, buffer = make_view(
      "[Alias][ref]\n\n[ref]: Target.md\nplain",
      "pending-reference-definition.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)
    test.ok(wait_until(function()
      return visible_render_text(view, 1) == "Alias"
    end, 5))
    test.equal(visible_render_text(view, 1), "Alias")

    buffer:remove(3, 1, 3, #buffer.lines[3])

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "[Alias][ref]")
    local pending = test.not_nil(view:get_line_render(1))
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
    for _, fragment in ipairs(pending.fragments or {}) do
      test.equal(fragment.on_mouse_pressed, nil)
    end
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 1), "[Alias][ref]")
  end)

  test.it("hides a newly completed inline comment while semantics are pending", function()
    local view, buffer = make_view("before hidden after\nplain", "pending-comment.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:apply_edits({
      { line1 = 1, col1 = 8, line2 = 1, col2 = 8, text = "%%" },
      { line1 = 1, col1 = 14, line2 = 1, col2 = 14, text = "%%" },
    }, { type = "comment", merge_cursors = false })

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "before  after")
    local pending = test.not_nil(view:get_line_render(1))
    test.equal(pending.source_text, "before %%hidden%% after")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 1), "before  after")
  end)

  test.it("presents a newly created blockquote without a raw-source frame", function()
    local view, buffer = make_view("body\nplain", "pending-blockquote.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:insert(1, 1, "> ")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "│ body")
    local pending = test.not_nil(view:get_line_render(1))
    test.equal(pending.source_text, "> body")
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 1), "│ body")
  end)

  test.it("presents a newly created callout without a raw-source frame", function()
    local view, buffer = make_view("Title\nplain", "pending-callout.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:insert(1, 1, "> [!note]+ ")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.ok(visible_render_text(view, 1):find("Title", 1, true) ~= nil)
    local pending = test.not_nil(view:get_line_render(1))
    test.equal(pending.source_text, "> [!note]+ Title")
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(visible_render_text(view, 1):find("Title", 1, true) ~= nil)
  end)

  test.it("presents a newly completed thematic break without a raw-source frame", function()
    local view, buffer = make_view("body\n\n**\nplain", "pending-rule.md")
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:insert(3, 3, "*")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    local pending = test.not_nil(view:get_line_render(3))
    test.equal(visible_render_text(view, 3), "────────────────")
    test.equal(pending.source_text, "***")
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 3), "────────────────")
  end)

  test.it("reprojects a newly created Setext heading while semantics are pending", function()
    local view, buffer = make_view("Title\n\nplain", "pending-setext.md")
    buffer:set_selection(3, 1)
    refresh(view)

    buffer:insert(2, 1, "=")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    local pending_title = test.not_nil(view:get_line_render(1))
    test.ok(pending_title.markdown_provenance ~= "retained")
    test.equal(visible_render_text(view, 1), "Title")
    test.equal(visible_render_text(view, 2), "")
    local pending_font = test.not_nil(pending_title.fragments[1].font)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    local current_title = test.not_nil(view:get_line_render(1))
    test.equal(current_title.markdown_provenance, "current")
    test.equal(current_title.fragments[1].font:get_size(), pending_font:get_size())
  end)

  test.it("captures current presentation before an edit even after selection invalidation", function()
    local view, buffer = make_view("Before **bold** after\nplain", "pending-pre-edit.md")
    buffer:set_selection(2, 1)
    refresh(view)
    test.equal(visible_render_text(view, 1), "Before bold after")

    buffer:set_selection(1, #buffer.lines[1])
    view:on_text_input("!")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "Before bold after!")
  end)

  test.it("keeps revealed inline syntax stable while typing inside it", function()
    local view, buffer = make_view("Before **bold** after\nplain", "pending-inline-edit.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local instance = test.not_nil(markdown_model.peek(buffer))

    buffer:set_selection(1, 11)
    test.equal(visible_render_text(view, 1), "Before **bold** after")
    view:on_text_input("X")
    test.equal(instance.status, "pending")
    test.equal(visible_render_text(view, 1), "Before **bXold** after")
  end)

  test.it("retains rendered paragraphs and shifted resident rows while inserting a line", function()
    local view, buffer = make_view("Before **bold** after\n# Following\nplain", "pending-line-split.md")
    buffer:set_selection(3, 1)
    refresh(view)
    test.equal(visible_render_text(view, 1), "Before bold after")
    test.equal(visible_render_text(view, 2), "Following")

    buffer:set_selection(1, #buffer.lines[1])
    test.equal(visible_render_text(view, 1), "Before bold after")
    view:on_text_input("\n")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "Before bold after")
    test.equal(visible_render_text(view, 2), "")
    test.equal(visible_render_text(view, 3), "Following")
  end)

  test.it("keeps a plain heading raw while its title is selected", function()
    local source = "## Resultados"
    local view, buffer = make_view("body\n" .. source .. "\nplain", "heading-selection.md")
    buffer:set_selection(3, 1)
    refresh(view)

    buffer:set_selection(2, 4, 2, #source + 1)
    test.equal(visible_render_text(view, 2), source)
  end)

  test.it("adopts published heading and inline semantic identities", function()
    local view, buffer = make_view("# **Title**\nText with ***bold***.\nplain", "note.md")
    buffer:set_selection(3, 1)
    refresh(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
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

    local heading_id = heading.semantic_id
    local generation_before = instance.generation
    buffer:insert(2, #buffer.lines[2], "!")
    test.equal(test.not_nil(view:get_line_render(1)).semantic_id, heading_id)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(instance.generation > generation_before)
    test.equal(test.not_nil(view:get_line_render(1)).semantic_id, heading_id)
    test.equal(view:get_line_render(2).semantic_generation, instance.generation)
  end)

  test.it("re-adopts suffix semantics after structural edits rendered while pending", function()
    local view, buffer = make_view("# A\nbody\n# B\nplain", "note.md")
    buffer:set_selection(4, 1)
    refresh(view)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.not_nil(view:get_line_render(3).semantic_id)

    local previous_generation = instance.generation
    buffer:insert(1, 1, "inserted\n")
    local pending = test.not_nil(view:get_line_render(4))
    test.equal(pending.source_text, "# B")
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
    test.ok(pending.markdown_provenance ~= "current")
    local split = Editor(buffer)
    split.size.x, split.size.y = 500, 200
    split:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(split)
    test.equal(visible_render_text(split, 4), "B")
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
    local view, buffer = make_view(source, "note.md")
    view.size.x = 500
    view:set_wrapping_enabled(true)
    buffer:set_selection(4, 1)
    refresh(view)
    test.equal(visible_render_text(view, 2), "# [[" .. target .. "|Alias]] after")
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
    buffer:remove(1, 1, 1, 4)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    local heading = test.not_nil(view:get_line_render(2))
    test.equal(heading.raw_passthrough, nil)
    test.ok(#(heading.fragments or {}) > 0)
    local rendered_breaks = break_signature()
    test.ok(rendered_breaks ~= raw_breaks, raw_breaks .. " -> " .. rendered_breaks)
    buffer:raw_insert(1, 1, "```", buffer.undo_stack, system.get_time())
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 2), "# [[" .. target .. "|Alias]] after")
    test.equal(break_signature(), raw_breaks)
  end)

  test.it("renders core emphasis families directly from semantic nodes", function()
    local view, buffer = make_view("**bold** *italic* ***both*** ~~strike~~\nplain", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local render_line = test.not_nil(view:get_line_render(1))
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
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local seen = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text and fragment.text ~= "" then seen[fragment.text] = fragment end
    end
    test.not_nil(seen.bold)
    test.not_nil(seen.italic)
    test.not_nil(seen.inner)
    test.not_nil(seen.bold.background)
    test.not_nil(seen.italic.background)
  end)

  test.it("preserves enclosing formatting across escapes and comments", function()
    local source = "**bold \\* literal** and **before %%hide%% after**\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local seen = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text and fragment.text ~= "" then seen[fragment.text] = fragment end
    end
    test.not_nil(seen["*"])
    local before, after
    for text, fragment in pairs(seen) do
      if text:find("before", 1, true) then before = fragment end
      if text:find("after", 1, true) then after = fragment end
    end
    test.not_nil(before)
    test.not_nil(after)
    test.equal(seen.hide, nil)
  end)

  test.it("refreshes every cached line of a multiline comment when delimiters change", function()
    local view, buffer = make_view("%%hide\nstill hidden%%\nplain", "note.md")
    buffer:set_selection(3, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"still hidden%%" + 1), 0)
    buffer:remove(1, 1, 1, 2)
    test.equal(visible_render_text(view, 2), "still hidden%%")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(
      view:get_col_x_offset(2, #"still hidden%%" + 1),
      live_body_font(view):get_width("still hidden%%")
    )
  end)

  test.it("refreshes multiline comments when ordinary edits form delimiters", function()
    local view, buffer = make_view("before %x%\nsecret\n%%\nplain", "note.md")
    buffer:set_selection(4, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"secret" + 1), live_body_font(view):get_width("secret"))
    buffer:remove(1, 9, 1, 10)
    test.equal(visible_render_text(view, 2), "")
    test.equal(view:get_col_x_offset(2, #"secret" + 1), 0)
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(view:get_col_x_offset(2, #"secret" + 1), 0)
  end)

  test.it("lets a newly formed comment own fence-looking lines while pending", function()
    local view, buffer = make_view("%x%\n```\n# hidden\n```\n%%\nplain", "pending-comment-fence.md")
    buffer:set_selection(6, 1)
    refresh(view)

    buffer:remove(1, 2, 1, 3)

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 2), "")
    test.equal(visible_render_text(view, 3), "")
    test.equal(visible_render_text(view, 4), "")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 3), "")
  end)

  test.it("does not form provisional comments inside fenced code", function()
    local view, buffer = make_view("```\nprint('%x%')\n```\nplain", "pending-fence-comment.md")
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:remove(2, 9, 2, 10)

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 2), "print('%%')")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 2), "print('%%')")
  end)

  test.it("does not extend provisional comments from inline code spans", function()
    local view, buffer = make_view("`value %x%` after\nplain", "pending-code-comment.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:remove(1, 9, 1, 10)

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 1), "value %% after")
    test.equal(visible_render_text(view, 2), "plain")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 2), "plain")
  end)

  test.it("does not form provisional comments inside display math", function()
    local view, buffer = make_view("$$\nvalue %x%\n$$\nplain", "pending-math-comment.md")
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:remove(2, 8, 2, 9)

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 2), "value %%")
    test.equal(visible_render_text(view, 4), "plain")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 4), "plain")
  end)

  test.it("keeps a wrapped suffix rendered while typing after a literal percentage", function()
    local paragraph = string.rep("wrapped prose ", 20)
      .. "realmente estaba el 99% hecho"
    local view, buffer = make_view(
      paragraph .. "\n## Following heading\n**following bold text**\nplain",
      "literal-percentage.md"
    )
    view.size.x = 360
    view:set_wrapping_enabled(true)
    buffer:set_selection(4, 1)
    refresh(view)
    buffer:set_selection(1, #buffer.lines[1])

    view:on_text_input("!")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 2), "Following heading")
    test.equal(visible_render_text(view, 3), "following bold text")

    view:on_text_input("?")
    test.equal(visible_render_text(view, 2), "Following heading")
    test.equal(visible_render_text(view, 3), "following bold text")
  end)

  test.it("invalidates comment-dependent suffix rendering when a delimiter is broken", function()
    local view, buffer = make_view("before %%hidden\nsecret\nend%%\n# after", "note.md")
    buffer:set_selection(4, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"secret" + 1), 0)

    buffer:insert(1, 9, "x")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 2), "secret")
  end)

  test.it("keeps a fenced suffix rendered while editing only the info string", function()
    local view, buffer = make_view("```lua\n# code\n```\n## Following heading\nplain", "note.md")
    buffer:set_selection(5, 1)
    refresh(view)
    buffer:set_selection(1, #buffer.lines[1])

    view:on_text_input("x")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 4), "Following heading")
  end)

  test.it("invalidates fence-dependent suffix rendering when an opener is broken", function()
    local view, buffer = make_view("```\n# code\n```\n# after", "note.md")
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:insert(1, 1, "x")
    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(visible_render_text(view, 2), "code")
  end)

  test.it("applies semantic comments and escapes inside headings", function()
    local view, buffer = make_view("# visible %%hidden%% \\*literal*\nplain", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "visible  *literal*")
  end)

  test.it("expands active headings to editable rendered Markdown syntax", function()
    local view, buffer = make_view("## Title ##", "note.md")
    refresh(view)
    buffer:set_selection(1, 5)
    test.equal(visible_render_text(view, 1), "## Title ##")
  end)

  test.it("reveals every multi-cursor line without expanding lines between them", function()
    local view, buffer = make_view("## One\n## Two\n## Three", "note.md")
    refresh(view)
    buffer:set_selections(1, 1, 4, 1, 4)
    buffer:set_selections(2, 3, 4, 3, 4, nil, 0)

    test.equal(visible_render_text(view, 1), "## One")
    test.equal(visible_render_text(view, 2), "Two")
    test.equal(visible_render_text(view, 3), "## Three")
  end)

  test.it("freezes rendered layout for the lifetime of IME composition", function()
    local view, buffer = make_view("## Title\nbody", "note.md")
    refresh(view)
    buffer:set_selection(1, 4)
    view:on_ime_text_editing("x", 0, 0)
    test.not_nil(view.__line_render_interaction_state)
    test.equal(view.__line_render_interaction_state.reason, "ime-composition")
    view:on_ime_text_editing("", 0, 0)
    test.equal(view.__line_render_interaction_state, nil)
  end)

  test.it("does not live-render Markdown syntax inside code blocks", function()
    local view, buffer = make_view("```\n# Not Heading\n**not bold**\n``` not closing\n# Still Not Heading\n```\n# Heading\n", "note.md")
    buffer:set_selection(7, 1)
    refresh(view)
    test.equal(visible_render_text(view, 2), "# Not Heading")
    test.equal(visible_render_text(view, 3), "**not bold**")
    test.equal(visible_render_text(view, 5), "# Still Not Heading")
    test.equal(visible_render_text(view, 7), "# Heading")
  end)

  test.it("renders emphasis inside heading content", function()
    local view, buffer = make_view("## A **bold** and *italic* Heading\nbody", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local render_line = view:get_line_render(1)
    test.not_nil(render_line)
    local seen = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      seen[fragment.text or ""] = fragment
    end
    test.not_nil(seen.bold)
    test.not_nil(seen.italic)
    test.ok(seen["**"] == nil)
    test.ok(seen["*"] == nil)
  end)

  test.it("keeps an inline construct rendered when the caret is elsewhere on its line", function()
    local view, buffer = make_view("See [[Note|Alias]]", "note.md")
    refresh(view)
    buffer:set_selection(1, 1)
    test.equal(visible_render_text(view, 1), "See Alias")
    test.equal(
      view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1),
      live_body_font(view):get_width("See Alias")
    )
  end)

  test.it("reveals emphasis syntax only while the caret is within that construct", function()
    local source = "before **bold** after *italic* tail\nplain"
    local view, buffer = make_view(source, "localized-emphasis.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local inactive_width = view:get_col_x_offset(1, #(source:match("[^\n]+")) + 1)

    buffer:set_selection(1, 2)
    test.equal(visible_render_text(view, 1), "before bold after italic tail")
    test.equal(view:get_col_x_offset(1, #(source:match("[^\n]+")) + 1), inactive_width)

    buffer:set_selection(1, 11)
    test.equal(visible_render_text(view, 1), "before **bold** after italic tail")

    buffer:set_selection(1, 18)
    test.equal(visible_render_text(view, 1), "before bold after italic tail")
  end)

  test.it("reveals inline construct source at the caret position after its closing delimiter", function()
    local cases = {
      { source = "**bold**", inactive = "bold" },
      { source = "*italic*", inactive = "italic" },
      { source = "`code`", inactive = "code" },
      { source = "==mark==", inactive = "mark" },
      { source = "~~gone~~", inactive = "gone" },
      { source = "\\*", inactive = "*" },
      { source = "%%hidden%%", inactive = "" },
    }
    local lines = {}
    for _, case in ipairs(cases) do lines[#lines + 1] = case.source end
    lines[#lines + 1] = "plain"
    local view, buffer = make_view(table.concat(lines, "\n"), "right-edge-inline.md")
    buffer:set_selection(#lines, 1)
    refresh(view)

    for line, case in ipairs(cases) do
      test.equal(visible_render_text(view, line), case.inactive)
      buffer:set_selection(line, #case.source + 1)
      test.equal(visible_render_text(view, line), case.source)
    end
  end)

  test.it("reveals only constructs intersected by a nonempty selection", function()
    local view, buffer = make_view("- before **bold** after *italic*\nplain", "localized-selection.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:set_selection(1, 3, 1, 9)
    test.equal(visible_render_text(view, 1), "before bold after italic")
    local body_bullet
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.unordered_list_marker then body_bullet = fragment break end
    end
    test.not_nil(test.not_nil(body_bullet).widget)

    buffer:set_selection(1, 12, 1, 16)
    test.equal(visible_render_text(view, 1), "before **bold** after italic")
    local bold_bullet
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.unordered_list_marker then bold_bullet = fragment break end
    end
    test.not_nil(test.not_nil(bold_bullet).widget)

    buffer:set_selection(1, 1, 1, 2)
    test.equal(visible_render_text(view, 1), "- before bold after italic")
  end)

  test.it("expands active-line emphasis syntax before caret movement crosses spans", function()
    local view, buffer = make_view("This is **bold** and **more**\nnext", "note.md")
    buffer:set_selection(1, 11)
    refresh(view)
    local render_line = view:get_line_render(1)
    test.not_nil(render_line)
    local texts = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      if not fragment.hidden then texts[#texts + 1] = fragment.text or "" end
    end
    test.same({ "This is ", "**", "bold", "**", " and ", "more" }, texts)
  end)

  test.it("reveals only the caret's link construct on a mixed line", function()
    local source = "See [[One|First]] and [[Two|Second]]\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(1, 9)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(1))) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "See [[One|First]] and Second")
  end)

  test.it("preserves UTF-8 link source mappings across reveal transitions", function()
    local label = "éλ漢"
    local prefix, suffix = "See ", " now"
    local target = "folder/target"
    local source = prefix .. "[" .. label .. "](" .. target .. ")" .. suffix
    local buffer_text = source .. "\nnext"
    local expected_buffer_text = buffer_text .. "\n"
    local view, buffer = make_view(buffer_text, "utf8-link-boundaries.md")
    local label_col1 = test.not_nil(source:find(label, 1, true))
    local link_col1 = test.not_nil(source:find("[", 1, true))
    local link_col2 = test.not_nil(source:find(")", link_col1, true)) + 1
    local original_revision = buffer.text_revision
    local old_active = core.active_view
    core.active_view = view

    local function snapshot()
      local render_line, fragments = collect_render_fragments(view, 1)
      local cursor, link
      cursor = 1
      for _, fragment in ipairs(fragments) do
        test.equal(fragment.source_col1, cursor)
        test.ok(fragment.source_col2 >= fragment.source_col1)
        cursor = math.max(cursor, fragment.source_col2)
        if fragment.link and fragment.text == label then link = fragment end
      end
      test.equal(cursor, #source + 1)
      return render_line, fragments, test.not_nil(link)
    end

    local ok, err = pcall(function()
      buffer:set_selection(1, label_col1)
      refresh(view)
      test.equal(table.concat(buffer.lines), expected_buffer_text)
      test.equal(#buffer.lines, 2)
      test.equal(buffer.lines[1], source .. "\n")
      test.equal(buffer.lines[2], "next\n")
      test.equal(buffer.text_revision, original_revision)
      test.equal(test.not_nil(view:get_line_render(1)).source_text, source)
      test.equal(test.not_nil(view:get_line_render(2)).source_text, "next")

      local active_render, active_fragments, active_link = snapshot()
      test.equal(active_render.source_text, source)
      test.equal(active_link.source_col1, label_col1)
      test.equal(active_link.source_col2, label_col1 + #label)
      test.equal(active_link.text_source_col1, nil)
      test.equal(active_link.text_source_col2, nil)
      local active_shape = fragment_shape(active_fragments)

      buffer:set_selection(1, link_col2)
      local right_line, right_fragments, right_link = snapshot()
      test.equal(buffer:get_selection(), 1)
      local _, right_col = buffer:get_selection()
      test.equal(right_col, link_col2)
      test.equal(right_line.source_text, source)
      test.equal(visible_render_text(view, 1), source)
      test.same(active_shape, fragment_shape(right_fragments))
      test.equal(right_link.source_col1, label_col1)
      test.equal(right_link.source_col2, label_col1 + #label)

      buffer:set_selection(2, 1)
      local inactive_line, _, inactive_link = snapshot()
      test.equal(inactive_line.source_text, source)
      test.equal(visible_render_text(view, 1), prefix .. label .. suffix)
      test.equal(inactive_link.source_col1, link_col1)
      test.equal(inactive_link.source_col2, link_col2)
      test.equal(inactive_link.text_source_col1, label_col1)
      test.equal(inactive_link.text_source_col2, label_col1 + #label)

      buffer:set_selection(1, label_col1)
      local reentered_line, reentered_fragments, reentered_link = snapshot()
      test.equal(reentered_line.source_text, source)
      test.equal(visible_render_text(view, 1), source)
      test.same(active_shape, fragment_shape(reentered_fragments))
      test.equal(reentered_link.source_col1, label_col1)
      test.equal(reentered_link.source_col2, label_col1 + #label)

      local line, col = buffer:get_selection()
      test.equal(line, 1)
      test.equal(col, label_col1)
      test.equal(table.concat(buffer.lines), expected_buffer_text)
      test.equal(buffer.text_revision, original_revision)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("maps wrapped UTF-8 link rows to source byte boundaries", function()
    local label = "éλ漢"
    local target = ("folder/segment/"):rep(4) .. "target"
    local source = "See [" .. label .. "](" .. target .. ") after"
    local view, buffer = make_view(source .. "\nnext\n", "wrapped-utf8-link.md")
    view.size.x = 170
    view:set_wrapping_enabled(true)
    local label_col1 = test.not_nil(source:find(label, 1, true))
    local old_active = core.active_view
    core.active_view = view

    local ok, err = pcall(function()
      buffer:set_selection(1, label_col1)
      refresh(view)
      local render_line = test.not_nil(view:get_line_render(1))
      test.equal(render_line.source_text, source)

      local first_idx, _, row_count, first_col =
        linewrapping.get_line_idx_col_count(view, 1, 1)
      test.equal(first_col, 1)
      test.ok(row_count >= 2, "expected the link source to wrap into multiple rows")

      local starts, ends = {}, {}
      for offset = 0, row_count - 1 do
        local idx = first_idx + offset
        local line, start_col = linewrapping.get_idx_line_col(view, idx)
        local end_col = linewrapping.get_idx_visual_end_col(view, idx, 1)
        test.equal(line, 1)
        test.ok(end_col > start_col)
        test.ok(is_utf8_boundary(source, start_col), "wrapped row split inside UTF-8")
        test.ok(is_utf8_boundary(source, end_col), "wrapped row ended inside UTF-8")
        starts[#starts + 1] = start_col
        ends[#ends + 1] = end_col
      end
      test.equal(starts[1], 1)
      for index = 2, #starts do test.equal(starts[index], ends[index - 1]) end
      test.equal(ends[#ends], #source + 1)

      local function round_trip(idx, col)
        local x = view:get_col_x_offset(1, col)
        local hit_line, hit_col = linewrapping.get_line_col_from_index_and_x(view, idx, x)
        test.equal(hit_line, 1)
        test.equal(hit_col, col)
      end
      round_trip(first_idx, starts[1])
      round_trip(first_idx + row_count - 1, starts[#starts])
      round_trip(first_idx + row_count - 1, ends[#ends])
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("reserves the indicator lane for ordinary prose soft wraps", function()
    local wrapping = config.plugins.linewrapping
    local old = {
      indent = wrapping.indent,
      wrapping_indent = wrapping.wrapping_indent,
      width_override = wrapping.width_override,
    }
    local view = make_view(
      string.rep("ordinary rendered Markdown prose ", 16),
      "wrapped-prose-indent.md"
    )
    wrapping.indent = true
    wrapping.wrapping_indent = 6
    wrapping.width_override = view:get_font():get_width(string.rep("x", 36))
    view:set_wrapping_enabled(true)

    local ok, err = pcall(function()
      refresh(view)
      local _, _, rows = linewrapping.get_line_idx_col_count(view, 1)
      test.ok(rows > 1, "expected a wrapped Markdown prose fixture")
      local offset = view.wrapped_line_offsets[1] or 0
      local indicator_width = style.soft_wrap_indicator_font:get_width(
        wrapping.continuation_indicator .. " "
      )
      test.ok(offset >= indicator_width, "expected the soft-wrap indicator lane")
    end)
    wrapping.indent = old.indent
    wrapping.wrapping_indent = old.wrapping_indent
    wrapping.width_override = old.width_override
    if not ok then error(err, 0) end
  end)

  test.it("captures visible presentation before a structural edit when render caches are cold", function()
    local lines = { "# Heading", "", "Before **bold** after", "", "## Following" }
    for i = 1, 80 do lines[#lines + 1] = "plain line " .. i end
    local view, buffer = make_view(table.concat(lines, "\n"), "cold-structural-presentation.md")
    view.size.y = 1200
    view:set_wrapping_enabled(false)
    buffer:set_selection(3, #buffer.lines[3])
    refresh(view)
    view:invalidate_line_render("cold-structural-regression")
    view:invalidate_visual_metrics("cold-structural-regression")

    view:on_text_input("\n")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.not_nil(view:get_line_render(1), "a cold visible heading flashed as raw source")
    test.not_nil(view:get_line_render(6), "a shifted visible heading flashed as raw source")
  end)

  test.it("projects uncaptured lines requested while semantics are pending", function()
    local lines = { "start" }
    for line = 2, 199 do lines[line] = "prose line " .. line end
    lines[200] = "# Ending heading"
    local view, buffer = make_view(table.concat(lines, "\n"), "pending-offscreen.md")
    view.size.y = live_body_font(view):get_height() * 4
    buffer:set_selection(1, 6)
    refresh(view)

    view:on_text_input("!")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    view:invalidate_line_render("pending-offscreen-projection")
    test.equal(visible_render_text(view, 200), "Ending heading")
    local pending = test.not_nil(view:get_line_render(200))
    test.equal(pending.source_text, "# Ending heading")
    test.equal(pending.markdown_buffer_revision, buffer.text_revision)
  end)

  test.it("keeps multi-cursor list rows represented while semantics are pending", function()
    local view, buffer = make_view("- first\n- second\nplain", "pending-multicursor-list.md")
    buffer:set_selection(1, #buffer.lines[1])
    buffer:add_selection(2, #buffer.lines[2])
    refresh(view)
    local old_active = core.active_view
    core.active_view = view
    command.perform("text:newline")
    core.active_view = old_active

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    for line = 1, 4 do
      test.not_nil(view:get_line_render(line), "list row %d disappeared while parsing" .. line)
    end
  end)

  test.it("keeps a new Markdown list marker rendered while semantics are pending", function()
    local view, buffer = make_view("- item\nplain", "pending-list-marker.md")
    buffer:set_selection(2, 1)
    refresh(view)
    buffer:set_selection(1, #buffer.lines[1])
    local old_active = core.active_view
    core.active_view = view
    command.perform("text:newline")
    core.active_view = old_active

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    local marker = test.not_nil(view:get_line_render(2)).fragments[1]
    test.ok(marker.unordered_list_marker, "new list marker lost its semantic marker")
    test.not_nil(marker.widget, "new list marker lost its bullet widget")
  end)

  test.it("keeps a split Markdown list suffix rendered while semantics are pending", function()
    local view, buffer = make_view("- first item\nplain", "pending-split-list.md")
    buffer:set_selection(2, 1)
    refresh(view)
    buffer:set_selection(1, 6)
    local old_active = core.active_view
    core.active_view = view
    command.perform("text:newline")
    core.active_view = old_active

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    local marker
    for _, fragment in ipairs(test.not_nil(view:get_line_render(2)).fragments or {}) do
      if fragment.unordered_list_marker then marker = fragment break end
    end
    test.not_nil(marker, "split list suffix lost its bullet widget")
    test.not_nil(marker.widget, "split list suffix lost its bullet widget")
  end)

  test.it("keeps pending task and parenthesized list markers rendered", function()
    local cases = {
      { source = "- [ ] item", field = "markdown_task_checkbox" },
      { source = "3) item", field = "ordered_list_marker" },
    }
    for _, item in ipairs(cases) do
      local view, buffer = make_view(item.source .. "\nplain", "pending-list-marker-types.md")
      buffer:set_selection(2, 1)
      refresh(view)
      buffer:set_selection(1, #buffer.lines[1])
      local old_active = core.active_view
      core.active_view = view
      command.perform("text:newline")
      core.active_view = old_active

      test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
      local marker
      for _, fragment in ipairs(test.not_nil(view:get_line_render(2)).fragments or {}) do
        if fragment[item.field] then marker = fragment break end
      end
      test.not_nil(marker, "pending marker missing for " .. item.source)
    end
  end)

  test.it("keeps Markdown list rows presented through rapid editing", function()
    local source_lines = { "- [ ] ", "plain" }
    for index = 1, 1000 do
      source_lines[#source_lines + 1] = "background paragraph line " .. index
    end
    local view, buffer = make_view(
      table.concat(source_lines, "\n"), "pending-rapid-list-editing.md"
    )
    view.size.y = 400
    buffer:set_selection(2, 1)
    refresh(view)
    local old_active = core.active_view
    core.active_view = view

    local ok, err = pcall(function()
      local function assert_rows(label, last_line)
        for line = 1, last_line do
          test.not_nil(
            view:get_line_render(line),
            string.format("%s: line %d fell back to raw source", label, line)
          )
        end
        local raw = view.__markdown_live_owner
          and view.__markdown_live_owner.raw_fallback_record
        local visible_line1, visible_line2 = view:get_visible_line_range()
        local raw_detail = raw and string.format(
          " count=%s range=%s-%s visible=%s-%s",
          tostring(raw.count), tostring(raw.line1), tostring(raw.line2),
          tostring(visible_line1), tostring(visible_line2)
        ) or ""
        test.equal(raw, nil, label .. ": recorded a raw fallback" .. raw_detail)
      end

      local function type_text(text, last_line)
        for index = 1, #text do
          test.equal(view:on_text_input(text:sub(index, index)), true)
          assert_rows("typing character " .. index, last_line)
          coroutine.yield(0.01)
          assert_rows("frame after character " .. index, last_line)
        end
      end

      buffer:set_selection(1, 7)
      type_text("first", 2)
      test.equal(command.perform("text:newline"), true)
      assert_rows("first Enter", 3)
      coroutine.yield(0.01)
      assert_rows("frame after first Enter", 3)

      type_text("more", 3)
      test.equal(command.perform("text:newline"), true)
      assert_rows("second Enter", 4)
      coroutine.yield(0.01)
      assert_rows("frame after second Enter", 4)

      test.equal(command.perform("text:indent"), true)
      assert_rows("indent at new task content start", 4)
      coroutine.yield(0.01)
      assert_rows("frame after indent", 4)
      type_text("nested", 4)
      assert_rows("typing nested item", 4)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps nested task rows presented after pressing Enter", function()
    local source_lines = {
      "- [ ] Si se hace picking con el qr, seleccionará la línea y meterá las unidades a recibir",
      "- [ ] Si no se hace picking",
      "    - [ ] test",
      "    - [ ] test",
      "    - [ ] ",
      "    - [ ] suffix task",
    }
    for index = 1, 1000 do
      source_lines[#source_lines + 1] = "background paragraph line " .. index
    end
    local source = table.concat(source_lines, "\n")
    local view, buffer = make_view(source, "pending-nested-task-enter.md")
    view.size.y = view:get_line_height() * 2
    view:set_wrapping_enabled(true)
    buffer:set_selection(2, 1)
    refresh(view)
    buffer:set_selection(5, #buffer.lines[5])
    view:scroll_to_make_visible(5, #buffer.lines[5])
    local old_active = core.active_view
    core.active_view = view

    local ok, err = pcall(function()
      local function checkbox_x(line)
        local render = test.not_nil(view:get_line_render(line))
        for _, fragment in ipairs(render.fragments or {}) do
          if fragment.markdown_task_checkbox and fragment.widget then
            local old_draw_rounded_rect = renderer.draw_rounded_rect
            local x
            renderer.draw_rounded_rect = function(box_x)
              x = x or box_x
            end
            local drew, draw_error = pcall(
              fragment.widget.draw, fragment.widget, fragment,
              0, 0, view:get_line_height()
            )
            renderer.draw_rounded_rect = old_draw_rounded_rect
            test.ok(drew, draw_error)
            return test.not_nil(x)
          end
        end
        error("line " .. line .. " has no checkbox widget")
      end

      local function draw_frame()
        local old_draw_rect = renderer.draw_rect
        local old_draw_rounded_rect = renderer.draw_rounded_rect
        local old_draw_text = renderer.draw_text
        local old_push_clip_rect = core.push_clip_rect
        local old_pop_clip_rect = core.pop_clip_rect
        local drawn = {}
        renderer.draw_rect = function() end
        renderer.draw_rounded_rect = function() end
        renderer.draw_text = function(font, text, x)
          drawn[#drawn + 1] = text
          return x + (font and font:get_width(text) or 0)
        end
        core.push_clip_rect = function() end
        core.pop_clip_rect = function() end
        local drew, draw_error = pcall(view.draw, view)
        renderer.draw_rect = old_draw_rect
        renderer.draw_rounded_rect = old_draw_rounded_rect
        renderer.draw_text = old_draw_text
        core.push_clip_rect = old_push_clip_rect
        core.pop_clip_rect = old_pop_clip_rect
        return drew, draw_error, drawn
      end

      local function assert_presented(label)
        local drew, draw_error, drawn = draw_frame()
        test.ok(drew, label .. " draw failed: " .. tostring(draw_error))
        test.ok(not table.concat(drawn):match("%- %[ %]"),
          label .. " drew a raw task marker")
        for line = 1, 6 do
          test.not_nil(
            view:get_line_render(line),
            string.format("%s: line %d fell back to raw source", label, line)
          )
        end
        local raw = view.__markdown_live_owner
          and view.__markdown_live_owner.raw_fallback_record
        test.equal(raw, nil, raw and string.format(
          "%s recorded raw fallback count=%d range=%d-%d scan_pending=%s",
          label, raw.count, raw.line1, raw.line2,
          tostring(view:is_horizontal_extent_scan_pending())
        ) or label .. " recorded a raw fallback")
      end

      assert_presented("before Enter")
      local nested_checkbox_x = checkbox_x(3)
      test.equal(command.perform("text:newline"), true)
      assert_presented("immediate after Enter")
      local cursor_line, cursor_col = buffer:get_selection()
      view:scroll_to_make_visible(cursor_line, cursor_col)
      view:get_h_scrollable_size()
      view.draw_overlay = function() end
      assert_presented("after Enter")
      for line = 3, 4 do
        local render = test.not_nil(view:get_line_render(line))
        local checkbox
        for _, fragment in ipairs(render.fragments or {}) do
          if fragment.markdown_task_checkbox then checkbox = fragment break end
        end
        test.not_nil(checkbox, string.format(
          "line %d lost its task checkbox after Enter", line
        ))
        test.equal(
          checkbox_x(line), nested_checkbox_x,
          string.format("line %d checkbox jumped horizontally after Enter", line)
        )
      end
      coroutine.yield(0.01)
      assert_presented("frame after Enter")
      for frame = 1, 4 do
        coroutine.yield(0.01)
        assert_presented("frame after Enter " .. frame)
      end
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("does not reveal neighboring task markers when completing an empty task", function()
    local view, buffer = make_view(table.concat({
      "- [ ] informar FechaSuAlbaran. Obligado",
      "- [ ] informar SuAlbaranNo Obligado",
      "- [ ]",
      "## Albaranes.",
      "```sql",
      "select CodigoEmpresa from CabeceraAlbaranProveedor",
      "```",
    }, "\n"), "task-reveal-isolation.md")
    buffer:set_selection(3, 6)
    refresh(view)
    local old_active = core.active_view
    core.active_view = view

    local ok, err = pcall(function()
      for char in ("- [ ]"):gmatch(".") do
        test.equal(view:on_text_input(char), true)
      end
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_status(instance, "ready"), instance.reason)

      for line = 1, 2 do
        local _, fragments = collect_render_fragments(view, line)
        local checkbox, source_marker
        for _, fragment in ipairs(fragments) do
          checkbox = checkbox or fragment.markdown_task_checkbox
          source_marker = source_marker or fragment.markdown_task_source_marker
        end
        test.ok(checkbox, string.format(
          "line %d lost its checkbox when another task marker was completed", line
        ))
        test.equal(source_marker, nil, string.format(
          "line %d revealed another task's source marker", line
        ))
        test.equal(visible_render_text(view, line):find("[ ]", 1, true), nil)
      end
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps a following heading's pending metric stable during an incomplete list marker", function()
    local view, buffer = make_view(table.concat({
      "- [ ] informar FechaSuAlbaran. Obligado",
      "- [ ] informar SuAlbaranNo Obligado",
      "- [ ]",
      "## Albaranes.",
      "```sql",
      "select CodigoEmpresa from CabeceraAlbaranProveedor",
      "```",
    }, "\n"), "task-heading-metric-stability.md")
    view:set_wrapping_enabled(true)
    buffer:set_selection(3, 6)
    refresh(view)
    local old_active = core.active_view
    core.active_view = view

    local function heading_provider_height()
      for _, entry in ipairs(view:visual_metric_provider_entries()) do
        if entry.id == "markdown-live" and entry.provider.line_height then
          return entry.provider:line_height(view, 4, { row_in_line = 1 })
        end
      end
    end

    local ok, err = pcall(function()
      buffer:set_selection(3, 1, 3, 6)
      test.equal(command.perform("text:backspace"), true)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_status(instance, "ready"), instance.reason)

      local expected_height = test.not_nil(heading_provider_height())
      test.equal(view:on_text_input("-"), true)
      test.equal(instance.status, "pending")
      test.equal(
        heading_provider_height(), expected_height,
        "the provisional heading metric dropped while the parser was pending"
      )
      test.ok(wait_status(instance, "ready"), instance.reason)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("aligns Markdown continuation text with task content", function()
    local view, buffer = make_view(
      "- [ ] task\n  continuation\nplain",
      "list-continuation-alignment.md"
    )
    buffer:set_selection(3, 1)
    refresh(view)

    local task_x = view:get_col_x_offset(1, 7)
    local continuation_x = view:get_col_x_offset(2, 3)
    test.ok(
      math.abs(task_x - continuation_x) < 0.1,
      string.format("task content x=%.2f continuation x=%.2f", task_x, continuation_x)
    )
  end)

  test.it("keeps a formatted row stable when one edit crosses rendered fragments", function()
    local view, buffer = make_view("Before **bold** after\nplain", "pending-cross-fragment.md")
    view:set_wrapping_enabled(true)
    buffer:set_selection(2, 1)
    refresh(view)
    buffer:set_selection(1, 11, 1, 17)
    view:on_text_input("replacement")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.not_nil(view:get_line_render(1), "the edited row flashed as raw source")
  end)

  test.it("keeps ordinary prose presented through typing, line edits, paste, and undo", function()
    local view, buffer = make_view(
      "First paragraph with ordinary words.\nSecond paragraph stays visible.\nplain",
      "pending-prose-editing.md"
    )
    view:set_wrapping_enabled(true)
    buffer:set_selection(3, 1)
    refresh(view)
    local old_active = core.active_view
    core.active_view = view

    local ok, err = pcall(function()
      local function assert_presented(label)
        local first, last = view:get_visible_line_range()
        for line = first, last do
          local render = test.not_nil(
            view:get_line_render(line),
            string.format("%s: line %d fell through to raw source", label, line)
          )
          test.ok(
            render.markdown_provenance ~= "unavailable",
            string.format("%s: line %d used unavailable source", label, line)
          )
        end
      end
      local function publish()
        local instance = test.not_nil(markdown_model.peek(buffer))
        test.ok(wait_status(instance, "ready"), instance.reason)
      end

      buffer:set_selection(1, 6)
      test.equal(view:on_text_input(" edited"), true)
      assert_presented("typing")
      publish()

      buffer:set_selection(1, 13)
      test.equal(command.perform("text:newline"), true)
      assert_presented("Enter")
      publish()

      local line, _ = buffer:get_selection()
      buffer:set_selection(line, 1)
      test.equal(command.perform("text:backspace"), true)
      assert_presented("Backspace")
      publish()

      buffer:set_selection(2, 8)
      local pasted = {}
      for index = 1, 10 do pasted[index] = "pasted prose " .. index end
      test.equal(view:on_text_input(table.concat(pasted, "\n")), true)
      assert_presented("paste")
      publish()

      test.equal(command.perform("text:undo"), true)
      assert_presented("undo")
      publish()
      test.equal(command.perform("text:redo"), true)
      assert_presented("redo")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps a paragraph rendered when deleting its following blank line", function()
    local view, buffer = make_view(
      "A paragraph that must remain in the Live Preview font.\n\nFollowing paragraph.\n",
      "paragraph-line-join.md"
    )
    buffer:set_selection(2, 1)
    refresh(view)
    test.not_nil(view:get_line_render(1))

    buffer:remove(1, #buffer.lines[1], 2, 1)

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.not_nil(
      view:get_line_render(1),
      "the retained paragraph flashed as raw source after joining the blank line"
    )
  end)

  test.it("retains unrelated visible rows during a local block-context edit", function()
    local lines = { "- [ ] item", "- [ ] " }
    for line = 3, 12 do lines[line] = "plain " .. line end
    lines[13] = "### Unrelated heading"
    local view, buffer = make_view(table.concat(lines, "\n"), "local-context-retention.md")
    view.size.y = 1200
    buffer:set_selection(2, 1)
    refresh(view)
    test.equal(visible_render_text(view, 13), "Unrelated heading")

    buffer:remove(2, 1, 2, #buffer.lines[2])

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    local heading = test.not_nil(view:get_line_render(13))
    test.equal(visible_render_text(view, 13), "Unrelated heading")
    test.equal(heading.markdown_provenance, "retained")
  end)

  test.it("does not retain prose formatting when a new fence changes its context", function()
    local view, buffer = make_view("before\n*italic*\nafter\n", "new-fence-context.md")
    buffer:set_selection(1, 1)
    refresh(view)
    test.equal(visible_render_text(view, 2), "italic")

    buffer:insert(2, 1, "```lua\n")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(
      visible_render_text(view, 3), "*italic*",
      "the newly fenced row retained its old prose semantics"
    )
  end)

  test.it("does not retain prose formatting when a new math block changes its context", function()
    local view, buffer = make_view("before\n*value*\n$$\nafter", "new-math-context.md")
    buffer:set_selection(4, 1)
    refresh(view)
    test.equal(visible_render_text(view, 2), "value")

    buffer:insert(2, 1, "$$\n")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(
      visible_render_text(view, 3), "*value*",
      "the newly math-owned row retained its old prose semantics"
    )
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 3), "*value*")
  end)

  test.it("does not retain prose formatting when frontmatter is created", function()
    local view, buffer = make_view("key: *value*\n---\n# Heading", "new-frontmatter.md")
    buffer:set_selection(3, 1)
    refresh(view)
    test.equal(visible_render_text(view, 1), "key: value")

    buffer:insert(1, 1, "---\n")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(
      visible_render_text(view, 2), "key: *value*",
      "the newly frontmatter-owned row retained prose formatting"
    )
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(visible_render_text(view, 2), "key: *value*")
  end)

  test.it("does not retain prose formatting when an HTML block is created", function()
    local view, buffer = make_view("before\n*value*\n</div>\nafter", "new-html-block.md")
    buffer:set_selection(4, 1)
    refresh(view)
    test.equal(visible_render_text(view, 2), "value")

    buffer:insert(2, 1, "<div>\n")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(
      visible_render_text(view, 3), "*value*",
      "the newly HTML-owned row retained prose formatting"
    )
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
  end)

  test.it("keeps fenced-code background ownership after a structural edit above it", function()
    local view, buffer = make_view(
      "before\n\n```lua\nprint('ok')\n```\nafter",
      "shifted-fence-background.md"
    )
    buffer:set_selection(6, 1)
    refresh(view)

    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then
        markdown_decoration = entry.provider
        break
      end
    end
    markdown_decoration = test.not_nil(markdown_decoration)
    test.equal(
      markdown_decoration:line_background(view, 4),
      style.markdown_live_code_background
    )
    local code_x_offset = test.not_nil(view:get_line_render(4)).x_offset
    view:invalidate_line_render("cold-shifted-fence")

    buffer:insert(1, 1, "inserted\n")

    test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
    test.equal(
      markdown_decoration:line_background(view, 5),
      style.markdown_live_code_background,
      "the transaction-mapped fence lost its code background while semantics were pending"
    )
    test.equal(
      visible_render_text(view, 4), "",
      "the shifted opening fence flashed as raw source while semantics were pending"
    )
    test.equal(
      visible_render_text(view, 6), "",
      "the shifted closing fence flashed as raw source while semantics were pending"
    )
    test.equal(
      test.not_nil(view:get_line_render(5)).x_offset, code_x_offset,
      "the shifted fenced-code body jumped horizontally while semantics were pending"
    )
    test.equal(markdown_decoration:line_background(view, 7), nil)
  end)

  test.it("reveals a Wikilink at the caret position after its closing brackets", function()
    local source = "[[APPi-Sage]]"
    local view, buffer = make_view(source .. "\nplain", "right-edge-link.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:set_selection(1, #source + 1)

    test.equal(visible_render_text(view, 1), source)
  end)

  test.it("keeps heading markers hidden when revealing a nested inline construct", function()
    local source = "# Head **bold** tail\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(1, 11)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "Head **bold** tail")
  end)

  test.it("renders semantic code, highlight, strikethrough, and escapes", function()
    local source = "`code` ==mark== ~~gone~~ and \\*literal*\nother"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local render_line = test.not_nil(view:get_line_render(1))
    local seen = {}
    for _, fragment in ipairs(render_line.fragments or {}) do
      seen[fragment.text or ""] = fragment
    end
    test.not_nil(seen.code)
    test.not_nil(seen.code.background)
    test.not_nil(seen.mark)
    test.not_nil(seen.mark.background)
    test.equal(seen.gone.strikethrough, true)
    test.not_nil(seen["*"])
  end)

  test.it("keeps fenced and heading-looking lines hidden inside comments", function()
    local source = "%%\n```\n# hidden heading\n```\n%%\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(6, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(2, #"```" + 1), 0)
    test.equal(view:get_col_x_offset(3, #"# hidden heading" + 1), 0)
    test.equal(view:get_col_x_offset(4, #"```" + 1), 0)
  end)

  test.it("composes active comment markers with enclosing formatting", function()
    local source = "**before %%hide%% after**\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(1, 13)
    refresh(view)
    local marker, content
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text and fragment.text:find("%", 1, true) then marker = fragment end
      if fragment.text == "hide" then content = fragment end
    end
    test.not_nil(marker)
    test.not_nil(content)
  end)

  test.it("reveals and re-hides every line of a multiline comment construct", function()
    local source = "%%one\nmiddle\nend%%\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(1, 3)
    refresh(view)
    test.equal(
      view:get_col_x_offset(2, #"middle" + 1), live_body_font(view):get_width("middle")
    )
    buffer:set_selection(4, 1)
    test.equal(view:get_col_x_offset(2, #"middle" + 1), 0)
  end)

  test.it("hides multiline comments until a touched line reveals source", function()
    local source = "before %%hidden\nstill hidden%% after\nother"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(3, 1)
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
    buffer:set_selection(1, 10)
    test.equal(
      view:get_col_x_offset(1, #"before %%hidden" + 1),
      live_body_font(view):get_width("before %%hidden")
    )
  end)

  test.it("removes the line-number lane only while presenting Live Preview", function()
    local view, buffer = make_view("# Heading\nbody", "live-preview-gutter.md")
    view.show_line_numbers = true
    buffer:set_selection(2, 1)
    refresh(view)

    local live_gutter = view:get_gutter_width()
    markdown.live_render.set_source_mode(view, true, "test-gutter")
    local source_gutter = view:get_gutter_width()
    test.ok(live_gutter < source_gutter)
    test.ok(
      math.abs(
        source_gutter - live_gutter - view:get_line_number_gutter_width()
      ) < 0.01
    )
  end)

  test.it("hides closing ATX heading markers", function()
    local view, buffer = make_view("# Title #\nbody", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    test.equal(view:get_col_x_offset(1, #"# Title #" + 1), view:get_col_x_offset(1, #"# Title" + 1))
    test.ok(view:get_col_x_offset(1, #"# Title #" + 1) < view:get_font():get_width("# Title #"))
  end)

  test.it("composes enclosing formatting with decoded links", function()
    local view, buffer = make_view("**[Label](target.md)**\nplain", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local link
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.text == "Label" then link = fragment end
    end
    link = test.not_nil(link)
    test.not_nil(link.link_resolution)
    test.not_nil(link.semantic_id)
    test.equal(visible_render_text(view, 1), "Label")
  end)

  test.it("renders decoded semantic links inside headings", function()
    local view, buffer = make_view("# [Label](target.md)\nplain", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "Label")
  end)

  test.it("keeps visible raw source around links overlapping comments", function()
    local source = "[visible %%hidden%% tail](target.md)\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(1))) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "[visible  tail](target.md)")
  end)

  test.it("preserves empty semantic Markdown labels as full targets", function()
    local source = "[](folder/target.md)\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    test.equal(
      view:get_col_x_offset(1, #"[](folder/target.md)" + 1),
      live_body_font(view):get_width("folder/target.md")
    )
  end)

  test.it("does not take the image-only path through comments", function()
    local source = "![Alt %%hidden%% tail](foo.png)\nplain"
    local view, buffer = make_view(source, "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local visible = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(1))) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    test.equal(table.concat(visible), "![Alt  tail](foo.png)")
  end)

  test.it("renders wikilink aliases when inactive and raw syntax when active", function()
    local view, buffer = make_view("See [[Note|Alias]]\nother", "note.md")
    buffer:set_selection(1, 1)
    refresh(view)
    buffer:set_selection(2, 1)

    local alias_width = live_body_font(view):get_width("See Alias")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), alias_width)

    buffer:set_selection(1, 7)
    local raw_width = live_body_font(view):get_width("See [[Note|Alias]]")
    test.equal(view:get_col_x_offset(1, #"See [[Note|Alias]]" + 1), raw_width)
  end)

  test.it("opens resolved links by command and left-click with navigation targets", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-open-link-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local target_path = root .. PATHSEP .. "Target.md"
    local source_path = root .. PATHSEP .. "Source.md"
    local fp = test.not_nil(io.open(target_path, "wb"))
    fp:write("# Heading\n")
    fp:close()
    local old_projects = core.projects
    core.projects = { Project(root) }
    local index = markdown.vault_index.get_index(root):rebuild("ui-open-link")
    local view, buffer = make_view("[[Target#Heading]]\nplain", source_path)
    buffer:set_selection(1, 5)
    refresh(view)
    test.equal(index.status, "ready")
    local old_active, old_open_file = core.active_view, core.open_file
    local opened, selected, scrolled
    core.active_view = view
    core.open_file = function(path)
      opened = path
      return {
        set_selection_state = function(_, state) selected = state.selections end,
        scroll_to_line = function(_, line) scrolled = line end,
      }
    end
    local ok, err = pcall(function()
      test.equal(command.perform("markdown-live-preview:open-link"), true)
      test.equal(opened, common.normalize_path(target_path))
      test.same(selected, { 1, 1, 1, 1 })
      test.equal(scrolled, 1)

      opened = nil
      buffer:set_selection(2, 1)
      local x, y = view:get_line_screen_position(1)
      view:on_mouse_pressed("left", x + 2, y + 2, 1)
      test.equal(opened, common.normalize_path(target_path))

      os.remove(target_path)
      opened = nil
      buffer:set_selection(1, 5)
      test.equal(command.perform("markdown-live-preview:open-link"), true)
      test.equal(opened, nil)
      test.ok(common.mkdirp(target_path))
      test.equal(command.perform("markdown-live-preview:open-link"), true)
      test.equal(opened, nil)
    end)
    core.open_file, core.active_view = old_open_file, old_active
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("opens resolved Obsidian unsupported-file links in the system application", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-open-unsupported-" .. system.get_process_id()
    test.ok(common.mkdirp(root .. PATHSEP .. ".obsidian"))
    test.ok(common.mkdirp(root .. PATHSEP .. "attachments"))
    local app = test.not_nil(io.open(root .. PATHSEP .. ".obsidian" .. PATHSEP .. "app.json", "wb"))
    app:write([[{"showUnsupportedFiles":true}]])
    app:close()
    local target_path = root .. PATHSEP .. "attachments" .. PATHSEP .. "NO CONSUMOS .msg"
    local fp = test.not_nil(io.open(target_path, "wb"))
    fp:write("message")
    fp:close()
    local source_path = root .. PATHSEP .. "Source.md"
    local old_projects = core.projects
    core.projects = { Project(root) }
    markdown.vault_index.get_index(root):rebuild("ui-open-unsupported-link")
    local view, buffer = make_view("[[NO CONSUMOS .msg]]\n", source_path)
    buffer:set_selection(1, 5)
    refresh(view)
    local old_active = core.active_view
    local old_open_in_system = common.open_in_system
    local old_open_file = core.open_file
    local opened_in_system, opened_in_editor
    core.active_view = view
    common.open_in_system = function(path) opened_in_system = path return true end
    core.open_file = function(path) opened_in_editor = path end
    local ok, err = pcall(function()
      test.equal(command.perform("markdown-live-preview:open-link"), true)
      test.equal(opened_in_system, common.normalize_path(target_path))
      test.equal(opened_in_editor, nil)
    end)
    common.open_in_system = old_open_in_system
    core.open_file = old_open_file
    core.active_view = old_active
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("publishes semantic link POIs for generic navigation and activation", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-link-poi-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local target_path = root .. PATHSEP .. "Target.md"
    local source_path = root .. PATHSEP .. "Source.md"
    local fp = test.not_nil(io.open(target_path, "wb"))
    fp:write("# Heading\n")
    fp:close()
    local old_projects = core.projects
    core.projects = { Project(root) }
    markdown.vault_index.get_index(root):rebuild("ui-link-poi")
    local view, buffer = make_view("prefix [[Target#Heading]] and `[[Target]]`\n", source_path)
    buffer:set_selection(1, 1)
    refresh(view)
    local points = view:get_points_of_interest()
    test.equal(#points, 1)
    test.equal(points[1].kind, "markdown-link")
    test.equal(points[1].text_bounds, true)
    local old_active, old_open_file = core.active_view, core.open_file
    local opened
    core.active_view = view
    core.open_file = function(path) opened = path return {
      set_selection_state = function() end,
      scroll_to_line = function() end,
    } end
    local ok, err = pcall(function()
      test.equal(command.perform("poi:next"), true)
      test.equal(command.perform("poi:activate"), true)
      test.equal(opened, common.normalize_path(target_path))
      test.equal(markdown.live_render.detach(view), true)
      test.equal(#view:get_points_of_interest(), 0)
    end)
    core.open_file, core.active_view = old_open_file, old_active
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("completes note, current/global heading, and current/global block Wikilink states", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-link-completion-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local note_path = root .. PATHSEP .. "Note.md"
    local fp = test.not_nil(io.open(note_path, "wb"))
    fp:write("# Global Heading\n\ntext ^global-block\n")
    fp:close()
    local old_projects = core.projects
    core.projects = { Project(root) }
    markdown.vault_index.get_index(root):rebuild("ui-completion")
    local autocomplete = require "plugins.autocomplete"
    local old_complete, old_active = autocomplete.complete, core.active_view
    local offered
    local offer_index = 0
    autocomplete.complete = function(symbols) offered = symbols end
    local ok, err = pcall(function()
      local function offer(text, line)
        offer_index = offer_index + 1
        local source_path = root .. PATHSEP .. "Source" .. offer_index .. ".md"
        local view, buffer = make_view(text, source_path)
        local content = (buffer.lines[line] or ""):gsub("\n$", "")
        buffer:set_selection(line, #content + 1)
        refresh(view)
        local deadline = system.get_time() + 5
        while system.get_time() < deadline do
          local ready = markdown_completion.symbols(view)
          if ready then break end
          coroutine.yield(0.01)
        end
        core.active_view = view
        offered = nil
        test.equal(command.perform("markdown-live-preview:complete-link"), true)
        return view, buffer, test.not_nil(offered, "completion was not offered for " .. text)
      end
      local function item_for(symbols, target)
        for _, item in pairs(symbols.items) do
          if item.data and item.data.target == target then return item end
        end
      end

      local note_view, note_buffer, symbols = offer("[[No", 1)
      local provider = test.not_nil(autocomplete.providers["markdown-live-links"])
      local automatic_symbols, automatic_opts = provider(note_view, { text = "o" })
      test.not_nil(item_for(test.not_nil(automatic_symbols), "Note"))
      test.equal(automatic_opts.force_open, true)
      local note = test.not_nil(item_for(symbols, "Note"))
      test.equal(note.onselect(1, { data = note.data }), true)
      test.equal(note_buffer.lines[1], "[[Note]]\n")

      local ignored_view, ignored_buffer
      ignored_view, ignored_buffer, symbols = offer("# Local Heading\n[[#Lo", 2)
      test.not_nil(item_for(symbols, "#Local Heading"))
      ignored_view, ignored_buffer, symbols = offer("[[##Gl", 1)
      test.not_nil(item_for(symbols, "Note#Global Heading"))
      ignored_view, ignored_buffer, symbols = offer("text ^local-block\n[[^loc", 2)
      test.not_nil(item_for(symbols, "^local-block"))
      ignored_view, ignored_buffer, symbols = offer("[[^^glob", 1)
      test.not_nil(item_for(symbols, "Note#^global-block"))
    end)
    autocomplete.complete = old_complete
    core.active_view = old_active
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("offers explicit create and ambiguity-picker link actions", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-link-actions-" .. system.get_process_id()
    test.ok(common.mkdirp(root .. PATHSEP .. "a"))
    test.ok(common.mkdirp(root .. PATHSEP .. "b"))
    test.ok(common.mkdirp(root .. PATHSEP .. "notes"))
    local function write(path, text)
      local fp = test.not_nil(io.open(path, "wb")); fp:write(text); fp:close()
    end
    write(root .. PATHSEP .. "a" .. PATHSEP .. "Note.md", "# A\n")
    write(root .. PATHSEP .. "b" .. PATHSEP .. "Note.md", "# B\n")
    local old_projects = core.projects
    core.projects = { Project(root) }
    markdown.vault_index.get_index(root):rebuild("ui-link-actions")
    local old_active, old_open_file = core.active_view, core.open_file
    local old_enter = core.global_prompt_bar.enter
    local opened, picker
    core.open_file = function(path) opened = path return {} end
    core.global_prompt_bar.enter = function(_, label, opts) picker = { label = label, opts = opts } end
    local ok, err = pcall(function()
      local missing_view, missing_buffer = make_view(
        "[[folder/New]]\nplain", root .. PATHSEP .. "notes" .. PATHSEP .. "MissingSource.md"
      )
      missing_buffer:set_selection(1, 5)
      refresh(missing_view)
      core.active_view = missing_view
      test.equal(command.perform("markdown-live-preview:create-link-target"), true)
      test.equal(opened, common.normalize_path(
        root .. PATHSEP .. "notes" .. PATHSEP .. "folder" .. PATHSEP .. "New.md"
      ))

      opened = nil
      local root_view, root_buffer = make_view("[[NewRoot]]\nplain", root .. PATHSEP .. "notes" .. PATHSEP .. "RootSource.md")
      root_buffer:set_selection(1, 4)
      refresh(root_view)
      core.active_view = root_view
      test.equal(command.perform("markdown-live-preview:create-link-target"), true)
      test.equal(opened, common.normalize_path(root .. PATHSEP .. "NewRoot.md"))

      opened = nil
      local query_view, query_buffer = make_view(
        "[[folder/Query.md?download]]\nplain",
        root .. PATHSEP .. "notes" .. PATHSEP .. "QuerySource.md"
      )
      query_buffer:set_selection(1, 5)
      refresh(query_view)
      core.active_view = query_view
      test.equal(command.perform("markdown-live-preview:create-link-target"), true)
      test.equal(opened, common.normalize_path(
        root .. PATHSEP .. "notes" .. PATHSEP .. "folder" .. PATHSEP .. "Query.md"
      ))

      opened = nil
      local outside_view, outside_buffer = make_view(
        "[[../../../../../../Outside]]\nplain",
        root .. PATHSEP .. "notes" .. PATHSEP .. "OutsideSource.md"
      )
      outside_buffer:set_selection(1, 5)
      refresh(outside_view)
      core.active_view = outside_view
      test.equal(command.perform("markdown-live-preview:create-link-target"), true)
      test.equal(opened, nil)

      local ambiguous_view, ambiguous_buffer = make_view("[[Note]]\nplain", root .. PATHSEP .. "AmbiguousSource.md")
      ambiguous_buffer:set_selection(1, 4)
      refresh(ambiguous_view)
      core.active_view = ambiguous_view
      test.equal(command.perform("markdown-live-preview:open-link"), true)
      test.equal(picker.label, "Open Markdown Link")
      test.equal(#picker.opts.suggest(""), 2)
      local filtered = picker.opts.suggest("b/Note")
      test.equal(#filtered, 1)
      test.equal(filtered[1].text, "b/Note.md")
    end)
    core.global_prompt_bar.enter = old_enter
    core.open_file, core.active_view = old_open_file, old_active
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("previews affected rename files and confirms before rewriting", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-rename-preview-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local old_path, ref_path = root .. PATHSEP .. "Old.md", root .. PATHSEP .. "Ref.md"
    local function write(path, text)
      local fp = test.not_nil(io.open(path, "wb")); fp:write(text); fp:close()
    end
    write(old_path, "# Old\n")
    write(ref_path, "[[Old]]\n")
    local index = markdown.vault_index.get_index(root):rebuild("rename-preview-ui")
    local plan = test.not_nil(index:plan_note_rename(old_path, root .. PATHSEP .. "New.md"))
    local old_enter, old_show = core.global_prompt_bar.enter, core.nag_view.show
    local picker, confirmation
    core.global_prompt_bar.enter = function(_, label, opts) picker = { label = label, opts = opts } end
    core.nag_view.show = function(_, title, text, options, callback)
      confirmation = { title = title, text = text, options = options, callback = callback }
    end
    local ok, err = pcall(function()
      test.equal(markdown_rename_links.present(plan), true)
      test.equal(picker.label, "Markdown links affected by rename")
      local suggestions = picker.opts.suggest("")
      test.equal(#suggestions, 2)
      test.equal(suggestions[2].text, "Ref.md")
      picker.opts.submit("", suggestions[1])
      test.equal(confirmation.title, "Update Markdown Links")
      local before = test.not_nil(io.open(ref_path, "rb")); local before_text = before:read("*a"); before:close()
      test.equal(before_text, "[[Old]]\n")
      confirmation.callback({ text = "Update Links" })
      local after = test.not_nil(io.open(ref_path, "rb")); local after_text = after:read("*a"); after:close()
      test.equal(after_text, "[[New]]\n")
    end)
    core.global_prompt_bar.enter, core.nag_view.show = old_enter, old_show
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("keeps an empty task marker as a checkbox after semantic rendering", function()
    local view, buffer = make_view("- [ ] \nafter", "empty-task-render.md")
    buffer:set_selection(2, 1)
    refresh(view)

    local checkbox
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.markdown_task_checkbox then checkbox = fragment break end
    end
    test.not_nil(checkbox)
    test.equal(checkbox.text or "", "")
  end)

  test.it("renders task markers as consistent checkbox widgets without list bullets", function()
    local view, buffer = make_view("- item\n- [ ] todo\n- [x] done\n> quote\nplain", "blocks.md")
    buffer:set_selection(5, 1)
    refresh(view)
    local function fragments(line)
      local render_line = view:get_line_render(line)
      return render_line and render_line.fragments or {}
    end
    local function find_text(line, text)
      for _, fragment in ipairs(fragments(line)) do
        if fragment.text == text then return fragment end
      end
    end
    local bullet
    for _, fragment in ipairs(fragments(1)) do
      if fragment.unordered_list_marker then bullet = fragment break end
    end
    bullet = test.not_nil(bullet)
    test.not_nil(bullet.widget)
    test.equal(bullet.text or "", "")
    local function task_checkbox(line)
      local checkbox, list_bullet
      for _, fragment in ipairs(fragments(line)) do
        if fragment.markdown_task_checkbox then checkbox = fragment end
        if fragment.unordered_list_marker and fragment.widget then list_bullet = fragment end
      end
      test.equal(list_bullet, nil)
      return test.not_nil(checkbox)
    end
    local unchecked = task_checkbox(2)
    local checked = task_checkbox(3)
    test.equal(unchecked.text or "", "")
    test.equal(checked.text or "", "")
    test.not_nil(unchecked.widget)
    test.not_nil(checked.widget)
    test.equal(unchecked.width, checked.width)
    test.equal(unchecked.widget.width, checked.widget.width)
    test.not_nil(find_text(4, "│ "))
  end)

  test.it("preserves list hierarchy across plain and task markers", function()
    local view, buffer = make_view(
      " - [ ] parent task\n - parent plain\n\t - child plain\n\t - [ ] child task\nplain",
      "list-hierarchy.md"
    )
    buffer.get_indent_info = function() return false, 1 end
    buffer:set_selection(5, 1)
    refresh(view)

    local parent_task_x = view:get_col_x_offset(1, 8)
    local parent_plain_x = view:get_col_x_offset(2, 4)
    local child_plain_x = view:get_col_x_offset(3, 5)
    local child_task_x = view:get_col_x_offset(4, 9)
    test.equal(parent_task_x, parent_plain_x)
    test.equal(child_task_x, child_plain_x)
    local indent_step = live_body_font(view):get_width(
      string.rep(" ", config.markdown_live_list_indent_spaces)
    )
    test.equal(child_plain_x - parent_plain_x, indent_step)
    test.equal(child_task_x - parent_task_x, indent_step)
  end)

  test.it("keeps formatted list content and source mappings through indentation", function()
    local source = "- See [[Target|Alias]] now"
    local view, buffer = make_view(
      "- Parent\n" .. source .. "\nplain",
      "pending-list-indent-link.md"
    )
    buffer:set_selection(3, 1)
    refresh(view)

    local before_body_x = view:get_col_x_offset(2, 3)
    test.equal(visible_render_text(view, 2), "See Alias now")

    buffer:set_selection(2, 3)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:indent"), true)
      test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")

      local indented = buffer.lines[2]:gsub("\n$", "")
      local indent = test.not_nil(indented:match("^([\t ]+)%- See"))
      test.equal(indented:sub(#indent + 1), source)
      test.equal(
        visible_render_text(view, 2),
        "See Alias now"
      )
      local pending = test.not_nil(view:get_line_render(2))
      test.ok(
        pending.markdown_provenance ~= "unavailable",
        "list indentation used the unavailable source presentation"
      )
      test.equal(pending.markdown_buffer_revision, buffer.text_revision)
      for _, fragment in ipairs(pending.fragments or {}) do
        test.equal(fragment.on_mouse_pressed, nil)
        if fragment.widget then test.equal(fragment.widget.on_mouse_pressed, nil) end
      end
      local body_col = #indent + 3
      test.ok(view:get_col_x_offset(2, body_col) > before_body_x)
      local end_col = #indented + 1
      local end_x = view:get_col_x_offset(2, end_col)
      test.equal(view:get_x_offset_col(2, end_x), end_col)

      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_status(instance, "ready"), instance.reason)
      test.equal(visible_render_text(view, 2), "See Alias now")
      local published = test.not_nil(view:get_line_render(2))
      test.equal(published.markdown_provenance, "current")
      test.equal(published.markdown_semantic_revision, buffer.text_revision)
      local published_end_x = view:get_col_x_offset(2, end_col)
      test.equal(view:get_x_offset_col(2, published_end_x), end_col)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps a first nested task stable when it cannot be indented further", function()
    local old_tab_type, old_indent_size = config.tab_type, config.indent_size
    config.tab_type, config.indent_size = "soft", 4
    local view, buffer = make_view(
      "- [ ] parent\n    - [ ] \n    - [ ] sibling\nplain",
      "pending-task-indent.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:set_selection(2, 11)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:indent"), true)
      test.equal(buffer.lines[2], "    - [ ] \n")
      test.equal(test.not_nil(markdown_model.peek(buffer)).status, "ready")

      local function task_checkbox()
        for _, fragment in ipairs(
          test.not_nil(view:get_line_render(2)).fragments or {}
        ) do
          if fragment.markdown_task_checkbox then return fragment end
        end
      end

      test.not_nil(task_checkbox())
      local published = test.not_nil(view:get_line_render(2))
      test.equal(published.markdown_provenance, "current")
    end)
    core.active_view = old_active
    config.tab_type, config.indent_size = old_tab_type, old_indent_size
    if not ok then error(err, 0) end
  end)

  test.it("toggles task checkboxes without moving the caret", function()
    local view, buffer = make_view("- [ ] todo\nplain", "task-toggle.md")
    buffer:set_selection(2, 3)
    refresh(view)
    local checkbox
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.markdown_task_checkbox then checkbox = fragment break end
    end
    checkbox = test.not_nil(checkbox)
    local selection = view:get_selection_state()

    local line_x, line_y = view:get_line_screen_position(1)
    local checkbox_x = line_x
      + view:get_line_render_col_x_offset(view:get_line_render(1), checkbox.source_col1) + 2
    test.equal(view:on_mouse_pressed("left", checkbox_x, line_y + 2, 1), true)
    test.equal(buffer.lines[1], "- [x] todo\n")
    test.same(view:get_selection_state(), selection)
    local immediate_checkbox
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.markdown_task_checkbox then immediate_checkbox = fragment break end
    end
    immediate_checkbox = test.not_nil(immediate_checkbox)
    test.equal(immediate_checkbox.checked, true)
    test.equal(immediate_checkbox.widget.checked, true)
  end)

  test.it("reveals the complete task-list prefix when the caret enters its checkbox", function()
    local view, buffer = make_view(" - [ ] todo\nplain", "task-reveal.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:set_selection(1, 4)
    local task_source, checkbox
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.markdown_task_source_marker then task_source = fragment end
      if fragment.markdown_task_checkbox then checkbox = fragment end
    end
    task_source = test.not_nil(task_source)
    test.equal(task_source.text, "- [ ]")
    test.equal(task_source.unordered_list_source_marker, true)
    test.equal(task_source.widget, nil)
    test.equal(checkbox, nil)
  end)

  test.it("reveals the complete task-list prefix on the second Home", function()
    local view, buffer = make_view(
      "- [ ] parent\n    - [ ] test\nplain",
      "task-prefix-home.md"
    )
    buffer:set_selection(3, 1)
    refresh(view)

    buffer:set_selection(2, #buffer.lines[2])
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:move-to-start-of-indentation"), true)
      test.same({ buffer:get_selection() }, { 2, 11, 2, 11 })
      test.equal(command.perform("text:move-to-start-of-indentation"), true)
      test.same({ buffer:get_selection() }, { 2, 5, 2, 5 })

      local prefix, checkbox
      for _, fragment in ipairs(test.not_nil(view:get_line_render(2)).fragments or {}) do
        if fragment.markdown_task_source_marker
          and fragment.unordered_list_source_marker
        then
          prefix = fragment
        end
        if fragment.markdown_task_checkbox then checkbox = fragment end
      end
      prefix = test.not_nil(prefix)
      test.equal(prefix.text, "- [ ]")
      test.equal(checkbox, nil)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("reveals a marker-only task after moving left from implicit content", function()
    local view, buffer = make_view(
      "- [ ] parent\n    - [ ]\n    - [ ] sibling\nplain",
      "empty-task-caret-edge.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)

    local inactive = test.not_nil(view:get_line_render(2))
    local inactive_checkbox
    for _, fragment in ipairs(inactive.fragments or {}) do
      if fragment.markdown_task_checkbox then inactive_checkbox = fragment break end
    end
    inactive_checkbox = test.not_nil(inactive_checkbox)
    local checkbox_x = view:get_line_render_col_x_offset(
      inactive, inactive_checkbox.source_col1
    ) + (inactive_checkbox.draw_x_offset or 0)

    buffer:set_selection(2, 10)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      local implicit = test.not_nil(view:get_line_render(2))
      local implicit_checkbox
      for _, fragment in ipairs(implicit.fragments or {}) do
        if fragment.markdown_task_checkbox then implicit_checkbox = fragment break end
      end
      test.not_nil(implicit_checkbox)

      test.equal(command.perform("text:move-to-previous-char"), true)
      test.same({ buffer:get_selection() }, { 2, 10, 2, 10 })
      local active = test.not_nil(view:get_line_render(2))
      local checkbox, task_source
      for _, fragment in ipairs(active.fragments or {}) do
        if fragment.markdown_task_checkbox then checkbox = fragment end
        if fragment.markdown_task_source_marker then task_source = fragment end
      end
      task_source = test.not_nil(task_source)
      test.equal(checkbox, nil)
      local task_source_x = view:get_line_render_col_x_offset(
        active, task_source.text_source_col1 or task_source.source_col1
      )
      test.equal(task_source_x, checkbox_x)
      test.equal(
        view:get_col_x_offset(2, 10),
        task_source_x + task_source.font:get_width("- [ ] ")
      )

      view:update()
      local old_draw_rect = renderer.draw_rect
      local old_draw_text = renderer.draw_text
      local old_draw_text_known_bounds = renderer.draw_text_known_bounds
      local bracket_frames = 0
      renderer.draw_rect = function(_, _, _, _, color)
        if color == style.bracketmatch_frame_color then
          bracket_frames = bracket_frames + 1
        end
      end
      renderer.draw_text = function(font, text, x, _, _, opts)
        return x + font:get_width(text, opts)
      end
      renderer.draw_text_known_bounds = function(_, _, x, _, _, _, width)
        return x + width
      end
      local draw_ok, draw_err = pcall(function()
        local x, y = view:get_line_screen_position(2)
        view:draw_line_text(2, x, y)
      end)
      renderer.draw_rect = old_draw_rect
      renderer.draw_text = old_draw_text
      renderer.draw_text_known_bounds = old_draw_text_known_bounds
      if not draw_ok then error(draw_err, 0) end
      test.equal(bracket_frames, 0)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("does not draw a bracket frame through a marker-only task checkbox", function()
    local view, buffer = make_view("- [ ]\nplain", "task-checkbox-bracket-frame.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:set_selection(1, 6)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      view:update()
      local old_draw_rect = renderer.draw_rect
      local old_draw_text = renderer.draw_text
      local old_draw_text_known_bounds = renderer.draw_text_known_bounds
      local bracket_frames = 0
      renderer.draw_rect = function(_, _, _, _, color)
        if color == style.bracketmatch_frame_color then
          bracket_frames = bracket_frames + 1
        end
      end
      renderer.draw_text = function(font, text, x, _, _, opts)
        return x + font:get_width(text, opts)
      end
      renderer.draw_text_known_bounds = function(_, _, x, _, _, _, width)
        return x + width
      end
      local draw_ok, draw_err = pcall(function()
        local x, y = view:get_line_screen_position(1)
        view:draw_line_text(1, x, y)
      end)
      renderer.draw_rect = old_draw_rect
      renderer.draw_text = old_draw_text
      renderer.draw_text_known_bounds = old_draw_text_known_bounds
      if not draw_ok then error(draw_err, 0) end
      test.equal(bracket_frames, 0)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("moves down onto implicit task content without revealing its prefix", function()
    local view, buffer = make_view(
      "- [ ] parent\n    - [ ] test\n    - [ ]\nplain",
      "empty-task-vertical-affinity.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:set_selection(2, 15)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:move-to-next-line"), true)
      test.same({ buffer:get_selection() }, { 3, 10, 3, 10 })

      local checkbox, task_source
      for _, fragment in ipairs(test.not_nil(view:get_line_render(3)).fragments or {}) do
        if fragment.markdown_task_checkbox then checkbox = fragment end
        if fragment.markdown_task_source_marker then task_source = fragment end
      end
      test.not_nil(checkbox)
      test.equal(task_source, nil)

      test.equal(command.perform("text:move-to-previous-char"), true)
      test.same({ buffer:get_selection() }, { 3, 10, 3, 10 })
      local revealed_source
      for _, fragment in ipairs(test.not_nil(view:get_line_render(3)).fragments or {}) do
        if fragment.markdown_task_source_marker then revealed_source = fragment break end
      end
      test.equal(test.not_nil(revealed_source).text, "- [ ]")

      test.equal(command.perform("text:move-to-previous-char"), true)
      test.same({ buffer:get_selection() }, { 3, 9, 3, 9 })
      test.equal(command.perform("text:move-to-next-char"), true)
      test.same({ buffer:get_selection() }, { 3, 10, 3, 10 })
      local right_source
      for _, fragment in ipairs(test.not_nil(view:get_line_render(3)).fragments or {}) do
        if fragment.markdown_task_source_marker then right_source = fragment break end
      end
      test.equal(test.not_nil(right_source).text, "- [ ]")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("moves Home directly from implicit task content to the prefix start", function()
    local view, buffer = make_view(
      "- [ ] parent\n    - [ ] test\n    - [ ]\nplain",
      "empty-task-home-affinity.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:set_selection(2, 15)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:move-to-next-line"), true)
      test.same({ buffer:get_selection() }, { 3, 10, 3, 10 })
      test.equal(command.perform("text:move-to-start-of-indentation"), true)
      test.same({ buffer:get_selection() }, { 3, 5, 3, 5 })

      local prefix
      for _, fragment in ipairs(test.not_nil(view:get_line_render(3)).fragments or {}) do
        if fragment.markdown_task_source_marker then prefix = fragment break end
      end
      test.equal(test.not_nil(prefix).text, "- [ ]")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("renders a checkbox while constructing a marker-only task", function()
    local view, buffer = make_view("\nplain", "construct-task-prefix.md")
    buffer:set_selection(2, 1)
    refresh(view)

    buffer:set_selection(1, 1)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      for _, input in ipairs({ "-", " ", "[", " ", "]" }) do
        test.equal(view:on_text_input(input), true)
      end
      test.equal(buffer.lines[1], "- [ ]\n")
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_status(instance, "ready"), instance.reason)

      local prefix, checkbox
      for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
        if fragment.markdown_task_source_marker then prefix = fragment end
        if fragment.markdown_task_checkbox then checkbox = fragment end
      end
      test.equal(prefix, nil)
      test.not_nil(checkbox)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps a marker-only task rendered after backspacing from the next line", function()
    local view, buffer = make_view(
      "- [ ] text\n- [ ]\n\nplain",
      "empty-task-backspace-affinity.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:set_selection(3, 1)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:backspace"), true)
      test.same({ buffer:get_selection() }, { 2, 6, 2, 6 })
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_status(instance, "ready"), instance.reason)

      local prefix, checkbox
      for _, fragment in ipairs(test.not_nil(view:get_line_render(2)).fragments or {}) do
        if fragment.markdown_task_source_marker then prefix = fragment end
        if fragment.markdown_task_checkbox then checkbox = fragment end
      end
      test.equal(prefix, nil)
      test.not_nil(checkbox)
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("inserts the implicit task gap before typing on a marker-only item", function()
    local view, buffer = make_view(
      "- [ ] parent\n    - [ ]\n    - [ ] sibling\nplain",
      "empty-task-implicit-gap.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)

    buffer:set_selection(2, 10)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(view:on_text_input("a"), true)
      test.equal(buffer.lines[2], "    - [ ] a\n")

      local function task_checkbox()
        for _, fragment in ipairs(
          test.not_nil(view:get_line_render(2)).fragments or {}
        ) do
          if fragment.markdown_task_checkbox then return fragment end
        end
      end

      test.not_nil(task_checkbox())
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_status(instance, "ready"), instance.reason)
      test.not_nil(task_checkbox())
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("does not draw a generic hover box around task checkboxes", function()
    local view, buffer = make_view("- [ ] task\nplain", "task-hover.md")
    buffer:set_selection(2, 1)
    refresh(view)

    local checkbox
    for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
      if fragment.markdown_task_checkbox then checkbox = fragment break end
    end
    checkbox = test.not_nil(checkbox)
    test.equal(checkbox.widget.suppress_hover_overlay, true)
    test.equal(checkbox.widget.suppress_hover_background, true)
    checkbox.hovered = true

    local old_draw_rect = renderer.draw_rect
    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    local hover_rects = 0
    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.interactive_hover_overlay
        or color == style.interactive_hover_border
      then
        hover_rects = hover_rects + 1
      end
    end
    renderer.draw_text = function(font, text, x, _, _, opts)
      return x + font:get_width(text, opts)
    end
    renderer.draw_text_known_bounds = function(_, _, x, _, _, _, width)
      return x + width
    end
    local draw_ok, draw_err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_text(1, x, y)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    if not draw_ok then error(draw_err, 0) end
    test.equal(hover_rects, 0)
  end)

  test.it("selects and reveals the task-list prefix when dragging into it", function()
    local view, buffer = make_view(
      "- [ ] task body\n  continuation\nplain", "task-drag-selection.md"
    )
    buffer:set_selection(3, 1)
    refresh(view)

    local start_x, start_y = view:get_line_screen_position(1, 8)
    local finish_x, finish_y = view:get_line_screen_position(1, 1)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(command.perform("text:set-cursor", start_x, start_y + 2), true)
      view:on_mouse_moved(
        finish_x, finish_y + 2, finish_x - start_x, finish_y - start_y
      )
      view:on_mouse_released("left", finish_x, finish_y + 2)

      local line1, col1, line2, col2 = buffer:get_selection(true)
      test.same({ line1, col1, line2, col2 }, { 1, 1, 1, 8 })
      test.equal(buffer.lines[1], "- [ ] task body\n")

      local marker_source
      for _, fragment in ipairs(test.not_nil(view:get_line_render(1)).fragments or {}) do
        if fragment.markdown_task_source_marker then
          marker_source = fragment
          break
        end
      end
      test.equal(test.not_nil(marker_source).text, "- [ ]")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("presents ordered markers, hard breaks, and indented code without replacing source content", function()
    local view, buffer = make_view("    local code\nplain\n\n1. first\n   2. nested\n\nline  \nnext\nplain", "remaining-blocks.md")
    buffer:set_selection(9, 1)
    refresh(view)
    local ordered = test.not_nil(view:get_line_render(4))
    test.equal(ordered.fragments[1].text, "1.")
    local nested = test.not_nil(view:get_line_render(5))
    local has_nested_marker = false
    for _, fragment in ipairs(nested.fragments) do
      if fragment.text == "2." then has_nested_marker = true end
    end
    test.equal(has_nested_marker, true)
    local hard_break = test.not_nil(view:get_line_render(7))
    local break_fragment
    for _, fragment in ipairs(hard_break.fragments) do
      if fragment.hard_break then break_fragment = fragment break end
    end
    test.equal(test.not_nil(break_fragment).text, " ↵")
    test.equal(view:get_line_render(1), nil)
    buffer:set_selection(7, 6)
    test.equal(visible_render_text(view, 7), "line  ")
  end)

  test.it("numbers and spaces ordered list markers and reveals their source at the caret", function()
    local view, buffer = make_view(
      "1. first\n1. second\n   1. nested\n   1. nested second\n"
        .. "      continuation\n   1. nested third\n1. third\nplain\n1. restarted",
      "ordered-list-spacing.md"
    )
    buffer:set_selection(8, 1)
    refresh(view)

    local inactive = test.not_nil(view:get_line_render(2))
    local marker
    for _, fragment in ipairs(inactive.fragments or {}) do
      if fragment.ordered_list_marker then marker = fragment break end
    end
    marker = test.not_nil(marker)
    local content_x = view:get_col_x_offset(2, 4)
    test.equal(marker.text, "2.")
    test.ok(content_x >= live_body_font(view):get_width("1. "))
    local nested = test.not_nil(view:get_line_render(4))
    local nested_marker
    for _, fragment in ipairs(nested.fragments or {}) do
      if fragment.ordered_list_marker then nested_marker = fragment break end
    end
    test.equal(test.not_nil(nested_marker).text, "2.")
    test.equal(visible_render_text(view, 6):match("(%d+[.)])"), "3.")
    test.equal(visible_render_text(view, 7):match("(%d+[.)])"), "3.")
    test.equal(visible_render_text(view, 9):match("(%d+[.)])"), "1.")

    buffer:set_selection(2, 2)
    local active = test.not_nil(view:get_line_render(2))
    local source_marker
    for _, fragment in ipairs(active.fragments or {}) do
      if fragment.ordered_list_source_marker then source_marker = fragment break end
    end
    source_marker = test.not_nil(source_marker)
    test.equal(source_marker.text, "1. ")
    test.equal(view:get_col_x_offset(2, 4), content_x)
  end)

  test.it("resolves and presents full, collapsed, and shortcut reference links", function()
    local view, buffer = make_view("[Anvil buffers][buffers]\n[buffers][]\n[buffers]\n\n[buffers]: Guide.md \"Guide\"\nText[^note]\n[^note]: Footnote body\nplain", "references.md")
    buffer:set_selection(8, 1)
    refresh(view)
    view:get_line_render(1)
    local reference_deadline = system.get_time() + 5
    while system.get_time() < reference_deadline do
      local rendered = view:get_line_render(1)
      local ready = false
      for _, fragment in ipairs(rendered and rendered.fragments or {}) do
        if fragment.link and fragment.link.kind == "reference" then ready = true break end
      end
      if ready then break end
      coroutine.yield(0.01)
    end
    local expected = { "Anvil buffers", "buffers", "buffers" }
    for line = 1, 3 do
      local rendered = test.not_nil(view:get_line_render(line))
      local reference
      for _, fragment in ipairs(rendered.fragments) do
        if fragment.link and fragment.link.kind == "reference" then reference = fragment break end
      end
      reference = test.not_nil(reference)
      test.equal(reference.text, expected[line])
      test.equal(reference.link.raw_target, "Guide.md")
      test.equal(reference.link.reference_label, "buffers")
    end
    local definition = test.not_nil(view:get_line_render(5))
    test.equal(definition.fragments[1].reference_definition, "buffers")
    local footnote_reference = test.not_nil(view:get_line_render(6))
    local footnote
    for _, fragment in ipairs(footnote_reference.fragments) do
      if fragment.footnote then footnote = fragment break end
    end
    test.equal(test.not_nil(footnote).footnote, "note")
    local footnote_definition = test.not_nil(view:get_line_render(7))
    local definition_fragment
    for _, fragment in ipairs(footnote_definition.fragments) do
      if fragment.footnote_definition then definition_fragment = fragment break end
    end
    test.equal(test.not_nil(definition_fragment).footnote_definition, "note")
    buffer:set_selection(1, 4)
    local active_reference = test.not_nil(view:get_line_render(1))
    local active_link
    for _, fragment in ipairs(active_reference.fragments) do
      if fragment.link and fragment.link.kind == "reference" then active_link = fragment break end
    end
    active_link = test.not_nil(active_link)
    test.equal(active_link.text, "Anvil buffers")
  end)

  test.it("recognizes semantic Obsidian tags without treating numeric or word-bound hashes as tags", function()
    local view, buffer = make_view("text #project/anvil #123 C#code \\#escaped\nplain", "tags.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local rendered = test.not_nil(view:get_line_render(1))
    local tags = {}
    for _, fragment in ipairs(rendered.fragments) do
      if fragment.tag then tags[#tags + 1] = fragment end
    end
    test.equal(#tags, 1)
    test.equal(tags[1].text, "#project/anvil")
    test.equal(tags[1].tag, "project/anvil")
    buffer:set_selection(1, 8)
    local active = view:get_line_render(1)
    for _, fragment in ipairs(active and active.fragments or {}) do
      test.equal(fragment.tag, nil)
    end
  end)

  test.it("styles semantic frontmatter as source-preserving structured content", function()
    local view, buffer = make_view("---\naliases: [Example]\ntags:\n  - project/anvil\n---\n# Body", "properties.md")
    buffer:set_selection(6, 2)
    refresh(view)
    local opening = test.not_nil(view:get_line_render(1))
    test.equal(opening.fragments[1].text, "---")
    local property = test.not_nil(view:get_line_render(2))
    test.equal(property.fragments[1].text, "aliases")
    test.equal(property.fragments[2].text, ": ")
    local list_value = test.not_nil(view:get_line_render(4))
    test.equal(list_value.fragments[1].text, "  - project/anvil")

    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then markdown_decoration = entry.provider break end
    end
    markdown_decoration = test.not_nil(markdown_decoration)
    test.equal(markdown_decoration:line_background(view, 6), nil)

    buffer:set_selection(2, 3)
    test.equal(visible_render_text(view, 2), "aliases: [Example]")
  end)

  test.it("presents semantic callout headers, bodies, and unknown-type fallbacks", function()
    local view, buffer = make_view("> [!note]+ Custom title\n> body [[Target]]\n\n> [!mystery]\n> fallback\n\nplain", "callouts.md")
    buffer:set_selection(7, 1)
    refresh(view)
    local header = test.not_nil(view:get_line_render(1))
    local callout_fragment
    for _, fragment in ipairs(header.fragments) do
      if fragment.callout_type then callout_fragment = fragment break end
    end
    callout_fragment = test.not_nil(callout_fragment)
    test.not_nil(callout_fragment.text)
    test.equal(callout_fragment.callout_type, "note")
    test.equal(callout_fragment.callout_known_type, true)

    local body = test.not_nil(view:get_line_render(2))
    local has_callout_prefix, has_link = false, false
    for _, fragment in ipairs(body.fragments) do
      has_callout_prefix = has_callout_prefix or fragment.callout_semantic_id ~= nil
      has_link = has_link or fragment.link ~= nil
    end
    test.equal(has_callout_prefix, true)
    test.equal(has_link, true)

    local unknown = test.not_nil(view:get_line_render(4))
    local unknown_fragment
    for _, fragment in ipairs(unknown.fragments) do
      if fragment.callout_type then unknown_fragment = fragment break end
    end
    unknown_fragment = test.not_nil(unknown_fragment)
    test.not_nil(unknown_fragment.text)
    test.equal(unknown_fragment.callout_known_type, false)

    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then markdown_decoration = entry.provider break end
    end
    markdown_decoration = test.not_nil(markdown_decoration)
    test.equal(markdown_decoration:line_background(view, 7), nil)

    buffer:set_selection(1, 5)
    test.equal(visible_render_text(view, 1), "> [!note]+ Custom title")
  end)

  test.it("normalizes callout aliases case-insensitively and gives unknown types note appearance", function()
    local view, buffer = make_view(
      "> [!TLDR] Summary\n\n> [!Important] Important\n\n> [!CITE] Citation\n\n> [!custom-kind] Custom\n\nplain",
      "callout-types.md"
    )
    buffer:set_selection(9, 1)
    refresh(view)

    local function callout_fragment(line)
      for _, fragment in ipairs(test.not_nil(view:get_line_render(line)).fragments) do
        if fragment.callout_type then return fragment end
      end
    end

    local abstract = test.not_nil(callout_fragment(1))
    test.equal(abstract.callout_type, "tldr")
    test.equal(abstract.callout_canonical_type, "abstract")
    test.equal(abstract.callout_known_type, true)
    test.equal(test.not_nil(callout_fragment(3)).callout_canonical_type, "tip")
    test.equal(test.not_nil(callout_fragment(5)).callout_canonical_type, "quote")
    local unknown = test.not_nil(callout_fragment(7))
    test.equal(unknown.callout_type, "custom-kind")
    test.equal(unknown.callout_canonical_type, "note")
    test.equal(unknown.callout_known_type, false)
    test.not_nil(unknown.callout_icon)
  end)

  test.it("uses inset callout card descriptors and aligns wrapped body text with titles", function()
    local header_source = "> [!warning] Long custom title that wraps across several visual rows"
    local body_source = "> Body text that wraps across several visual rows as well"
    local view, buffer = make_view(header_source .. "\n" .. body_source .. "\nplain", "callout-card.md")
    view.size.x = 220
    view:set_wrapping_enabled(true)
    buffer:set_selection(3, 1)
    refresh(view)

    local header = test.not_nil(view:get_line_render(1))
    local body = test.not_nil(view:get_line_render(2))
    local title_col = test.not_nil(header_source:find("Long", 1, true))
    local body_col = test.not_nil(body_source:find("Body", 1, true))
    test.equal(header.continuation_indent_col, title_col)
    test.equal(body.continuation_indent_col, body_col)
    test.equal(view:get_col_x_offset(1, title_col), view:get_col_x_offset(2, body_col))

    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then markdown_decoration = entry.provider break end
    end
    markdown_decoration = test.not_nil(markdown_decoration)
    local header_card = test.not_nil(markdown_decoration:line_background_descriptor(view, 1))
    local body_card = test.not_nil(markdown_decoration:line_background_descriptor(view, 2))
    test.equal(header_card.kind, "markdown-callout-card")
    test.equal(header_card.semantic_id, body_card.semantic_id)
    test.ok(header_card.x_offset > 0)
    test.not_nil(header_card.rail_color)
    test.not_nil(header_card.color)
    test.equal(header_card.first, true)
    test.equal(body_card.last, true)
  end)

  test.it("keeps revealed callout source inside the card and styles its marker", function()
    local source = ">[!note] NOTE: A long title whose revealed source wraps across visual rows"
    local view, buffer = make_view(source .. "\nplain", "callout-source-reveal.md")
    view.size.x = 220
    view:set_wrapping_enabled(true)
    buffer:set_selection(2, 1)
    refresh(view)
    buffer:set_selection(1, 5)

    local render = test.not_nil(view:get_line_render(1))
    local marker
    for _, fragment in ipairs(render.fragments or {}) do
      if fragment.callout_source_marker then marker = fragment break end
    end
    marker = test.not_nil(marker)
    test.equal(marker.text, "[!note]")
    test.equal(
      marker.color,
      style.markdown_live_callout_palette.note.accent
    )

    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then markdown_decoration = entry.provider break end
    end
    local card = test.not_nil(
      test.not_nil(markdown_decoration):line_background_descriptor(view, 1)
    )
    test.ok(test.not_nil(render.x_offset) > card.x_offset + card.rail_width)
    test.equal(render.continuation_indent_col, source:find("NOTE", 1, true))
    test.equal(visible_render_text(view, 1), source)
  end)

  test.it("folds only callout bodies and updates defaults when fold signs change", function()
    local view, buffer = make_view(
      "> [!note]- Folded title\n> hidden body\n> second body line\n\nplain",
      "foldable-callout.md"
    )
    buffer:set_selection(5, 1)
    refresh(view)

    local fold
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then fold = candidate break end
    end
    fold = test.not_nil(fold)
    test.equal(fold.collapsed, true)
    test.equal(fold.show_widget, false)
    test.equal(fold.line1, 1)
    test.equal(fold.line2, 3)
    test.equal(view:is_line_hidden_by_fold(1), false)
    test.equal(view:is_line_hidden_by_fold(2), true)
    test.not_nil(view:get_line_render(1))
    test.equal(view:get_visual_row_entry(1).type, "line")

    local header = test.not_nil(view:get_line_render(1))
    local control
    for _, fragment in ipairs(header.fragments) do
      if fragment.callout_type then control = fragment break end
    end
    control = test.not_nil(control)
    local line_x, line_y = view:get_line_screen_position(1)
    local control_x = line_x
      + view:get_line_render_col_x_offset(header, control.source_col1) + 2
    test.equal(view:on_mouse_pressed("left", control_x, line_y + view:get_line_height() / 2, 1), true)
    test.equal(fold.collapsed, false)

    test.equal(view:on_mouse_pressed("left", control_x, line_y + view:get_line_height() / 2, 1), true)
    test.equal(fold.collapsed, true)
    buffer:apply_edits({
      { line1 = 1, col1 = 10, line2 = 1, col2 = 11, text = "+" },
    }, { type = "callout-fold-sign", merge_cursors = false })
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    local updated
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then updated = candidate break end
    end
    test.equal(test.not_nil(updated).collapsed, false)

    buffer:apply_edits({
      { line1 = 1, col1 = 10, line2 = 1, col2 = 11, text = "" },
    }, { type = "callout-fold-sign", merge_cursors = false })
    test.ok(wait_status(instance, "ready"), instance.reason)
    for _, candidate in ipairs(view.fold_regions) do
      test.ok(candidate.kind ~= "markdown-callout")
    end

    buffer:apply_edits({
      { line1 = 1, col1 = 10, line2 = 1, col2 = 10, text = "-" },
    }, { type = "callout-fold-sign", merge_cursors = false })
    test.ok(wait_status(instance, "ready"), instance.reason)
    local restored
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then restored = candidate break end
    end
    test.equal(test.not_nil(restored).collapsed, true)
  end)

  test.it("retains independent nested callout fold state", function()
    local view, buffer = make_view(
      "> [!question]+ Outer\n> > [!note]- Inner\n> > hidden inner body\n> outer body\n\nplain",
      "nested-callout-folds.md"
    )
    buffer:set_selection(6, 1)
    refresh(view)

    local outer, inner
    for _, fold in ipairs(view.fold_regions) do
      if fold.kind == "markdown-callout" then
        local depth = fold.metadata and fold.metadata.nesting_depth
        if depth == 1 then outer = fold elseif depth == 2 then inner = fold end
      end
    end
    outer, inner = test.not_nil(outer), test.not_nil(inner)
    test.equal(outer.collapsed, false)
    test.equal(inner.collapsed, true)
    test.equal(view:is_line_hidden_by_fold(2), false)
    test.equal(view:is_line_hidden_by_fold(3), true)

    test.equal(view:collapse_fold_region(outer, "test-outer"), true)
    test.equal(inner.collapsed, true)
    test.equal(view:is_line_hidden_by_fold(2), true)
    test.equal(view:expand_fold_region(outer, "test-outer"), true)
    test.equal(inner.collapsed, true)
    test.equal(view:is_line_hidden_by_fold(3), true)
  end)

  test.it("preserves callout fold state across body edits and expands for hidden carets", function()
    local view, buffer = make_view(
      "> [!tip]+ Stable\n> body text\n> more body\n\nplain",
      "callout-fold-state.md"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local fold
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then fold = candidate break end
    end
    fold = test.not_nil(fold)
    test.equal(view:collapse_fold_region(fold, "test-state"), true)

    buffer:insert(2, #buffer.lines[2], " updated")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.ok(wait_status(instance, "ready"), instance.reason)
    local reconciled
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then reconciled = candidate break end
    end
    reconciled = test.not_nil(reconciled)
    test.equal(reconciled.collapsed, true)

    buffer:set_selection(2, 3)
    test.equal(reconciled.collapsed, false)
    test.equal(view:is_line_hidden_by_fold(2), nil)
  end)

  test.it("keeps callout fold state while Source Mode exposes all source", function()
    local view, buffer = make_view(
      "> [!warning]- Hidden\n> body\n\nplain",
      "callout-source-mode.md"
    )
    buffer:set_selection(4, 1)
    refresh(view)
    local fold
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then fold = candidate break end
    end
    test.equal(test.not_nil(fold).collapsed, true)

    markdown.live_render.set_source_mode(view, true, "test-callout-source")
    for _, candidate in ipairs(view.fold_regions) do
      test.ok(candidate.kind ~= "markdown-callout")
    end
    test.equal(view:get_line_render(1), nil)
    markdown.live_render.set_source_mode(view, false, "test-callout-live")

    local restored
    for _, candidate in ipairs(view.fold_regions) do
      if candidate.kind == "markdown-callout" then restored = candidate break end
    end
    test.equal(test.not_nil(restored).collapsed, true)
  end)

  test.it("composes links, tasks, and fenced code inside callout cards", function()
    local view, buffer = make_view(
      "> [!success] Content\n> - [ ] Task [[Target]]\n> ```lua\n> print('ok')\n> ```\n\nplain",
      "callout-content.md"
    )
    buffer:set_selection(7, 1)
    refresh(view)

    local task = test.not_nil(view:get_line_render(2))
    local has_checkbox, has_link, has_callout_prefix = false, false, false
    for _, fragment in ipairs(task.fragments or {}) do
      has_checkbox = has_checkbox or fragment.markdown_task_checkbox == true
      has_link = has_link or fragment.link ~= nil
      has_callout_prefix = has_callout_prefix or fragment.callout_semantic_id ~= nil
    end
    test.equal(has_checkbox, true)
    test.equal(has_link, true)
    test.equal(has_callout_prefix, true)

    local code = test.not_nil(view:get_line_render(4))
    test.ok(code.x_offset > 0)
    local markdown_decoration
    for _, entry in ipairs(view:decoration_provider_entries()) do
      if entry.id == "markdown-live" then markdown_decoration = entry.provider break end
    end
    local code_card = test.not_nil(
      test.not_nil(markdown_decoration):line_background_descriptor(view, 4)
    )
    test.equal(code_card.kind, "markdown-callout-card")
    test.equal(code_card.color, style.markdown_live_code_background)
  end)

  test.it("presents semantic thematic breaks and reveals their source when active", function()
    local view, buffer = make_view("before\n\n---\n\nafter", "rule.md")
    buffer:set_selection(5, 1)
    refresh(view)
    local rule = test.not_nil(view:get_line_render(3))
    test.not_nil(rule.fragments[1].text)
    buffer:set_selection(3, 2)
    test.equal(visible_render_text(view, 3), "---")
  end)

  test.it("keeps inactive fence padding and reveals the whole fence while editing it", function()
    local view, buffer = make_view("```lua\nprint('ok')\n```\nplain", "fence.md")
    buffer:set_selection(4, 1)
    refresh(view)
    view:invalidate_line_render("fence-ready")
    local opening = test.not_nil(view:get_line_render(1))
    test.equal(opening.fragments[1].hidden, true)
    test.ok(test.not_nil(view:get_line_render(2)).x_offset > 0)
    local closing = test.not_nil(view:get_line_render(3))
    test.equal(closing.fragments[1].hidden, true)

    buffer:set_selection(2, 4)
    test.equal(view:get_line_render(1), nil)
    test.equal(view:get_line_render(3), nil)
  end)

  test.it("insets fenced code content without moving revealed fence delimiters", function()
    local view, buffer = make_view("```lua\nprint('ok')\n```\nplain", "fence-padding.md")
    buffer:set_selection(4, 1)
    refresh(view)

    local content_inset = view:get_col_x_offset(2, 1)
    test.ok(content_inset > 0, "expected fenced code content to have a left inset")
    test.equal(
      view:get_col_x_offset(2, #"print('ok')" + 1),
      content_inset + view:get_font():get_width("print('ok')")
    )
    test.equal(view:get_x_offset_col(2, content_inset / 2), 1)

    local old_draw_text = renderer.draw_text
    local first_text_x
    renderer.draw_text = function(font, text, x, y, color, opts)
      if text ~= "" and not first_text_x then first_text_x = x end
      return x + font:get_width(text, opts)
    end
    local ok, err = pcall(view.draw_line_text, view, 2, 100, 0)
    renderer.draw_text = old_draw_text
    if not ok then error(err) end
    test.equal(first_text_x, 100 + content_inset)

    buffer:set_selection(2, 4)
    test.equal(view:get_col_x_offset(1, 1), 0)
    test.equal(view:get_col_x_offset(2, 1), content_inset)
    test.equal(view:get_col_x_offset(3, 1), 0)
  end)

  test.it("reveals fence delimiters when a selection crosses the whole block", function()
    local view, buffer = make_view(
      "before\n```lua\nprint('ok')\n```\nafter\n", "fence-crossing-selection.md"
    )
    buffer:set_selection(1, 1)
    refresh(view)
    test.equal(test.not_nil(view:get_line_render(2)).fragments[1].hidden, true)
    test.equal(test.not_nil(view:get_line_render(4)).fragments[1].hidden, true)

    buffer:set_selection(1, 1, 5, 1)

    test.equal(view:get_line_render(2), nil)
    test.equal(view:get_line_render(4), nil)
  end)

  test.it("presents Setext headings through the semantic heading path", function()
    local view, buffer = make_view("Setext title\n============\nplain", "setext.md")
    buffer:set_selection(3, 1)
    refresh(view)

    local rendered = test.not_nil(view:get_line_render(1))
    test.not_nil(rendered.fragments[1].text)
    local marker = test.not_nil(view:get_line_render(2))
    test.equal(marker.fragments[1].hidden, true)
    buffer:set_selection(2, 3)
    test.equal(visible_render_text(view, 2), "============")
  end)

  test.it("keeps source visible for a tab-indented fence-like block", function()
    local view, buffer = make_view(
      "- item\n\t```\n\tselect first_row\nfrom second_row\n\t```\nplain",
      "tab-indented-fence.md"
    )
    buffer:set_selection(6, 1)
    refresh(view)
    local rendered = view:get_line_render(3)
    if rendered then
      local visible = {}
      for _, fragment in ipairs(rendered.fragments or {}) do
        if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
      end
      visible = table.concat(visible)
      test.ok(
        visible:find("select first_row", 1, true),
        "the first code source line disappeared outside the caret"
      )
    end
  end)

  test.it("presents inactive GFM tables as an aligned compact grid", function()
    config.markdown_live_interactive_tables = true
    local view, buffer = make_view("| Name | Value |\n| :--- | ---: |\n| one | two |\n\nplain", "table.md")
    buffer:set_selection(5, 1)
    refresh(view)
    local header = test.not_nil(view:get_line_render(1))
    local header_cells = 0
    for _, fragment in ipairs(header.fragments) do
      if fragment.table_cell then
        header_cells = header_cells + 1
        test.equal(fragment.table_alignment, header_cells == 2 and "right" or "left")
      elseif fragment.table_border then
        test.not_nil(fragment.widget)
        test.equal(fragment.text or "", "")
      end
    end
    test.equal(header_cells, 2)
    local row = test.not_nil(view:get_line_render(3))
    local row_cells = 0
    for _, fragment in ipairs(row.fragments) do
      if fragment.table_cell then
        row_cells = row_cells + 1
      end
    end
    test.equal(row_cells, 2)
    local delimiter = test.not_nil(view:get_line_render(2))
    test.not_nil(delimiter.fragments[1].widget)
    buffer:insert(3, 3, "a much longer value ")
    local instance = test.not_nil(markdown_model.peek(buffer))
    test.equal(instance.status, "pending")
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(visible_render_text(view, 3):find("a much longer value", 1, true))

    buffer:set_selection(3, 4)
    local active_row = test.not_nil(view:get_line_render(3))
    local active_cells = 0
    for _, fragment in ipairs(active_row.fragments or {}) do
      if fragment.table_cell then active_cells = active_cells + 1 end
    end
    test.equal(active_cells, 2)
  end)

  test.it("wraps long table cells inside aligned variable-height rows", function()
    config.markdown_live_interactive_tables = true
    local view, buffer = make_view(
      "| Command | Action |\n| --- | --- |\n"
        .. "| `/rp_campaign_status` | Show scene, turn, configuration, and Git state |\n"
        .. "| `/rp_recap` | Recap the story without advancing it |\n\nplain",
      "wrapped-table.md"
    )
    view.size.x = 380
    view:set_wrapping_enabled(true)
    buffer:set_selection(6, 1)
    refresh(view)

    local row = test.not_nil(view:get_line_render(3))
    test.equal(row.disable_wrapping, true)
    local _, _, wrapped_rows = linewrapping.get_line_idx_col_count(view, 3)
    test.equal(wrapped_rows, 1)
    local wrapped_cell
    local code_cell
    for _, fragment in ipairs(row.fragments or {}) do
      if fragment.table_cell and fragment.table_column == 1 then code_cell = fragment end
      if fragment.table_cell and #(fragment.text_lines or {}) > 1 then
        wrapped_cell = fragment
      end
    end
    wrapped_cell = test.not_nil(wrapped_cell)
    test.not_nil(code_cell)
    test.ok(not (code_cell.text_lines[1].text or ""):find("`", 1, true))
    test.equal(#code_cell.text_lines, 1)
    test.ok(view:get_visual_row_height(3) > view:get_line_height())

    local wrapped_x = 0
    for _, fragment in ipairs(row.fragments or {}) do
      if fragment == wrapped_cell then break end
      wrapped_x = wrapped_x + (fragment.width or 0)
    end
    local continuation = test.not_nil(wrapped_cell.text_lines[2])
    local line_x, line_y = view:get_line_screen_position(3)
    local hit_line, hit_col = view:resolve_screen_position(
      line_x + wrapped_x + continuation.x_offset + 1,
      line_y + wrapped_cell.text_y_padding + wrapped_cell.text_line_height + 1
    )
    test.equal(hit_line, 3)
    test.ok(hit_col >= continuation.source_col1)
    test.ok(hit_col <= continuation.source_col2)
  end)

  test.it("keeps empty table-cell source mappings valid", function()
    config.markdown_live_interactive_tables = true
    local view, buffer = make_view(
      "| A | B |\n| --- | --- |\n|   | value |\n\nplain",
      "empty-table-cell.md"
    )
    buffer:set_selection(5, 1)
    refresh(view)
    local row = test.not_nil(view:get_line_render(3))
    local empty
    for _, fragment in ipairs(row.fragments or {}) do
      if fragment.table_cell and fragment.table_column == 1 then empty = fragment break end
    end
    empty = test.not_nil(empty)
    test.equal(empty.text, "")
    test.equal(empty.text_source_col1, empty.text_source_col2)
    test.ok(empty.text_source_col1 >= empty.source_col1)
    test.ok(empty.text_source_col2 <= empty.source_col2)
  end)

  test.it("edits canonical GFM table rows and columns through commands", function()
    local view, buffer = make_view("| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n\nplain", "table-commands.md")
    local old_active = core.active_view
    core.active_view = view
    local function reparse()
      markdown_model.get(buffer):submit("table-command-test")
      refresh(view)
    end
    local ok, err = pcall(function()
      buffer:set_selection(3, 3)
      refresh(view)
      test.equal(command.perform("markdown-live-preview:table-insert-row-below"), true)
      test.equal(buffer.lines[4], "|  |  |\n")
      buffer:undo(); reparse()

      buffer:set_selection(3, 3)
      test.equal(command.perform("markdown-live-preview:table-delete-row"), true)
      test.equal(buffer.lines[3], "| 3 | 4 |\n")
      buffer:undo(); reparse()

      buffer:set_selection(3, 3)
      test.equal(command.perform("markdown-live-preview:table-move-row-down"), true)
      test.equal(buffer.lines[3], "| 3 | 4 |\n")
      test.equal(buffer.lines[4], "| 1 | 2 |\n")
      buffer:undo(); reparse()

      buffer:set_selection(3, 3)
      test.equal(command.perform("markdown-live-preview:table-insert-column-right"), true)
      test.equal(buffer.lines[1], "| A |  | B |\n")
      test.equal(buffer.lines[3], "| 1 |  | 2 |\n")
      buffer:undo(); reparse()

      buffer:set_selection(3, 3)
      test.equal(command.perform("markdown-live-preview:table-delete-column"), true)
      test.equal(buffer.lines[1], "| B |\n")
      test.equal(buffer.lines[3], "| 2 |\n")
      buffer:undo(); reparse()

      buffer:set_selection(3, 3)
      test.equal(command.perform("markdown-live-preview:table-move-column-right"), true)
      test.equal(buffer.lines[1], "| B | A |\n")
      test.equal(buffer.lines[3], "| 2 | 1 |\n")
    end)
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("presents resolved note, heading, and block embeds as bounded visual rows", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-note-embeds-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local function write(path, text)
      local fp = test.not_nil(io.open(path, "wb")); fp:write(text); fp:close()
    end
    local target = root .. PATHSEP .. "Target.md"
    write(target, "# Target\nfirst\nsecond\n\n## Child\nchild text\n\nblock content ^block-id\n")
    local source = root .. PATHSEP .. "Source.md"
    write(source, "![[Target]]\n![[Target#Child]]\n![[Target#^block-id]]\nplain\n")
    local old_projects = core.projects
    core.projects = { Project(root) }
    local index = markdown.vault_index.get_index(root):rebuild("embed-ui-test")
    local view, buffer = make_view("![[Target]]\n![[Target#Child]]\n![[Target#^block-id]]\nplain", source)
    buffer:set_selection(4, 1)
    refresh(view)
    local render_provider
    for _, entry in ipairs(view:line_render_provider_entries()) do
      if entry.id == "markdown-live" then render_provider = entry.provider break end
    end
    render_provider = test.not_nil(render_provider)
    local ok, err = pcall(function()
      local function preview(line)
        local rendered = test.not_nil(render_provider:render_line(view, line))
        for _, fragment in ipairs(rendered.fragments or {}) do
          if fragment.embed_preview then return fragment end
        end
      end
      local note_preview = test.not_nil(preview(1))
      test.same(note_preview.preview_lines, { "Target", "first", "second" })
      test.equal(note_preview.widget.type, "markdown-embed-preview")
      test.same(test.not_nil(preview(2)).preview_lines, { "child text", "block content" })
      test.same(test.not_nil(preview(3)).preview_lines, { "block content" })
      test.equal(preview(4), nil)
      test.equal(index.status, "ready")
    end)
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("presents inline and display math as styled editable source", function()
    local view, buffer = make_view("Inline $x^2 + y^2$ text\n\n$$\na + b\n$$\nplain", "math.md")
    buffer:set_selection(6, 1)
    refresh(view)
    local inline = test.not_nil(view:get_line_render(1))
    local inline_math
    for _, fragment in ipairs(inline.fragments) do
      if fragment.math_source then inline_math = fragment break end
    end
    inline_math = test.not_nil(inline_math)
    test.equal(inline_math.text, "$x^2 + y^2$")
    for line = 3, 5 do
      local rendered = test.not_nil(view:get_line_render(line))
      local found = false
      for _, fragment in ipairs(rendered.fragments) do
        if fragment.math_source then found = true end
      end
      test.equal(found, true)
    end
    buffer:set_selection(1, 10)
    test.equal(visible_render_text(view, 1), "Inline $x^2 + y^2$ text")
  end)

  test.it("presents non-image attachment links and embeds as source-preserving chips", function()
    local view, buffer = make_view("![[manual.pdf]] [[song.mp3|Audio]] [clip](movie.mp4)\nplain", "attachments.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local rendered = test.not_nil(view:get_line_render(1))
    local chips = {}
    for _, fragment in ipairs(rendered.fragments) do
      if fragment.attachment_chip then chips[#chips + 1] = fragment end
    end
    test.equal(#chips, 3)
    test.equal(chips[1].text, "▣ manual.pdf")
    test.equal(chips[1].attachment_kind, "pdf")
    test.equal(chips[2].text, "♪ Audio")
    test.equal(chips[2].attachment_kind, "audio")
    test.equal(chips[3].text, "▶ clip")
    test.equal(chips[3].attachment_kind, "video")
    for _, chip in ipairs(chips) do
      test.equal(chip.cursor, "hand")
    end

    buffer:set_selection(1, 4)
    local active = view:get_line_render(1)
    local remaining_chips = 0
    for _, fragment in ipairs(active and active.fragments or {}) do
      if fragment.attachment_chip then
        remaining_chips = remaining_chips + 1
        test.ok(fragment.source_col1 > 1)
      end
    end
    test.equal(remaining_chips, 2)
  end)

  test.it("imports clipboard image data through generic paste routing", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-clipboard-project-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local old_projects, old_active = core.projects, core.active_view
    local old_get_clipboard = system.get_clipboard
    local old_get_clipboard_data = system.get_clipboard_data
    core.projects = { Project(root) }
    local view, buffer = make_view("start ", root .. PATHSEP .. "Source.md")
    buffer:set_selection(1, 7)
    refresh(view)
    core.active_view = view
    system.get_clipboard = function() return "" end
    system.get_clipboard_data = function(mime)
      if mime == "image/png" then return "png clipboard bytes" end
    end
    local ok, err = pcall(function()
      test.equal(command.perform("text:paste"), true)
      test.ok(buffer.lines[1]:match("^start !%[%[attachments/pasted%-image[^]]*%.png%]%]\n$"))
      local relative = buffer.lines[1]:match("!%[%[(.-)%]%]")
      test.equal(system.get_file_info(root .. PATHSEP .. relative).type, "file")
    end)
    system.get_clipboard = old_get_clipboard
    system.get_clipboard_data = old_get_clipboard_data
    core.projects, core.active_view = old_projects, old_active
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("copies dropped attachments and inserts configured source-preserving links", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-attachment-project-" .. system.get_process_id()
    local outside = USERDIR .. PATHSEP .. "markdown-live-attachment-source-" .. system.get_process_id()
    test.ok(common.mkdirp(root .. PATHSEP .. "notes"))
    test.ok(common.mkdirp(outside))
    local image_source = outside .. PATHSEP .. "photo.png"
    local pdf_path = root .. PATHSEP .. "file.pdf"
    local function write(path, text)
      local fp = test.not_nil(io.open(path, "wb")); fp:write(text); fp:close()
    end
    write(image_source, "png")
    write(pdf_path, "pdf")
    local old_projects = core.projects
    local old_folder = config.markdown_live_attachment_folder
    local old_format = config.markdown_live_attachment_link_format
    core.projects = { Project(root) }
    config.markdown_live_attachment_folder = "media"
    config.markdown_live_attachment_link_format = "wikilink"
    local view, buffer = make_view("start ", root .. PATHSEP .. "notes" .. PATHSEP .. "Source.md")
    buffer:set_selection(1, 7)
    refresh(view)
    local ok, err = pcall(function()
      local inserted, result = markdown.attachments.import_file(view, image_source)
      test.equal(inserted, true)
      test.equal(result.copied, true)
      test.equal(buffer.lines[1], "start ![[media/photo.png]]\n")
      test.equal(system.get_file_info(root .. PATHSEP .. "media" .. PATHSEP .. "photo.png").type, "file")

      buffer:set_selection(1, #buffer.lines[1])
      inserted, result = markdown.attachments.import_file(view, image_source)
      test.equal(inserted, true)
      test.ok(result.path:match("photo%-1%.png$"))

      local x, y = view:get_line_screen_position(1)
      test.equal(view:on_file_dropped(image_source, x + 2, y + 2), true)
      test.ok(buffer.lines[1]:find("![[media/photo-2.png]]", 1, true) ~= nil)

      config.markdown_live_attachment_link_format = "markdown"
      buffer:set_selection(1, #buffer.lines[1])
      inserted, result = markdown.attachments.import_file(view, pdf_path)
      test.equal(inserted, true)
      test.equal(result.copied, false)
      test.equal(result.text, "[file](../file.pdf)")
      test.ok(buffer.lines[1]:find(result.text, 1, true) ~= nil)
      buffer:undo()
      test.equal(buffer.lines[1]:find("[file](../file.pdf)", 1, true), nil)
      buffer:redo()
      test.ok(buffer.lines[1]:find("[file](../file.pdf)", 1, true) ~= nil)
    end)
    config.markdown_live_attachment_folder = old_folder
    config.markdown_live_attachment_link_format = old_format
    core.projects = old_projects
    common.rm(root, true)
    common.rm(outside, true)
    if not ok then error(err, 0) end
  end)

  test.it("keeps one-shot remote image permission view-local and Project trust shared", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-remote-policy-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local source_path = root .. PATHSEP .. "Source.md"
    local old_projects = core.projects
    local old_trust = config.markdown_live_trusted_remote_image_projects
    core.projects = { Project(root) }
    config.markdown_live_trusted_remote_image_projects = {}
    local view, buffer = make_view("![Remote](https://example.com/image.png)\nplain", source_path)
    local split = Editor(buffer)
    markdown.live_render.refresh_view(split)
    buffer:set_selection(2, 1)
    refresh(view)
    local blocked
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.image_status then blocked = fragment break end
    end
    blocked = test.not_nil(blocked)
    test.equal(blocked.text, "[remote image blocked: Remote]")
    buffer:set_selection(1, 15)
    local old_active = core.active_view
    core.active_view = view
    local ok, err = pcall(function()
      test.equal(markdown.live_render.remote_image_allowed(view, "https://example.com/image.png"), false)
      test.equal(command.perform("markdown-live-preview:load-remote-image"), true)
      test.equal(markdown.live_render.remote_image_allowed(view, "https://example.com/image.png"), true)
      test.equal(markdown.live_render.remote_image_allowed(split, "https://example.com/image.png"), false)

      test.equal(command.perform("markdown-live-preview:trust-project-remote-images"), true)
      test.equal(markdown.live_render.remote_image_allowed(split, "https://example.com/image.png"), true)
      test.equal(command.perform("markdown-live-preview:untrust-project-remote-images"), true)
      test.equal(markdown.live_render.remote_image_allowed(split, "https://example.com/image.png"), false)
    end)
    markdown.live_render.release(split, "test-cleanup")
    core.active_view = old_active
    config.markdown_live_trusted_remote_image_projects = old_trust
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("renders project-local image fragments", function(context)
    local image_path = USERDIR .. PATHSEP .. "markdown-live-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()

    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, buffer = make_view("![Alt](" .. image_url .. ")\nother", USERDIR .. PATHSEP .. "note.md")
    buffer:set_selection(2, 1)
    local old_load_image = canvas.load_image
    local old_draw_canvas = renderer.draw_canvas
    local old_draw_text = renderer.draw_text
    local drawn = 0
    local drawn_text = {}
    local old_draw_rect = renderer.draw_rect
    canvas.load_image = function(path)
      test.equal(path, image_path)
      return {
        get_size = function() return 64, 32 end,
        scaled = function(self) return self end,
      }
    end
    renderer.draw_canvas = function() drawn = drawn + 1 end
    renderer.draw_rect = function() end
    renderer.draw_text = function(font, text, x, y, color, opts)
      drawn_text[#drawn_text + 1] = text
      return x + font:get_width(text, opts)
    end

    refresh(view)
    drawn, drawn_text = 0, {}
    local image_fragment_result
    for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
      if fragment.widget then image_fragment_result = fragment break end
    end
    test.not_nil(test.not_nil(image_fragment_result).semantic_id)
    local inactive_height = view:get_visual_row_height(1)
    test.ok(inactive_height > 32)
    buffer:set_selection(1, 1)
    test.ok(view:get_visual_row_height(1) > inactive_height)
    local active_render_line = test.not_nil(view:get_line_render(1))
    local rendered_line, source_row = view:get_position_line_render_row(1, 1)
    test.equal(rendered_line, active_render_line)
    test.not_nil(source_row)
    test.equal(source_row.source_col1, 1)
    test.equal(source_row.source_col2, #buffer.lines[1])
    test.ok(
      active_render_line.layout_height > source_row.height,
      "the revealed image source must occupy its own row above the image"
    )
    view:draw_line_text(1, 0, 0)
    test.equal(table.concat(drawn_text), "![Alt](" .. image_url .. ")")
    buffer:set_selection(2, 1)
    test.equal(view:get_visual_row_height(1), inactive_height)
    test.equal(view:get_x_offset_col(1, 1), 1)
    view:draw_line_text(1, 0, 0)

    canvas.load_image = old_load_image
    renderer.draw_canvas = old_draw_canvas
    renderer.draw_text = old_draw_text
    renderer.draw_rect = old_draw_rect
    os.remove(image_path)
    test.equal(drawn, 2)
  end)

  test.it("reveals raw source when the caret enters an unavailable image embed", function()
    local source = "![[missing-image-" .. system.get_process_id() .. ".png]]"
    local view, buffer = make_view(source .. "\nother", USERDIR .. PATHSEP .. "missing-image-note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    test.match(visible_render_text(view, 1), "[image unavailable:", nil, true)

    buffer:set_selection(1, 5)
    test.equal(visible_render_text(view, 1), source)
  end)

  test.it("reveals image source at its right edge for both link syntaxes", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-source-caret-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local source = "![Alt](" .. image_url .. ")"
    local view, buffer = make_view(source .. "\nother", USERDIR .. PATHSEP .. "note.md")
    buffer:set_selection(1, #source + 1)
    local old_load_image = canvas.load_image
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end

    refresh(view)
    local render_line = test.not_nil(view:get_line_render(1))
    local visible = {}
    for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
      if not fragment.hidden then visible[#visible + 1] = fragment.text or "" end
    end
    local wiki_source = "![[" .. image_url .. "]]"
    local wiki_view, wiki_buffer = make_view(
      wiki_source .. "\nother", USERDIR .. PATHSEP .. "wiki-note.md"
    )
    wiki_buffer:set_selection(1, #wiki_source + 1)
    refresh(wiki_view)
    local wiki_visible = {}
    for _, fragment in ipairs(wiki_view:iter_line_render_fragments(
      test.not_nil(wiki_view:get_line_render(1))
    )) do
      if not fragment.hidden then wiki_visible[#wiki_visible + 1] = fragment.text or "" end
    end

    canvas.load_image = old_load_image
    os.remove(image_path)
    test.equal(table.concat(visible), source)
    test.equal(table.concat(wiki_visible), wiki_source)
  end)

  test.it("moves up from the following Buffer line into text below an inline image", function()
    with_inline_image_text_fixture(function(view, buffer, fixture)
      local old_active = core.active_view
      core.active_view = view
      buffer:set_selection(2, 1)
      command.perform("text:move-to-previous-line")
      local line, col = buffer:get_selection()
      test.equal(line, 1)
      test.equal(col, fixture.image_end)

      command.perform("text:move-to-previous-line")
      line, col = buffer:get_selection()
      test.equal(line, 1)
      test.equal(col, 1)

      command.perform("text:move-to-next-line")
      line, col = buffer:get_selection()
      test.equal(line, 1)
      test.equal(col, fixture.image_end)

      command.perform("text:move-to-next-line")
      core.active_view = old_active
      line, col = buffer:get_selection()
      test.equal(line, 2)
      test.equal(col, 1)
    end)
  end)

  test.it("keeps scrolling stable while moving through wrapped text below a tall image", function()
    local image_path = USERDIR .. PATHSEP
      .. "markdown-live-tall-caret-scroll-" .. system.get_process_id() .. ".png"
    local fp = test.not_nil(io.open(image_path, "wb"))
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path)
      or image_path:match("[^" .. PATHSEP .. "]+$")
    local prefix = "before "
    local image_source = "![[" .. image_url .. "]]"
    local suffix = " " .. string.rep("wrapped suffix words ", 45)
    local trailing = {}
    for i = 1, 80 do trailing[i] = "following line " .. i end
    local source = prefix .. image_source .. suffix
    local view, buffer = make_view(
      source .. "\n" .. table.concat(trailing, "\n"),
      USERDIR .. PATHSEP .. "tall-caret-scroll-note.md"
    )
    view.size.x, view.size.y = 420, 220
    view:set_wrapping_enabled(true)
    buffer:set_selection(2, 1)

    local old_load_image = canvas.load_image
    local old_active = core.active_view
    canvas.load_image = function()
      return {
        get_size = function() return 1295, 1600 end,
        scaled = function(self) return self end,
      }
    end
    local ok, err = pcall(function()
      refresh(view)
      local render_line = test.not_nil(view:get_line_render(1))
      local rows = test.not_nil(render_line.position_rows)
      test.ok(#rows >= 5, "expected several navigable suffix rows")
      local target_index = #rows - 1
      local target = rows[target_index]
      test.ok(
        (target.y_offset or 0) > view:get_line_height(),
        "expected the target row below the tall image"
      )
      local target_col = math.floor(
        ((target.source_col1 or 1) + (target.source_col2 or target.source_col1 or 1)) / 2
      )
      buffer:set_selection(1, target_col)
      render_line = test.not_nil(view:get_line_render(1))
      target = test.not_nil(test.not_nil(render_line.position_rows)[target_index])
      view:get_visual_row_metric_cache()

      local context_rows = view:get_visible_scroll_context_lines()
      local initial_scroll = math.max(
        view:get_line_height() * 2,
        (target.y_offset or 0) - view:get_line_height() * (context_rows + 2)
      )
      view.scroll.y, view.scroll.to.y = initial_scroll, initial_scroll
      core.active_view = view

      test.equal(command.perform("text:move-to-previous-line"), true)
      local line, col = buffer:get_selection()
      test.equal(line, 1)
      view:get_line_screen_position(line, col)

      test.equal(view.scroll.y, initial_scroll)
      test.equal(view.scroll.to.y, initial_scroll)
      view:update()
      test.ok(
        math.abs(view.scroll.y - initial_scroll) < view.size.y,
        "one caret-row move must not teleport the current viewport"
      )
      test.ok(
        math.abs(view.scroll.to.y - initial_scroll) < view.size.y,
        "one caret-row move must not target an image-sized scroll correction"
      )
    end)
    core.active_view = old_active
    canvas.load_image = old_load_image
    os.remove(image_path)
    if not ok then error(err, 0) end
  end)

  test.it("scrolls to the raw image source row instead of the image bottom", function()
    local image_path = USERDIR .. PATHSEP
      .. "markdown-live-raw-source-scroll-" .. system.get_process_id() .. ".png"
    local fp = test.not_nil(io.open(image_path, "wb"))
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path)
      or image_path:match("[^" .. PATHSEP .. "]+$")
    local source = "![[" .. image_url .. "]]"
    local view, buffer = make_view(
      source .. "\nfollowing line", USERDIR .. PATHSEP .. "raw-source-scroll-note.md"
    )
    view.size.x, view.size.y = 420, 220
    view:set_wrapping_enabled(true)
    buffer:set_selection(1, 5)

    local old_load_image = canvas.load_image
    local old_active = core.active_view
    canvas.load_image = function()
      return {
        get_size = function() return 1295, 1600 end,
        scaled = function(self) return self end,
      }
    end
    local ok, err = pcall(function()
      refresh(view)
      core.active_view = view
      view:scroll_to_make_visible(1, 5, true)
      test.ok(
        view.scroll.to.y < view:get_line_height() * 2,
        "raw image source scrolling must not target the image bottom"
      )
    end)
    core.active_view = old_active
    canvas.load_image = old_load_image
    os.remove(image_path)
    if not ok then error(err, 0) end
  end)

  test.it("selects only the suffix caret row with Shift+Home below an inline image", function()
    with_inline_image_text_fixture(function(view, buffer, fixture)
      local old_active = core.active_view
      core.active_view = view
      buffer:set_selection(1, #fixture.source + 1)
      command.perform("text:select-to-start-of-indentation")
      core.active_view = old_active

      local line1, col1, line2, col2 = buffer:get_selection()
      test.same({ line1, col1, line2, col2 }, {
        1, fixture.image_end, 1, #fixture.source + 1,
      })
    end)
  end)

  test.it("keeps inline-image caret-row navigation when soft wrapping is disabled", function()
    with_inline_image_text_fixture(function(view, buffer, fixture)
      local old_active = core.active_view
      core.active_view = view
      view:set_wrapping_enabled(false)

      buffer:set_selection(2, 1)
      command.perform("text:move-to-previous-line")
      local line, col = buffer:get_selection()
      test.equal(line, 1)
      test.equal(col, fixture.image_end)

      buffer:set_selection(1, #fixture.source + 1)
      command.perform("text:select-to-start-of-indentation")
      core.active_view = old_active
      local line1, col1, line2, col2 = buffer:get_selection()
      test.same({ line1, col1, line2, col2 }, {
        1, fixture.image_end, 1, #fixture.source + 1,
      })
    end)
  end)

  test.it("soft-wraps suffix text as it is typed below an inline image", function()
    with_inline_image_text_fixture(function(view, buffer, fixture)
      local old_active = core.active_view
      core.active_view = view
      view.size.x = 180
      view:update_wrap_cache()
      buffer:set_selection(1, #fixture.source + 1)
      view:on_text_input(" with enough additional words to wrap onto several rows")

      test.equal(test.not_nil(markdown_model.peek(buffer)).status, "pending")
      local pending = test.not_nil(view:get_line_render(1))
      for _, fragment in ipairs(pending.fragments or {}) do
        test.equal(fragment.on_mouse_pressed, nil)
        if fragment.widget then
          test.equal(fragment.widget.on_mouse_pressed, nil)
        end
      end

      command.perform("text:move-to-previous-line")
      core.active_view = old_active
      local line, col = buffer:get_selection()
      test.equal(line, 1)
      test.ok(col > fixture.image_end, "expected Up to remain within wrapped suffix text")
    end)
  end)

  test.it("shows unresolved image embeds as loading while the vault indexes", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-image-indexing-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    -- Keep the cooperative scan active long enough to render its initial
    -- placeholder instead of racing a tiny vault's ready notification.
    for i = 1, 200 do
      local file = test.not_nil(io.open(root .. PATHSEP .. "Fill" .. i .. ".md", "wb"))
      file:write("# Fill\n")
      file:close()
    end
    local old_projects = core.projects
    core.projects = { Project(root) }
    local view, buffer = make_view("![[not-yet-indexed.png]]\nnext", root .. PATHSEP .. "Source.md")
    buffer:set_selection(2, 1)
    local ok, err = pcall(function()
      refresh(view)
      test.equal(view.__markdown_live_owner.link_index.status, "indexing")
      local loading
      for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
        if fragment.image_status then loading = fragment break end
      end
      test.equal(test.not_nil(loading).text, "[loading image: not-yet-indexed.png]")

      test.ok(wait_status(view.__markdown_live_owner.link_index, "ready"))
      local unavailable
      for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
        if fragment.image_status then unavailable = fragment break end
      end
      test.equal(test.not_nil(unavailable).text, "[image unavailable: not-yet-indexed.png]")
    end)
    markdown.live_render.detach(view)
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("publishes a pending preview from an attachment-only vault", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-attachment-only-" .. system.get_process_id()
    local media = root .. PATHSEP .. "attachments"
    test.ok(common.mkdirp(media))
    for i = 1, 200 do
      local file = test.not_nil(io.open(media .. PATHSEP .. "Image" .. i .. ".png", "wb"))
      file:write("png")
      file:close()
    end
    local image_path = media .. PATHSEP .. "Pasted image.png"
    local image = test.not_nil(io.open(image_path, "wb"))
    image:write("png")
    image:close()

    local old_projects = core.projects
    local old_load_image = canvas.load_image
    local view
    core.projects = { Project(root) }
    canvas.load_image = function(path)
      if common.path_equals(path, image_path) then
        return {
          get_size = function() return 80, 40 end,
          scaled = function(self) return self end,
        }
      end
      return old_load_image(path)
    end

    local function rendered_image()
      for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
        if fragment.widget and fragment.widget.type == "image" then return fragment end
      end
    end

    local ok, err = pcall(function()
      local buffer
      view, buffer = make_view(
        "![[Pasted image.png]]\nnext", root .. PATHSEP .. "Source.md"
      )
      buffer:set_selection(2, 1)
      refresh(view)
      local index = view.__markdown_live_owner.link_index
      test.equal(index.status, "indexing")
      test.match(visible_render_text(view, 1), "[loading image:", nil, true)

      test.ok(wait_status(index, "ready"))
      test.not_nil(
        rendered_image(),
        "the first attachment snapshot must replace the pending preview"
      )
    end)
    if view then markdown.live_render.detach(view) end
    canvas.load_image = old_load_image
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
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

    local view, buffer = make_view("![[diagram.png]]\nother", root .. PATHSEP .. "Planificación Fabricación.md")
    buffer:set_selection(2, 1)
    local old_load_image = canvas.load_image
    canvas.load_image = function(path)
      test.equal(path, image_path)
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end

    refresh(view)
    canvas.load_image = old_load_image
    os.remove(image_path)
    common.rm(root, true)
  end)

  test.it("renders wikilink images found by unique filename anywhere in an Obsidian vault", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-vault-images-" .. system.get_process_id()
    local obsidian = root .. PATHSEP .. ".obsidian"
    local notes = root .. PATHSEP .. "SISTEMAS"
    local media = notes .. PATHSEP .. "attachments"
    test.ok(common.mkdirp(obsidian))
    test.ok(common.mkdirp(media))
    local app = test.not_nil(io.open(obsidian .. PATHSEP .. "app.json", "wb"))
    app:write("{}")
    app:close()
    local image_path = media .. PATHSEP .. "Pasted image.png"
    local image = test.not_nil(io.open(image_path, "wb"))
    image:write("png")
    image:close()

    local source = notes .. PATHSEP .. "AP 4g.md"
    local old_projects = core.projects
    local old_load_image = canvas.load_image
    local view
    core.projects = { Project(root) }
    markdown.vault_index.get_index(root):rebuild("vault-image-ui-test")
    local loaded_path
    canvas.load_image = function(path)
      loaded_path = path
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end

    local ok, err = pcall(function()
      local buffer
      view, buffer = make_view("![[Pasted image.png]]\nother", source)
      buffer:set_selection(2, 1)
      refresh(view)
      local rendered = test.not_nil(view:get_line_render(1))
      local image_fragment
      for _, fragment in ipairs(rendered.fragments or {}) do
        if fragment.widget and fragment.widget.type == "image" then
          image_fragment = fragment
          break
        end
      end
      test.not_nil(image_fragment)
      test.ok(common.path_equals(test.not_nil(loaded_path), image_path))
    end)
    if view then markdown.live_render.detach(view) end
    canvas.load_image = old_load_image
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("keeps a published image preview while the vault refreshes", function()
    local root = USERDIR .. PATHSEP .. "markdown-live-image-refresh-" .. system.get_process_id()
    local notes = root .. PATHSEP .. "SISTEMAS"
    local media = notes .. PATHSEP .. "attachments"
    test.ok(common.mkdirp(media))
    local image_path = media .. PATHSEP .. "Pasted image.png"
    local image = test.not_nil(io.open(image_path, "wb"))
    image:write("png")
    image:close()
    local source_path = notes .. PATHSEP .. "Source.md"
    local source_file = test.not_nil(io.open(source_path, "wb"))
    source_file:write("![[Pasted image.png]]\n")
    source_file:close()

    local old_projects = core.projects
    local old_load_image = canvas.load_image
    local view
    core.projects = { Project(root) }
    local index = markdown.vault_index.get_index(root):rebuild("image-refresh-fixture")
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end

    local function rendered_image()
      for _, fragment in ipairs(view:get_line_render(1).fragments or {}) do
        if fragment.widget and fragment.widget.type == "image" then return fragment end
      end
    end

    local ok, err = pcall(function()
      local buffer
      view, buffer = make_view("![[Pasted image.png]]\nnext", source_path)
      buffer:set_selection(2, 1)
      refresh(view)
      test.not_nil(rendered_image())
      canvas.load_image = old_load_image

      index:rebuild("image-refresh-settle")
      index:rebuild_async("image-refresh-regression")
      test.equal(index.status, "indexing")
      view:invalidate_line_render("image-refresh-regression", 1, 1)

      test.not_nil(
        rendered_image(),
        "a refresh must keep using the last published attachment snapshot"
      )
      test.ok(wait_status(index, "ready"))
    end)
    if view then markdown.live_render.detach(view) end
    canvas.load_image = old_load_image
    core.projects = old_projects
    common.rm(root, true)
    if not ok then error(err, 0) end
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
    local view, buffer = make_view("![[" .. image_url .. "]]\nother", USERDIR .. PATHSEP .. "note.md")
    buffer:set_selection(2, 1)
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

  test.it("opens a clicked rendered image in the system application", function()
    local image_path = USERDIR .. PATHSEP .. "markdown-live-click-image-" .. system.get_process_id() .. ".png"
    local fp = io.open(image_path, "wb")
    test.not_nil(fp)
    fp:write("png")
    fp:close()
    local image_url = common.basename and common.basename(image_path) or image_path:match("[^" .. PATHSEP .. "]+$")
    local view, buffer = make_view("![[" .. image_url .. "]]\nother", USERDIR .. PATHSEP .. "note.md")
    buffer:set_selection(2, 1)
    local old_load_image = canvas.load_image
    local old_open = common.open_in_system
    local opened_path
    canvas.load_image = function()
      return {
        get_size = function() return 80, 40 end,
        scaled = function(self) return self end,
      }
    end
    common.open_in_system = function(path)
      opened_path = path
      return true
    end

    refresh(view)
    local x, y = view:get_line_screen_position(1)
    test.ok(view:on_mouse_pressed("left", x + 10, y + 10, 1))
    test.equal(opened_path, image_path)
    local line = buffer:get_selection()
    test.equal(line, 1)

    common.open_in_system = old_open
    canvas.load_image = old_load_image
    os.remove(image_path)
  end)

  test.it("honors disabled live image rendering", function()
    local old = config.markdown_live_render_images
    config.markdown_live_render_images = false
    local view, buffer = make_view("![Alt](image.png)\nother", "note.md")
    buffer:set_selection(2, 1)
    refresh(view)
    local link_width = live_body_font(view):get_width("Alt")
    test.equal(view:get_col_x_offset(1, #"![Alt](image.png)" + 1), link_width)
    config.markdown_live_render_images = old
  end)

  test.it("owns lifecycle independently for split views of one Buffer", function()
    local first, buffer = make_view("# Title", "note.md")
    local second = Editor(buffer)
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

    buffer:set_filename("note.txt", "note.txt")
    test.equal(first.__markdown_live_attached, nil)
    test.equal(second.__markdown_live_attached, nil)
  end)

  test.it("releases owned lifecycle state when its Buffer closes", function()
    local view, buffer = make_view("# Title", "note.md")
    refresh(view)
    test.not_nil(view.__markdown_live_owner)
    buffer:on_close()
    test.equal(view.__markdown_live_owner, nil)
    test.equal(view.__markdown_live_attached, nil)
  end)

  test.it("rebinds link resolution when a Buffer moves between Projects", function()
    local root1 = USERDIR .. PATHSEP .. "markdown-live-index-one-" .. system.get_process_id()
    local root2 = USERDIR .. PATHSEP .. "markdown-live-index-two-" .. system.get_process_id()
    test.ok(common.mkdirp(root1))
    test.ok(common.mkdirp(root2))
    local old_projects = core.projects
    core.projects = { Project(root1), Project(root2) }
    local ok, err = pcall(function()
      local path1 = root1 .. PATHSEP .. "Source.md"
      local path2 = root2 .. PATHSEP .. "Source.md"
      local view, buffer = make_view("[[Target]]\nplain", path1)
      buffer:set_selection(2, 1)
      refresh(view)
      test.equal(view.__markdown_live_owner.link_index.root, common.normalize_path(root1))
      buffer:set_filename(path2, path2)
      test.equal(view.__markdown_live_owner.link_index.root, common.normalize_path(root2))
    end)
    core.projects = old_projects
    common.rm(root1, true)
    common.rm(root2, true)
    if not ok then error(err, 0) end
  end)

  test.it("automatically follows direct Buffer filename and syntax changes", function()
    local view, buffer = make_view("# Title", "note.md")
    local suffix = tostring(test_buffer_id)
    refresh(view)
    test.equal(view.__markdown_live_attached, true)

    buffer:set_filename("note.txt", "note-" .. suffix .. ".txt")
    test.equal(view.__markdown_live_attached, nil)

    buffer:set_filename("note.md", "note-" .. suffix .. ".md")
    test.equal(view.__markdown_live_attached, true)

    view.__markdown_live_image_cache = { ["image.png"] = { path = "old/image.png" } }
    buffer:set_filename("moved/note.md", "moved/note-" .. suffix .. ".md")
    test.equal(view.__markdown_live_attached, true)
    test.equal(view.__markdown_live_image_cache, nil)
  end)
end)
