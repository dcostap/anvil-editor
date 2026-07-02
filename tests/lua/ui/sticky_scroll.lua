local test = require "core.test"
local sticky_scroll = require "plugins.sticky_scroll"

test.describe("sticky scroll", function()
  test.it("uses cleaned UTF-8 text when measuring indentation in binary-marked documents", function()
    local invalid_surrogate = "\237\160\128"
    local line = "  " .. invalid_surrogate .. "heading\n"
    local clean_line = line:uclean("\26", true)
    local doc = {
      binary = true,
      lines = { line },
      clean_lines = { clean_line },
      get_utf8_line = function(self, idx)
        if self.binary and self.clean_lines[idx] then return self.clean_lines[idx] end
        return self.lines[idx]
      end,
    }

    test.ok(sticky_scroll.get_level_from_indent(doc, 1) >= 0)
  end)
end)
