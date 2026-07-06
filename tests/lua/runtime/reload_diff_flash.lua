local test = require "core.test"
local flash = require "plugins.reload_diff_flash"

local function model(old_lines, new_lines, opts)
  return flash._build_model_for_test(old_lines, new_lines, opts)
end

test.describe("reload diff flash", function()
  test.test("builds inline ranges for modified new text", function()
    local m = model({ "alpha\n", "two\n", "omega\n" }, { "alpha\n", "too\n", "omega\n" })
    test.not_ok(m.meta.clean)
    local line = m.lines[2]
    test.not_nil(line)
    test.same(line.inline, { { col1 = 2, col2 = 3, tag = "modify" } })
  end)

  test.test("builds line and inline flash for inserted lines", function()
    local m = model({ "alpha\n", "omega\n" }, { "alpha\n", "bravo\n", "omega\n" })
    local line = m.lines[2]
    test.not_nil(line)
    test.equal(line.tag, "insert")
    test.equal(line.line, true)
    test.same(line.inline, { { col1 = 1, col2 = 6, tag = "insert" } })
  end)

  test.test("anchors pure deletions in the reloaded document", function()
    local m = model({ "alpha\n", "bravo\n", "omega\n" }, { "alpha\n", "omega\n" })
    local line = m.lines[2]
    test.not_nil(line)
    test.equal(line.tag, "delete")
    test.equal(line.line, true)
  end)

  test.test("falls back to coarse line flashes when over budget", function()
    local m = model({ "one\n", "two\n" }, { "three\n", "four\n" }, { max_diff_cells = 1 })
    test.ok(m.meta.too_large)
    test.equal(m.meta.reason, "too_many_cells")
    test.ok(m.lines[1] and m.lines[1].line)
    test.ok(m.lines[2] and m.lines[2].line)
  end)
end)
