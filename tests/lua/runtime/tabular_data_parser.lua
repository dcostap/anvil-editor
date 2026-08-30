local parser = require "plugins.tabular_data_preview.parser"
local test = require "core.test"

local function buffer_lines(text)
  if text == "" then return { "\n" } end
  local lines = {}
  local start = 1
  while start <= #text do
    local stop = text:find("\n", start, true)
    if stop then
      lines[#lines + 1] = text:sub(start, stop)
      start = stop + 1
    else
      lines[#lines + 1] = text:sub(start) .. "\n"
      break
    end
  end
  return lines
end

local function parse(text, delimiter)
  return parser.parse(buffer_lines(text), delimiter or ",")
end

test.describe("Tabular data parser", function()
  test.it("parses each supported delimiter", function()
    for _, case in ipairs {
      { ",", "Name,Age\nAda,37" },
      { "\t", "Name\tAge\nAda\t37" },
      { "|", "Name|Age\nAda|37" },
      { ";", "Name;Age\nAda;37" },
    } do
      local result = parse(case[2], case[1])
      test.same(result.headers, { "Name", "Age" })
      test.same(result.rows[1].cells, { "Ada", "37" })
    end
  end)

  test.it("keeps delimiters, escaped quotes, and newlines inside quotes", function()
    local result = parse('Name,Note\nAda,"one, ""two""\nthree"')
    test.same(result.headers, { "Name", "Note" })
    test.same(result.rows[1].cells, { "Ada", 'one, "two"\nthree' })
    test.equal(result.rows[1].source_line1, 2)
    test.equal(result.rows[1].source_line2, 3)
  end)

  test.it("tracks source ranges after multiline records", function()
    local result = parse('A,B\nx,"first\nsecond"\ny,z')
    test.equal(result.rows[1].source_line1, 2)
    test.equal(result.rows[1].source_line2, 3)
    test.equal(result.rows[2].source_line1, 4)
    test.equal(result.rows[2].source_line2, 4)
  end)

  test.it("pads ragged records and keeps missing fields distinct", function()
    local result = parse("A,B\n1\n2,,3")
    test.same(result.headers, { "A", "B", "Column 3" })
    test.same(result.rows[1].cells, { "1", false, false })
    test.same(result.rows[2].cells, { "2", "", "3" })
    test.equal(result.column_count, 3)
  end)

  test.it("skips physical blank records but keeps empty field records", function()
    local result = parse('\nA,B\n\n,,\n"",x')
    test.same(result.headers, { "A", "B", "Column 3" })
    test.equal(#result.rows, 2)
    test.same(result.rows[1].cells, { "", "", "" })
    test.same(result.rows[2].cells, { "", "x", false })
    test.equal(result.rows[1].source_line1, 4)
    test.equal(result.rows[2].source_line1, 5)
  end)

  test.it("returns unfinished quoted data with a warning", function()
    local result = parse('A,B\n1,"unfinished')
    test.same(result.rows[1].cells, { "1", "unfinished" })
    test.not_nil(result.warning)
  end)

  test.it("keeps UTF-8 cell text unchanged", function()
    local result = parse("Name,City\nZoë,東京")
    test.same(result.rows[1].cells, { "Zoë", "東京" })
  end)
end)
