local core = require "core"
local style = require "core.style"
local test = require "core.test"
local command = require "core.command"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

test.describe("Fuzzy Searcher Search Modifier Indicator", function()
  test.after_each(function()
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
  end)

  test.it("shows active Search Modifiers at the right of the query field", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.include_ignored = true
    picker:update()

    test.equal(picker:search_modifier_text(), "Ignored files included")
    test.equal(picker.input:get_trailing_text(), "Ignored files included")

    local x, _, width = picker.input:get_trailing_text_bounds()
    test.ok(x, "expected an inline Search Modifier Indicator")
    local expected_x = picker.input.position.x + picker.input.size.x
      - style.padding.x / 2 - picker.input:get_font():get_width("Ignored files included")
    test.equal(x, expected_x)
    test.equal(x + width, picker.input.position.x + picker.input.size.x - style.padding.x / 2)
    test.ok(picker.input.textview.size.x < picker.input.size.x)
  end)

  test.it("combines future active Search Modifiers in one indicator", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.active_search_modifiers = function()
      return { "Ignored files included", "Another modifier" }
    end

    test.equal(
      picker:search_modifier_text(),
      "Ignored files included  ·  Another modifier"
    )
  end)

  test.it("keeps Case Sensitive and Include Ignored Files independent", function()
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(command.perform("fuzzy:toggle_ignored_files"))
    test.ok(command.perform("fuzzy:toggle_case_sensitive"))
    test.equal(picker:search_modifier_text(),
      "Ignored files included  ·  Case Sensitive")

    picker.input:set_text("$Widget")
    test.equal(picker:search_modifier_text(), "Case Sensitive")
    test.not_ok(command.is_valid("fuzzy:toggle_ignored_files"))
    test.ok(command.perform("fuzzy:toggle_case_sensitive"))
    test.equal(picker:search_modifier_text(), "")
    test.equal(picker.include_ignored, true)
  end)
end)
