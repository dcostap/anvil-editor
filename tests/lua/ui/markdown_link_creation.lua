local core = require "core"
local common = require "core.common"
local Editor = require "core.editor"
local Project = require "core.project"
local panes = require "core.panes"
local test = require "core.test"
local markdown = require "core.markdown"
local live = require "core.markdown.live_render"
local links = require "core.markdown.links"

test.describe("Markdown missing link activation", function()
  test.before_each(function(c)
    panes.reset_for_tests()
    c.projects = core.projects
    c.root = USERDIR .. PATHSEP .. "link-create-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(c.root))
    c.source = c.root .. PATHSEP .. "Source.md"
    local file = assert(io.open(c.source, "wb")); file:write("# Source\n"); file:close()
    core.projects = { Project(c.root) }
    c.index = markdown.vault_index.get_index(c.root):rebuild("creation-test")
    c.buffer = core.open_buffer(c.source)
    c.view = panes.place(function() return Editor(c.buffer) end, { placement = "new", focus = true })
    local deadline = system.get_time() + 5
    while not c.index:can_resolve() and system.get_time() < deadline do coroutine.yield(0.01) end
    test.ok(c.index:can_resolve())
    live.refresh_view(c.view)
    c.show, c.open = core.nag_view.show, core.open_file
    core.nag_view.show = function(_, title, text, choices, submit) c.confirm = submit end
    core.open_file = function(path) c.opened = path; return {} end
  end)

  test.after_each(function(c)
    core.nag_view.show, core.open_file = c.show, c.open
    panes.reset_for_tests()
    c.buffer:clean()
    for i = #core.buffers, 1, -1 do
      if core.buffers[i] == c.buffer then table.remove(core.buffers, i) end
    end
    c.buffer:on_close()
    core.projects = c.projects
    common.rm(c.root, true)
  end)

  test.it("creates a missing note and its folders only after confirmation", function(c)
    local link = links.from_target("wiki", "folder/New")
    test.ok(live.open_link(c.view, { link = link }))
    test.ok(c.confirm, "activation should request confirmation")
    local path = common.normalize_path(c.root .. PATHSEP .. "folder" .. PATHSEP .. "New.md")
    test.is_nil(system.get_file_info(path))
    c.confirm({ text = "Cancel" })
    test.is_nil(system.get_file_info(common.dirname(path)))
    c.confirm({ text = "Create Note" })
    test.equal(system.get_file_info(path).type, "file")
    test.equal(c.opened, path)
  end)

  test.it("does not offer to create missing images or attachments", function(c)
    for _, link in ipairs({ links.from_target("image", "image.png"), links.from_target("wiki", "file.pdf") }) do
      test.ok(not live.open_link(c.view, { link = link }))
      test.is_nil(c.confirm)
      test.is_nil(c.opened)
    end
  end)

  test.it("keeps a note that appears while confirmation is open", function(c)
    test.ok(live.open_link(c.view, { link = links.from_target("wiki", "New") }))
    local path = common.normalize_path(c.root .. PATHSEP .. "New.md")
    local file = assert(io.open(path, "wb")); file:write("Keep this note\n"); file:close()
    c.confirm({ text = "Create Note" })
    file = assert(io.open(path, "rb"))
    test.equal(file:read("*a"), "Keep this note\n")
    file:close()
    test.equal(c.opened, path)
  end)

  test.it("opens the existing note without creating a missing heading", function(c)
    test.ok(live.open_link(c.view, { link = links.from_target("wiki", "Source#Missing") }))
    test.is_nil(c.confirm)
    test.equal(c.opened, common.normalize_path(c.source))
    local file = assert(io.open(c.source, "rb"))
    test.equal(file:read("*a"), "# Source\n")
    file:close()
  end)

  test.it("does not create notes outside the Project", function(c)
    test.ok(not live.open_link(c.view, { link = links.from_target("wiki", "../../Outside") }))
    test.is_nil(c.confirm)
    test.is_nil(c.opened)
  end)
end)
