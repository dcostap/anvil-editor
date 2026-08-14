local common = require "core.common"
local core = require "core"
local command = require "core.command"
local EmptyView = require "core.emptyview"
local Project = require "core.project"
local panes = require "core.panes"
local test = require "core.test"
local treesitter = require "core.treesitter"
local symbol_index = require "core.treesitter.symbol_index"
require "core.commands.language"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function wait_ready(buffer, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_buffer(buffer)
    if buffer.treesitter and buffer.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while system.get_time() < deadline do
    if predicate() then return true end
    coroutine.yield(0.03)
  end
  return false
end

test.describe("language navigation", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_cwd = system.getcwd()
    panes.reset_for_tests()
    panes.create { factory = function() return EmptyView() end }
    context.temp_root = USERDIR
      .. PATHSEP .. "language-navigation-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.temp_root))
    core.projects = { Project(context.temp_root) }
    system.chdir(context.temp_root)
    symbol_index.reset_for_tests()
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    if context.temp_root then
      for i = #core.buffers, 1, -1 do
        local buffer = core.buffers[i]
        if buffer.abs_filename and common.path_belongs_to(buffer.abs_filename, context.temp_root) then
          if buffer:is_dirty() then buffer:clean() end
          remove_buffer(buffer)
        end
      end
      if context.original_cwd then pcall(system.chdir, context.original_cwd) end
      symbol_index.reset_for_tests()
      coroutine.yield(0.05)
      if system.get_file_info(context.temp_root) then
        local ok, err
        local deadline = system.get_time() + 1
        repeat
          ok, err = common.rm(context.temp_root, true)
          if not ok and system.get_time() < deadline then coroutine.yield(0.05) end
        until ok or system.get_time() >= deadline
        test.ok(ok, err)
      end
    end
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    symbol_index.reset_for_tests()
  end)

  test.it("goes to exact Tree-sitter workspace symbol when LSP has no declaration", function(context)
    local main_path = join_path(context.temp_root, "main.odin")
    local defs_path = join_path(context.temp_root, "defs.odin")
    write_file(main_path, [[package demo

main :: proc() {
  target()
}
]])
    write_file(defs_path, [[package demo

target :: proc() {}
]])

    local view = core.open_file(main_path)
    core.set_active_view(view)
    test.ok(wait_ready(view.buffer))
    view.buffer:insert(5, 1, "// local edit\n")
    test.ok(view.buffer:is_dirty())
    view:with_selection_state(function()
      view.buffer:set_selection(4, 5)
    end)

    test.ok(command.perform("language:go-to-declaration", view))
    test.ok(wait_until(function()
      local active = core.active_view
      return active and active.buffer and common.path_equals(active.buffer.abs_filename, defs_path)
    end))

    local project_views = 0
    for _, item in ipairs(panes.history_views(panes.active())) do
      if item.buffer and item.buffer.abs_filename and common.path_belongs_to(item.buffer.abs_filename, context.temp_root) then
        project_views = project_views + 1
      end
    end
    test.equal(project_views, 2, "dirty source Editor should remain in Pane history")
    local buffer = core.active_view.buffer
    local line1, col1, line2, col2 = buffer:get_selection(true)
    test.equal(line1, 3)
    test.equal(col1, 1)
    test.equal(line2, 3)
    test.equal(col2, 7)
  end)
end)
