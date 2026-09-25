local command = require "core.command"
local core = require "core"
local settings = require "plugins.settings"
local style = require "core.style"
local test = require "core.test"

local function primary_path(font)
  local path = font:get_path()
  return type(path) == "table" and path[1] or path
end

test.describe("global font selection", function()
  local saved, previous
  test.before_each(function()
    core.global_prompt_bar:exit(true)
    saved = settings.config.font_categories
    previous = {}
    for _, role in ipairs({"font", "code_font", "terminal_font", "view_text_font",
      "terminal_bold_font", "terminal_italic_font", "terminal_bold_italic_font",
      "markdown_body_font", "prose_strong_font", "prose_emphasis_font",
      "prose_strong_emphasis_font", "prose_heading_font",
      "prose_heading_emphasis_font", "big_font"}) do
      previous[role] = style[role]
    end
  end)
  test.after_each(function()
    core.global_prompt_bar:exit(true)
    for role, font in pairs(previous) do style[role] = font end
    settings.config.font_categories = saved
  end)

  test.it("shows font categories without dimming the editor", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    test.equal(core.active_view, bar)
    local names = {}
    for _, item in ipairs(bar.suggestions) do names[#names + 1] = item.text end
    test.same({"Interface", "Code", "Terminal", "Text", "Markdown Prose", "Headings"}, names)
    test.not_equal(core.root_panel.app_overlay and core.root_panel.app_overlay.owner, bar)
    test.ok(not command.is_valid("editor:select_monospace_font"))
  end)

  test.it("offers the same bundled fonts in every category", function()
    local bar = core.global_prompt_bar
    local names_for_interface
    for _, category in ipairs({"Interface", "Code", "Terminal", "Text", "Markdown Prose", "Headings"}) do
      test.ok(command.perform("editor:select_font"))
      bar:set_text(category)
      bar:submit()
      local names = {}
      for _, item in ipairs(bar.suggestions) do names[#names + 1] = item.text end
      table.sort(names)
      if names_for_interface then
        test.same(names_for_interface, names)
      else
        names_for_interface = names
      end
      bar:exit(false)
    end
  end)

  test.it("can preview a proportional font for code and restore the prior font", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    bar:set_text("Code")
    bar:submit()
    bar:set_text("Crimson Pro")
    bar:update_suggestions()
    test.ok(primary_path(style.code_font):find("CrimsonPro-Regular.ttf", 1, true))
    bar:exit(false)
    test.equal(previous.code_font, style.code_font)
  end)

  test.it("previews a Markdown Prose font and restores it on cancel", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    bar:set_text("Markdown Prose")
    bar:submit()
    test.ok(bar.label:find("Markdown Prose", 1, true) ~= nil)
    test.not_equal(core.root_panel.app_overlay and core.root_panel.app_overlay.owner, bar)
    bar:set_text("Inter")
    bar:update_suggestions()
    test.ok(primary_path(style.markdown_body_font):find("Inter-Regular.ttf", 1, true))
    bar:exit(false)
    test.equal(previous.markdown_body_font, style.markdown_body_font)
    test.equal(previous.view_text_font, style.view_text_font)
    test.equal(saved, settings.config.font_categories)
  end)

  test.it("selects Text without changing Markdown Prose", function()
    local bar = core.global_prompt_bar
    test.ok(command.perform("editor:select_font"))
    bar:set_text("Text")
    bar:submit()
    test.equal("Text Font: ", bar.label)
    bar:set_text("Inter")
    bar:submit()
    test.ok(primary_path(style.view_text_font):find("Inter-Regular.ttf", 1, true))
    test.equal(previous.markdown_body_font, style.markdown_body_font)
    test.equal("inter", settings.config.font_categories.view_text)

    test.ok(command.perform("editor:select_font"))
    bar:set_text("Markdown Prose")
    bar:submit()
    bar:set_text("Fira Sans")
    bar:update_suggestions()
    test.ok(primary_path(style.markdown_body_font):find("FiraSans-Regular.ttf", 1, true))
    test.ok(primary_path(style.view_text_font):find("Inter-Regular.ttf", 1, true))
    bar:exit(false)
  end)

  test.it("restores Text after canceling a font preview", function()
    local bar = core.global_prompt_bar
    test.ok(command.perform("editor:select_font"))
    bar:set_text("Text")
    bar:submit()
    bar:set_text("Inter")
    bar:update_suggestions()
    test.ok(primary_path(style.view_text_font):find("Inter-Regular.ttf", 1, true))
    test.equal(previous.markdown_body_font, style.markdown_body_font)
    bar:exit(false)
    test.equal(previous.view_text_font, style.view_text_font)
    test.equal(saved, settings.config.font_categories)
  end)

  test.it("keeps calibrated prose sizes stable across previews and cancel", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    bar:set_text("Markdown Prose")
    bar:submit()
    bar:set_text("Inter")
    bar:update_suggestions()
    local inter_size = style.markdown_body_font:get_size()
    local strong_ratio = style.prose_strong_font:get_size() / inter_size
    bar:set_text("Crimson Pro")
    bar:update_suggestions()
    local crimson_size = style.markdown_body_font:get_size()
    test.ok(crimson_size > inter_size)
    test.ok(math.abs(style.prose_strong_font:get_size() / crimson_size - strong_ratio) < 0.00001)
    bar:set_text("Inter")
    bar:update_suggestions()
    bar:set_text("Crimson Pro")
    bar:update_suggestions()
    test.equal(crimson_size, style.markdown_body_font:get_size())
    bar:exit(false)

    test.ok(command.perform("editor:select_font"))
    bar:set_text("Markdown Prose")
    bar:submit()
    bar:set_text("Crimson Pro")
    bar:update_suggestions()
    test.equal(crimson_size, style.markdown_body_font:get_size())
    bar:exit(false)
  end)

  test.it("saves a global heading choice that remains after a theme change", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    bar:set_text("Headings")
    bar:submit()
    bar:set_text("Merriweather")
    bar:submit()
    test.equal("merriweather", settings.config.font_categories.headings)
    local fp = assert(io.open(USERDIR .. "/user_settings.lua", "rb"))
    local saved_text = fp:read("*a")
    fp:close()
    test.ok(saved_text:find("merriweather", 1, true) ~= nil)
    test.ok(primary_path(style.prose_heading_font):find("Merriweather", 1, true))
    core.reload_module("colors.light2")
    test.ok(primary_path(style.prose_heading_font):find("Merriweather", 1, true))
    test.ok(primary_path(style.big_font):find("Merriweather", 1, true))
  end)

  test.it("keeps heading role sizes when switching heading families", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    bar:set_text("Headings")
    bar:submit()
    for _, name in ipairs({"Crimson Pro", "Inter", "Cormorant Garamond"}) do
      bar:set_text(name)
      bar:update_suggestions()
      test.equal(previous.prose_heading_font:get_size(), style.prose_heading_font:get_size())
      test.equal(previous.big_font:get_size(), style.big_font:get_size())
    end
    bar:exit(false)
  end)

  test.it("changes terminal font without changing code or interface font", function()
    test.ok(command.perform("editor:select_font"))
    local bar = core.global_prompt_bar
    bar:set_text("Terminal")
    bar:submit()
    bar:set_text("JetBrains Mono")
    bar:submit()
    test.ok(primary_path(style.terminal_font):find("JetBrainsMono-Regular.ttf", 1, true))
    test.equal(previous.code_font, style.code_font)
    test.equal(previous.font, style.font)
  end)
end)
