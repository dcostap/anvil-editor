local Buffer = require "core.buffer"
local model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function buffer_with(text)
  local buffer = Buffer("incremental.md", "incremental.md", true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  return buffer
end

local function ready(instance)
  local deadline = system.get_time() + 30
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.001)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function nodes(instance, count)
  local result, reason = instance:nodes_for_lines(1, count)
  test.not_nil(result, reason)
  test.ok(not result.truncated)
  -- Identities belong to one model. Source ranges and semantic content must agree.
  for _, node in ipairs(result) do node.id = nil end
  return result
end

local function compare(buffer, instance, label)
  ready(instance)
  test.equal(instance.published_revision, buffer.text_revision, label)
  local text = buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
  local fresh_buffer = buffer_with(text)
  local fresh = model.get(fresh_buffer)
  ready(fresh)
  local actual, expected = nodes(instance, #buffer.lines), nodes(fresh, #fresh_buffer.lines)
  test.equal(#actual, #expected, label)
  for index = 1, #actual do test.same(actual[index], expected[index]) end
  test.same(instance:footnote_definitions(), fresh:footnote_definitions(), label)
  test.same(instance:footnote_lines(), fresh:footnote_lines(), label)
  model.close(fresh_buffer, "test")
end

local function replace(buffer, old, new)
  local text = table.concat(buffer.lines)
  local first = test.not_nil(text:find(old, 1, true), old)
  local line1, col1 = buffer:position_offset(1, 1, first - 1)
  local line2, col2 = buffer:position_offset(line1, col1, #old)
  buffer:clear_undo_redo()
  buffer:apply_edits({ { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = new } })
end

test.describe("Markdown incremental semantic publication", function()
  test.it("matches a full parse through text edits, block changes, deletes, and undo", function()
    local buffer = buffer_with(table.concat({
      "---", "title: Note", "---", "", "# Heading", "",
      "First **bold** and *word* with [[Note]] and ==light==.", "",
      "- one", "- two", "", "> quote", "> tail", "",
      "| A | B |", "| - | - |", "| a | b |", "",
      "```lua", "local x = 1", "```", "",
      "Footnote[^a] and #tag.", "", "[^a]: Definition", "",
      "Last **span**.",
    }, "\n"))
    local instance = model.get(buffer)
    compare(buffer, instance, "initial")
    local edits = {
      { "*word*", "*words*" },
      { "First **bold**", "First\n**bold**" },
      { "- one\n- two", "- one\n\n- two" },
      { "> quote\n> tail", "> quote\ntail" },
      { "| - | - |", "| -- | -- |" },
      { "```lua", "``lua" },
      { "``lua", "```lua" },
      { "title: Note\n---", "title: Note\n--" },
      { "title: Note\n--", "title: Note\n---" },
      { "[^a]: Definition", "[^a]: Changed **definition**" },
      { "- two\n\n> quote\ntail\n\n| A | B |", "Joined" },
    }
    for index, edit in ipairs(edits) do
      replace(buffer, edit[1], edit[2])
      compare(buffer, instance, "edit " .. index)
    end
    buffer:undo()
    compare(buffer, instance, "undo across blocks")
    model.close(buffer, "test")
  end)
end)
