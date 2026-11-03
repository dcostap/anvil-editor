local Buffer = require "core.buffer"
local Editor = require "core.editor"
local json = require "core.json"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local live_fonts = require "core.markdown.live_fonts"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local harness = {}
local buffers = {}
local sequence = 0

function harness.corpus()
  local file = assert(io.open("tests/fixtures/markdown/commonmark-inline.json", "rb"))
  local corpus = json.decode(file:read("*a"))
  file:close()
  return corpus
end

function harness.check_reference(corpus, fixture)
  local source = fixture.markdown:sub(1, -2)
  local view = harness.view(source)
  local actual = harness.runs(view, 1)
  test.same(actual, fixture.runs,
    string.format("https://spec.commonmark.org/%s/#example-%d\nsource: %q\nexpected: %s\nactual: %s",
      corpus.version, fixture.example, source, json.encode(fixture.runs), json.encode(actual)))
end

function harness.close()
  for _, buffer in ipairs(buffers) do model.close(buffer, "inline-contract-test") end
  buffers = {}
end

function harness.refresh(view)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(view.buffer))
  local deadline = system.get_time() + 30
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.01) end
  end
  test.equal(instance.status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
  return instance
end

function harness.view(source)
  sequence = sequence + 1
  local filename = "inline-contract-" .. sequence .. ".md"
  local buffer = Buffer(filename, filename, true)
  buffers[#buffers + 1] = buffer
  buffer:insert(1, 1, source .. "\n\ncontract caret\n")
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.size.x, view.size.y = 1000, 400
  view:set_wrapping_enabled(false)
  buffer:set_selection(#buffer.lines - 1, 1)
  harness.refresh(view)
  return view, buffer
end

-- Compare font semantics, not font names, sizes, colors, or fragment boundaries.
function harness.runs(view, line)
  local fonts = {}
  for _, kind in ipairs({ "emphasis", "strong", "strong_emphasis", "code" }) do
    fonts[live_fonts.inline_style(view, kind)] = kind
  end
  local runs = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(line))) do
    local text = fragment.text or ""
    if not fragment.hidden and text ~= "" then
      local kind = fonts[fragment.font] or "normal"
      local strike = fragment.strikethrough or nil
      local highlight = fragment.background == style.markdown_live_highlight_bg or nil
      local previous = runs[#runs]
      if previous and previous.style == kind and previous.strike == strike
        and previous.highlight == highlight
      then
        previous.text = previous.text .. text
      else
        runs[#runs + 1] = { text = text, style = kind, strike = strike, highlight = highlight }
      end
    end
  end
  return runs
end

function harness.snapshot(view, source)
  harness.refresh(view)
  local lines = {}
  local count = 1
  for _ in source:gmatch("\n") do count = count + 1 end
  for line = 1, count do lines[line] = harness.runs(view, line) end
  return lines
end

return harness
