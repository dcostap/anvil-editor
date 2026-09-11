local test = require "core.test"
local core = require "core"
local style = require "core.style"
local fuzzy = require "plugins.fuzzy_searcher"

test.describe("Picker status text", function()
  local draw_text
  test.before_each(function() draw_text = renderer.draw_text end)
  test.after_each(function()
    renderer.draw_text = draw_text
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
  end)

  for _, status in ipairs {
    "0 files + 0 folders indexed — C:/Projects/世界/long/project/path",
    "Indexing files… 100 available — C:/Projects/long/project/path",
  } do
    test.it("fits long status text within its width: " .. status, function()
      local picker = fuzzy.open_static_results("Results", {})
      picker.status = status
      local font = style.code_font
      local width = font:get_width("0 files + 0 folders indexed")
      local drawn = {}
      renderer.draw_text = function(f, text, x)
        test.ok(x + f:get_width(text) <= width, "status text exceeds its available width")
        drawn[#drawn + 1] = text
        return x + f:get_width(text)
      end
      picker:draw_status(font, 0, 0, width)
      test.ok(table.concat(drawn):match("%.%.%.$"), "truncated status needs an ellipsis")
      test.equal(picker.status, status)
    end)
  end
end)
