local test = require "core.test"
local scan = require "core.local_find_scan"
local native = require "line_search"

test.it("native line ranges match the original line scanner", function()
  local lines = { "", "\n", "aAa aa\n", "abc", "last a", "a\0A\n", "é É a\n" }
  for _, query in ipairs { "a", "aa", "\n", "^", "$", "a*", "(?=a)", "[", "é" } do
    for _, is_regex in ipairs { false, true } do
      for _, sensitive in ipairs { false, true } do
        local search, err = scan.compile(query, is_regex, sensitive)
        if err then
          test.is_nil(search)
        else
          local expected = {}
          local old_ok, old_err = pcall(function() for line, text in ipairs(lines) do
            scan.line(text, search, function(first, last)
              expected[#expected + 1] = { line = line, col1 = first, col2 = last }
            end)
          end end)
          local new_ok, index = pcall(native.scan, lines, search.query, search.compiled, sensitive)
          test.equal(new_ok, old_ok, query)
          if not old_ok then
            test.ok(tostring(index):find("regex matching error", 1, true), tostring(old_err))
          else
          test.equal(#index, #expected, query)
          for i, match in ipairs(expected) do test.same(index[i], match, query) end
          end
        end
      end
    end
  end
end)

test.it("returns the first caret candidate before completing the scan", function()
  local lines = {}
  for i = 1, 200 do lines[i] = "hit hit\n" end
  local index = native.begin(lines)
  local next_line, long_line, nearest = index:advance(lines, "hit", nil, true, 100, 1, 65536, 200, 100, 8, true)
  test.equal(next_line, 102)
  test.equal(long_line, false)
  test.same(nearest, { line = 101, col1 = 1, col2 = 4 })
  index:advance(lines, "hit", nil, true, next_line, 1, 65536, 200, 100, 8)
  index:advance(lines, "hit", nil, true, 1, 1, 65536, 99, 100, 8)
  index:finish()
  test.equal(#index, 400)
  test.same(index[201], nearest)
end)

test.it("keeps edited coverage correct across budgeted updates", function()
  local lines = {}
  for i = 1, 130 do lines[i] = "x\n" end
  local index = native.scan(lines, "x", nil, true)
  test.is_nil(index:coverage(nil, nil, 130, 1, 0, 130, 1, .000000001))
  lines[1], lines[100] = "xx\n", "\n"
  index:replace(lines, "x", nil, true, 1, 1, 1, 1)
  index:replace(lines, "x", nil, true, 100, 100, 100, 100)
  local rows
  repeat rows = index:coverage(nil, nil, 130, 1, 0, 130, 1, .000000001) until rows
  for row = 0, 129 do test.equal(rows[row], row == 0 and 2 or row == 99 and 0 or 1) end
end)

test.it("native line ranges retain navigation after line replacement and insertion", function()
  local native = require "line_search"
  local lines = { "hit hit\n", "miss\n", "hit\n" }
  local index = native.scan(lines, "hit", nil, true)
  lines[2] = "hit\n"
  index:replace(lines, "hit", nil, true, 2, 2, 2, 2)
  test.equal(#index, 4)
  test.same(index[3], { line = 2, col1 = 1, col2 = 4 })
  lines = { "hit hit\n", "hit\n", "hit hit\n", "hit\n" }
  index:replace(lines, "hit", nil, true, 2, 2, 2, 3)
  test.equal(#index, 6)
  test.same(index[6], { line = 4, col1 = 1, col2 = 4 })
  test.same({ index:line_range(3) }, { 4, 5 })
end)

test.it("coverage counts stay current after a local edit", function()
  local native = require "line_search"
  local lines = { "hit hit\n", "miss\n", "hit\n" }
  local index = native.scan(lines, "hit", nil, true)
  test.same(index:coverage(nil, nil, 3, 1, 0, 3, 1), { [0] = 2, [1] = 0, [2] = 1 })
  lines[2] = "hit\n"
  index:replace(lines, "hit", nil, true, 2, 2, 2, 2)
  test.same(index:coverage(nil, nil, 3, 1, 0, 3, 1), { [0] = 2, [1] = 1, [2] = 1 })
end)
