-- Replay one seed with ANVIL_FUZZ_SEED; increase ANVIL_FUZZ_STEPS for longer chains.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local reference = require "core.layout_reference"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local workers = require "core.worker_pool"
local style = require "core.style"
local test = require "core.test"

-- Park-Miller uses exact integer products within Lua's double precision range.
local function random_source(seed)
  local state = seed
  return function(limit)
    state = (state * 48271) % 2147483647
    return state % limit + 1
  end
end

local function env_integer(name, fallback)
  local text = os.getenv(name)
  if not text then return fallback end
  local value = tonumber(text)
  assert(value and value >= 1 and value < 2147483647 and value == math.floor(value),
    name .. " must be an integer from 1 to 2147483646")
  return value
end

local seeds = os.getenv("ANVIL_FUZZ_SEED") and { env_integer("ANVIL_FUZZ_SEED") } or { 17, 7331 }
local steps = env_integer("ANVIL_FUZZ_STEPS", 12)
local NOTE = table.concat({
  "---", "title: Edit test", "tags: [markdown, test]", "---", "",
  "# Heading", "", "Paragraph with *emphasis*, **strong** and `code`.",
  "A [link](https://example.com) and [reference][site] with a note[^a].", "",
  "- List item", "  - Nested item", "- [ ] First task", "- [x] Second task", "",
  "> A quote with *emphasis*.", "> Second quote line.", "",
  "> [!note]+ Callout", "> Callout body with **strong** words.", "",
  "```lua", "print('hello')", "```", "",
  "Before %%hidden comment%% after.", "%%", "Hidden block", "%%", "",
  "| Name | Value |", "| --- | --- |", "| first | **second** |", "",
  "A long paragraph " .. string.rep("with words that can wrap. ", 12), "",
  "[site]: https://example.com/reference", "[^a]: A footnote definition.",
  "    A second definition line.", "", "## Final heading", "", "Tail paragraph.",
}, "\n")

