local common = require "core.common"
local config = require "core.config"
local core = require "core"
local style = require "core.style"
local test = require "core.test"
local TitleBar = require "core.titlebar"

test.describe("Title Bar", function()
  test.after_each(function(context)
    if context.original_root_project then core.root_project = context.original_root_project end
    if context.original_common_draw_text then common.draw_text = context.original_common_draw_text end
  end)

  test.it("truncates Project title text before native window controls", function(context)
    context.original_root_project = core.root_project
    context.original_common_draw_text = common.draw_text

    local project_title = "prefix-abcdefghijklmnopqrstuvwxyz-SUFFIX"
    core.root_project = function()
      return { path = "C:" .. PATHSEP .. "tmp" .. PATHSEP .. project_title }
    end

    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 420 * SCALE, 32 * SCALE

    local calls = {}
    common.draw_text = function(font, color, text, align, x, y, w, h)
      calls[#calls + 1] = { font = font, text = text, align = align, x = x, y = y, w = w, h = h }
      return x + font:get_width(text), y + font:get_height(), x, y
    end

    titlebar:draw_window_title()

    test.equal(#calls, 1)
    local call = calls[1]
    test.ok(style.font:get_width(project_title) > call.w, "expected test Project title to exceed available width")
    test.ok(style.font:get_width(call.text) <= call.w, call.text)
    test.ok(call.text:find("^prefix%-"), call.text)
    test.ok(call.text:find("…$"), call.text)
    test.ok(not call.text:find("SUFFIX", 1, true), call.text)
  end)

  test.it("allocates independent titlebar tab regions to both panes", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local lx, _, lw = titlebar:get_pane_tabs_rect("left")
    local rx, _, rw = titlebar:get_pane_tabs_rect("right")
    local midpoint = math.floor(titlebar.size.x / 2)

    test.equal(lx + lw, midpoint)
    test.equal(rx, midpoint)
    test.ok(rw > 0)
  end)
end)
