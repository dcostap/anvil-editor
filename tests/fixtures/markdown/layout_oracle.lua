-- Fresh-view layout oracle for Markdown Live Preview tests.
--
-- A retained view reuses render plans, wrap maps, and row heights across
-- edits. A fresh view builds all of them from the current text. After both
-- views settle, they must agree on every line's presentation and geometry.
--
-- Load with dofile("tests/fixtures/markdown/layout_oracle.lua").
local core = require "core"
local Buffer = require "core.buffer"
local command = require "core.command"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local wrapping = require "core.linewrapping"
local workers = require "core.worker_pool"
local test = require "core.test"

local oracle = {}

oracle.width, oracle.height = 600, 600

function oracle.drain()
  local pool = workers.current_system()
  if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
end

local function parse_ready(buffer)
  local instance = model.peek(buffer)
  if not instance then return true end
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    oracle.drain()
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
end

-- Run one UI frame the way the main loop does: update, then draw.
function oracle.frame(view)
  core.active_view = view
  renderer.begin_frame(core.window)
  local ok, err = pcall(function()
    core.ui_snapshot_active = true
    core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
    view:update()
    core.ui_snapshot_id = core.ui_snapshot_id + 1
    view:draw()
  end)
  renderer.end_frame()
  core.ui_snapshot_active = false
  if not ok then error(err, 0) end
end

