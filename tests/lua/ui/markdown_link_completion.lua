local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Editor = require "core.editor"
local Project = require "core.project"
local panes = require "core.panes"
local test = require "core.test"
local markdown = require "core.markdown"
local autocomplete = require "plugins.autocomplete"

local function write_file(path, text)
  local dir = common.dirname(path)
  if not system.get_file_info(dir) then test.ok(common.mkdirp(dir)) end
  local file = test.not_nil(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_until(predicate)
  local deadline = system.get_time() + 5
  repeat
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return predicate()
end

local function suggestions()
  local items = {}
  local first = autocomplete.get_selected_suggestion()
  if not first then return items end
  repeat
    items[#items + 1] = autocomplete.get_selected_suggestion()
    test.ok(command.perform("autocomplete:next"))
  until autocomplete.get_selected_suggestion() == first
  return items
end

test.describe("Markdown link completion", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.projects = core.projects
    context.root = USERDIR .. PATHSEP .. "link-completion-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    context.source = context.root .. PATHSEP .. "Source.md"
    write_file(context.source, "# Alta de usuarios\n\n")
    core.projects = { Project(context.root) }
    context.index = markdown.vault_index.get_index(context.root):rebuild("completion-test")
    context.buffer = core.open_buffer(context.source)
    context.view = panes.place(function() return Editor(context.buffer) end, {
      placement = "new", focus = true,
    })
    context.view:set_selection_state({ selections = { 2, 1, 2, 1 }, last_selection = 1 })
    test.ok(wait_until(function()
      local entry = context.index:note(context.source)
      return context.index:can_resolve() and entry and #entry.headings == 1
    end), "the source note did not become ready")
  end)

  test.after_each(function(context)
    autocomplete.close()
    autocomplete.map["test-link-unrelated-symbols"] = nil
    panes.reset_for_tests()
    if context.buffer then
      context.buffer:clean()
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == context.buffer then table.remove(core.buffers, i) end
      end
      context.buffer:on_close()
    end
    core.projects = context.projects
    if context.root then common.rm(context.root, true) end
  end)

  test.it("offers only link targets and closes the accepted heading link", function(context)
    autocomplete.add({
      name = "test-link-unrelated-symbols", files = ".*",
      items = { Altabogus = "symbol" },
    })
    core.root_panel:on_text_input("[[#Alta")
    local labels = {}
    for _, item in ipairs(suggestions()) do labels[#labels + 1] = item.text end
    test.same(labels, { "Alta de usuarios" })
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(context.buffer.lines), "# Alta de usuarios\n[[#Alta de usuarios]]\n")
  end)

  test.it("fuzzy matches a heading without requiring its spaces", function(context)
    core.root_panel:on_text_input("[[#altade")
    test.ok(autocomplete.is_open(), "the fuzzy heading query had no suggestions")
    test.equal(autocomplete.get_selected_suggestion().text, "Alta de usuarios")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(context.buffer.lines), "# Alta de usuarios\n[[#Alta de usuarios]]\n")
  end)

  test.it("completes a heading from a named note", function(context)
    local path = context.root .. PATHSEP .. "Project Notes.md"
    write_file(path, "# Setup details\n")
    context.index:update_path(path)
    core.root_panel:on_text_input("[[Project Notes#setup de")
    local items = suggestions()
    test.equal(#items, 1)
    test.equal(items[1].text, "Setup details")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[Project Notes#Setup details]]\n")
  end)

  test.it("replaces the whole target while keeping its alias and following text", function(context)
    core.root_panel:on_text_input("[[#Alta old target|My label]] after")
    context.view:set_selection_state({ selections = { 2, 8, 2, 8 }, last_selection = 1 })
    test.ok(command.perform("markdown:complete_link"))
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[#Alta de usuarios|My label]] after\n")
    test.ok(command.perform("core:undo"))
    test.equal(context.buffer.lines[2], "[[#Alta old target|My label]] after\n")
  end)

  test.it("keeps all query words when a note name contains spaces", function(context)
    local first = context.root .. PATHSEP .. "Alpha Plan.md"
    local second = context.root .. PATHSEP .. "Beta Plan.md"
    write_file(first, "# First\n")
    write_file(second, "# Second\n")
    context.index:rebuild("completion-spaces")
    core.root_panel:on_text_input("[[Plan")
    core.root_panel:on_text_input(" ")
    core.root_panel:update()
    test.ok(autocomplete.is_open(), "a space closed link completion")
    core.root_panel:on_text_input("Alpha")
    local items = suggestions()
    test.equal(#items, 1)
    test.equal(items[1].text, "Alpha Plan")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[Alpha Plan]]\n")
  end)

  test.it("shows each heading's file and accepts the chosen destination", function(context)
    write_file(context.root .. PATHSEP .. "a" .. PATHSEP .. "Guide.md", "# Setup details\n")
    write_file(context.root .. PATHSEP .. "b" .. PATHSEP .. "Guide.md", "# Setup details\n")
    context.index:rebuild("completion-details")
    core.root_panel:on_text_input("[[##setupde")
    local items = suggestions()
    test.equal(#items, 2)
    test.equal(items[1].text, "Setup details")
    test.equal(items[2].text, "Setup details")
    test.contains(items[1].info, "a/Guide.md")
    test.contains(items[2].info, "b/Guide.md")
    test.ok(command.perform("autocomplete:next"))
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[b/Guide#Setup details]]\n")
  end)

  test.it("closes an attachment link whose file name contains spaces", function(context)
    local path = context.root .. PATHSEP .. "Annual Report.pdf"
    write_file(path, "%PDF-fixture")
    context.index:update_path(path)
    core.root_panel:on_text_input("[[annual rep")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[Annual Report.pdf]]\n")
  end)

  test.it("completes a note alias", function(context)
    local path = context.root .. PATHSEP .. "Note.md"
    write_file(path, "---\naliases: [Other Name]\n---\n# Title\n")
    context.index:update_path(path)
    core.root_panel:on_text_input("[[othername")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[Note|Other Name]]\n")
  end)

  test.it("completes a block within a named note", function(context)
    local path = context.root .. PATHSEP .. "Project Notes.md"
    write_file(path, "# Setup details\n\ntext ^setup-block\n")
    context.index:update_path(path)
    core.root_panel:on_text_input("[[Project Notes#^setup")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[Project Notes#^setup-block]]\n")
  end)

  test.it("completes a block in the current note", function(context)
    context.buffer:insert(2, 1, "text ^local-block\n")
    context.view:set_selection_state({ selections = { 3, 1, 3, 1 }, last_selection = 1 })
    test.ok(wait_until(function()
      return #context.index:note(context.source).blocks == 1
    end), "the current block was not indexed")
    core.root_panel:on_text_input("[[^local")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[3], "[[^local-block]]\n")
  end)

  test.it("completes a block across notes", function(context)
    local path = context.root .. PATHSEP .. "Note.md"
    write_file(path, "text ^global-block\n")
    context.index:update_path(path)
    core.root_panel:on_text_input("[[^^global")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[Note#^global-block]]\n")
  end)

  test.it("does not replace missing link results with ordinary symbols", function(context)
    autocomplete.add({
      name = "test-link-unrelated-symbols", files = ".*",
      items = { Altabogus = "symbol" },
    })
    core.root_panel:on_text_input("[[#Altabogus")
    test.not_ok(autocomplete.is_open())
    test.not_ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[[#Altabogus\n")
  end)
end)
