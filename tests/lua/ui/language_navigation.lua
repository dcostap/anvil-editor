local common = require "core.common"
local core = require "core"
local command = require "core.command"
local EmptyView = require "core.emptyview"
local Project = require "core.project"
local panes = require "core.panes"
local process = require "core.process"
local test = require "core.test"
local treesitter = require "core.treesitter"
local symbol_index = require "core.treesitter.symbol_index"
require "core.commands.language"
require "plugins.gitdiff_highlight"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function git(root, ...)
  local args = { "git", "-C", root }
  for _, arg in ipairs({...}) do args[#args + 1] = arg end
  local proc = assert(process.start(args, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_DISCARD,
    stderr = process.REDIRECT_PIPE,
  }))
  local code = proc:wait(process.WAIT_INFINITE, 0.01)
  test.equal(code, 0, proc:read_stderr() or "Git fixture failed")
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
        if PLATFORM == "Windows" and system.get_file_info(join_path(context.temp_root, ".git")) then
          os.execute('attrib -R /S /D "' .. context.temp_root:gsub("/", "\\") .. '\\*" >NUL 2>NUL')
        end
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

  for _, alternate in ipairs({ false, true }) do
    test.it("goes to a workspace declaration in the " .. (alternate and "new Pane Group" or "current Pane"), function(context)
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

      local source_pane = panes.active()
      local source_group = source_pane.group
      core.set_active_view(view)
      test.ok(command.perform(alternate and "core:activate_point_of_interest_alternate"
        or "core:activate_point_of_interest"))
      test.ok(wait_until(function()
        local active = core.active_view
        return active and active.buffer and common.path_equals(active.buffer.abs_filename, defs_path)
      end))

      local project_views = 0
      for _, item in ipairs(panes.views(panes.active())) do
        if item.buffer and item.buffer.abs_filename and common.path_belongs_to(item.buffer.abs_filename, context.temp_root) then
          project_views = project_views + 1
        end
      end
      test.equal(project_views, alternate and 1 or 2)
      if alternate then
        test.not_equal(panes.active().group, source_group)
        test.equal(source_pane.current_view, view)
      else
        test.equal(panes.active(), source_pane)
      end
      local buffer = core.active_view.buffer
      local line1, col1, line2, col2 = buffer:get_selection(true)
      test.equal(line1, 3)
      test.equal(col1, 1)
      test.equal(line2, 3)
      test.equal(col2, 7)
    end)
  end

  for _, change in ipairs({ "addition", "modification" }) do
    test.it("opens a method declaration from a Git " .. change, function(context)
      local caller_path = join_path(context.temp_root, "Caller.kt")
      local declaration_path = join_path(context.temp_root, "MainWindow.kt")
      local baseline = change == "addition" and "" or "  println(\"before\")\n"
      write_file(caller_path, "fun main() {\n" .. baseline .. "}\n")
      write_file(declaration_path, [[object MainWindow {
  fun setVisibleAndLoadInitialSize() {}
}
]])
      git(context.temp_root, "init", "-q")
      git(context.temp_root, "add", ".")
      git(context.temp_root, "-c", "user.name=Anvil Test", "-c", "user.email=anvil@example.test",
        "commit", "-qm", "Add navigation fixture")
      write_file(caller_path, "fun main() {\n  MainWindow.setVisibleAndLoadInitialSize()\n}\n")

      local view = core.open_file(caller_path)
      core.set_active_view(view)
      test.ok(wait_ready(view.buffer))
      test.ok(wait_until(function()
        for _, point in ipairs(view:get_points_of_interest() or {}) do
          if point.kind == "git-change" and point.label == change and point.line == 2 then return true end
        end
      end), "expected the method call to belong to a Git change")
      test.ok(wait_until(function()
        local symbols, _, status = symbol_index.workspace_symbols("setVisibleAndLoadInitialSize")
        return status == "fresh" and symbols and #symbols == 1
      end), "expected the Project index to contain the method declaration")
      view:with_selection_state(function() view.buffer:set_selection(2, 14) end)
      local source_pane = panes.active()
      local alternate = change == "modification"
      test.ok(command.perform(alternate and "core:activate_point_of_interest_alternate"
        or "core:activate_point_of_interest"))
      test.ok(wait_until(function()
        local active = core.active_view
        return active and active.buffer and common.path_equals(active.buffer.abs_filename, declaration_path)
      end), "expected activation to open the method declaration, not the Git preview")
      local buffer = core.active_view.buffer
      test.equal(buffer:get_text(buffer:get_selection(true)), "setVisibleAndLoadInitialSize")
      if alternate then
        test.not_equal(panes.active().group, source_pane.group)
        test.equal(source_pane.current_view, view)
      else
        test.equal(panes.active(), source_pane)
      end
    end)
  end
end)
