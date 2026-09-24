local core = require "core"
local command = require "core.command"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local json = require "core.json"
local markdown = require "core.markdown"
local test = require "core.test"

test.describe("Markdown diagnostic capture", function()
  test.it("saves a private input and edit history for the current Editor", function(context)
    context.active = core.active_view
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("diagnostic.md", nil)
    buffer:insert(1, 1, "- first\n\n# Next\n")
    local view = Editor(buffer)
    context.view = view
    core.active_view = view
    markdown.live_render.refresh_view(view)

    test.ok(command.perform("markdown:toggle_diagnostic_capture"))
    core.on_event("textinput", "x")
    buffer:insert(1, 8, "x")
    test.ok(command.perform("core:newline", view))
    local saved = command.perform("markdown:save_diagnostic_capture")
    test.ok(saved)

    local diagnostic = require "core.markdown.diagnostic_capture"
    local path = test.not_nil(diagnostic.last_saved_path())
    context.path = path
    local file = assert(io.open(path, "rb"))
    local data = assert(json.decode(file:read("*a")))
    file:close()
    test.equal(data.version, 1)
    test.ok(#data.events >= 2)
    local has_input, has_edit, has_command = false, false, false
    for _, event in ipairs(data.events) do
      if event.kind == "input" and event.type == "textinput" and event.text == "x" then
        has_input = event.before and event.before.text:find("- first", 1, true) ~= nil
      elseif event.kind == "edit" and event.after and event.after.text:find("- firstx", 1, true) then
        has_edit = true
      elseif event.kind == "command" and event.name == "core:newline" then
        has_command = true
      end
    end
    test.ok(has_input, "capture must retain the text before input")
    test.ok(has_edit, "capture must retain the Buffer after the edit")
    test.ok(has_command, "capture must retain commands without a fixed key binding")
    test.ok(path:find("markdown%-diagnostics"), "capture belongs outside the source tree")
  end)

  test.it("stops collecting edits when turned off", function(context)
    context.active = core.active_view
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("diagnostic.md", nil)
    local view = Editor(buffer)
    context.view = view
    core.active_view = view
    markdown.live_render.refresh_view(view)

    test.ok(command.perform("markdown:toggle_diagnostic_capture"))
    test.ok(command.perform("markdown:toggle_diagnostic_capture"))
    buffer:insert(1, 1, "private text")
    local diagnostic = require "core.markdown.diagnostic_capture"
    test.equal(diagnostic.is_active(view), false)
    local path, err = diagnostic.save(view)
    test.equal(path, nil)
    test.ok(err:find("not on", 1, true))
  end)

  test.after_each(function(context)
    if context.path then os.remove(context.path) end
    if context.view then
      local diagnostic = package.loaded["core.markdown.diagnostic_capture"]
      if diagnostic then diagnostic.stop(context.view) end
      context.view.discard_buffer_on_close = true
      context.view:on_close()
    end
    core.active_view = context.active
  end)
end)
