local heap_census = require "core.heap_census"
local test = require "core.test"

local MODULE = "heap_census_test_owner"

local function owner_row(report, name)
  for _, row in ipairs(report.owners) do
    if row.owner == name then return row end
  end
end

local function owner_ending(report, suffix)
  for _, row in ipairs(report.owners) do
    if row.owner:sub(-#suffix) == suffix then return row end
  end
end

test.describe("Heap Census", function()
  test.after_each(function()
    package.loaded[MODULE] = nil
  end)

  test.it("gives a module's data to the module key that holds it", function()
    local rows = {}
    for i = 1, 40000 do rows[i] = { i } end
    package.loaded[MODULE] = { rows = rows, again = rows }
    rows = nil
    local report = heap_census.run()
    -- Both keys reach the rows. The first one that the walk reaches owns them, once.
    local children = owner_row(report, MODULE .. ".rows[n]") or owner_row(report, MODULE .. ".again[n]")
    test.equal(test.not_nil(children).tables, 40000)
    local large
    for _, row in ipairs(report.large_tables) do
      if row.owner == MODULE .. ".again" or row.owner == MODULE .. ".rows" then large = row end
    end
    test.equal(test.not_nil(large).entries, 40000)
  end)

  test.it("names module-private state by its source file and variable", function()
    local private_cache = {}
    for i = 1, 1000 do private_cache[i] = { i } end
    package.loaded[MODULE] = { get = function() return private_cache end }
    local report = heap_census.run()
    local row = test.not_nil(owner_ending(report, "heap_census.lua:private_cache[n]"))
    test.equal(row.tables, 1000)
  end)

  test.it("writes a report with the owners and the largest tables", function()
    local rows = {}
    for i = 1, 40000 do rows[i] = i end
    package.loaded[MODULE] = { rows = rows }
    local text = heap_census.format(heap_census.run())
    test.ok(text:find(MODULE .. ".rows", 1, true), "the report names the owner")
    test.ok(text:find("Largest single tables", 1, true), "the report lists large tables")
  end)
end)
