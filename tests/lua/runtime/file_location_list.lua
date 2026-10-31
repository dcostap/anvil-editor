local test = require "core.test"
local common = require "core.common"
local locations = require "core.text_poi_locations"
local list = require "core.file_location_list"

local function candidate(label, end_col)
  return {
    source_path = "a.lua", label = label, line = 1, col = 1,
    line2 = 1, col2 = end_col, target_line = 8, target_col = 2,
  }
end

test.describe("File location lists", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "location-list-" .. system.get_process_id()
    test.ok(common.mkdirp(context.root))
    context.path = common.normalize_path(context.root .. PATHSEP .. "a.lua")
    local file = assert(io.open(context.path, "wb"))
    file:write("target\n")
    file:close()
  end)

  test.after_each(function(context)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("preserves source ranges and target positions", function(context)
    local data = list.new(locations.extract_candidates("a.lua:8:2\nx a.lua:3:4"), context.root, "test-location")
    data = list.decode(list.encode(data))
    test.same(list.points(data), {
      { line = 1, col = 1, line2 = 1, col2 = 10, target_line = 8, target_col = 2,
        path = context.path, label = "a.lua", kind = "test-location", text_bounds = true },
      { line = 2, col = 3, line2 = 2, col2 = 12, target_line = 3, target_col = 4,
        path = context.path, label = "a.lua", kind = "test-location", text_bounds = true },
    })
    test.ok(os.remove(context.path))
    local next_snapshot = list.new(locations.extract_candidates("a.lua:8:2"), context.root, "test-location")
    test.equal(#list.points(next_snapshot), 0)
  end)

  test.it("finds the next and previous source position without wrapping", function(context)
    local data = list.new(locations.extract_candidates("a.lua:8:2\nx a.lua:3:4"), context.root, "test-location")
    local point = list.next(data, 1, 1, 1)
    test.same({ point.line, point.col }, { 2, 3 })
    point = list.next(data, -1, 2, 3)
    test.same({ point.line, point.col }, { 1, 1 })
    local missing, status = list.next(data, 1, 2, 3)
    test.equal(missing, nil)
    test.equal(status, "boundary")
    missing, status = list.next(data, -1, 1, 1)
    test.equal(missing, nil)
    test.equal(status, "boundary")
    missing, status = list.next(list.new({}, context.root, "test-location"), 1, 1, 1)
    test.equal(missing, nil)
    test.equal(status, "empty")
  end)

  test.it("orders equal positions by range and keeps each label", function(context)
    local data = list.new({ candidate("long", 20), candidate("short", 10) }, context.root, "test-location")
    test.equal(list.point(data, 1).label, "short")
    test.equal(list.point(data, 2).label, "long")
    test.equal(list.point(data, 2).path, context.path)
    test.equal(list.at(data, 1, 5).label, "short")
    test.equal(list.at(data, 1, 15).label, "long")
    test.equal(list.at(data, 1, 20), nil)
    test.equal(list.at(data, 2, 1), nil)
  end)

  test.it("keeps numeric values and complete labels across transfer", function(context)
    local item = candidate("α\0beta", 20)
    item.target_line, item.target_col = 9007199254740991, math.huge
    local data = list.new({ item }, context.root, "test-location")
    local point = list.point(list.decode(list.encode(data)), 1)
    test.equal(point.label, "α\0beta")
    test.equal(point.target_line, 9007199254740991)
    test.equal(point.target_col, math.huge)
  end)
end)
