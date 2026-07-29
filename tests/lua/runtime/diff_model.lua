local test = require "core.test"
local model = require "plugins.diff.model"

local function lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do out[#out + 1] = line end
  if #out == 0 then out[1] = "\n" end
  return out
end

test.describe("DiffModel", function()
  test.it("computes equal text", function()
    local m = model.compute(lines("a\nb"), lines("a\nb"))
    test.equal(m:line_state("a", 1), "equal")
    test.equal(#m.equal_blocks, 1)
    test.equal(m:map_line("a", 2), 2)
  end)

  test.it("computes insert and delete hunks with line mapping", function()
    local m = model.compute(lines("aa\nbb"), lines("aa\ninserted\nbb"))
    test.equal(m:line_state("b", 2), "insert")
    test.equal(m.b_gaps[2][2], 0)
    test.equal(m.a_gaps[2][2], 1)
    test.equal(m:map_line("a", 2), 3)
    test.equal(m:map_line("b", 3), 2)

    local hunk = m:hunk_at("b", 2)
    test.same({ hunk.tag, hunk.start_line, hunk.end_line }, { "insert", 2, 2 })
  end)

  test.it("uses whole-word inline ranges for modified tokens", function()
    local m = model.compute(lines("cat"), lines("cot"))
    test.equal(m:line_state("a", 1), "modify")
    local ranges = m:inline_ranges("a", 1)
    test.ok(type(ranges) == "table" and #ranges > 0, "expected inline ranges")
    test.same(ranges, { { col1 = 1, col2 = 4 } })
    test.equal(m:next_hunk("a", 1, 1).tag, "modify")
  end)

  test.it("pairs structurally corresponding lines despite substantially different text", function()
    local before = '    description: "Verifies that APPi loaded its managed Pi extension bundle",'
    local after = '    description: "Comprueba que APPi cargó las extensiones administradas del asistente IA",'
    local m = model.compute(lines(before), lines(after))

    test.equal("modify", m:line_state("a", 1))
    test.equal("modify", m:line_state("b", 1))
    test.equal(1, m:map_line("a", 1))
    test.equal(1, m:map_line("b", 1))

    local a_ranges = m:inline_ranges("a", 1)
    local b_ranges = m:inline_ranges("b", 1)
    test.ok(#a_ranges <= 3 and #b_ranges <= 3, "expected calm phrase-level inline spans")
    test.ok(a_ranges[1].col2 - a_ranges[1].col1 > 3, "expected a meaningful old-text span")
    test.ok(b_ranges[1].col2 - b_ranges[1].col1 > 3, "expected a meaningful new-text span")
  end)

  test.it("looks past a neighboring insertion to retain structural line pairing", function()
    local before = lines('description: "old managed extension bundle"\nstable tail')
    local after = lines('inserted: true\ndescription: "new managed assistant extensions"\nstable tail')
    local m = model.compute(before, after)

    test.equal("modify", m:line_state("b", 1))
    test.equal("modify", m:line_state("a", 1))
    test.equal("modify", m:line_state("b", 2))
    test.equal(2, m:map_line("a", 1))
    test.equal(1, m:map_line("b", 2))
  end)

  test.it("pairs a rewritten comment with the first line of its expanded replacement", function()
    local before = lines(table.concat({
      "// Let Swing paint the lightweight loading surface before cold Compose/Skiko initialization occupies the EDT.",
      "Timer(AI_CHAT_COMPOSE_START_DELAY_MILLIS) {",
    }, "\n"))
    local after = lines(table.concat({
      "// First let the loading Canvas become displayable and create its native buffers. ComposePanel",
      "// then has to initialize and compose on the AWT event thread, so the Canvas renders actively",
      "// on its own thread until the complete chat tree is ready.",
      "Timer(AI_CHAT_COMPOSE_START_DELAY_MILLIS) {",
    }, "\n"))
    local m = model.compute(before, after)

    test.equal(m:line_state("a", 1), "modify")
    test.equal(m:line_state("b", 1), "modify")
    test.equal(m:line_state("b", 2), "modify")
    test.equal(m:line_state("b", 3), "modify")
    test.equal(m:map_line("a", 1), 1)
  end)

  test.it("highlights whole replaced words instead of matching stray letters across words", function()
    local before = '"Pi rechazó el mensaje, pero no confirmó la retirada de su correlación.",'
    local after = '"El asistente IA rechazó el mensaje, pero no confirmó la retirada de su correlación.",'
    local m = model.compute(lines(before), lines(after))
    local old_range = m:inline_ranges("a", 1)[1]
    local new_range = m:inline_ranges("b", 1)[1]

    test.equal(before:sub(old_range.col1, old_range.col2 - 1), "Pi")
    test.equal(after:sub(new_range.col1, new_range.col2 - 1), "El asistente IA")
  end)

  test.it("uses programming symbols as word boundaries", function()
    local before = "it.add(AiChatSwingLoadingPanel(loadingStartedAt), AI_CHAT_LOADING_CARD)"
    local after = "it.add(AiChatSwingLoadingCanvas(loadingStartedAt), AI_CHAT_LOADING_CARD)"
    local m = model.compute(lines(before), lines(after))
    local old_range = m:inline_ranges("a", 1)[1]
    local new_range = m:inline_ranges("b", 1)[1]

    test.equal(before:sub(old_range.col1, old_range.col2 - 1), "AiChatSwingLoadingPanel")
    test.equal(after:sub(new_range.col1, new_range.col2 - 1), "AiChatSwingLoadingCanvas")
  end)

  test.it("treats multi-character operators as lexical words", function()
    local before, after = "if (left == right)", "if (left != right)"
    local m = model.compute(lines(before), lines(after))
    local old_range = m:inline_ranges("a", 1)[1]
    local new_range = m:inline_ranges("b", 1)[1]

    test.equal(before:sub(old_range.col1, old_range.col2 - 1), "==")
    test.equal(after:sub(new_range.col1, new_range.col2 - 1), "!=")
  end)

  test.it("emits long unchanged fold candidates", function()
    local left, right = {}, {}
    for i = 1, 20 do left[i], right[i] = "same " .. i .. "\n", "same " .. i .. "\n" end
    left[10], right[10] = "old\n", "new\n"
    local m = model.compute(left, right)
    test.ok(#m.equal_blocks >= 2, "expected equal blocks around the change")
    test.equal(m.equal_blocks[1].has_next_change, true)
    test.equal(m.equal_blocks[2].has_prev_change, true)
  end)
end)
