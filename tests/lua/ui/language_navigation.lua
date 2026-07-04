local common = require "core.common"
local core = require "core"
local command = require "core.command"
local EmptyView = require "core.emptyview"
local Project = require "core.project"
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

local function remove_doc(doc)
  local root = core.root_panel.root_node
  for _, view in ipairs(core.get_views_referencing_doc(doc)) do
    local node = root:get_node_for_view(view)
    if node then node:remove_view(root, view) end
  end
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function wait_ready(doc, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_doc(doc)
    if doc.treesitter and doc.treesitter.status == "ready" then return true end
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
    context.original_main_panel_views = nil
    local node = core.root_panel and core.root_panel:get_main_panel()
    if node then
      context.original_main_panel_views = { views = node.views, active_view = node.active_view }
      node.views = {}
      node:add_view(EmptyView())
      core.set_active_view(node.active_view)
    end
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
    if context.temp_root then
      for i = #core.docs, 1, -1 do
        local doc = core.docs[i]
        if doc.abs_filename and common.path_belongs_to(doc.abs_filename, context.temp_root) then
          if doc:is_dirty() then doc:clean() end
          remove_doc(doc)
        end
      end
      if context.original_cwd then pcall(system.chdir, context.original_cwd) end
      symbol_index.reset_for_tests()
      coroutine.yield(0.05)
      if system.get_file_info(context.temp_root) then
        local ok, err = common.rm(context.temp_root, true)
        test.ok(ok, err)
      end
    end
    if context.original_main_panel_views then
      local node = core.root_panel and core.root_panel:get_main_panel()
      if node then
        node.views = context.original_main_panel_views.views
        node.active_view = context.original_main_panel_views.active_view
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
    test.ok(wait_ready(view.doc))
    view.doc:insert(5, 1, "// local edit\n")
    test.ok(view.doc:is_dirty())
    view:with_selection_state(function()
      view.doc:set_selection(4, 5)
    end)

    test.ok(command.perform("language:go-to-declaration", view))
    test.ok(wait_until(function()
      local active = core.active_view
      return active and active.doc and common.path_equals(active.doc.abs_filename, defs_path)
    end))

    local project_file_tabs = 0
    for _, item in ipairs(core.root_panel:get_main_panel().views) do
      if item.doc and item.doc.abs_filename and common.path_belongs_to(item.doc.abs_filename, context.temp_root) then
        project_file_tabs = project_file_tabs + 1
      end
    end
    test.equal(project_file_tabs, 1)
    local doc = core.active_view.doc
    local line1, col1, line2, col2 = doc:get_selection(true)
    test.equal(line1, 3)
    test.equal(col1, 1)
    test.equal(line2, 3)
    test.equal(col2, 7)
  end)
end)
