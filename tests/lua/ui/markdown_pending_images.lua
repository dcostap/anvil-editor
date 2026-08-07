local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function wait_ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == "ready"
end

local function image_count(view, label)
  local count = 0
  for line, text in ipairs(view.doc.lines) do
    if text:find("![[", 1, true) then
      local render = test.not_nil(view:get_line_render(line))
      local found = false
      local fragments = {}
      for _, fragment in ipairs(render.fragments or {}) do
        fragments[#fragments + 1] = fragment.widget and fragment.widget.type
          or fragment.text or (fragment.hidden and "hidden" or "fragment")
        if fragment.widget and fragment.widget.type == "image" then
          found = true
          count = count + 1
          break
        end
      end
      test.ok(found, string.format(
        "%s line %d transiently lost its rendered image: fragments=%s",
        tostring(label), line, table.concat(fragments, "|")
      ))
    end
  end
  return count
end

test.describe("Markdown pending images", function()
  test.it("keeps a duplicated image line rendered while semantics publish", function()
    local old_live = config.markdown_live_editor
    local old_images = config.markdown_live_render_images
    local old_active = core.active_view
    local old_load_image = canvas.load_image
    local root = USERDIR .. PATHSEP .. "markdown-pending-image-duplicate-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local file = test.not_nil(io.open(root .. PATHSEP .. "one.png", "wb"))
    file:write("png")
    file:close()

    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      config.markdown_live_render_images = true
      canvas.load_image = function(path)
        if tostring(path):find(root, 1, true) then
          return {
            get_size = function() return 80, 40 end,
            scaled = function(self) return self end,
          }
        end
        return old_load_image(path)
      end

      local filename = root .. PATHSEP .. "note.md"
      local doc = Doc(filename, filename, true)
      doc:insert(1, 1, "![[one.png]]\nplain")
      doc:clear_undo_redo()
      view = DocView(doc)
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 500, 500
      view:set_wrapping_enabled(true)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(doc))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(image_count(view, "initial duplicate"), 1)

      doc:apply_edits({
        { line1 = 2, col1 = 1, line2 = 2, col2 = 1, text = "![[one.png]]\n" },
      }, { type = "insert" })

      test.equal(image_count(view, "pending duplicate"), 2)
      test.ok(wait_ready(instance), instance.reason)
      test.equal(image_count(view, "published duplicate"), 2)
    end)

    if view then markdown.live_render.detach(view) end
    canvas.load_image = old_load_image
    config.markdown_live_editor = old_live
    config.markdown_live_render_images = old_images
    core.active_view = old_active
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("keeps an image below an exited list item rendered while semantics publish", function()
    local old_live = config.markdown_live_editor
    local old_images = config.markdown_live_render_images
    local old_active = core.active_view
    local old_load_image = canvas.load_image
    local root = USERDIR .. PATHSEP .. "markdown-pending-image-list-exit-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local file = test.not_nil(io.open(root .. PATHSEP .. "one.png", "wb"))
    file:write("png")
    file:close()

    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      config.markdown_live_render_images = true
      canvas.load_image = function(path)
        if tostring(path):find(root, 1, true) then
          return {
            get_size = function() return 80, 40 end,
            scaled = function(self) return self end,
          }
        end
        return old_load_image(path)
      end

      local filename = root .. PATHSEP .. "note.md"
      local doc = Doc(filename, filename, true)
      doc:insert(1, 1, "- \n![[one.png]]\nplain")
      doc:clear_undo_redo()
      view = DocView(doc)
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 500, 500
      view:set_wrapping_enabled(true)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(doc))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(image_count(view, "initial list exit"), 1)

      doc:set_selection(1, 3)
      test.ok(command.perform("doc:newline"))

      test.equal(image_count(view, "pending list exit"), 1)
      test.ok(wait_ready(instance), instance.reason)
      test.equal(image_count(view, "published list exit"), 1)
    end)

    if view then markdown.live_render.detach(view) end
    canvas.load_image = old_load_image
    config.markdown_live_editor = old_live
    config.markdown_live_render_images = old_images
    core.active_view = old_active
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("keeps rendered images while Enter waits for semantic publication", function()
    local old_live = config.markdown_live_editor
    local old_images = config.markdown_live_render_images
    local old_active = core.active_view
    local old_load_image = canvas.load_image
    local root = USERDIR .. PATHSEP .. "markdown-pending-images-" .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local file = test.not_nil(io.open(root .. PATHSEP .. "one.png", "wb"))
    file:write("png")
    file:close()

    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      config.markdown_live_render_images = true
      canvas.load_image = function(path)
        if tostring(path):find(root, 1, true) then
          return {
            get_size = function() return 80, 40 end,
            scaled = function(self) return self end,
          }
        end
        return old_load_image(path)
      end

      local filename = root .. PATHSEP .. "note.md"
      local doc = Doc(filename, filename, true)
      doc:insert(1, 1, "\n![[one.png]]\n\n# Heading")
      doc:clear_undo_redo()
      view = DocView(doc)
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 500, 500
      view:set_wrapping_enabled(true)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(doc))
      test.ok(wait_ready(instance), instance.reason)
      view:invalidate_line_render("pending-image-fixture")
      test.equal(image_count(view, "initial"), 1)

      doc:set_selection(1, 1)
      view:on_text_input("\n")
      test.equal(image_count(view, "pending Enter"), 1)
    end)

    if view then markdown.live_render.detach(view) end
    canvas.load_image = old_load_image
    config.markdown_live_editor = old_live
    config.markdown_live_render_images = old_images
    core.active_view = old_active
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)
end)
