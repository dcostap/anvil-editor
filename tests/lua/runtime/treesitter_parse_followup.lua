local test = require "core.test"
local native = require "treesitter"

test.it("finishes a parse that exceeds one worker time slice", function()
  local lines = {}
  for i = 1, 50000 do lines[i] = "int input = input + 1; /* input */\n" end
  local state = assert(native.new_buffer_state("c", { parse_timeout_ms = 1 }))
  assert(state:schedule_parse(lines, 1))
  local deadline = system.get_time() + 30
  local status, reason
  repeat
    state:poll(1)
    status, reason = state:status()
    if status ~= "queued" and status ~= "parsing" then break end
    coroutine.yield(.001)
  until system.get_time() > deadline
  state:close()
  test.equal(status, "ready", reason)
end)

test.it("publishes the same highlights, outline, and symbols as a fresh parse after queued edits", function()
  local Buffer = require "core.buffer"
  local treesitter = require "core.treesitter"
  local highlight = require "core.treesitter.highlight"
  local buffer = Buffer("queued-edits.c", USERDIR .. PATHSEP .. "queued-edits.c", true)
  local fresh = Buffer("fresh-edits.c", USERDIR .. PATHSEP .. "fresh-edits.c", true)
  local function ready(doc)
    local deadline = system.get_time() + 10
    repeat
      treesitter.poll_buffer(doc)
      local state = doc.treesitter
      if state.status == "ready" and not state.latest_parse_pending and not state.pending_parse_thread then return end
      coroutine.yield(.001)
    until system.get_time() > deadline
    error("latest text did not reach ready")
  end
  local ok, err = pcall(function()
    buffer:insert(1, 1, "int kept(void) { return 1; }\n" .. ("int input = 2;\n"):rep(2500))
    for _ = 1, 10 do buffer:insert(1, 1, "/* queued edit */\n") end
    buffer:insert(#buffer.lines, 1, "int newest(void) { return kept(); }\n")
    ready(buffer)
    fresh:insert(1, 1, buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines]))
    ready(fresh)
    test.same(treesitter.get_buffer_outline(buffer), treesitter.get_buffer_outline(fresh))
    local symbols = treesitter.locals.get_buffer_symbols(buffer)
    test.ok(#symbols > 0)
    test.same(symbols, treesitter.locals.get_buffer_symbols(fresh))
    for _, line in ipairs { 1, 11, 12, 100, #buffer.lines - 1 } do
      local tokens = highlight.line_tokens(buffer, line)
      test.not_nil(tokens)
      test.same(tokens, highlight.line_tokens(fresh, line))
    end
  end)
  buffer:on_close()
  fresh:on_close()
  if not ok then error(err) end
end)
