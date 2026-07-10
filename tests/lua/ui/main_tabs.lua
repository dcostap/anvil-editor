local core = require "core"
local command = require "core.command"
local test = require "core.test"
local DocView = require "core.docview"
local EmptyView = require "core.emptyview"
local sidepanel = require "core.sidepanel"
local file_context = require "core.file_context"

local function write_file(path, text)
  local abs = core.root_project():absolute_path(path)
  local fp = assert(io.open(abs, "wb"))
  fp:write(text or "")
  fp:close()
end

local function track(context, key, value)
  context[key] = context[key] or {}
  table.insert(context[key], value)
  return value
end

local function cleanup(context)
  local node = core.root_panel and core.root_panel:get_main_panel()
  if node then
    node.views = {}
    node:add_view(EmptyView())
  end
  sidepanel.hide(false)
  if sidepanel.file_view then sidepanel.remove_view(sidepanel.file_view, false) end
  if context.docs then
    for _, doc in ipairs(context.docs) do
      for i = #core.docs, 1, -1 do
        if core.docs[i] == doc then table.remove(core.docs, i) end
      end
    end
  end
end

test.describe("Main Tabs", function()
  test.before_each(function(context)
    cleanup(context)
  end)

  test.after_each(function(context)
    cleanup(context)
  end)

  test.it("opening ordinary files reuses the singleton Main Editor tab", function(context)
    write_file("a.txt", "a\n")
    write_file("b.txt", "b\n")
    local doc_a = track(context, "docs", core.open_doc("a.txt"))
    local view_a = core.root_panel:open_doc(doc_a)
    test.ok(view_a.__main_tabs_singleton_editor)
    test.equal(#core.root_panel:get_main_panel().views, 1)

    local doc_b = track(context, "docs", core.open_doc("b.txt"))
    local view_b = core.root_panel:open_doc(doc_b)
    test.ok(view_b.__main_tabs_singleton_editor)
    test.ok(view_b ~= view_a)
    test.equal(view_b.doc, doc_b)
    test.equal(#core.root_panel:get_main_panel().views, 1)
  end)

  test.it("releases owned features when replacing the singleton Main Editor", function(context)
    write_file("owned-a.txt", "a\n")
    write_file("owned-b.txt", "b\n")
    local doc_a = track(context, "docs", core.open_doc("owned-a.txt"))
    local view_a = core.root_panel:open_doc(doc_a)
    local released = false
    view_a:add_owned_feature("test", {
      on_release = function() released = true end,
    })

    local doc_b = track(context, "docs", core.open_doc("owned-b.txt"))
    core.root_panel:open_doc(doc_b)
    test.equal(released, true)
    test.equal(view_a:remove_owned_feature("test"), false)
  end)

  test.it("dirty file-backed Main Editor documents are promoted before replacement", function(context)
    write_file("dirty-a.txt", "a\n")
    write_file("dirty-b.txt", "b\n")
    local doc_a = track(context, "docs", core.open_doc("dirty-a.txt"))
    local view_a = core.root_panel:open_doc(doc_a)
    doc_a:insert(1, 1, "dirty")
    test.ok(doc_a:is_dirty())

    local doc_b = track(context, "docs", core.open_doc("dirty-b.txt"))
    local view_b = core.root_panel:open_doc(doc_b)
    local node = core.root_panel:get_main_panel()
    test.equal(#node.views, 2)
    test.ok(not view_a.__main_tabs_singleton_editor)
    test.ok(view_b.__main_tabs_singleton_editor)
    test.equal(node.active_view, view_b)
  end)

  test.it("untitled documents open as independent Main Tabs", function(context)
    local doc_a = track(context, "docs", core.open_doc())
    local doc_b = track(context, "docs", core.open_doc())
    local view_a = core.root_panel:open_doc(doc_a)
    local view_b = core.root_panel:open_doc(doc_b)
    local node = core.root_panel:get_main_panel()
    test.equal(#node.views, 2)
    test.ok(view_a ~= view_b)
    test.ok(not view_a.__main_tabs_singleton_editor)
    test.ok(not view_b.__main_tabs_singleton_editor)
  end)

  test.it("adopts a restored file-backed Editor as the singleton Main Editor", function(context)
    write_file("restore-a.txt", "a\n")
    write_file("restore-b.txt", "b\n")
    local restored_doc = track(context, "docs", core.open_doc("restore-a.txt"))
    local restored_view = track(context, "views", file_context.mark_editor_view(DocView(restored_doc)))
    local node = core.root_panel:get_main_panel()
    node.views = { restored_view }
    node.active_view = restored_view

    local next_doc = track(context, "docs", core.open_doc("restore-b.txt"))
    local next_view = core.root_panel:open_doc(next_doc)
    test.ok(restored_view.__main_tabs_singleton_editor == nil or restored_view.doc == restored_doc)
    test.ok(next_view.__main_tabs_singleton_editor)
    test.equal(#node.views, 1)
    test.equal(node.active_view.doc, next_doc)
  end)

  test.it("closing the singleton Main Editor returns it to a blank slate", function(context)
    write_file("close-me.txt", "close\n")
    local doc = track(context, "docs", core.open_doc("close-me.txt"))
    local view = core.root_panel:open_doc(doc)
    local node = core.root_panel:get_main_panel()
    node:close_view(core.root_panel.root_node, view)
    test.equal(#node.views, 1)
    test.ok(node.active_view.__main_tabs_blank_editor)
    test.ok(node.active_view:is(EmptyView))
  end)

  test.it("Ctrl+Tab cycles Main Tabs even when the Side Panel has focus", function(context)
    local doc_a = track(context, "docs", core.open_doc())
    local doc_b = track(context, "docs", core.open_doc())
    local view_a = core.root_panel:open_doc(doc_a)
    local view_b = core.root_panel:open_doc(doc_b)
    local side_doc = track(context, "docs", core.open_doc())
    sidepanel.open_doc_in_side(side_doc, { focus = true })
    test.ok(sidepanel.is_side_view(core.active_view))

    command.perform("root:switch-to-next-tab")
    test.equal(core.root_panel:get_main_panel().active_view, view_a)
    command.perform("root:switch-to-next-tab")
    test.equal(core.root_panel:get_main_panel().active_view, view_b)
  end)
end)
