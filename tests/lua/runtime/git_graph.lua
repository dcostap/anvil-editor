local test = require "core.test"
local graph = require "plugins.git.graph"

test.describe("plugins.git.graph", function()
  test.it("keeps a linear history in one lane", function()
    local rows = graph.layout({
      { hash = "a", parents = { "b" } },
      { hash = "b", parents = { "c" } },
      { hash = "c", parents = {} },
    })

    test.equal(rows[1].node_lane, 1)
    test.equal(rows[2].node_lane, 1)
    test.equal(rows[3].node_lane, 1)
    test.equal(rows.max_lanes, 1)
    test.equal(rows[1].segments[1].from_lane, 1)
    test.equal(rows[1].segments[1].to_lane, 1)
  end)

  test.it("splits and rejoins lanes for a merge", function()
    local rows = graph.layout({
      { hash = "merge", parents = { "left", "right" } },
      { hash = "left", parents = { "base" } },
      { hash = "right", parents = { "base" } },
      { hash = "base", parents = {} },
    })

    test.equal(rows[1].node_lane, 1)
    test.equal(rows[1].segments[1].to_lane, 1)
    test.equal(rows[1].segments[2].to_lane, 2)
    test.equal(rows[2].node_lane, 1)
    test.equal(rows[3].node_lane, 2)
    test.equal(rows[3].segments[#rows[3].segments].to_lane, 1)
    test.equal(rows[4].node_lane, 1)
    test.equal(rows.max_lanes, 2)
  end)

  test.it("keeps existing lane positions when another page is appended", function()
    local first_page = {
      { hash = "merge", parents = { "left", "right" } },
      { hash = "left", parents = { "base" } },
    }
    local before = graph.layout(first_page)
    local after = graph.layout({
      first_page[1], first_page[2],
      { hash = "right", parents = { "base" } },
      { hash = "base", parents = {} },
    })

    test.equal(after[1].node_lane, before[1].node_lane)
    test.equal(after[2].node_lane, before[2].node_lane)
    test.equal(after[1].node_color, before[1].node_color)
    test.equal(after[2].node_color, before[2].node_color)
  end)
end)
