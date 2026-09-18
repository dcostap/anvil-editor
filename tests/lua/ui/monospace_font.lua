local command = require "core.command"
local core = require "core"
local settings = require "plugins.settings"
local style = require "core.style"
local test = require "core.test"

local function primary_path(font)
  local paths = renderer.font.get_path(font)
  return type(paths) == "table" and paths[1] or paths
end

test.describe("Monospace font selection", function()
  local previous_id
  local previous_saved_id

  test.before_each(function()
    previous_id = core.get_monospace_font_id()
    previous_saved_id = settings.config.monospace_font
    if core.global_prompt_bar then core.global_prompt_bar:exit(true) end
  end)

  test.after_each(function()
    if core.global_prompt_bar then core.global_prompt_bar:exit(true) end
    if previous_id then core.set_monospace_font(previous_id) end
    settings.config.monospace_font = previous_saved_id
  end)

  test.it("opens the bundled font picker in the Global Prompt Bar", function()
    test.ok(command.perform("editor:select_monospace_font"))
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(#core.global_prompt_bar.suggestions, 2)
  end)

  test.it("previews a highlighted font and restores it on cancel", function()
    test.ok(command.perform("editor:select_monospace_font"))
    core.global_prompt_bar:move_suggestion_idx(1)

    test.equal(core.get_monospace_font_id(), "jetbrains_mono")
    test.ok(primary_path(style.font):find("JetBrainsMono-Regular.ttf", 1, true))

    core.global_prompt_bar:exit(false)
    test.equal(core.get_monospace_font_id(), previous_id)
  end)

  test.it("applies the selected font to UI, code, and terminal roles", function()
    test.ok(command.perform("editor:select_monospace_font"))
    core.global_prompt_bar:set_text("JetBrains Mono")
    core.global_prompt_bar:submit()

    test.equal(core.get_monospace_font_id(), "jetbrains_mono")
    test.ok(primary_path(style.font):find("JetBrainsMono-Regular.ttf", 1, true))
    test.ok(primary_path(style.code_font):find("JetBrainsMono-Regular.ttf", 1, true))
    test.ok(primary_path(style.terminal_font):find("JetBrainsMono-Regular.ttf", 1, true))
    test.equal(settings.config.monospace_font, "jetbrains_mono")
  end)
end)