-- Code fence tokens come from a UI-thread coroutine, which runs only while the
-- test yields.
local function fences_ready(view)
  local owner = view.__markdown_live_owner
  local service = owner and owner.fence_service
  if not service then return end
  local deadline = system.get_time() + 5
  while (service.worker_running or #service.queue > 0) and system.get_time() < deadline do
    coroutine.yield(0.001)
  end
end

-- Finish parsing, fence tokenization and wrapping, then let a few frames
-- adopt the results.
function oracle.settle(view)
  parse_ready(view.buffer)
  wrapping.complete_async_reconstruction(view)
  for _ = 1, 3 do
    oracle.frame(view)
    parse_ready(view.buffer)
    fences_ready(view)
    wrapping.complete_async_reconstruction(view)
  end
end

function oracle.make_view(context, source, opts)
  opts = opts or {}
  local buffer = Buffer(opts.name or "layout-oracle.md", nil, true)
  buffer:insert(1, 1, source)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  if opts.selections then
    view:with_selection_state(function()
      for index, selection in ipairs(opts.selections) do
        if index == 1 then
          buffer:set_selection(table.unpack(selection, 1, 4))
        else
          buffer:add_selection(table.unpack(selection, 1, 4))
        end
      end
    end)
  end
  if context then
    context.views = context.views or {}
    context.views[#context.views + 1] = view
  end
  view.position.x, view.position.y = 0, 0
  view.size.x = opts.width or oracle.width
  view.size.y = opts.height or oracle.height
  view:set_wrapping_enabled(true)
  core.active_view = view
  markdown.live_render.refresh_view(view)
  oracle.settle(view)
  return view, buffer
end

function oracle.close_views(context)
  for _, view in ipairs(context.views or {}) do
    view.discard_buffer_on_close = true
    view:on_close()
  end
  context.views = nil
end

local function visible_text(render, source)
  if not render then return source end
  local parts = {}
  for _, fragment in ipairs(render.fragments or {}) do
    if not fragment.hidden then parts[#parts + 1] = fragment.text or "" end
  end
  return table.concat(parts)
end

local function largest_font_size(render)
  local size = 0
  for _, fragment in ipairs(render and render.fragments or {}) do
    if not fragment.hidden and fragment.font and fragment.font.get_size then
      size = math.max(size, fragment.font:get_size())
    end
  end
  return size
end

-- Draw every part of the document once, the way a reader scrolls through
-- it, then return to the original position.
function oracle.scroll_through(view)
  local scroll_y = view.scroll.y
  local y = 0
  for _ = 1, 10000 do
    view.scroll.y, view.scroll.to.y = y, y
    oracle.frame(view)
    local max_y = math.max(0, view:get_scrollable_size() - view.size.y)
    if y >= max_y then break end
    y = math.min(max_y, y + view.size.y / 2)
  end
  view.scroll.y, view.scroll.to.y = scroll_y, scroll_y
  oracle.frame(view)
end

-- Describe each line as a reader sees it: shown text, text size, wrapped
-- rows, and the height of every row.
function oracle.layout(view)
  oracle.scroll_through(view)
  local lines = {}
  for line = 1, #view.buffer.lines do
    local source = view.buffer.lines[line]:gsub("\n$", "")
    local render = view:get_line_render(line)
    local first_row = view.wrapped_line_to_idx and view.wrapped_line_to_idx[line] or line
    local row_count = view:get_visual_row_count_for_line(line)
    local heights = {}
    for offset = 0, row_count - 1 do
      heights[#heights + 1] = view:get_visual_row_height(first_row + offset)
    end
    lines[line] = {
      source = source,
      visible = visible_text(render, source),
      font_size = largest_font_size(render),
      heights = heights,
    }
  end
  return lines
end

local function selections(buffer)
  local result = {}
  for _, line1, col1, line2, col2 in buffer:get_selections() do
    result[#result + 1] = { line1, col1, line2, col2 }
  end
  return result
end

function oracle.fresh_layout(view)
  local fresh = oracle.make_view(nil, view.buffer:get_text(1, 1, math.huge, math.huge), {
    width = view.size.x, height = view.size.y, selections = selections(view.buffer),
  })
  local layout = oracle.layout(fresh)
  fresh.discard_buffer_on_close = true
  fresh:on_close()
  return layout
end

local function describe_line(entry)
  return string.format("visible=%q font=%s heights={%s}",
    entry.visible, tostring(entry.font_size), table.concat(entry.heights, ","))
end

-- Return the first difference, or nil when both layouts match.
function oracle.difference(actual, expected)
  if #actual ~= #expected then
    return string.format("line count %d, fresh view has %d", #actual, #expected)
  end
  for line, want in ipairs(expected) do
    local got = actual[line]
    local same = got.visible == want.visible and got.font_size == want.font_size
      and #got.heights == #want.heights
    for row = 1, same and #want.heights or 0 do
      if math.abs(got.heights[row] - want.heights[row]) > 0.001 then
        same = false
        break
      end
    end
    if not same then
      return string.format("line %d %q\n  retained: %s\n  fresh:    %s",
        line, want.source, describe_line(got), describe_line(want))
    end
  end
end

-- Settle a retained view and compare it with a fresh view of the same text.
function oracle.check(view)
  oracle.settle(view)
  local actual = oracle.layout(view)
  local expected = oracle.fresh_layout(view)
  core.active_view = view
  return oracle.difference(actual, expected)
end

function oracle.assert_matches_fresh(view, label)
  local difference = oracle.check(view)
  if difference then
    error(string.format("%s: retained layout differs from a fresh view at %s",
      label or "layout", difference), 0)
  end
end

-- Deterministic pseudo-random sequence. A failing seed reproduces exactly.
function oracle.random(seed)
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function(low, high)
    state = (state * 48271) % 2147483647
    if not low then return state / 2147483647 end
    return low + state % (high - low + 1)
  end
end

local function pick(rand, items) return items[rand(1, #items)] end

local WORDS = {
  "alpha", "bravo", "charlie", "delta", "export", "integration", "planning",
  "visibility", "calendar", "**bold**", "*italic*", "`code`", "[link](https://example.com)",
  "==mark==", "~~old~~", "#tag",
}

local function words(rand, count)
  local result = {}
  for index = 1, count do result[index] = pick(rand, WORDS) end
  return table.concat(result, " ")
end

local BLOCKS = {
  function(rand) return string.rep("#", rand(1, 3)) .. " " .. words(rand, rand(1, 3)) end,
  function(rand) return string.rep("#", rand(1, 2)) .. " " .. words(rand, rand(12, 20)) end,
  function(rand) return words(rand, rand(3, 8)) end,
  function(rand) return words(rand, rand(20, 40)) end,
  function(rand)
    local items = {}
    for index = 1, rand(2, 6) do
      items[index] = string.rep("    ", rand(0, 1) * (index > 1 and 1 or 0))
        .. "- " .. words(rand, rand(1, 12))
    end
    return table.concat(items, "\n")
  end,
  function(rand)
    local items = {}
    for index = 1, rand(1, 4) do
      items[index] = "- [" .. pick(rand, { " ", "x" }) .. "] " .. words(rand, rand(2, 6))
    end
    return table.concat(items, "\n")
  end,
  function(rand)
    local items = {}
    for index = 1, rand(2, 4) do items[index] = index .. ". " .. words(rand, rand(1, 5)) end
    return table.concat(items, "\n")
  end,
  function(rand) return "> " .. words(rand, rand(3, 15)) end,
  function(rand) return "```lua\nlocal value = " .. rand(1, 99) .. "\nprint(value)\n```" end,
  function(rand)
    return "| name | value |\n| --- | --- |\n| " .. words(rand, 1) .. " | " .. rand(1, 99) .. " |"
  end,
  function() return "---" end,
}

-- Build a document from common Markdown blocks. Most blocks are short; some
-- headings and paragraphs wrap at the oracle width.
function oracle.random_document(rand, block_count)
  local blocks = {}
  for index = 1, block_count or rand(8, 30) do
    blocks[index] = pick(rand, BLOCKS)(rand)
  end
  return table.concat(blocks, "\n\n") .. "\n"
end

local function random_line(rand, buffer) return rand(1, #buffer.lines) end

local function set_carets(view, positions)
  view:with_selection_state(function()
    for index, position in ipairs(positions) do
      if index == 1 then
        view.buffer:set_selection(table.unpack(position, 1, 4))
      else
        view.buffer:add_selection(table.unpack(position, 1, 4))
      end
    end
  end)
end

local function distinct_lines(rand, buffer, count)
  local chosen, result = {}, {}
  for _ = 1, count * 3 do
    local line = random_line(rand, buffer)
    if line < #buffer.lines and not chosen[line] and not chosen[line - 1] and not chosen[line + 1] then
      chosen[line] = true
      result[#result + 1] = line
      if #result == count then break end
    end
  end
  table.sort(result)
  return result
end

local function end_col(buffer, line) return #buffer.lines[line] end

-- Each edit uses a command or the text-input path a user would trigger.
oracle.EDITS = {
  { name = "delete lines with several carets", run = function(view, rand)
    local positions = {}
    for _, line in ipairs(distinct_lines(rand, view.buffer, rand(2, 4))) do
      positions[#positions + 1] = { line, 1, line + 1, 1 }
    end
    if #positions == 0 then return false end
    set_carets(view, positions)
    return command.perform("core:backspace", view)
  end },
  { name = "type at several carets", run = function(view, rand)
    local positions = {}
    for _, line in ipairs(distinct_lines(rand, view.buffer, rand(1, 3))) do
      local col = rand(1, end_col(view.buffer, line))
      positions[#positions + 1] = { line, col }
    end
    if #positions == 0 then return false end
    set_carets(view, positions)
    view:on_text_input(pick(rand, { "x", "# ", "- ", "**", "word ", "> " }))
    return true
  end },
  { name = "split a line", run = function(view, rand)
    local line = random_line(rand, view.buffer)
    set_carets(view, { { line, rand(1, end_col(view.buffer, line)) } })
    return command.perform("core:newline", view)
  end },
  { name = "join lines", run = function(view, rand)
    local line = random_line(rand, view.buffer)
    if line >= #view.buffer.lines then return false end
    set_carets(view, { { line, end_col(view.buffer, line), line + 1, 1 } })
    return command.perform("core:backspace", view)
  end },
  { name = "delete a block range", run = function(view, rand)
    local line1 = random_line(rand, view.buffer)
    local line2 = math.min(#view.buffer.lines, line1 + rand(1, 8))
    set_carets(view, { { line1, 1, line2, 1 } })
    return command.perform("core:backspace", view)
  end },
  { name = "insert a block", run = function(view, rand)
    local line = random_line(rand, view.buffer)
    set_carets(view, { { line, 1 } })
    view:on_text_input(pick(rand, BLOCKS)(rand) .. "\n")
    return true
  end },
  { name = "indent lines", run = function(view, rand)
    local line1 = random_line(rand, view.buffer)
    local line2 = math.min(#view.buffer.lines, line1 + rand(0, 3))
    set_carets(view, { { line1, 1, line2, end_col(view.buffer, line2) } })
    return command.perform(rand(0, 1) == 0 and "core:indent" or "core:unindent", view)
  end },
  { name = "undo", run = function(view) return command.perform("core:undo", view) end },
  { name = "redo", run = function(view) return command.perform("core:redo", view) end },
  { name = "resize the view", run = function(view, rand)
    view.size.x = pick(rand, { 380, 520, 760, 1000 })
    return true
  end },
  { name = "scroll elsewhere", run = function(view, rand)
    local max_y = math.max(0, view:get_scrollable_size() - view.size.y)
    local y = max_y * rand(0, 10) / 10
    view.scroll.y, view.scroll.to.y = y, y
    return true
  end },
}

-- Between edits, the UI may draw zero or more frames and the parser may or
-- may not publish. Each choice exercises a different ordering. Waiting for
-- a complete parse keeps a seed repeatable; a partial drain would depend on
-- worker timing.
function oracle.between_edits(view, rand)
  local choice = rand(1, 5)
  if choice == 2 then
    oracle.frame(view)
  elseif choice == 3 then
    parse_ready(view.buffer)
  elseif choice == 4 then
    parse_ready(view.buffer)
    oracle.frame(view)
  elseif choice == 5 then
    oracle.settle(view)
  end
end

-- Run one seeded sequence. Return nil, or a description of the first
-- difference and the steps that produced it.
function oracle.run_sequence(context, seed, opts)
  opts = opts or {}
  local rand = oracle.random(seed)
  local source = oracle.random_document(rand, opts.block_count)
  local view = oracle.make_view(context, source, { width = pick(rand, { 420, 600, 900 }) })
  local steps = {}
  for _ = 1, opts.edit_count or rand(2, 6) do
    local edit = pick(rand, opts.edits or oracle.EDITS)
    core.active_view = view
    if edit.run(view, rand) ~= false then steps[#steps + 1] = edit.name end
    oracle.between_edits(view, rand)
  end
  local difference = oracle.check(view)
  if difference then
    return string.format("seed %d after [%s]: %s", seed, table.concat(steps, ", "), difference)
  end
end

return oracle