local function gallery_slice()
  local file = assert(io.open("tests/fixtures/markdown/gallery-benchmark.md", "rb"))
  local lines = {}
  for _ = 1, 60 do
    local line = file:read("*l")
    if not line then break end
    lines[#lines + 1] = line:gsub("\r$", "")
  end
  file:close()
  return table.concat(lines, "\n")
end

local function ready(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 15
  repeat
    local pool = workers.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    view:update()
    linewrapping.complete_async_reconstruction(view)
    if instance.status == "ready" and instance.published_revision == view.buffer.text_revision
      and not view.__async_wrap_reconstruction then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  error("Markdown publication did not finish: " .. tostring(instance.status))
end

local function visible_render_text(view, line)
  local render = view:get_line_render(line)
  if not render or render.raw_passthrough then return view.buffer.lines[line]:gsub("\n$", "") end
  local parts = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(render)) do
    if not fragment.hidden then parts[#parts + 1] = fragment.text or "" end
  end
  return table.concat(parts)
end

local function finite(number)
  return number == number and math.abs(number) < math.huge
end

-- Read public row geometry, including rows outside the viewport.
local function check_pending(view)
  view:update()
  view:reconcile_visible_line_layout()
  local first, last = view:get_visible_line_range()
  for line = first, last do
    local plan = view:get_line_render(line)
    if plan then
      test.equal(plan.source_text, view.buffer.lines[line]:gsub("\n$", ""), "source at line " .. line)
    end
  end
  -- Mouse callbacks capture `line` in private closures, not in a public field.
  -- Do not inspect debug upvalues or call links that can open external programs.
  local count, bottom, previous_line = view:get_scrollable_line_count(), 0, 0
  for row = 1, count do
    local y, height = view:get_visual_row_y_offset(row), view:get_visual_row_height(row)
    local line = view:get_visual_row_line_col(row)
    test.ok(finite(y) and finite(height) and height >= 0, "invalid row " .. row)
    test.ok(math.abs(y - bottom) < 0.000001, "row gap or overlap at " .. row)
    test.ok(line >= previous_line and line <= #view.buffer.lines, "row order at " .. row)
    bottom, previous_line = y + height, line
  end
  -- These tests disable scroll-past-end. Scrollbar and padding are public inputs.
  local expected = math.max(view.size.y, bottom + style.padding.y * 2 + view:get_horizontal_scrollbar_height())
  test.ok(math.abs(view:get_scrollable_size() - expected) < 0.000001, "scrollable size disagrees with rows")
end

local function check_published(context, view)
  ready(view)
  -- Reading all plans starts deferred reference-definition work too.
  for _ = 1, 3 do
    for line = 1, #view.buffer.lines do view:get_line_render(line) end
    coroutine.yield(0)
    view:update()
    linewrapping.complete_async_reconstruction(view)
  end
  local report = reference.compare(view)
  test.ok(not report.skipped, report.summary)
  test.ok(report.ok, report.summary .. "\n" .. table.concat(report.mismatches or {}, "\n"))

  -- Use a new view of the same Buffer. Give it the same public presentation inputs.
  local fresh = Editor(view.buffer)
  context.views[#context.views + 1] = fresh
  fresh.position.x, fresh.position.y = view.position.x, view.position.y
  fresh.size.x, fresh.size.y = view.size.x, view.size.y
  fresh:set_selection_state(view:get_selection_state())
  fresh:restore_owned_feature_state(view:get_owned_feature_state())
  fresh:set_wrapping_enabled(view:is_wrapping_enabled())
  core.active_view = fresh
  markdown.live_render.refresh_view(fresh)
  for _ = 1, 3 do
    for line = 1, #view.buffer.lines do fresh:get_line_render(line) end
    coroutine.yield(0)
    fresh:update()
    linewrapping.complete_async_reconstruction(fresh)
  end
  local expected = {}
  for line = 1, #view.buffer.lines do expected[line] = visible_render_text(fresh, line) end
  core.active_view = view
  for line = 1, #view.buffer.lines do
    local actual = visible_render_text(view, line)
    test.equal(actual, expected[line], string.format("published text at line %d: %q, fresh %q", line, actual, expected[line]))
  end
  fresh.discard_buffer_on_close = false
  fresh:on_close()
  table.remove(context.views)
end

local TOKENS = { "```", "~~~", "%%", "[^", "]:", "- ", "[ ]", "[x]", ">", "#", "|", "---" }
local TEXT = { "x", "*", "**", "`", "%%", "\n", "\n\n", "> ", "- ", "[^a]", "```", "lua" }

local function position(buffer, random)
  local candidates = {}
  for line, text in ipairs(buffer.lines) do
    for _, token in ipairs(TOKENS) do
      local col = text:find(token, 1, true)
      if col then
        candidates[#candidates + 1] = { line, col }
        candidates[#candidates + 1] = { line, col + #token }
      end
    end
  end
  if #candidates > 0 and random(3) ~= 1 then
    local at = candidates[random(#candidates)]
    return at[1], math.min(at[2], #buffer.lines[at[1]])
  end
  local line = random(#buffer.lines)
  local edge = random(3)
  return line, edge == 1 and 1 or edge == 2 and #buffer.lines[line] or random(#buffer.lines[line])
end

local function edit(view, random, step, edits)
  local buffer = view.buffer
  local line, col = position(buffer, random)
  local op = step <= 10 and step or random(10)
  local text = TEXT[random(#TEXT)]
  local description = string.format("%d: op=%d at %d:%d text=%q", step, op, line, col, text)
  edits[#edits + 1] = description
  view:with_selection_state(function() buffer:set_selection(line, col) end)
  if op == 1 or op == 10 then
    view:on_text_input(text)
  elseif op == 2 then
    buffer:insert(line, col, text)
  elseif op == 3 then
    local end_line, end_col = line, math.min(col + random(3), #buffer.lines[line])
    if end_col == col and line < #buffer.lines then end_line, end_col = line + 1, 1 end
    edits[#edits] = description .. string.format(" remove to %d:%d", end_line, end_col)
    buffer:remove(line, col, end_line, end_col)
  elseif op == 4 then
    test.ok(command.perform("core:newline"))
  elseif op == 5 then
    test.ok(command.perform("core:delete"))
  elseif op == 6 then
    local other = line % #buffer.lines + 1
    view:with_selection_state(function() buffer:add_selection(other, 1) end)
    edits[#edits] = description .. " second caret=" .. other .. ":1"
    view:on_text_input(text)
  elseif op == 7 then
    local original = system.get_clipboard
    system.get_clipboard = function() return text .. " pasted\ntext" end
    local ok, err = pcall(command.perform, "core:paste")
    system.get_clipboard = original
    test.ok(ok, err)
    test.ok(err, "paste command did not run")
  elseif op == 8 then
    test.ok(command.perform("core:undo"))
  elseif op == 9 then
    test.ok(command.perform("core:redo"))
  end
end

test.describe("Markdown seeded edit layout", function()
  test.before_each(function(context)
    context.views, context.active = {}, core.active_view
    context.live, context.merge = config.markdown_live_editor, config.undo_merge_timeout
    context.scroll_past_end = config.scroll_past_end
    context.clipboard, context.whole_line = core.cursor_clipboard, core.cursor_clipboard_whole_line
    core.cursor_clipboard, core.cursor_clipboard_whole_line = {}, {}
    config.markdown_live_editor, config.undo_merge_timeout, config.scroll_past_end = true, 0, false
  end)

  test.after_each(function(context)
    for _, view in ipairs(context.views) do
      view.discard_buffer_on_close = true
      view:on_close()
    end
    core.active_view = context.active
    config.markdown_live_editor, config.undo_merge_timeout = context.live, context.merge
    config.scroll_past_end = context.scroll_past_end
    core.cursor_clipboard, core.cursor_clipboard_whole_line = context.clipboard, context.whole_line
  end)

  for _, seed in ipairs(seeds) do
    for _, fixture in ipairs({ { name = "mixed", text = NOTE }, { name = "gallery", text = gallery_slice() } }) do
      for _, wrapped in ipairs({ false, true }) do
        for _, width in ipairs({ 420, 900 }) do
          local label = string.format("seed=%d %s wrapped=%s width=%d", seed, fixture.name, tostring(wrapped), width)
          test.it(label, function(context)
            local buffer = Buffer("edit-fuzz.md", nil, true)
            buffer:insert(1, 1, fixture.text)
            buffer:clear_undo_redo()
            local view = Editor(buffer)
            context.views[#context.views + 1] = view
            view.position.x, view.position.y, view.size.x, view.size.y = 0, 0, width, 380
            view:set_wrapping_enabled(wrapped)
            core.active_view = view
            markdown.live_render.refresh_view(view)
            local edits, step = {}, 0
            local ok, err = pcall(function()
              local random = random_source(seed)
              check_published(context, view)
              local publish_at = random(4) + 2
              for index = 1, steps do
                step = index
                edit(view, random, step, edits)
                check_pending(view)
                if step == publish_at or step == steps then
                  check_published(context, view)
                  publish_at = step + random(4) + 2
                end
              end
            end)
            if not ok then
              error(string.format("%s step=%d\n%s\nDOCUMENT:\n%s\nEDITS:\n%s", label, step,
                tostring(err), buffer:get_text(1, 1, math.huge, math.huge), table.concat(edits, "\n")), 0)
            end
          end)
        end
      end
    end
  end
end)
