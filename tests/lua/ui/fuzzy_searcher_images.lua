local core = require "core"
local panes = require "core.panes"
local ImageView = require "core.imageview"
local View = require "core.view"
local config = require "core.config"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function little_endian(value, bytes)
  local encoded = {}
  for _ = 1, bytes do
    encoded[#encoded + 1] = string.char(value % 256)
    value = math.floor(value / 256)
  end
  return table.concat(encoded)
end

local function write_blue_bmp(path, width, height)
  local row_size = math.ceil(width * 3 / 4) * 4
  local image_size = row_size * height
  local header = "BM" .. little_endian(54 + image_size, 4)
    .. little_endian(0, 4) .. little_endian(54, 4)
    .. little_endian(40, 4) .. little_endian(width, 4)
    .. little_endian(height, 4) .. little_endian(1, 2)
    .. little_endian(24, 2) .. little_endian(0, 4)
    .. little_endian(image_size, 4) .. little_endian(0, 16)
  local row = string.rep(string.char(255, 0, 0), width)
    .. string.rep("\0", row_size - width * 3)
  local file = assert(io.open(path, "wb"))
  file:write(header, string.rep(row, height))
  file:close()
end

test.describe("Fuzzy Searcher images", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.path = USERDIR .. PATHSEP .. "fuzzy-image-test.bmp"
    write_blue_bmp(context.path, 1, 1)
    context.source = View()
    context.transitions = config.transitions
    context.pane = panes.create { factory = function() return context.source end }
  end)

  test.after_each(function(context)
    config.transitions = context.transitions
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
      if split then
        test.equal(context.pane.current_view, context.source)
        test.equal(core.fuzzy_searcher_active_view, picker)
      else
        test.equal(context.pane.current_view, view)
        test.equal(core.active_view, view)
      end
    end)
  end

  test.it("fits a tall image inside the Passive File Preview", function(context)
    write_blue_bmp(context.path, 100, 2000)
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:layout()
    picker.results = { { kind = "file", file = context.path, text = context.path } }
    picker.selected = 1

    local preview = test.not_nil(picker:update_preview_view())

    test.ok(preview.width <= preview.size.x, "expected the image width to fit")
    test.ok(preview.height <= preview.size.y, "expected the image height to fit")
  end)

  test.it("zooms and pans the image preview without changing the result or input focus", function(context)
    write_blue_bmp(context.path, 1200, 2000)
    config.transitions = false
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:layout()
    picker.results = { { kind = "file", file = context.path, text = context.path } }
    picker.selected = 1
    local preview = test.not_nil(picker:update_preview_view())
    local width = preview.width
    local focus = core.active_view
    local x, y = preview.position.x + preview.size.x / 2, preview.position.y + preview.size.y / 2
    picker:on_mouse_moved(x, y, 0, 0)
    picker:on_mouse_wheel(3, 0)
    test.ok(preview.width > width)
    local _, before = preview:get_image_rect()
    picker:on_mouse_pressed("left", x, y, 1)
    picker:on_mouse_moved(x, y + 10, 0, 10)
    picker:on_mouse_released("left", x, y + 10)
    local _, after = preview:get_image_rect()
    test.ok(after > before, "expected direct image panning")
    test.equal(picker.selected, 1)
    test.equal(core.active_view, focus)
  end)

  test.it("stops image preview panning when the pointer leaves the window", function(context)
    write_blue_bmp(context.path, 1200, 2000)
    config.transitions = false
    fuzzy_searcher.open("")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:layout()
    picker.results = { { kind = "file", file = context.path, text = context.path } }
    picker.selected = 1
    local preview = test.not_nil(picker:update_preview_view())
    local x, y = preview.position.x + preview.size.x / 2, preview.position.y + preview.size.y / 2
    picker:on_mouse_moved(x, y, 0, 0)
    picker:on_mouse_wheel(3, 0)
    picker:on_mouse_pressed("left", x, y, 1)
    picker:on_mouse_left()
    local _, before = preview:get_image_rect()
    picker:on_mouse_moved(x, y + 10, 0, 10)
    local _, after = preview:get_image_rect()
    test.equal(after, before)
  end)
end)
