local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Editor = require "core.editor"
local Project = require "core.project"
local panes = require "core.panes"
local test = require "core.test"
local markdown = require "core.markdown"
local autocomplete = require "plugins.autocomplete"
local style = require "core.style"

local function render_completions(view, width)
  local runs = {}
  local old_text, old_rect, old_clip = renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect
  local old_size, old_stack = system.get_window_size, core.clip_rect_stack
  local clip = { 0, 0, width, 800 }
  core.clip_rect_stack = { clip }
  system.get_window_size = function() return width, 800 end
  renderer.set_clip_rect = function(x, y, w, h) clip = { x, y, w, h } end
  renderer.draw_rect = function(x, y, w, h, color)
    if color == style.background3 or color == style.autocomplete_selection then
      for i = #runs, 1, -1 do
        local run = runs[i]
        if run.x >= x and run.x + run.width <= x + w and run.y >= y and run.y < y + h then
          table.remove(runs, i)
        end
      end
    end
  end
  renderer.draw_text = function(font, text, x, y, color)
    test.is_nil(text:uinvalidoffset(), "completion text contains incomplete UTF-8")
    local visible, prefix = "", ""
    for char in common.utf8_chars(text) do
      local left = x + font:get_width(prefix)
      prefix = prefix .. char
      local right = x + font:get_width(prefix)
      if left >= clip[1] and right <= clip[1] + clip[3]
        and y >= clip[2] and y + font:get_height() <= clip[2] + clip[4]
      then visible = visible .. char end
    end
    runs[#runs + 1] = { text = visible, x = x, y = y, width = font:get_width(text), color = color }
    return x + font:get_width(text)
  end
  local ok, err = pcall(function() autocomplete.draw(view) end)
  renderer.draw_text, renderer.draw_rect, renderer.set_clip_rect = old_text, old_rect, old_clip
  system.get_window_size, core.clip_rect_stack = old_size, old_stack
  if not ok then error(err, 0) end
  return runs
end

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

  test.it("completes a local non-Markdown file and encodes its spaces", function(context)
    write_file(context.root .. PATHSEP .. "Annual Report.csv", "name,value\n")
    core.root_panel:on_text_input("[Report](annual rep")
    test.ok(autocomplete.is_open(), "local file completion did not open")
    test.equal(autocomplete.get_selected_suggestion().text, "Annual Report.csv")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[Report](Annual%20Report.csv)\n")
  end)

  test.it("keeps a Markdown link title when replacing its file target", function(context)
    write_file(context.root .. PATHSEP .. "Annual Report.csv", "name,value\n")
    core.root_panel:on_text_input('[Report](Annual old.csv "Existing title") after')
    local col = #'[Report](Annual' + 1
    context.view:set_selection_state({ selections = { 2, col, 2, col }, last_selection = 1 })
    test.ok(command.perform("markdown:complete_link"))
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], '[Report](Annual%20Report.csv "Existing title") after\n')
  end)

  test.it("continues file completion inside an accepted directory", function(context)
    write_file(context.root .. PATHSEP .. "reports" .. PATHSEP .. "Annual Data.csv", "name,value\n")
    core.root_panel:on_text_input("[Data](rep")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[Data](reports/)\n")
    core.root_panel:on_text_input("annual da")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], "[Data](reports/Annual%20Data.csv)\n")
    local link = require("core.markdown.links").find_links(context.buffer.lines[2], 2)[1]
    test.equal(link.path, "reports/Annual Data.csv")
  end)

  test.it("completes an angle-bracket image target without changing its label or title", function(context)
    write_file(context.root .. PATHSEP .. "Plot Image.png", "image fixture")
    core.root_panel:on_text_input('![Plot](<plot old.png> "Figure (one)") after')
    local col = #'![Plot](<plot' + 1
    context.view:set_selection_state({ selections = { 2, col, 2, col }, last_selection = 1 })
    test.ok(command.perform("markdown:complete_link"))
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[2], '![Plot](<Plot%20Image.png> "Figure (one)") after\n')
  end)

  test.it("keeps a subheading visible when its parent headings do not fit", function(context)
    write_file(context.root .. PATHSEP .. "Guide.md",
      "# " .. string.rep("Long parent heading ", 12) .. "\n## C# LeafTarget\n")
    context.index:rebuild("completion-row-layout")
    core.root_panel:on_text_input("[[Guide#")
    context.view.position.x, context.view.size.x = 0, 500
    local visible = {}
    for _, run in ipairs(render_completions(context.view, 600)) do visible[#visible + 1] = run.text end
    test.contains(table.concat(visible), "C# LeafTarget")
  end)

  test.it("aligns file details to one right edge across completion rows", function(context)
    write_file(context.root .. PATHSEP .. "A.md", "# First\n")
    write_file(context.root .. PATHSEP .. "Bigger Name.md", "# Second\n")
    context.index:rebuild("completion-row-alignment")
    core.root_panel:on_text_input("[[")
    context.view.position.x, context.view.size.x = 0, 500
    local ends = {}
    for _, run in ipairs(render_completions(context.view, 600)) do
      if run.text == "A.md:1" or run.text == "Bigger Name.md:1" then
        ends[run.text] = run.x + run.width
      end
    end
    test.not_nil(ends["A.md:1"])
    test.not_nil(ends["Bigger Name.md:1"])
    test.near(ends["A.md:1"], ends["Bigger Name.md:1"], 0.01)
  end)

  test.it("keeps the matched text highlighted when the subheading itself is too long", function(context)
    local heading = string.rep("Información ", 20) .. "MatchedNeedle" .. string.rep(" salida", 20)
    context.buffer:insert(2, 1, "## " .. heading .. "\n")
    context.view:set_selection_state({ selections = { 3, 1, 3, 1 }, last_selection = 1 })
    test.ok(wait_until(function() return #context.index:note(context.source).headings == 2 end))
    core.root_panel:on_text_input("[[#matchedneedle")
    context.view.position.x, context.view.size.x = 0, 500
    local matched = false
    for _, run in ipairs(render_completions(context.view, 600)) do
      if run.text == "MatchedNeedle" and run.color == style.accent then matched = true end
    end
    test.ok(matched, "the clipped row hid the match or removed its highlight")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(context.buffer.lines[3], "[[#Alta de usuarios#" .. heading .. "]]\n")
  end)

  test.it("renders shared file-type icons from target paths rather than result labels", function(context)
    local file_icons = require "core.file_icons"
    local image = context.root .. PATHSEP .. "Picture.png"
    local note = context.root .. PATHSEP .. "Note.md"
    write_file(image, "image fixture")
    write_file(note, "---\naliases: [Picture.png]\n---\n# Title\n")
    context.index:rebuild("completion-file-icons")
    core.root_panel:on_text_input("[[Picture")
    test.equal(#suggestions(), 2)
    context.view.position.x, context.view.size.x = 0, 500
    local drawn = {}
    for _, run in ipairs(render_completions(context.view, 600)) do drawn[run.text] = true end
    for _, path in ipairs { image, note } do
      local _, glyph = file_icons.get(path)
      test.not_nil(glyph)
      test.ok(drawn[glyph], "the popup did not draw the shared file icon for " .. path)
    end
  end)
end)
