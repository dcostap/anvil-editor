local test = require "core.test"
local common = require "core.common"

local TEXT, HIDDEN, WIDGET = 0, 1, 2
local font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
font:set_tab_size(4)
local cell = font:get_width("a")

-- Keep this oracle in the test. The rules come from the Lua rendered-line
-- loop and column cursor at 6c57c4d7, not from the native wrap implementation.
-- Text layouts supply measurements only; they do not choose row starts.
-- Each row accepts one character, even if that character exceeds its width.
local function opportunity(source, col, char)
  if char:find("^[ ,;(%[{/\\:]$") then return true end
  local before, after = source:sub(col - 1, col - 1), source:sub(col + 1, col + 1)
  if char == "." then
    return after ~= "." and not (before:match("%d") and after:match("%d"))
  end
  return char == "-" and before:match("%a") and after:match("%a")
end

local function oracle(line, width, mode)
  -- Scan from the start for each lookup. Hidden endpoints keep the left x.
  -- Widgets contribute their full width at the first column inside the span.
  local function x_at(col)
    local x = line.x_offset
    for i = 1, #line.fragments, 7 do
      local f = line.fragments
      local kind, first, last, size, offset, text_first, text_last = unpack(f, i, i + 6)
      if col < first or (col == first and not (kind == WIDGET and first == last)) then return x end
      if kind == HIDDEN then
        if col <= last then return x end
      elseif col < last then
        if kind == WIDGET then return x + size end
        if text_first > 0 and text_last > 0 then
          if col <= text_first then return x + offset end
          if col > text_last then return x + size end
        else
          text_first = first
        end
        return x + offset + line.layouts[(i - 1) / 7 + 1]:width_at(col - text_first)
      end
      if kind ~= HIDDEN then x = x + size end
    end
    return x
  end
  local splits, row, col = { line.start_col }, line.start_col, line.start_col
  local origin, current_x = x_at(row), x_at(row)
  local last_space, space_x
  local last = #line.text - (line.text:sub(-1) == "\n" and 1 or 0)
  for char in common.utf8_chars(line.text:sub(col, last)) do
    local next_col, next_x = col + #char, x_at(col + #char)
    local function too_wide()
      return line.x_offset + (row > 1 and line.begin_width or 0) + next_x - origin > width
    end
    if too_wide() and col > row then
      local split = mode == "word" and last_space and last_space >= row and last_space + 1 or col
      if split <= row then split = col end
      if split > splits[#splits] then splits[#splits + 1] = split end
      row, origin = split, split == col and current_x or space_x or current_x
      if last_space and last_space < row then last_space = nil end
      -- A word break can leave a word that is still wider than the row.
      if too_wide() and col > row then
        splits[#splits + 1], row, origin = col, col, current_x
      end
    elseif mode == "word" and opportunity(line.text, col, char) then
      last_space, space_x = col, next_x
    end
    col, current_x = next_col, next_x
  end
  return splits
end

-- Park-Miller uses exact integer arithmetic in Lua's double number type.
local function random(seed)
  return function(limit)
    seed = (seed * 16807) % 2147483647
    return seed % limit + 1
  end
end

local function chars(value)
  local result = {}
  for char in common.utf8_chars(value) do result[#result + 1] = char end
  return result
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

-- Parts retain source and display text, so shrinking can rebuild valid records.
local function prepare(model)
  local line = { text = "", fragments = {}, layouts = {},
    x_offset = model.x_offset, begin_width = model.begin_width }
  local x = model.x_offset
  for index, part in ipairs(model.parts) do
    local first = #line.text + 1
    local source = part.prefix and part.prefix .. part.value .. part.suffix or part.source
    line.text = line.text .. source
    local layout = part.kind == TEXT and font:text_layout(part.value, { tab_offset = x }) or false
    local size = part.kind == HIDDEN and 0 or part.width or layout:width()
    local text_first = part.prefix and first + #part.prefix or 0
    local text_last = part.prefix and text_first + #part.value or 0
    for _, n in ipairs { part.kind, first, #line.text + 1, size,
      part.offset or 0, text_first, text_last } do
      line.fragments[#line.fragments + 1] = n
    end
    line.layouts[index] = layout
    x = x + size
  end
  local boundaries, col = { 1 }, 1
  for char in common.utf8_chars(line.text) do
    col = col + #char
    boundaries[#boundaries + 1] = col
  end
  line.start_col = boundaries[math.min(model.start_index, #boundaries)]
  if model.newline then line.text = line.text .. "\n" end
  return line
end

local words = { "alpha", "beta", "fragment", "abcdefghijabcdefghijabcdefghij", "a" }
local unicode = { "漢字中文", "🙂🚀", "❤️", "👩‍💻", "👨‍👩‍👧‍👦", "éä", "́" }
local delimiters = { " ", "   ", "\t", ",", ";", "(", "[", "{", "/", "\\", ":", ".", "..", "-", "12.34", "a-b", "12-34" }
local function part_for(kind, rand)
  if kind == 1 then
    local value = words[rand(#words)]
    return { kind = TEXT, source = value, value = value }
  elseif kind == 2 then
    local value = delimiters[rand(#delimiters)]
    return { kind = TEXT, source = value, value = value }
  elseif kind == 3 then
    local value = unicode[rand(#unicode)]
    return { kind = TEXT, source = value, value = value }
  elseif kind == 4 then
    return { kind = HIDDEN, source = ({ "**", "hidden words", "漢🙂", "" })[rand(4)] }
  elseif kind == 5 then
    return { kind = TEXT, source = "&amp;source", value = ({ "&", "longer displayed label", "漢", "" })[rand(4)] }
  elseif kind == 6 then
    return { kind = WIDGET, source = rand(2) == 1 and "[ ]" or "", width = (rand(6) - 1) * cell }
  elseif kind == 7 then
    return { kind = TEXT, prefix = "[", suffix = "](url)", value = words[rand(#words)], offset = cell / 2 }
  elseif kind == 8 then
    return { kind = TEXT, source = "", value = "" }
  end
  return { kind = TEXT, source = "ab", value = "ab", width = cell * rand(5), offset = cell / 2 }
end

local function generate(seed, count)
  local rand, models = random(seed), {}
  for index = 1, count do
    local model = { parts = {}, x_offset = (rand(4) - 1) * cell / 2,
      begin_width = (rand(4) - 1) * cell / 2, start_index = 1, newline = rand(2) == 1 }
    for j = 1, rand(10) + 2 do
      local part = part_for(j == 1 and (index - 1) % 9 + 1 or rand(9), rand)
      -- Styling boundaries can split words, UTF-8 text, and combining sequences.
      if part.kind == TEXT and part.source == part.value and #chars(part.value) > 1 and rand(3) == 1 then
        local units = chars(part.value)
        local at = rand(#units - 1)
        local left, right = table.concat(units, "", 1, at), table.concat(units, "", at + 1)
        model.parts[#model.parts + 1] = { kind = TEXT, source = left, value = left }
        part = { kind = TEXT, source = right, value = right }
      end
      model.parts[#model.parts + 1] = part
    end
    if index % 3 == 0 then model.start_index = rand(12) end
    models[#models + 1] = model
  end
  return models
end

local function equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function results(model, width, mode)
  local line = prepare(model)
  return oracle(line, width, mode), renderer.wrap_fragment_lines({ line }, width, mode)[1]
end

-- Greedy reduction reaches a fixed point for fragment removal, character
-- removal, and removal of optional geometry. All strings keep valid UTF-8.
local function shrink(model, width, mode)
  model = copy(model)
  local function accept(candidate)
    local expected, actual = results(candidate, width, mode)
    if not equal(expected, actual) then model = candidate; return true end
  end
  local changed = true
  while changed do
    changed = false
    for _, key in ipairs { "x_offset", "begin_width", "start_index", "newline" } do
      local neutral = key == "start_index" and 1 or 0
      if key == "newline" then neutral = false end
      if model[key] ~= neutral then
        local candidate = copy(model)
        candidate[key] = neutral
        if accept(candidate) then changed = true end
      end
    end
    for i = #model.parts, 1, -1 do
      local candidate = copy(model)
      table.remove(candidate.parts, i)
      if accept(candidate) then changed = true end
    end
    for i = 1, #model.parts do
      for _, key in ipairs { "source", "value", "prefix", "suffix" } do
        local value = model.parts[i][key]
        if value then
          local units = chars(value)
          for j = #units, 1, -1 do
            local candidate = copy(model)
            local shorter = copy(units)
            table.remove(shorter, j)
            candidate.parts[i][key] = table.concat(shorter)
            if accept(candidate) then changed = true; break end
          end
        end
      end
      for _, key in ipairs { "width", "offset" } do
        if model.parts[i][key] and model.parts[i][key] ~= 0 then
          local candidate = copy(model)
          candidate.parts[i][key] = 0
          if accept(candidate) then changed = true end
        end
      end
    end
  end
  return model
end

local function describe(model, width, mode, batch_result)
  local line = prepare(model)
  local expected, actual = results(model, width, mode)
  actual = batch_result or actual
  local output = { string.format("width=%.17g mode=%s text=%q start_col=%d x_offset=%.17g begin_width=%.17g",
    width, mode, line.text, line.start_col, line.x_offset, line.begin_width) }
  for i, part in ipairs(model.parts) do
    local numbers = {}
    for j = (i - 1) * 7 + 1, i * 7 do numbers[#numbers + 1] = string.format("%.17g", line.fragments[j]) end
    output[#output + 1] = string.format("fragment %d: {%s} display=%q", i, table.concat(numbers, ","), part.value or "")
  end
  output[#output + 1] = "oracle={" .. table.concat(expected, ",") .. "} native={" .. table.concat(actual, ",") .. "}"
  return table.concat(output, "\n")
end

local function compare_batch(models, width, mode, seed)
  local lines = {}
  for i, model in ipairs(models) do lines[i] = prepare(model) end
  local actual = renderer.wrap_fragment_lines(lines, width, mode)
  test.equal(#actual, #lines, "native batch must return one result per line")
  for i, line in ipairs(lines) do
    local expected = oracle(line, width, mode)
    if not equal(expected, actual[i]) then
      local original = describe(models[i], width, mode, actual[i])
      local isolated_expected, isolated_actual = results(models[i], width, mode)
      local reduced
      if not equal(isolated_expected, isolated_actual) then
        reduced = describe(shrink(models[i], width, mode), width, mode)
      else
        -- Keep companion lines if the error requires a batch. Remove each
        -- line that does not affect the mismatch, then repeat to a fixed point.
        local remaining, changed = copy(models), true
        local function batch_mismatch(batch)
          local input = {}
          for j, model in ipairs(batch) do input[j] = prepare(model) end
          local output = renderer.wrap_fragment_lines(input, width, mode)
          for j, item in ipairs(input) do
            if not equal(oracle(item, width, mode), output[j]) then return j, output end
          end
        end
        while changed do
          changed = false
          for j = #remaining, 1, -1 do
            local candidate = copy(remaining)
            table.remove(candidate, j)
            if batch_mismatch(candidate) then remaining, changed = candidate, true end
          end
        end
        local failing, output = batch_mismatch(remaining)
        local descriptions = { "Batch-only mismatch at line " .. failing }
        for j, model in ipairs(remaining) do
          descriptions[#descriptions + 1] = describe(model, width, mode, output[j])
        end
        reduced = table.concat(descriptions, "\n")
      end
      error(string.format("seed=%d line=%d\nOriginal:\n%s\nReduced:\n%s", seed, i,
        original, reduced), 0)
    end
  end
end

test.describe("Fragment wrap differential", function()
  test.it("checks the Lua oracle against worked row starts", function()
    local fixtures = {
      { "abcdefgh ij", 3, "word", { 1, 4, 7, 10 } },
      { "alpha,beta,gamma", 7, "word", { 1, 7, 12 } },
      { "12.34567", 4, "word", { 1, 5 } },
      { "aaa,bbb", 3, "word", { 1, 4, 7 } },
      { "\tab cd", 7, "word", { 1, 5 } },
    }
    for _, fixture in ipairs(fixtures) do
      local model = { parts = { { kind = TEXT, source = fixture[1], value = fixture[1] } },
        x_offset = 0, begin_width = 0, start_index = 1 }
      test.same(oracle(prepare(model), fixture[2] * cell, fixture[3]), fixture[4])
    end
  end)

  for _, seed in ipairs { 1, 42, 8675309, 2147483646 } do
    test.it("matches the old Lua rules with seed " .. seed, function()
      local models = generate(seed, 128)
      for _, width in ipairs { cell / 8, cell, cell * 2, cell * 3.5, cell * 7, cell * 19, cell * 80, math.huge } do
        for _, mode in ipairs { "letter", "word" } do compare_batch(models, width, mode, seed) end
      end
    end)
  end

  test.it("keeps malformed UTF-8 breaks inside each source line", function()
    local models = {}
    local invalid = { "\128", "\191", "\192\175", "\245\128\128\128", "\255", "\226\130", "\240\159", "\237\160\128" }
    for _, bytes in ipairs(invalid) do
      for _, source in ipairs { bytes, "a" .. bytes .. " b", bytes .. "\n" } do
        -- A hidden fragment isolates invalid source from font decoding.
        models[#models + 1] = { text = source, start_col = 1, x_offset = 0, begin_width = 0,
          fragments = { HIDDEN, 1, #source + 1, 0, 0, 0, 0 }, layouts = { false } }
        -- Also exercise invalid text in the renderer's text layout.
        local layout = font:text_layout(source)
        models[#models + 1] = { text = source, start_col = 1, x_offset = 0, begin_width = 0,
          fragments = { TEXT, 1, #source + 1, layout:width(), 0, 0, 0 }, layouts = { layout } }
      end
    end
    for _, width in ipairs { cell / 8, cell * 3, cell * 20 } do
      for _, mode in ipairs { "word", "letter" } do
        local breaks = renderer.wrap_fragment_lines(models, width, mode)
        test.equal(#breaks, #models)
        for i, rows in ipairs(breaks) do
          test.equal(rows[1], 1)
          local last = 0
          local limit = #models[i].text + (models[i].text:sub(-1) == "\n" and 0 or 1)
          for _, col in ipairs(rows) do
            test.ok(col == math.floor(col) and col > last and col <= limit,
              "malformed source must return ordered columns inside the line bounds")
            last = col
          end
        end
      end
    end
  end)
end)
