local core = require "core"
local panes = require "core.panes"
local ImageView = require "core.imageview"
local View = require "core.view"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

test.describe("Fuzzy Searcher images", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.path = USERDIR .. PATHSEP .. "fuzzy-image-test.bmp"
    -- A complete one-pixel, 24-bit BMP with a padded blue pixel row.
    local hex = "424d3a000000000000003600000028000000010000000100000001001800"
      .. "000000000400000000000000000000000000000000000000ff000000"
    local file = assert(io.open(context.path, "wb"))
    file:write((hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)))
    file:close()
    context.source = View()
    context.pane = panes.create { factory = function() return context.source end }
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.reset_for_tests()
    os.remove(context.path)
  end)

  for _, split in ipairs({ false, true }) do
    test.it("opens an image in " .. (split and "a split Pane" or "the source Pane"), function(context)
      fuzzy_searcher.open("")
      local picker = test.not_nil(core.fuzzy_searcher_active_view)
      local view = picker:open_file_result({
        kind = "path", file = context.path, abs_path = context.path,
      }, split)
      test.ok(view and view:extends(ImageView), "expected an Image View, not an Editor")
      test.not_nil(view.image)
      test.equal(core.active_view, view)
      if split then
        test.equal(context.pane.current_view, context.source)
      else
        test.equal(context.pane.current_view, view)
      end
    end)
  end
end)
