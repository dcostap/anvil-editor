local Buffer = require "core.buffer"
local common = require "core.common"
local core = require "core"
local Editor = require "core.editor"
local test = require "core.test"

require "plugins.autosave_fast"

local function read_file(path)
  local fp = assert(io.open(path, "rb"))
  local text = fp:read("*a")
  fp:close()
  return text
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
end

test.describe("Autosave Pane close", function()
  test.before_each(function(context)
    context.path = system.absolute_path(USERDIR .. PATHSEP
      .. "autosave-pane-close-" .. system.get_process_id() .. ".txt")
    context.prompt_enter = core.global_prompt_bar.enter
    context.nag_show = core.nag_view.show
    pcall(os.remove, context.path)
    write_file(context.path, "original\n")
  end)

  test.after_each(function(context)
    core.global_prompt_bar.enter = context.prompt_enter
    core.nag_view.show = context.nag_show
    if context.view then context.view:on_close() end
    if context.buffer and core.buffer_registry then
      core.buffer_registry:remove(context.buffer, true)
    elseif context.buffer then
      context.buffer:on_close()
    end
    pcall(os.remove, context.path)
  end)

  test.it("saves a dirty named Buffer before Pane close approval", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "changed ")
    test.ok(buffer:is_dirty())

    local prompted = false
    core.global_prompt_bar.enter = function() prompted = true end
    local approved = false
    view:can_close(function() approved = true end)

    test.ok(approved, "expected close approval after autosave")
    test.not_ok(prompted, "did not expect the unsaved-changes prompt")
    test.not_ok(buffer:is_dirty(), "expected autosave to clean the Buffer")
    test.equal(read_file(context.path), "changed original\n")
  end)

  test.it("keeps close pending when autosave detects a disk conflict", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")
    write_file(context.path, "external replacement\n")

    local prompt_title
    core.nag_view.show = function(_, title) prompt_title = title end
    local unsaved_prompt = false
    core.global_prompt_bar.enter = function() unsaved_prompt = true end
    local approved = false
    view:can_close(function() approved = true end)

    test.not_ok(approved)
    test.not_ok(unsaved_prompt, "expected the conflict prompt to own close resolution")
    test.equal(prompt_title, "File Changed on Disk")
    test.equal(read_file(context.path), "external replacement\n")
  end)
end)
