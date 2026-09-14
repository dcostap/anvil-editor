-- Run with anvil:lua-ui --test-args ui/markdown_edit_matrix.lua through Meson.
-- These cases check edit transitions, not screenshots or exact theme values.
-- Keep pending-state failures active. Do not replace expected output with raw source.
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local test = require "core.test"

local function ready(instance)
  local deadline = system.get_time() + 5
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

-- Each fixture declares its expected visible text independently of the renderer.
local fixtures = {
  { name = "prose", source = "body", visible = "body" },
  { name = "strong", source = "**bold** body", visible = "bold body" },
  { name = "emphasis", source = "*word* body", visible = "word body" },
  { name = "inline code", source = "`code` body", visible = "code body" },
  { name = "strike", source = "~~old~~ body", visible = "old body" },
  { name = "highlight", source = "==word== body", visible = "word body" },
  { name = "link", source = "[site](https://example.com) body", visible = "site body" },
  { name = "heading", source = "## body", visible = "## body" },
  { name = "bullet", source = "- body", visible = "body" },
  { name = "task", source = "- [ ] body", visible = "body", checkbox = true },
  { name = "checked task", source = "- [x] body", visible = "body", checkbox = true, checked = true },
  { name = "nested bullet", prefix = "- parent\n", source = "  - body", visible = "body" },
  { name = "formatted bullet", source = "- **bold** body", visible = "bold body" },
  { name = "formatted task", source = "- [ ] **bold** body", visible = "bold body", checkbox = true },
  { name = "quoted bullet", source = "> - body", visible = "- body" },
  { name = "YAML bullet", prefix = "---\ntags:\n", source = "  - body", suffix = "\n---", raw = true },
  { name = "TOML list-like text", prefix = "+++\n", source = "- body", suffix = "\n+++", raw = true },
  { name = "fenced list-like text", prefix = "```text\n", source = "- [ ] body", suffix = "\n```", visible = "- [ ] body" },
}

local operations = {
  { name = "typing", text = "!", result = "!" },
  { name = "rapid typing", text = "!", second = "?", result = "!?" },
  { name = "deletion", remove = 1, result = "", trim = 1 },
  { name = "replacement", remove = 1, text = "ies", result = "ies", trim = 1 },
  { name = "split and join", split = true, result = "" },
  { name = "undo and redo", text = "!", history = true, result = "!" },
  { name = "indent and unindent", indent = true, result = "" },
}

local function visible_text(render, source)
  if not render then return source end
  local parts = {}
  for _, fragment in ipairs(render.fragments or {}) do
    if not fragment.hidden then parts[#parts + 1] = fragment.text or "" end
  end
  return table.concat(parts)
end

local function frame_state(view, line, sentinel_line)
  local source = view.buffer.lines[line]:gsub("\n$", "")
  local render = view:get_line_render(line)
  local caret_line, caret_col = view.buffer:get_selection()
  local caret_x, caret_y = view:get_line_screen_position(caret_line, caret_col)
  local first_row = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line] or line
  local sentinel_row = view.wrapped_line_to_idx
    and view.wrapped_line_to_idx[sentinel_line] or sentinel_line
  return {
    visible = visible_text(render, source),
    row_count = view:get_visual_row_count_for_line(line),
    row_height = view:get_visual_row_height(first_row),
    caret_line = caret_line,
    caret_col = caret_col,
    caret_x = caret_x,
    caret_y = caret_y,
    sentinel_y = view:get_visual_row_y_offset(sentinel_row),
  }
end

local function published_frame(view, instance, line, sentinel_line)
  core.ui_snapshot_active = false
  ready(instance)
  linewrapping.complete_async_reconstruction(view)
  core.ui_snapshot_id = core.ui_snapshot_id + 1
  core.ui_snapshot_active = true
  view:update()
  local published = frame_state(view, line, sentinel_line)
  core.ui_snapshot_active = false
  core.ui_snapshot_id = core.ui_snapshot_id + 1
  core.ui_snapshot_active = true
  view:update()
  local settled = frame_state(view, line, sentinel_line)
  core.ui_snapshot_active = false
  test.same(settled, published)
  return published
end

-- The drawing boundary exposes actual checkbox size, not its private closure state.
local function checkbox_size(view, render)
  for _, fragment in ipairs(render and render.fragments or {}) do
    if fragment.markdown_task_checkbox then
      local renderer = require "renderer"
      local saved, size = renderer.draw_rounded_rect
      local saved_text = renderer.draw_text
      renderer.draw_text = function() end
      renderer.draw_rounded_rect = function(x, y, width, height)
        size = size or { width, height }
      end
      local ok, err = pcall(fragment.widget.draw, fragment.widget, fragment,
        0, 0, view:get_line_height())
      renderer.draw_rounded_rect = saved
      renderer.draw_text = saved_text
      if not ok then error(err, 0) end
      return test.not_nil(size)
    end
  end
  error("expected a rendered checkbox")
end

