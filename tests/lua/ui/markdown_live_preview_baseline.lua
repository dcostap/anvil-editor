local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local parser = require "core.markdown.parser"
local Project = require "core.project"
local style = require "core.style"
local test = require "core.test"

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
      markdown.live_render.refresh_view(view)
      test.equal(view.__markdown_live_attached, true)

      doc:set_filename("note.txt", "note.txt")
      test.equal(view.__markdown_live_attached, nil)
      doc:set_filename("note.md", "note.md")
      test.equal(view.__markdown_live_attached, true)

      local syntax_view, syntax_doc = make_view("# Title", "note.txt")
      markdown.live_render.refresh_view(syntax_view)
      test.equal(syntax_view.__markdown_live_attached, nil)
      syntax_doc:set_syntax(markdown_syntax, "baseline-test")
      test.equal(syntax_view.__markdown_live_attached, true)
      syntax_doc:reset_syntax()
      test.equal(syntax_view.__markdown_live_attached, nil)
    end)
  end)

  test.it("has no Live Preview open-link command", function()
    test.equal(command.map["markdown-live-preview:open-link"], nil)
  end)

  test.it("styles resolved, missing, and ambiguous wikilinks identically", function()
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
        markdown.live_render.refresh_view(view)
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

  test.it("recomputes visual metrics for every Document line after a caret move", function()
    with_live_preview(function()
      local lines = {}
      for i = 1, 80 do lines[i] = i == 1 and "# Heading" or ("line " .. i) end
      local view, doc = make_view(table.concat(lines, "\n"))
      markdown.live_render.refresh_view(view)

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
      test.equal(second_pass, #doc.lines)
    end)
  end)

  test.it("reparses one line independently in mapping and draw paths", function()
    with_live_preview(function()
      local view, doc = make_view("See [[Target|Alias]] and **bold**\nother")
      doc:set_selection(2, 1)
      markdown.live_render.refresh_view(view)

      local old_parse_inline = parser.parse_inline
      local calls = 0
      parser.parse_inline = function(...)
        calls = calls + 1
        return old_parse_inline(...)
      end
      local old_draw_text = renderer.draw_text
      renderer.draw_text = function(font, text, x, _, _, opts)
        return x + font:get_width(text, opts)
      end
      local ok, err = pcall(function()
        view:get_col_x_offset(1, 5)
        view:get_x_offset_col(1, 10)
        view:draw_line_text(1, 0, 0)
      end)
      renderer.draw_text = old_draw_text
      parser.parse_inline = old_parse_inline
      if not ok then error(err, 0) end

      test.ok(calls >= 3, "expected mapping and draw to parse the line separately")
    end)
  end)

  test.it("keeps a missing image result stale after the file appears", function()
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
        markdown.live_render.refresh_view(view)
        view:get_line_render(1)
        write_file(image_path, "png")
        view:invalidate_line_render("baseline-file-appeared")
        view:invalidate_visual_metrics("baseline-file-appeared")
        local render_line = view:get_line_render(1)
        local has_widget = false
        for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
          has_widget = has_widget or fragment.widget ~= nil
        end
        test.equal(loads, 0)
        test.equal(has_widget, false)
      end)

      canvas.load_image = old_load_image
      common.rm(root, true)
      if not passed then error(failure, 0) end
    end)
  end)

  test.it("keeps a remote-disabled image stale after policy changes", function()
    with_live_preview(function()
      local old_download_remote = config.markdown_live_download_remote_images
      config.markdown_live_download_remote_images = false
      local view, doc = make_view("![Remote](https://example.com/image.png)\nother")
      doc:set_selection(2, 1)
      markdown.live_render.refresh_view(view)
      view:get_line_render(1)

      local old_ensure_entry = markdown.images.ensure_entry
      local resolutions = 0
      markdown.images.ensure_entry = function(...)
        resolutions = resolutions + 1
        return old_ensure_entry(...)
      end
      config.markdown_live_download_remote_images = true
      local ok, err = pcall(function()
        view:invalidate_line_render("baseline-policy-change")
        view:invalidate_visual_metrics("baseline-policy-change")
        view:get_line_render(1)
      end)
      markdown.images.ensure_entry = old_ensure_entry
      config.markdown_live_download_remote_images = old_download_remote
      if not ok then error(err, 0) end

      test.equal(resolutions, 0)
    end)
  end)

  test.it("keeps actually wrapped aliases on the raw source path", function()
    with_live_preview(function()
      local source = "See [[folder/with/a/very/long/target/name|Alias]] after"
      local view, doc = make_view(source .. "\nother")
      view.size.x = 90
      view:set_wrapping_enabled(true)
      doc:set_selection(2, 1)
      markdown.live_render.refresh_view(view)

      test.equal(view:get_line_render(1), nil)
      test.ok(view:get_col_x_offset(1, #source + 1) < view:get_font():get_width(source))
    end)
  end)
end)
