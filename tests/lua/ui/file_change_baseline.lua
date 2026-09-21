local core = require "core"
local common = require "core.common"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local test = require "core.test"

local file_changes = require "plugins.gitdiff_highlight"
local untitled_tabs = require "plugins.untitled_tabs"

local function wait_until(predicate, message)
  local deadline = system.get_time() + 8
  while system.get_time() < deadline do
    if predicate() then return end
    coroutine.yield(0.02)
  end
  test.fail(message or "timed out waiting for file changes", 2)
end

local function file_change_count(view)
  local points = view:get_points_of_interest()
  local count = 0
  for _, point in ipairs(points or {}) do
    if point.kind == "file-change" then count = count + 1 end
  end
  return count
end

local function make_untitled(context)
  local buffer = Buffer(nil, nil, true)
  untitled_tabs.tag_buffer(buffer, "Untitled-Baseline-Test")
  local view = Editor(buffer)
  context.buffer = buffer
  context.view = view
  core.active_view = view
  return buffer, view
end

local function text(buffer)
  return buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
end

test.describe("Buffer Baseline file changes", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    context.clipboard = system.get_clipboard()
  end)

  test.after_each(function(context)
    core.active_view = context.active_view
    system.set_clipboard(context.clipboard or "")
    if context.buffer then context.buffer:on_close() end
    if context.path then os.remove(context.path) end
  end)

  test.it("does not make ordinary Untitled typing a baseline", function(context)
    local _, view = make_untitled(context)
    view:on_text_input(string.rep("typed words ", 12))
    local source = file_changes.get_patch_source(view.buffer)
    test.equal(source, nil)
  end)

  test.it("uses a large whole-content paste as the initial Untitled baseline", function(context)
    local buffer, view = make_untitled(context)
    local pasted = string.rep("baseline words ", 9)
    test.ok(#pasted > 100)
    system.set_clipboard(pasted)
    test.ok(command.perform("core:paste"))
    wait_until(function() return file_changes.get_patch_source(buffer) ~= nil end)
    test.equal(file_change_count(view), 0)

    buffer:insert(1, 1, "changed ")
    wait_until(function() return file_change_count(view) > 0 end)
    test.ok(command.perform("diff:copy_diff_patch_for_file"))
    test.contains(system.get_clipboard(), "+changed baseline words")
  end)

  test.it("does not capture a paste beside existing non-whitespace text", function(context)
    local buffer = make_untitled(context)
    buffer:insert(1, 1, "typed first ")
    system.set_clipboard(string.rep("pasted words ", 10))
    test.ok(command.perform("core:paste"))
    test.equal(file_changes.get_patch_source(buffer), nil)
  end)

  test.it("captures a large paste that replaces all meaningful content", function(context)
    local buffer, view = make_untitled(context)
    buffer:insert(1, 1, "draft")
    view:with_selection_state(function()
      buffer:set_selection(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
    end)
    system.set_clipboard(string.rep("replacement words ", 8))
    test.ok(command.perform("core:paste"))
    wait_until(function() return file_changes.get_patch_source(buffer) ~= nil end)
    test.equal(file_change_count(view), 0)
  end)

  test.it("does not capture a paste of 100 characters", function(context)
    local buffer = make_untitled(context)
    system.set_clipboard(string.rep("x", 100))
    test.ok(command.perform("core:paste"))
    test.equal(file_changes.get_patch_source(buffer), nil)
  end)

  test.it("uses the Untitled paste rule for a new file path", function(context)
    local path = USERDIR .. PATHSEP .. "new-file-baseline-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000) .. ".txt"
    context.path = path
    local buffer = Buffer(path, path, true)
    local view = Editor(buffer)
    context.buffer = buffer
    context.view = view
    core.active_view = view
    system.set_clipboard(string.rep("new file words ", 9))
    test.ok(command.perform("core:paste"))
    wait_until(function() return file_changes.get_patch_source(buffer) ~= nil end)
    test.equal(file_change_count(view), 0)
  end)

  test.it("sets, navigates, copies, and reverts visible file changes", function(context)
    local buffer, view = make_untitled(context)
    buffer:insert(1, 1, "old\nkeep\n")
    test.ok(command.perform("editor:set_buffer_baseline"))
    buffer:replace(function() return "new\nkeep\n" end)
    wait_until(function() return file_change_count(view) == 1 end)

    view:with_selection_state(function() buffer:set_selection(1, 1) end)
    test.ok(command.perform("diff:copy_diff_patch_under_cursor"))
    test.contains(system.get_clipboard(), "-old\n+new\n")
    test.ok(command.perform("editor:revert_file_change"))
    test.equal(text(buffer), "old\nkeep\n")
  end)

  test.it("uses a manual Buffer Baseline instead of the prior Git comparison", function(context)
    local buffer, view = make_untitled(context)
    buffer:insert(1, 1, "local baseline\n")
    file_changes._set_state_for_tests(buffer, {
      is_in_repo = true,
      base_lines = { "Git baseline\n" },
      ranges = {},
      line_index = {},
    })
    test.ok(command.perform("editor:set_buffer_baseline"))
    buffer:insert(1, 1, "changed ")
    wait_until(function() return file_change_count(view) > 0 end)
    test.ok(command.perform("diff:copy_diff_patch_for_file"))
    test.contains(system.get_clipboard(), "-local baseline\n+changed local baseline\n")
    test.ok(not system.get_clipboard():find("Git baseline", 1, true))
  end)

  test.it("captures an existing non-Git file when first opened", function(context)
    local path = USERDIR .. PATHSEP .. "file-baseline-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000) .. ".txt"
    context.path = path
    local file = assert(io.open(path, "wb"))
    assert(file:write("old\nkeep\n"))
    file:close()

    local buffer = Buffer(path, path, false)
    local view = Editor(buffer)
    context.buffer = buffer
    context.view = view
    core.active_view = view
    wait_until(function() return file_changes.get_patch_source(buffer) ~= nil end)
    test.equal(file_change_count(view), 0)

    buffer:replace(function() return "new\nkeep\n" end)
    wait_until(function() return file_change_count(view) > 0 end)
    test.ok(command.perform("diff:copy_diff_patch_for_file"))
    test.contains(system.get_clipboard(), "-old\n+new\n")

    buffer:save()
    view:on_close()
    if core.buffer_registry then core.buffer_registry:remove(buffer, true) end
    local reopened = Buffer(path, path, false)
    view = Editor(reopened)
    context.buffer = reopened
    context.view = view
    core.active_view = view
    wait_until(function() return file_change_count(view) > 0 end,
      "reopened file did not retain its Buffer Baseline")
  end)
end)