test.describe("Markdown edit matrix", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.merge = config.undo_merge_timeout
    context.snapshot_active = core.ui_snapshot_active
    context.snapshot_id = core.ui_snapshot_id
    config.markdown_live_editor = true
    config.undo_merge_timeout = 0
  end)

  test.after_each(function(context)
    if context.view then
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
    core.active_view = context.active
    core.ui_snapshot_active = context.snapshot_active
    core.ui_snapshot_id = context.snapshot_id
    config.markdown_live_editor = context.live
    config.undo_merge_timeout = context.merge
  end)

  for _, fixture in ipairs(fixtures) do
    local selected_operations = {}
    local list = fixture.checkbox or fixture.name == "bullet"
      or fixture.name == "nested bullet" or fixture.name == "formatted bullet"
    for _, operation in ipairs(operations) do
      if not operation.indent or list then
        selected_operations[#selected_operations + 1] = operation
      end
    end
    for _, operation in ipairs(selected_operations) do
      for _, wrapped in ipairs({ false, true }) do
        test.it(fixture.name .. " / " .. operation.name .. " / "
          .. (wrapped and "wrapped" or "unwrapped"), function(context)
          local prefix = fixture.prefix or ""
          local _, newlines = prefix:gsub("\n", "")
          local line = newlines + 1
          local filename = USERDIR .. PATHSEP .. "markdown-edit-matrix.md"
          local buffer = Buffer(filename, filename, true)
          buffer:insert(1, 1, prefix .. fixture.source .. (fixture.suffix or "") .. "\n\nplain")
          buffer:clear_undo_redo()
          local view = Editor(buffer)
          context.view = view
          view.size.x, view.size.y = wrapped and 90 or 700, 600
          view:set_wrapping_enabled(wrapped)
          core.active_view = view
          buffer:set_selection(line, #fixture.source + 1)
          markdown.live_render.refresh_view(view)
          local instance = test.not_nil(model.peek(buffer))
          ready(instance)
          local original_visible = fixture.visible or fixture.source
          local sentinel_height = view:get_position_visual_row_height(#buffer.lines, 1)
          local original_box
          if fixture.checkbox then original_box = checkbox_size(view, view:get_line_render(line)) end

          local function check(source, visible)
            test.equal(buffer.lines[line]:gsub("\n$", ""), source)
            local render = view:get_line_render(line)
            if fixture.raw then test.equal(render, nil, "frontmatter acquired Markdown rendering") end
            test.equal(visible_text(render, source), visible)
            if render then test.equal(render.source_text, source) end
            if original_box then
              test.same(checkbox_size(view, render), original_box)
              for _, fragment in ipairs(render.fragments) do
                if not fragment.hidden and not fragment.widget and fragment.text ~= "" then
                  test.equal(fragment.strikethrough == true, fixture.checked == true,
                    "task text changed its completion style")
                end
              end
            end
            local x, y = view:get_line_screen_position(line, #source + 1)
            test.ok(x == x and y == y and math.abs(x) < math.huge and math.abs(y) < math.huge,
              "caret position is not finite")
            test.ok(view:get_position_visual_row_height(line, #source + 1) > 0)
            local last = #buffer.lines
            test.equal(visible_text(view:get_line_render(last), "plain"), "plain")
            test.equal(view:get_position_visual_row_height(last, 1), sentinel_height,
              "editing changed the height of the untouched paragraph")
          end
          check(fixture.source, original_visible)
          local col = #fixture.source + 1
          local expected_source = fixture.source:sub(1, #fixture.source - (operation.trim or 0))
            .. operation.result
          local expected_visible = original_visible:sub(1, #original_visible - (operation.trim or 0))
            .. operation.result
          if operation.indent then
            buffer:insert(line, 1, "  ")
            test.equal(instance.status, "pending")
            check("  " .. fixture.source, original_visible)
            ready(instance)
            check("  " .. fixture.source, original_visible)
            buffer:remove(line, 1, line, 3)
          elseif operation.split then
            buffer:insert(line, col, "\n")
            test.equal(instance.status, "pending")
            check(fixture.source, original_visible)
            buffer:remove(line, col, line + 1, 1)
          else
            buffer:set_selection(line, col - (operation.remove or 0), line, col)
            view:on_text_input(operation.text or "")
            if operation.second then
              test.equal(instance.status, "pending")
              check(fixture.source .. operation.text, original_visible .. operation.text)
              view:on_text_input(operation.second)
            end
          end
          test.equal(instance.status, "pending")
          check(expected_source, expected_visible)
          ready(instance)
          check(expected_source, expected_visible)
          if operation.history then
            buffer:undo()
            test.equal(instance.status, "pending")
            check(fixture.source, original_visible)
            ready(instance)
            check(fixture.source, original_visible)
            buffer:redo()
            test.equal(instance.status, "pending")
            check(expected_source, expected_visible)
            ready(instance)
            check(expected_source, expected_visible)
          end
        end)
      end
    end
  end

  for _, delimiter in ipairs({ "---", "+++", "```" }) do
    for _, wrapped in ipairs({ false, true }) do
      test.it("remove and restore " .. delimiter .. " block boundary / "
        .. (wrapped and "wrapped" or "unwrapped"), function(context)
        local filename = USERDIR .. PATHSEP .. "markdown-edit-matrix.md"
        local buffer = Buffer(filename, filename, true)
        buffer:insert(1, 1, delimiter .. "\n- body\n" .. delimiter .. "\n\nplain")
        local view = Editor(buffer)
        context.view = view
        view.size.x, view.size.y = wrapped and 90 or 700, 600
        view:set_wrapping_enabled(wrapped)
        buffer:set_selection(5, 1)
        core.active_view = view
        markdown.live_render.refresh_view(view)
        local instance = test.not_nil(model.peek(buffer))
        ready(instance)
        local function check(expected)
          test.equal(visible_text(view:get_line_render(2), "- body"), expected)
        end
        check("- body")
        buffer:remove(1, 1, 1, #delimiter + 1)
        test.equal(instance.status, "pending")
        check("body")
        ready(instance)
        check("body")
        buffer:insert(1, 1, delimiter)
        test.equal(instance.status, "pending")
        check("- body")
        ready(instance)
        check("- body")
      end)
    end
  end

  local shifted_blocks = {
    { name = "heading", source = "# Heading words that wrap across several visual rows" },
    { name = "formatted prose", source = "**Bold words that wrap across several visual rows**" },
    { name = "bullet", source = "- List words that wrap across several visual rows" },
    { name = "ordered item", source = "12. List words that wrap across several visual rows" },
    { name = "task", source = "- [ ] Task words that wrap across several visual rows" },
    { name = "quote", source = "> Quote words that wrap across several visual rows" },
    { name = "callout", source = "> [!NOTE] Callout words that wrap across several visual rows" },
    { name = "thematic break", source = "---" },
  }

  for _, fixture in ipairs(shifted_blocks) do
    for _, wrapped in ipairs({ false, true }) do
      test.it("keeps a shifted " .. fixture.name .. " stable through each frame / "
        .. (wrapped and "wrapped" or "unwrapped"), function(context)
        local filename = USERDIR .. PATHSEP .. "markdown-frame-transition.md"
        local buffer = Buffer(filename, filename, true)
        buffer:insert(1, 1, fixture.source .. "\n\nsentinel")
        buffer:clear_undo_redo()
        local view = Editor(buffer)
        context.view = view
        view.size.x, view.size.y = wrapped and 320 or 700, 600
        view:set_wrapping_enabled(wrapped)
        core.active_view = view
        buffer:set_selection(1, 1)
        markdown.live_render.refresh_view(view)
        local instance = test.not_nil(model.peek(buffer))
        ready(instance)
        linewrapping.complete_async_reconstruction(view)
        core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
        core.ui_snapshot_active = true
        for line = 1, #buffer.lines do view:get_line_render(line) end
        view:get_visual_row_metric_cache()

        test.equal(command.perform("core:newline"), true)
        core.ui_snapshot_id = core.ui_snapshot_id + 1
        view:update()
        test.equal(instance.status, "pending")
        test.equal(buffer.lines[2]:gsub("\n$", ""), fixture.source)
        local pending = frame_state(view, 2, 4)
        local published = published_frame(view, instance, 2, 4)
        test.same(published, pending)
      end)
    end
  end

  local joined_blocks = {
    shifted_blocks[1], -- heading
    shifted_blocks[3], -- bullet
    shifted_blocks[4], -- ordered item
    shifted_blocks[5], -- task
    shifted_blocks[6], -- quote
    shifted_blocks[7], -- callout
    shifted_blocks[8], -- thematic break
  }

  for _, fixture in ipairs(joined_blocks) do
    for _, wrapped in ipairs({ false, true }) do
      test.it("keeps a joined " .. fixture.name .. " stable through each frame / "
        .. (wrapped and "wrapped" or "unwrapped"), function(context)
        local filename = USERDIR .. PATHSEP .. "markdown-frame-transition.md"
        local buffer = Buffer(filename, filename, true)
        buffer:insert(1, 1, "\n" .. fixture.source .. "\n\nsentinel")
        buffer:clear_undo_redo()
        local view = Editor(buffer)
        context.view = view
        view.size.x, view.size.y = wrapped and 320 or 700, 600
        view:set_wrapping_enabled(wrapped)
        core.active_view = view
        buffer:set_selection(2, 1)
        markdown.live_render.refresh_view(view)
        local instance = test.not_nil(model.peek(buffer))
        ready(instance)
        linewrapping.complete_async_reconstruction(view)
        core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
        core.ui_snapshot_active = true
        for line = 1, #buffer.lines do view:get_line_render(line) end
        view:get_visual_row_metric_cache()

        test.equal(command.perform("core:backspace"), true)
        core.ui_snapshot_id = core.ui_snapshot_id + 1
        view:update()
        test.equal(instance.status, "pending")
        test.equal(buffer.lines[1]:gsub("\n$", ""), fixture.source)
        local pending = frame_state(view, 1, 3)
        local published = published_frame(view, instance, 1, 3)
        test.same(published, pending)
      end)
    end
  end
end)
