local test = require "core.test"
local model = require "plugins.diff.model"

local function lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do out[#out + 1] = line end
  if #out == 0 then out[1] = "\n" end
  return out
end

local function highlighted_text(m, side, text)
  local result = {}
  for _, range in ipairs(m:inline_ranges(side, 1) or {}) do
    local content = text:sub(range.col1, range.col2 - 1):gsub("^%s+", ""):gsub("%s+$", "")
    if content ~= "" then result[#result + 1] = { text = content, tag = range.tag } end
  end
  return result
end

test.describe("DiffModel", function()
  test.it("keeps reflowed parameters free of addition and deletion emphasis", function()
    local before = {
      "void share_resources(uchar** search_map_pointer, uchar*** search_map_rows_pointer,\n",
      "    Map_Stack** stack_array_pointer, Map_Stack*** stack_offsets_pointer);\n",
    }
    local after = {
      "void share_resources(\n",
      "    uchar** search_map_pointer, uchar*** search_map_rows_pointer, Map_Stack** stack_array_pointer,\n",
      "    Map_Stack*** stack_offsets_pointer\n",
      ");\n",
    }
    for _, mode in ipairs { "none", "trim", "ignore" } do
      for _, sides in ipairs { { before, after }, { after, before } } do
        local m = model.compute(sides[1], sides[2], { whitespace_mode = mode })
        test.not_nil(m:next_hunk("a", 1), "line breaks must remain visible changes")
        for index, side in ipairs { "a", "b" } do
          for line, text in ipairs(sides[index]) do
            for _, range in ipairs(m:inline_ranges(side, line) or {}) do
              test.ok(text:sub(range.col1, range.col2 - 1):match("^%s*$"),
                "retained parameters and delimiters must not receive inline emphasis")
            end
            test.same(m:inline_markers(side, line), {})
          end
        end
      end
    end
  end)

  test.it("highlights a renamed parameter without emphasizing the surrounding reflow", function()
    local before = { "void call(first,\r\n", "    oldValue);\r\n" }
    local after = { "void call(\r\n", "    first,\r\n", "    newValue\r\n", ");\r\n" }
    for _, mode in ipairs { "none", "trim", "ignore" } do
      for _, sides in ipairs { { before, after, "oldValue", "newValue" }, { after, before, "newValue", "oldValue" } } do
        local m = model.compute(sides[1], sides[2], { whitespace_mode = mode })
        for index, side in ipairs { "a", "b" } do
          local highlighted = {}
          for line, text in ipairs(sides[index]) do
            for _, range in ipairs(m:inline_ranges(side, line) or {}) do
              test.ok(range.col1 >= 1 and range.col2 <= #text - 1, "ranges must stay within line content")
              local content = text:sub(range.col1, range.col2 - 1)
              if not content:match("^%s*$") then
                highlighted[#highlighted + 1] = { text = content, tag = range.tag }
              end
            end
            test.same(m:inline_markers(side, line), {})
          end
          test.same(highlighted, { { text = sides[index + 2], tag = "modify" } })
        end
      end
    end
  end)

  test.it("separates added wrappers from reindented code", function()
    local before = lines(table.concat({
      "LaunchedEffect(reloadNonce) {",
      "    loading = true",
      "    mainViewModel.apiClient.getPedidosPendientesAlmacen().fold(",
      "        onSuccess = { data = it },",
      '        onFailure = { mainViewModel.onSnackbarQuickError(it.message ?: "No se pudieron cargar los pedidos pendientes") },',
      "    )",
      "    loading = false",
      "}",
    }, "\n"))
    local after = lines(table.concat({
      "LaunchedEffect(reloadNonce) {",
      "    loading = true",
      "    try {",
      "        mainViewModel.apiClient.getPedidosPendientesAlmacen().fold(",
      "            onSuccess = { data = it },",
      '            onFailure = { mainViewModel.onSnackbarQuickError(it.message ?: "No se pudieron cargar los pedidos pendientes") },',
      "        )",
      "    } finally {",
      "        loading = false",
      "        isPullToRefreshInProgress = false",
      "    }",
      "}",
    }, "\n"))
    for _, sides in ipairs { { before, after, "a", "b", "insert" }, { after, before, "b", "a", "delete" } } do
      local m = model.compute(sides[1], sides[2])
      for _, line in ipairs { 3, 8, 10, 11 } do
        test.equal(m:line_state(sides[4], line), sides[5])
      end
      for _, pair in ipairs { { 3, 4 }, { 4, 5 }, { 5, 6 }, { 6, 7 }, { 7, 9 } } do
        test.equal(m:map_line(sides[3], pair[1]), pair[2])
        test.equal(m:map_line(sides[4], pair[2]), pair[1])
        test.equal(m:line_state(sides[3], pair[1]), "modify")
        test.equal(m:line_state(sides[4], pair[2]), "modify")
        test.same(m:inline_ranges(sides[3], pair[1]), {})
        test.same(m:inline_ranges(sides[4], pair[2]), {})
      end
    end
  end)

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

  test.it("does not align an empty Buffer placeholder with content blank lines", function()
    local added = model.compute(lines(""), lines("header\n\nbody"))
    test.equal("insert", added:line_state("b", 1))
    test.equal("insert", added:line_state("b", 2))
    test.equal("insert", added:line_state("b", 3))

    local removed = model.compute(lines("header\n\nbody"), lines(""))
    test.equal("delete", removed:line_state("a", 1))
    test.equal("delete", removed:line_state("a", 2))
    test.equal("delete", removed:line_state("a", 3))
  end)

  test.it("uses whole-word inline ranges for modified tokens", function()
    local m = model.compute(lines("cat"), lines("cot"))
    test.equal(m:line_state("a", 1), "modify")
    local ranges = m:inline_ranges("a", 1)
    test.ok(type(ranges) == "table" and #ranges > 0, "expected inline ranges")
    test.same(ranges, { { col1 = 1, col2 = 4, tag = "modify" } })
    test.equal(m:next_hunk("a", 1, 1).tag, "modify")
  end)

  test.it("distinguishes a replaced separator from text added beside a retained separator", function()
    local before = {
      '2 -> "${vehiculos.first()}, ${vehiculos.last()}"',
      'else -> "${vehiculos.first()} ➜ ${vehiculos.last()} (${vehiculos.size})"',
    }
    local after = {
      '2 -> "${vehiculos.first()} ➜ ${vehiculos.last()}"',
      'else -> "${vehiculos.first()} ➜ (...) ➜ ${vehiculos.last()} (${vehiculos.size})"',
    }
    local function range_at(ranges, col)
      for _, range in ipairs(ranges) do
        if range.col1 <= col and range.col2 > col then return range end
      end
    end
    for _, mode in ipairs { "none", "trim", "ignore" } do
      local m = model.compute(before, after, { whitespace_mode = mode })
      local old = range_at(m:inline_ranges("a", 1), before[1]:find(",", 1, true))
      local new = range_at(m:inline_ranges("b", 1), after[1]:find("➜", 1, true))
      local addition = range_at(m:inline_ranges("b", 2), after[2]:find("(...)", 1, true))
      test.ok(old and new and addition, "all changed separators must have highlights")
      test.equal(old.tag, "modify")
      test.equal(new.tag, "modify")
      test.ok(addition.tag ~= "modify", "added text is not a replacement")
      local markers = m:inline_markers("a", 2)
      test.ok(#markers > 0, "the retained separator must show an insertion marker")
      local first = before[2]:find("➜", 1, true)
      local last = before[2]:find("${vehiculos.last()}", 1, true)
      for _, marker in ipairs(markers) do
        test.ok(marker.col >= first and marker.col <= last, "the marker must stay at the separator")
        local byte = before[2]:byte(marker.col)
        test.ok(byte < 128 or byte >= 192, "the marker must not split a UTF-8 character")
      end
    end
  end)

  test.it("marks inline additions on the unchanged side without adding text", function()
    for _, mode in ipairs { "none", "trim", "ignore" } do
      for _, example in ipairs {
        { "head tail", "head extra tail", 6 },
        { "head", "extra head", 1 },
        { "head", "head extra", 5 },
      } do
        local before, after, col = example[1], example[2], example[3]
        local m = model.compute({ before }, { after }, { whitespace_mode = mode })
        test.same(m:inline_markers("a", 1), { { col = col } })
        test.same(m:inline_ranges("a", 1), {})
        local reversed = model.compute({ after }, { before }, { whitespace_mode = mode })
        test.same(reversed:inline_markers("b", 1), { { col = col } })
        local replaced = model.compute({ "head old tail" }, { "head new tail" }, { whitespace_mode = mode })
        test.same(replaced:inline_markers("a", 1), {})
        test.same(replaced:inline_markers("b", 1), {})
      end
    end
  end)

  test.it("keeps a replacement separate from the added word beside it", function()
    for _, mode in ipairs { "none", "trim", "ignore" } do
      local m = model.compute({ "head oldName tail" }, { "head newName extra tail" }, { whitespace_mode = mode })
      test.same(m:inline_ranges("a", 1), { { col1 = 6, col2 = 13, tag = "modify" } })
      test.same(highlighted_text(m, "b", "head newName extra tail"), {
        { text = "newName", tag = "modify" }, { text = "extra" },
      })
      test.same(m:inline_markers("a", 1), { { col = 14 } })
    end
  end)

  test.it("treats a word extension as a replacement in every whitespace mode", function()
    for _, mode in ipairs { "none", "trim", "ignore" } do
      local m = model.compute({ "head foo tail" }, { "head foobar tail" }, { whitespace_mode = mode })
      test.same(m:inline_ranges("a", 1), { { col1 = 6, col2 = 9, tag = "modify" } })
      test.same(m:inline_ranges("b", 1), { { col1 = 6, col2 = 12, tag = "modify" } })
      test.same(m:inline_markers("a", 1), {})
      test.same(m:inline_markers("b", 1), {})
    end
  end)

  test.it("keeps an insertion marker at the start of a replacement", function()
    for _, mode in ipairs { "none", "trim", "ignore" } do
      local m = model.compute({ "head oldName tail" }, { "head extra newName tail" }, { whitespace_mode = mode })
      test.same(m:inline_markers("a", 1), { { col = 6 } })
      test.same(m:inline_ranges("a", 1), { { col1 = 6, col2 = 13, tag = "modify" } })
      test.same(highlighted_text(m, "b", "head extra newName tail"), {
        { text = "extra" }, { text = "newName", tag = "modify" },
      })
      local reversed = model.compute({ "head extra newName tail" }, { "head oldName tail" }, { whitespace_mode = mode })
      test.same(reversed:inline_markers("b", 1), { { col = 6 } })
    end
  end)

  test.it("does not match UTF-8 fragments inside a replaced word", function()
    local before, after = "head é tail", "head è© tail"
    for _, mode in ipairs { "none", "trim", "ignore" } do
      local m = model.compute({ before }, { after }, { whitespace_mode = mode })
      for _, marker in ipairs(m:inline_markers("a", 1)) do
        local byte = before:byte(marker.col)
        test.ok(not byte or byte < 128 or byte >= 192, "markers must use character boundaries")
      end
      test.same(m:inline_ranges("a", 1), { { col1 = 6, col2 = 8, tag = "modify" } })
      test.same(m:inline_ranges("b", 1), { { col1 = 6, col2 = 10, tag = "modify" } })
      test.same(m:inline_markers("a", 1), {})
      test.same(m:inline_markers("b", 1), {})
    end
  end)

  test.it("places a suffix insertion marker after existing trailing whitespace", function()
    for _, mode in ipairs { "none", "trim", "ignore" } do
      for _, ending in ipairs { "", "\n", "\r\n" } do
        local before, after = "head " .. ending, "head extra" .. ending
        local m = model.compute({ before }, { after }, { whitespace_mode = mode })
        test.same(m:inline_markers("a", 1), { { col = 6 } })
        test.same(m:inline_ranges("a", 1), {})
        local reversed = model.compute({ after }, { before }, { whitespace_mode = mode })
        test.same(reversed:inline_markers("b", 1), { { col = 6 } })
      end
    end
  end)

  test.it("marks all added and removed content within a mixed change block", function()
    local before = { "top\n", "\t-- removed comment  \r\n", " \t\n", "value = 1\n", "bottom\n" }
    local after = { "top\n", "value = 2\n", "bottom\n" }
    for _, sides in ipairs { { before, after, "a", "delete" }, { after, before, "b", "insert" } } do
      local m = model.compute(sides[1], sides[2])
      test.equal(m:line_state(sides[3], 2), sides[4])
      test.same(m:inline_ranges(sides[3], 2), { { col1 = 2, col2 = 20 } })
      test.same(m:inline_ranges(sides[3], 3), {})
      test.same(m:inline_ranges(sides[3], 1), {})
    end
  end)

  test.it("leaves fully added and removed blocks without separate text emphasis", function()
    for _, tail in ipairs { "\nbottom", "" } do
      local text = lines("top\n    added code\n\nmore code" .. tail)
      local context = lines("top" .. tail)
      for _, sides in ipairs { { text, context, "a", "delete" }, { context, text, "b", "insert" } } do
        local m = model.compute(sides[1], sides[2])
        for line = 2, 4 do
          test.equal(m:line_state(sides[3], line), sides[4])
          test.same(m:inline_ranges(sides[3], line), {})
        end
      end
    end
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

    test.equal("insert", m:line_state("b", 1))
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
    test.equal(m:line_state("b", 2), "insert")
    test.equal(m:line_state("b", 3), "insert")
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
