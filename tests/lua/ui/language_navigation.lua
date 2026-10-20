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
local fuzzy_searcher = require "plugins.fuzzy_searcher"

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
    fuzzy_searcher._test.clear_prompt_history()
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
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
      test.ok(test.remove_tree(context.temp_root))
    end
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    symbol_index.reset_for_tests()
  end)

  for _, change in ipairs({ "addition", "modification" }) do
    test.it("searches for a method declaration from a Git " .. change, function(context)
      local caller_path = join_path(context.temp_root, "Caller.kt")
      local baseline = change == "addition" and "" or "  println(\"before\")\n"
      write_file(caller_path, "fun main() {\n" .. baseline .. "}\n")
      write_file(join_path(context.temp_root, "MainWindow.kt"), [[object MainWindow {
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
          if point.kind == "file-change" and point.label == change and point.line == 2 then return true end
        end
      end), "expected the method call to belong to a file change")
      view:with_selection_state(function() view.buffer:set_selection(2, 14) end)
      local alternate = change == "modification"
      test.ok(command.perform(alternate and "core:activate_point_of_interest_alternate"
        or "core:activate_point_of_interest"))
      -- A symbol inside a Git change opens its Project Symbol Search, not the Git preview.
      local picker = test.not_nil(core.fuzzy_searcher_active_view,
        "expected activation to search for the method declaration")
      test.equal(picker.input:get_text(), "$setVisibleAndLoadInitialSize")
      test.equal(picker.source_view, view)
    end)
  end
end)
