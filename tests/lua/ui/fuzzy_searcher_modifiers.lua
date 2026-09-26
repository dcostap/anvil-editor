local core = require "core"
local test = require "core.test"
local command = require "core.command"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

test.describe("Fuzzy Searcher Search Modifier Indicator", function()
  local draw_text
  test.before_each(function() draw_text = renderer.draw_text end)
  test.after_each(function()
    renderer.draw_text = draw_text
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
  end)

  test.it("shows active Search Modifiers after the status below the query field", function()
    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.include_ignored = true
    picker:update()

    test.equal(picker:search_modifier_text(), "Ignored files included")
    test.equal(picker.input:get_trailing_text(), "")
    test.equal(picker.input.textview.size.x, picker.input.size.x)

    picker.status = "5 matches"
    local drawn = {}
    renderer.draw_text = function(font, text, x, y, color)
      drawn[#drawn + 1] = { text = text, x = x, y = y, color = color }
      return x + font:get_width(text)
    end
    picker:draw_status(picker.input:get_font(), 0, 0, 800)
    test.equal(drawn[1].text, "5 matches")
    test.equal(drawn[2].text, "Ignored files included")
    test.ok(drawn[2].x > drawn[1].x)
    test.equal(drawn[2].y, drawn[1].y)
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
