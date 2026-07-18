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
    if context.original_set_window_hit_test then system.set_window_hit_test = context.original_set_window_hit_test end
    if context.original_draw_rect then renderer.draw_rect = context.original_draw_rect end
    if context.original_set_clip_rect then renderer.set_clip_rect = context.original_set_clip_rect end
    if context.original_panes then core.panes = context.original_panes end
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

  test.it("starts Left Pane tabs immediately after the Project title", function(context)
    context.original_root_project = core.root_project
    context.original_common_draw_text = common.draw_text
    core.root_project = function()
      return { path = "C:" .. PATHSEP .. "A" }
    end

    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local title_call
    common.draw_text = function(font, color, text, align, x, y, w, h)
      title_call = { font = font, text = text, x = x }
      return x + font:get_width(text), y + font:get_height(), x, y
    end
    titlebar:draw_window_title()

    local tabs_x = titlebar:get_pane_tabs_rect("left")
    local title_right = title_call.x + title_call.font:get_width(title_call.text)
    test.ok(tabs_x >= title_right, string.format("tabs_x=%g title_right=%g", tabs_x, title_right))
    test.ok(tabs_x - title_right <= style.padding.x + 1,
      string.format("gap=%g padding=%g", tabs_x - title_right, style.padding.x))
  end)

  test.it("allocates independent titlebar tab regions to both panes", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local lx, _, lw = titlebar:get_pane_tabs_rect("left")
    local rx, _, rw = titlebar:get_pane_tabs_rect("right")
    local midpoint = math.floor(titlebar.size.x / 2)

    test.ok(lx + lw <= midpoint)
    test.equal(rx, midpoint)
    test.ok(rw > 0)
  end)

  test.it("reserves a draggable safe zone covering at least 15 percent of app width in each pane", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local minimum_safe_width = math.floor(titlebar.size.x * 0.15)
    local left_safe_x, _, left_safe_width = titlebar:get_pane_safe_rect("left")
    local right_safe_x, _, right_safe_width = titlebar:get_pane_safe_rect("right")
    local left_tabs_x, _, left_tabs_width = titlebar:get_pane_tabs_rect("left")
    local right_tabs_x, _, right_tabs_width = titlebar:get_pane_tabs_rect("right")
    local midpoint = math.floor(titlebar.size.x / 2)

    test.ok(left_safe_width >= minimum_safe_width)
    test.ok(right_safe_width >= minimum_safe_width)
    test.ok(left_tabs_x + left_tabs_width <= left_safe_x)
    test.ok(right_tabs_x + right_tabs_width <= right_safe_x)
    test.equal(left_safe_x + left_safe_width, midpoint)
    test.is_nil(titlebar:get_titlebar_tab_at(left_safe_x + left_safe_width / 2, titlebar.size.y / 2))
    test.is_nil(titlebar:get_titlebar_tab_at(right_safe_x + right_safe_width / 2, titlebar.size.y / 2))
    test.is_nil(titlebar:get_titlebar_scroll_button_at(left_safe_x + left_safe_width / 2, titlebar.size.y / 2))
    test.is_nil(titlebar:get_titlebar_scroll_button_at(right_safe_x + right_safe_width / 2, titlebar.size.y / 2))

    context.original_set_window_hit_test = system.set_window_hit_test
    local hit_test_args
    system.set_window_hit_test = function(...)
      hit_test_args = { ... }
    end
    titlebar:configure_hit_test(true)

    test.not_nil(hit_test_args)
    test.equal(hit_test_args[5], left_tabs_x)
    test.ok(hit_test_args[6] <= left_tabs_width)
    test.equal(hit_test_args[7], right_tabs_x)
    test.ok(hit_test_args[8] <= right_tabs_width)
  end)

  test.it("keeps unused tab capacity available for native window dragging", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local view = {}
    local node = {
      views = { view },
      active_view = view,
      titlebar_tab_offset = 1,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and node or nil
    end

    context.original_set_window_hit_test = system.set_window_hit_test
    local hit_test_args
    system.set_window_hit_test = function(...)
      hit_test_args = { ... }
    end
    titlebar:configure_hit_test(true)

    local tabs_x, _, tabs_capacity = titlebar:get_pane_tabs_rect("left")
    test.equal(hit_test_args[5], tabs_x)
    test.ok(hit_test_args[6] > 0)
    test.ok(hit_test_args[6] < tabs_capacity)
  end)

  test.it("draws clear separators on both sides of every Pane Tab", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local views = { {}, {} }
    local node = {
      views = views,
      active_view = views[1],
      titlebar_tab_offset = 1,
      get_tab_title_font = function() return style.font end,
      draw_tab_title = function() end,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and node or nil
    end

    context.original_draw_rect = renderer.draw_rect
    context.original_set_clip_rect = renderer.set_clip_rect
    local separators = {}
    renderer.draw_rect = function(x, y, w, h, color)
      if color == style.titlebar_tab_separator then
        separators[#separators + 1] = { x = x, y = y, w = w, h = h }
      end
    end
    renderer.set_clip_rect = function() end

    titlebar:draw_titlebar_tabs()

    test.not_nil(style.titlebar_tab_separator)
    test.equal(#separators, #views * 2)
    for _, separator in ipairs(separators) do
      test.equal(separator.w, style.divider_size)
      test.ok(separator.h >= titlebar.size.y - style.divider_size)
    end
  end)

  test.it("fades Right Pane tabs while the Right Pane is hidden", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local view = {}
    local title_color
    local node = {
      views = { view },
      active_view = view,
      titlebar_tab_offset = 1,
      get_tab_title_font = function() return style.font end,
      draw_tab_title = function(_, _, _, _, _, _, _, _, _, color)
        title_color = color
      end,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "right" and node or nil
    end

    context.original_panes = core.panes
    core.panes = {
      is_placeholder = function() return false end,
      focused_pane = function() return "left" end,
      right_visible = function() return false end,
    }
    context.original_draw_rect = renderer.draw_rect
    context.original_set_clip_rect = renderer.set_clip_rect
    renderer.draw_rect = function() end
    renderer.set_clip_rect = function() end

    titlebar:draw_titlebar_tabs()

    test.not_nil(title_color)
    test.equal(title_color[4], 255)
    for channel = 1, 3 do
      local background = style.titlebar[channel]
      local foreground = style.text[channel]
      test.ok(title_color[channel] > math.min(background, foreground))
      test.ok(title_color[channel] < math.max(background, foreground))
    end
  end)
end)
