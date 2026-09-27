local core = require "core"
local Buffer = require "core.buffer"
local common = require "core.common"
local Editor = require "core.editor"
local test = require "core.test"

local function wait_for_point(view, target_line)
  local deadline = system.get_time() + 5
  while system.get_time() < deadline do
    for _, point in ipairs(view:get_points_of_interest()) do
      if point.kind == "editor-file-location" and point.target_line == target_line then
        return point
      end
    end
    coroutine.yield(0.01)
  end
  test.fail("file location scan did not finish", 2)
end

test.describe("Editor file locations in growing files", function()
  test.after_each(function(context)
    for _, view in ipairs(context.views or {}) do view:on_close() end
    if context.buffer then context.buffer:on_close() end
    if context.old_project then core.root_project = context.old_project end
    if context.root then common.rm(context.root, true) end
  end)

  test.it("publishes a large reload after the UI can run again", function(context)
    local root = USERDIR .. PATHSEP .. "editor-file-poi-scan-" .. system.get_process_id()
    local source = root .. PATHSEP .. "source.txt"
    local target = root .. PATHSEP .. "target.txt"
    context.root = root
    context.old_project = core.root_project
    test.ok(common.mkdirp(root))
    local file = assert(io.open(target, "wb"))
    file:write("target\n")
    file:close()
    file = assert(io.open(source, "wb"))
    file:write("target.txt:12:1\n")
    file:close()
    core.root_project = function() return { path = root } end

    local buffer = Buffer(source, source, false)
    local view = Editor(buffer)
    local other = Editor(buffer)
    context.buffer = buffer
    context.views = { view, other }
    test.equal(view:get_points_of_interest()[1].target_line, 12)
    test.equal(other:get_points_of_interest()[1].target_line, 12)
    file = assert(io.open(source, "wb"))
    file:write("plain\n")
    for _ = 1, 8000 do file:write("plain log entry\n") end
    file:write("target.txt:25:1\n")
    file:close()

    buffer:reload()
    -- A reload cannot keep the old location or scan the complete file in one UI step.
    for _, editor in ipairs({ view, other }) do
      for _, point in ipairs(editor:get_points_of_interest()) do
        test.ok(point.kind ~= "editor-file-location")
      end
    end
    local point = wait_for_point(view, 25)
    test.equal(point.path, common.normalize_path(target))
    test.equal(wait_for_point(other, 25).target_line, 25)

    local fresh = Editor(buffer)
    context.views[#context.views + 1] = fresh
    fresh:update()
    test.equal(#fresh:get_points_of_interest(), 0)
    test.equal(wait_for_point(fresh, 25).target_line, 25)
    fresh:on_close()

    file = assert(io.open(source, "ab"))
    for _ = 1, 2000 do file:write("more log text\n") end
    file:write("target.txt:36:1\n")
    file:close()
    buffer:reload()
    -- Locations in the unchanged prefix remain available during an append scan.
    test.equal(view:get_points_of_interest()[1].target_line, 25)
    file = assert(io.open(source, "ab"))
    for _ = 1, 2000 do file:write("still growing\n") end
    file:write("target.txt:40:1\n")
    file:close()
    buffer:reload()
    test.equal(wait_for_point(view, 36).target_line, 36)
    test.equal(wait_for_point(other, 36).target_line, 36)
    test.equal(wait_for_point(view, 40).target_line, 40)
    test.equal(wait_for_point(other, 40).target_line, 40)

    file = assert(io.open(source, "wb"))
    for _ = 1, 8000 do file:write("replacement log text\n") end
    file:write("target.txt:50:1\n")
    file:close()
    buffer:reload()
    test.equal(#view:get_points_of_interest(), 0)
    test.equal(wait_for_point(view, 50).target_line, 50)
    test.equal(wait_for_point(other, 50).target_line, 50)
  end)

  test.it("refreshes a large file-location list without blocking navigation", function(context)
    local root = USERDIR .. PATHSEP .. "editor-file-poi-refresh-" .. system.get_process_id()
    local target = root .. PATHSEP .. "target.txt"
    context.root = root
    context.old_project = core.root_project
    test.ok(common.mkdirp(root))
    local file = assert(io.open(target, "wb"))
    file:write("target\n")
    file:close()
    core.root_project = function() return { path = root } end

    local buffer = Buffer()
    local lines = {}
    for _ = 1, 200 do lines[#lines + 1] = "target.txt:8:1" end
    buffer:insert(1, 1, table.concat(lines, "\n"))
    local view = Editor(buffer)
    context.buffer = buffer
    context.views = { view }
    local deadline = system.get_time() + 5
    while #view:get_points_of_interest() < 200 and system.get_time() < deadline do
      coroutine.yield(0.01)
    end
    test.equal(#view:get_points_of_interest(), 200)

    test.ok(os.remove(target))
    -- Navigation can use the last complete result while file checks run in slices.
    test.equal(#view:get_points_of_interest({ force_revalidate = true }), 200)
    while #view:get_points_of_interest() > 0 and system.get_time() < deadline do
      coroutine.yield(0.01)
    end
    test.equal(#view:get_points_of_interest(), 0)
  end)
end)
