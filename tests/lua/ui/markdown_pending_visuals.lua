local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local Project = require "core.project"
local style = require "core.style"
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

local function make_view(filename, text)
  local buffer = Buffer(filename, filename, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 500, 500
  view:set_wrapping_enabled(true)
  return view, buffer
end

local function count_visuals(view, field)
  local count = 0
  for line, text in ipairs(view.buffer.lines) do
    if text:find("[", 1, true) then
      for _, fragment in ipairs((view:get_line_render(line) or {}).fragments or {}) do
        if fragment[field] then count = count + 1 break end
      end
    end
  end
  return count
end

local function count_flag(view, line, field)
  local count = 0
  for _, fragment in ipairs((view:get_line_render(line) or {}).fragments or {}) do
    if fragment[field] then count = count + 1 end
  end
  return count
end

local function visible_render_text(view, line)
  local text = {}
  for _, fragment in ipairs((view:get_line_render(line) or {}).fragments or {}) do
    if not fragment.hidden and fragment.text then text[#text + 1] = fragment.text end
  end
  return table.concat(text)
end

local function exit_empty_list(buffer)
  -- This is the normalized edit produced by buffer:newline for an empty list
  -- item: remove the marker and insert the newline at the same position.
  buffer:apply_edits({
    { line1 = 1, col1 = 1, line2 = 1, col2 = 3, text = "\n" },
  }, { type = "insert" })
end

test.describe("Markdown pending visual continuity", function()
  test.it("keeps attachment chips through an empty-list exit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP
      .. "markdown-pending-attachment-chip.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "![[manual.pdf]]\nplain")
      local buffer = view.buffer
      buffer:set_selection(2, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(count_visuals(view, "attachment_chip"), 1)
      buffer:apply_edits({
        { line1 = 2, col1 = 1, line2 = 2, col2 = 1, text = "![[manual.pdf]]\n" },
      }, { type = "insert" })
      test.equal(count_visuals(view, "attachment_chip"), 2)
      test.ok(wait_ready(instance), instance.reason)
      markdown.live_render.detach(view)
      view = nil

      view = make_view(filename, "- \n![[manual.pdf]]\nplain")
      buffer = view.buffer
      buffer:set_selection(3, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(count_visuals(view, "attachment_chip"), 1)

      exit_empty_list(buffer)

      test.equal(count_visuals(view, "attachment_chip"), 1)
      test.ok(wait_ready(instance), instance.reason)
      test.equal(count_visuals(view, "attachment_chip"), 1)
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps note embed previews through an empty-list exit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local old_projects = core.projects
    local root = USERDIR .. PATHSEP .. "markdown-pending-embed-"
      .. system.get_process_id()
    test.ok(common.mkdirp(root))
    local function write(path, text)
      local file = test.not_nil(io.open(path, "wb"))
      file:write(text)
      file:close()
    end
    local target = root .. PATHSEP .. "Target.md"
    local source = root .. PATHSEP .. "Source.md"
    write(target, "# Target\nfirst\nsecond\n")
    write(source, "- \n![[Target]]\nplain\n")
    core.projects = { Project(root) }
    local index = markdown.vault_index.get_index(root):rebuild(
      "pending-embed-continuity"
    )
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(source, "![[Target]]\nplain")
      local buffer = view.buffer
      buffer:set_selection(2, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(index.status, "ready")
      test.equal(count_visuals(view, "embed_preview"), 1)
      buffer:apply_edits({
        { line1 = 2, col1 = 1, line2 = 2, col2 = 1, text = "![[Target]]\n" },
      }, { type = "insert" })
      test.equal(count_visuals(view, "embed_preview"), 2)
      test.ok(wait_ready(instance), instance.reason)
      markdown.live_render.detach(view)
      view = nil

      view = make_view(source, "- \n![[Target]]\nplain")
      buffer = view.buffer
      buffer:set_selection(3, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(index.status, "ready")
      test.equal(count_visuals(view, "embed_preview"), 1)

      exit_empty_list(buffer)

      test.equal(count_visuals(view, "embed_preview"), 1)
      test.ok(wait_ready(instance), instance.reason)
      test.equal(count_visuals(view, "embed_preview"), 1)
    end)
    if view then markdown.live_render.detach(view) end
    core.projects = old_projects
    config.markdown_live_editor = old_live
    core.active_view = old_active
    common.rm(root, true)
    if not ok then error(err, 0) end
  end)

  test.it("keeps local semantic decorations through an empty-list exit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local cases = {
      { "tag", "This has #tag", "tag" },
      { "hard break", "line  ", "hard_break" },
      { "footnote", "See [^1]", "footnote" },
      { "reference definition", "[ref]: target.md", "reference_definition" },
      { "escaped Markdown", "Escaped \\*literal\\*", "escape" },
    }
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      for index, item in ipairs(cases) do
        local filename = USERDIR .. PATHSEP .. "markdown-pending-decoration-"
          .. tostring(index) .. ".md"
        local view, buffer = make_view(
          filename, "- \n" .. item[2] .. "\nplain"
            .. (item[1] == "footnote" and "\n\n[^1]: note" or "")
        )
        buffer:set_selection(3, 1)
        core.active_view = view
        markdown.live_render.refresh_view(view)
        local instance = test.not_nil(markdown_model.peek(buffer))
        test.ok(wait_ready(instance), instance.reason)
        test.ok(count_flag(view, 2, item[3]) > 0, item[1])

        exit_empty_list(buffer)

        test.ok(count_flag(view, 3, item[3]) > 0, item[1])
        test.ok(wait_ready(instance), instance.reason)
        test.ok(count_flag(view, 3, item[3]) > 0, item[1])
        markdown.live_render.detach(view)
      end
    end)
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps indented-code background ownership through an empty-list exit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP .. "markdown-pending-indented-code.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "- \n\n    local code\nplain")
      local buffer = view.buffer
      buffer:set_selection(4, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local decoration
      for _, entry in ipairs(view:decoration_provider_entries()) do
        if entry.id == "markdown-live" then decoration = entry.provider break end
      end
      decoration = test.not_nil(decoration)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(decoration:line_background(view, 3), style.markdown_live_code_background)

      exit_empty_list(buffer)

      test.equal(decoration:line_background(view, 4), style.markdown_live_code_background)
      test.ok(wait_ready(instance), instance.reason)
      test.equal(decoration:line_background(view, 4), style.markdown_live_code_background)
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps callout card ownership through an empty-list exit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP .. "markdown-pending-callout-card.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "- \n\n> [!NOTE] title\nbody\nplain")
      local buffer = view.buffer
      buffer:set_selection(5, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local decoration
      for _, entry in ipairs(view:decoration_provider_entries()) do
        if entry.id == "markdown-live" then decoration = entry.provider break end
      end
      decoration = test.not_nil(decoration)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.not_nil(decoration:line_background_descriptor(view, 3))

      exit_empty_list(buffer)

      test.not_nil(decoration:line_background_descriptor(view, 4))
      test.ok(wait_ready(instance), instance.reason)
      test.not_nil(decoration:line_background_descriptor(view, 4))
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps callout ownership for a duplicated body line in a changed range", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP
      .. "markdown-pending-callout-duplicate-body.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "> [!NOTE] title\n> body\nplain")
      local buffer = view.buffer
      buffer:set_selection(3, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local decoration
      for _, entry in ipairs(view:decoration_provider_entries()) do
        if entry.id == "markdown-live" then decoration = entry.provider break end
      end
      decoration = test.not_nil(decoration)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.not_nil(decoration:line_background_descriptor(view, 2))

      buffer:apply_edits({
        { line1 = 3, col1 = 1, line2 = 3, col2 = 1, text = "> body\n" },
      }, { type = "insert" })

      test.equal(instance.status, "pending")
      test.not_nil(
        decoration:line_background_descriptor(view, 3),
        "the duplicated callout body lost its card while semantics were pending"
      )
      test.ok(wait_ready(instance), instance.reason)
      test.not_nil(decoration:line_background_descriptor(view, 3))
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps indented-code ownership for a duplicated code line in a changed range", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP
      .. "markdown-pending-indented-duplicate.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "- \n\n    local code\nplain")
      local buffer = view.buffer
      buffer:set_selection(4, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local decoration
      for _, entry in ipairs(view:decoration_provider_entries()) do
        if entry.id == "markdown-live" then decoration = entry.provider break end
      end
      decoration = test.not_nil(decoration)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(decoration:line_background(view, 3), style.markdown_live_code_background)

      buffer:apply_edits({
        { line1 = 4, col1 = 1, line2 = 4, col2 = 1, text = "    local code\n" },
      }, { type = "insert" })

      test.equal(instance.status, "pending")
      test.equal(
        decoration:line_background(view, 4),
        style.markdown_live_code_background,
        "the duplicated indented-code line lost its background while semantics were pending"
      )
      test.ok(wait_ready(instance), instance.reason)
      test.equal(decoration:line_background(view, 4), style.markdown_live_code_background)
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps plus-delimited frontmatter ownership during a pending edit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP
      .. "markdown-pending-plus-frontmatter.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "+++\nkey: value\n+++\nplain")
      local buffer = view.buffer
      buffer:set_selection(4, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local decoration
      for _, entry in ipairs(view:decoration_provider_entries()) do
        if entry.id == "markdown-live" then decoration = entry.provider break end
      end
      decoration = test.not_nil(decoration)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)

      buffer:insert(2, 5, "\n")

      test.equal(instance.status, "pending")
      test.equal(
        decoration:line_background(view, 2),
        style.markdown_live_frontmatter_background,
        "plus-delimited frontmatter lost its pending background"
      )
      test.ok(wait_ready(instance), instance.reason)
      test.equal(
        decoration:line_background(view, 2),
        style.markdown_live_frontmatter_background
      )
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps frontmatter ownership through an ordinary pending edit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP
      .. "markdown-pending-frontmatter-content.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "---\nkey: value\n---\nplain")
      local buffer = view.buffer
      buffer:set_selection(4, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local decoration
      for _, entry in ipairs(view:decoration_provider_entries()) do
        if entry.id == "markdown-live" then decoration = entry.provider break end
      end
      decoration = test.not_nil(decoration)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)

      buffer:insert(2, #buffer.lines[2] - 1, "!")

      test.equal(instance.status, "pending")
      test.equal(
        decoration:line_background(view, 2),
        style.markdown_live_frontmatter_background,
        "frontmatter lost its background during an ordinary pending edit"
      )
      test.ok(wait_ready(instance), instance.reason)
      test.equal(
        decoration:line_background(view, 2),
        style.markdown_live_frontmatter_background
      )
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)

  test.it("keeps comment ownership through an ordinary pending edit", function()
    local old_live = config.markdown_live_editor
    local old_active = core.active_view
    local filename = USERDIR .. PATHSEP
      .. "markdown-pending-comment-content.md"
    local view
    local ok, err = pcall(function()
      config.markdown_live_editor = true
      view = make_view(filename, "%%hidden\ncomment body\nend%%\nplain")
      local buffer = view.buffer
      buffer:set_selection(4, 1)
      core.active_view = view
      markdown.live_render.refresh_view(view)
      local instance = test.not_nil(markdown_model.peek(buffer))
      test.ok(wait_ready(instance), instance.reason)
      test.equal(visible_render_text(view, 2), "")

      buffer:insert(2, #buffer.lines[2] - 1, "!")

      test.equal(instance.status, "pending")
      test.equal(
        visible_render_text(view, 2), "",
        "comment content became visible during a pending edit"
      )
      test.ok(wait_ready(instance), instance.reason)
      test.equal(visible_render_text(view, 2), "")
    end)
    if view then markdown.live_render.detach(view) end
    config.markdown_live_editor = old_live
    core.active_view = old_active
    if not ok then error(err, 0) end
  end)
end)
