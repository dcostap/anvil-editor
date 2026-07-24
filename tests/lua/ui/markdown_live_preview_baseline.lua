local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local linewrapping = require "core.linewrapping"
local Project = require "core.project"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_view(text, filename)
  filename = filename or "note.md"
  local doc = Doc(filename, filename, true)
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
    repeat
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      if instance.status == "ready" then return result end
      system.sleep(0.001)
    until system.get_time() >= deadline
    test.equal(instance.status, "ready", instance.reason)
  end
  return result
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function with_live_preview(fn)
  local old_enabled = config.markdown_live_editor
  config.markdown_live_editor = true
  local ok, err = pcall(fn)
  config.markdown_live_editor = old_enabled
  if not ok then error(err, 0) end
end

-- These characterization tests intentionally describe prototype limitations.
-- Later milestones replace each assertion with the required public behavior.
test.describe("Markdown Live Preview prototype baseline", function()
  test.it("automatically follows direct filename and syntax lifecycle changes", function()
    with_live_preview(function()
      local view, doc = make_view("# Title", "note.md")
      local markdown_syntax = doc.syntax
      refresh(view)
      test.equal(view.__markdown_live_attached, true)

      doc:set_filename("note.txt", "note.txt")
      test.equal(view.__markdown_live_attached, nil)
      doc:set_filename("note.md", "note.md")
      test.equal(view.__markdown_live_attached, true)

      local syntax_view, syntax_doc = make_view("# Title", "note.txt")
      refresh(syntax_view)
      test.equal(syntax_view.__markdown_live_attached, nil)
      syntax_doc:set_syntax(markdown_syntax, "baseline-test")
      test.equal(syntax_view.__markdown_live_attached, true)
      syntax_doc:reset_syntax()
      test.equal(syntax_view.__markdown_live_attached, nil)
    end)
  end)

  test.it("registers Live Preview link commands", function()
    test.not_nil(command.map["markdown-live-preview:open-link"])
    test.not_nil(command.map["markdown-live-preview:create-link-target"])
    test.not_nil(command.map["markdown-live-preview:complete-link"])
    test.not_nil(command.map["markdown-live-preview:load-remote-image"])
    test.not_nil(command.map["markdown-live-preview:trust-project-remote-images"])
    test.not_nil(command.map["markdown-live-preview:untrust-project-remote-images"])
  end)

  test.it("keeps resolved, missing, and ambiguous wikilinks visually consistent", function()
    with_live_preview(function()
      local root = USERDIR .. PATHSEP .. "markdown-live-baseline-links-" .. system.get_process_id()
      local ok, err = common.mkdirp(root .. PATHSEP .. "a")
      test.ok(ok, err)
      ok, err = common.mkdirp(root .. PATHSEP .. "b")
      test.ok(ok, err)
      write_file(root .. PATHSEP .. "Resolved.md", "# Resolved\n")
      write_file(root .. PATHSEP .. "a" .. PATHSEP .. "Ambiguous.md", "# A\n")
      write_file(root .. PATHSEP .. "b" .. PATHSEP .. "Ambiguous.md", "# B\n")
      local source_path = root .. PATHSEP .. "Source.md"
      local old_projects = core.projects
      core.projects = { Project(root) }

      local passed, failure = pcall(function()
        local index = markdown.vault_index.get_index(root):rebuild("baseline")
        local source = "[[Resolved]] [[Missing]] [[Ambiguous]]"
        local parsed_links = markdown.links.find_links(source, 1)
        test.equal(index:resolve(parsed_links[1], source_path).status, "resolved")
        test.equal(index:resolve(parsed_links[2], source_path).status, "missing")
        test.equal(index:resolve(parsed_links[3], source_path).status, "ambiguous")

        local view, doc = make_view(source .. "\nother", source_path)
        doc:set_selection(2, 1)
        refresh(view)
        local render_line = view:get_line_render(1)
        local link_colors = {}
        for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
          if fragment.text == "Resolved" or fragment.text == "Missing" or fragment.text == "Ambiguous" then
            link_colors[#link_colors + 1] = fragment.color
          end
        end
        test.equal(#link_colors, 3)
        test.same(link_colors[1], style.markdown_live_link)
        test.same(link_colors[2], style.markdown_live_link)
        test.same(link_colors[3], style.markdown_live_link)
      end)

      core.projects = old_projects
      common.rm(root, true)
      if not passed then error(failure, 0) end
    end)
  end)

  test.it("recomputes visual metrics only for old and new caret lines", function()
    with_live_preview(function()
      local lines = {}
      for i = 1, 80 do lines[i] = i == 1 and "# Heading" or ("line " .. i) end
      local view, doc = make_view(table.concat(lines, "\n"))
      refresh(view)

      local calls = 0
      view:add_visual_metric_provider("markdown-baseline-observer", {
        line_height = function()
          calls = calls + 1
        end,
      })
      doc:set_selection(2, 1)
      view:get_visual_row_height(1)
      local first_pass = calls
      doc:set_selection(3, 1)
      view:get_visual_row_height(1)
      local second_pass = calls - first_pass

      test.equal(first_pass, #doc.lines)
      test.equal(second_pass, 2)
    end)
  end)

  test.it("recomputes only affected wrapped rows when the caret moves", function()
    with_live_preview(function()
      local lines = {}
      for i = 1, 80 do
        lines[i] = i == 1 and "# Heading"
          or ("line " .. i .. " with enough words to wrap in a narrow editor")
      end
      local view, doc = make_view(table.concat(lines, "\n"))
      view.size.x = 180
      view:set_wrapping_enabled(true)
      refresh(view)

      local calls = 0
      view:add_visual_metric_provider("markdown-wrapped-baseline-observer", {
        line_height = function()
          calls = calls + 1
        end,
      })
      doc:set_selection(2, 1)
      view:get_visual_row_height(1)
      local first_pass = calls
      local expected = view:get_visual_row_count_for_line(2)
        + view:get_visual_row_count_for_line(3)

      doc:set_selection(3, 1)
      view:get_visual_row_height(1)
      local second_pass = calls - first_pass

      test.equal(first_pass, view:get_scrollable_line_count())
      test.equal(second_pass, expected)
      test.ok(second_pass < first_pass)
    end)
  end)

  test.it("does not reflow an existing wrapped selection when it grows", function()
    with_live_preview(function()
      local lines = {}
      for i = 1, 80 do
        lines[i] = "line " .. i .. " with enough words to wrap in a narrow editor"
      end
      local view, doc = make_view(table.concat(lines, "\n"))
      view.size.x = 180
      view:set_wrapping_enabled(true)
      refresh(view)

      local calls = 0
      view:add_visual_metric_provider("markdown-wrapped-selection-observer", {
        line_height = function()
          calls = calls + 1
        end,
      })
      doc:set_selection(2, 2, 60, 1)
      view:get_visual_row_height(1)
      local first_pass = calls
      local expected_max = view:get_visual_row_count_for_line(2)
        + view:get_visual_row_count_for_line(60)
        + view:get_visual_row_count_for_line(61)

      doc:set_selection(2, 2, 61, 1)
      view:get_visual_row_height(1)
      local second_pass = calls - first_pass

      test.ok(second_pass <= expected_max)
      test.ok(second_pass < first_pass)
    end)
  end)

  test.it("reuses one rendered line across mapping and draw paths", function()
    with_live_preview(function()
      local view, doc = make_view("See [[Target|Alias]] and **bold**\nother")
      doc:set_selection(2, 1)
      refresh(view)

      local provider = view.line_render_providers["markdown-live"].provider
      local old_render_line = provider.render_line
      local calls = 0
      provider.render_line = function(...)
        calls = calls + 1
        return old_render_line(...)
      end
      local old_draw_text = renderer.draw_text
      local old_draw_rect = renderer.draw_rect
      renderer.draw_text = function(font, text, x, _, _, opts)
        return x + font:get_width(text, opts)
      end
      renderer.draw_rect = function() end
      local ok, err = pcall(function()
        view:get_col_x_offset(1, 5)
        view:get_x_offset_col(1, 10)
        view:draw_line_text(1, 0, 0)
      end)
      renderer.draw_text = old_draw_text
      renderer.draw_rect = old_draw_rect
      provider.render_line = old_render_line
      if not ok then error(err, 0) end

      test.equal(calls, 1)
    end)
  end)

  test.it("adopts a missing image when the file appears", function()
    with_live_preview(function()
      local root = USERDIR .. PATHSEP .. "markdown-live-baseline-image-" .. system.get_process_id()
      local ok, err = common.mkdirp(root)
      test.ok(ok, err)
      local image_path = root .. PATHSEP .. "appears.png"
      local view, doc = make_view("![Alt](appears.png)\nother", root .. PATHSEP .. "note.md")
      doc:set_selection(2, 1)
      local old_load_image = canvas.load_image
      local loads = 0
      canvas.load_image = function()
        loads = loads + 1
        return {
          get_size = function() return 20, 10 end,
          scaled = function(self) return self end,
        }
      end

      local passed, failure = pcall(function()
        refresh(view)
        view:get_line_render(1)
        write_file(image_path, "png")
        view:invalidate_line_render("baseline-file-appeared")
        view:invalidate_visual_metrics("baseline-file-appeared")
        local render_line = view:get_line_render(1)
        local has_widget = false
        for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
          has_widget = has_widget or fragment.widget ~= nil
        end
        test.equal(loads, 1)
        test.equal(has_widget, true)
      end)

      canvas.load_image = old_load_image
      common.rm(root, true)
      if not passed then error(failure, 0) end
    end)
  end)

  test.it("rekeys a remote image asset after policy changes", function()
    with_live_preview(function()
      local old_download_remote = config.markdown_live_download_remote_images
      config.markdown_live_download_remote_images = false
      local view, doc = make_view("![Remote](https://example.com/image.png)\nother")
      doc:set_selection(2, 1)
      refresh(view)
      view:get_line_render(1)

      local old_get_asset = markdown.images.get_asset
      local resolutions = 0
      markdown.images.get_asset = function()
        resolutions = resolutions + 1
        return { status = "loading", subscribers = setmetatable({}, { __mode = "k" }) }
      end
      config.markdown_live_download_remote_images = true
      local ok, err = pcall(function()
        view:invalidate_line_render("baseline-policy-change")
        view:invalidate_visual_metrics("baseline-policy-change")
        view:get_line_render(1)
      end)
      markdown.images.get_asset = old_get_asset
      config.markdown_live_download_remote_images = old_download_remote
      if not ok then error(err, 0) end

      test.equal(resolutions, 1)
    end)
  end)

  test.it("wraps aliases by rendered fragments while preserving source columns", function()
    with_live_preview(function()
      local source = "See [[folder/with/a/very/long/target/name|Álias]] after"
      local view, doc = make_view(source .. "\nother")
      view.size.x = 160
      doc:set_selection(2, 1)
      refresh(view)
      view:set_wrapping_enabled(true)

      local render_line = test.not_nil(view:get_line_render(1))
      local found_alias = false
      for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
        if fragment.text == "Álias" then found_alias = true end
      end
      test.equal(found_alias, true)
      local rendered_rows = view:get_line_visual_row_count(1)
      local first_idx = linewrapping.get_line_idx_col_count(view, 1)
      for idx = first_idx, first_idx + rendered_rows - 1 do
        local _, start_col = linewrapping.get_idx_line_col(view, idx)
        local x = view:get_col_x_offset(1, start_col)
        local hit_line, hit_col = linewrapping.get_line_col_from_index_and_x(view, idx, x)
        test.equal(hit_line, 1)
        test.equal(hit_col, start_col)
      end

      local old_draw_text = renderer.draw_text
      local old_draw_rect = renderer.draw_rect
      local drawn = {}
      renderer.draw_text = function(font, text, x, y, color, opts)
        drawn[#drawn + 1] = text
        return x + font:get_width(text, opts)
      end
      renderer.draw_rect = function() end
      local ok, err = pcall(view.draw_line_text, view, 1, 0, 0)
      renderer.draw_text = old_draw_text
      renderer.draw_rect = old_draw_rect
      if not ok then error(err, 0) end
      test.equal(table.concat(drawn), "See Álias after")

      markdown.live_render.detach(view)
      view:update_wrap_cache()
      local raw_rows = view:get_line_visual_row_count(1)
      test.ok(rendered_rows < raw_rows)
    end)
  end)
end)
