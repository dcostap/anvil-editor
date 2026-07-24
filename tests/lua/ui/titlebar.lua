local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Node = require "core.node"
local style = require "core.style"
local test = require "core.test"
local TitleBar = require "core.titlebar"

test.describe("Title Bar", function()
  test.after_each(function(context)
    if context.original_root_project then core.root_project = context.original_root_project end
    if context.original_common_draw_text then common.draw_text = context.original_common_draw_text end
    if context.original_set_window_hit_test then system.set_window_hit_test = context.original_set_window_hit_test end
    if context.original_draw_rect then renderer.draw_rect = context.original_draw_rect end
    if context.original_draw_rounded_rect then renderer.draw_rounded_rect = context.original_draw_rounded_rect end
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

  test.it("keeps Left and Right Pane tab regions separated by one safe zone", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local left_node = { views = { {} }, titlebar_tab_offset = 1 }
    local right_node = { views = { {} }, titlebar_tab_offset = 1 }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and left_node or right_node
    end

    local lx, _, lw = titlebar:get_pane_tabs_rect("left")
    local rx, _, rw = titlebar:get_pane_tabs_rect("right")
    local safe_x, _, safe_width = titlebar:get_titlebar_safe_rect()

    test.ok(lw > 0)
    test.ok(rw > 0)
    test.ok(lx + lw <= safe_x)
    test.ok(safe_x + safe_width <= rx)
  end)

  test.it("allocates Title Bar width from each pane's tab demand", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1800 * SCALE, 32 * SCALE

    local left_node = { views = { {} }, titlebar_tab_offset = 1 }
    local right_node = { views = { {}, {}, {}, {}, {} }, titlebar_tab_offset = 1 }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and left_node or right_node
    end

    local _, _, left_width = titlebar:get_pane_tabs_rect("left")
    local _, _, right_width = titlebar:get_pane_tabs_rect("right")
    test.ok(right_width > left_width)
    test.ok(math.abs(left_width - right_width / #right_node.views) < 0.001,
      "equally sized labels should have equal per-tab widths")
  end)

  test.it("anchors Right Pane tabs beside the window controls and adds tabs leftward", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local controls_x
    for _, x in titlebar:each_control_item() do
      controls_x = x
      break
    end

    local first, second = {}, {}
    local node = {
      views = { first },
      active_view = first,
      titlebar_tab_offset = 1,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "right" and node or nil
    end

    local first_x, _, first_width = titlebar:get_titlebar_tab_rect("right", node, node.views, 1)
    test.equal(first_x + first_width, controls_x)

    node.views = { first, second }
    first_x, _, first_width = titlebar:get_titlebar_tab_rect("right", node, node.views, 1)
    local second_x, _, second_width = titlebar:get_titlebar_tab_rect("right", node, node.views, 2)
    test.equal(first_x + first_width, controls_x)
    test.equal(second_x + second_width, first_x)

    local pane, _, hit_first = titlebar:get_titlebar_tab_at(first_x + first_width / 2, titlebar.size.y / 2)
    local _, _, hit_second = titlebar:get_titlebar_tab_at(second_x + second_width / 2, titlebar.size.y / 2)
    test.equal(pane, "right")
    test.equal(hit_first, first)
    test.equal(hit_second, second)
  end)

  test.it("sizes each Pane Tab from its own label", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1800 * SCALE, 32 * SCALE

    local short = { get_name = function() return "a.lua" end }
    local long = { get_name = function() return "a-significantly-longer-document-name.lua" end }
    local node = Node()
    node.views = { short, long }
    node.active_view = short
    node.titlebar_tab_offset = 1
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and node or nil
    end

    local _, _, short_width = titlebar:get_titlebar_tab_rect("left", node, node.views, 1)
    local _, _, long_width = titlebar:get_titlebar_tab_rect("left", node, node.views, 2)

    test.ok(short_width < long_width,
      string.format("short=%g long=%g", short_width, long_width))
  end)

  test.it("keeps a draggable safe zone between the Left and Right Pane tabs", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local safe_x, _, safe_width = titlebar:get_titlebar_safe_rect()
    local left_tabs_x, _, left_tabs_width = titlebar:get_pane_tabs_rect("left")
    local right_tabs_x, _, right_tabs_width = titlebar:get_pane_tabs_rect("right")

    test.ok(safe_width > 0)
    test.ok(left_tabs_x + left_tabs_width <= safe_x)
    test.ok(safe_x + safe_width <= right_tabs_x)
    test.is_nil(titlebar:get_titlebar_tab_at(safe_x + safe_width / 2, titlebar.size.y / 2))
    test.is_nil(titlebar:get_titlebar_scroll_button_at(safe_x + safe_width / 2, titlebar.size.y / 2))

    context.original_set_window_hit_test = system.set_window_hit_test
    local hit_test_args
    system.set_window_hit_test = function(...)
      hit_test_args = { ... }
    end
    titlebar:configure_hit_test(true)

    test.not_nil(hit_test_args)
    local left_interactive_x, _, left_interactive_width = titlebar:get_pane_tabs_interactive_rect("left")
    local right_interactive_x, _, right_interactive_width = titlebar:get_pane_tabs_interactive_rect("right")
    test.equal(hit_test_args[5], left_interactive_x)
    test.equal(hit_test_args[6], left_interactive_width)
    test.ok(hit_test_args[6] <= left_tabs_width)
    test.equal(hit_test_args[7], right_interactive_x)
    test.equal(hit_test_args[8], right_interactive_width)
    test.ok(hit_test_args[8] <= right_tabs_width)
  end)

  test.it("backfills hidden Pane Tabs and removes overflow buttons after growing", function()
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 600 * SCALE, 32 * SCALE

    local views = {}
    for i = 1, 10 do views[i] = {} end
    local node = {
      views = views,
      active_view = views[#views],
      titlebar_tab_offset = 1,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "right" and node or nil
    end

    titlebar:scroll_titlebar_tabs_to_active("right", node)
    test.ok(node.titlebar_tab_offset > 1)

    titlebar.size.x = 1800 * SCALE
    titlebar:scroll_titlebar_tabs_to_active("right", node)

    test.equal(node.titlebar_tab_offset, 1)
    local _, _, _, _, show_previous, show_next =
      titlebar:get_titlebar_tabs_content_rect("right", node, views)
    test.ok(not show_previous)
    test.ok(not show_next)
  end)

  test.it("keeps unused shared Title Bar width available for native window dragging", function(context)
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

    titlebar.size.x = 2000 * SCALE
    local tabs_x, _, tabs_capacity = titlebar:get_pane_tabs_rect("left")
    local safe_x, _, safe_width = titlebar:get_titlebar_safe_rect()
    test.ok(safe_width > tabs_capacity)
    test.is_nil(titlebar:get_titlebar_tab_at(safe_x + safe_width / 2, titlebar.size.y / 2))

    context.original_set_window_hit_test = system.set_window_hit_test
    local hit_test_args
    system.set_window_hit_test = function(...)
      hit_test_args = { ... }
    end
    titlebar:configure_hit_test(true)

    test.equal(hit_test_args[5], tabs_x)
    test.ok(hit_test_args[6] > 0)
    test.ok(hit_test_args[6] <= tabs_capacity)
  end)

  test.it("renders the selected Pane Tab as an inset rounded tile", function(context)
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
    context.original_draw_rounded_rect = renderer.draw_rounded_rect
    context.original_set_clip_rect = renderer.set_clip_rect
    renderer.draw_rect = function() end
    local tiles = {}
    renderer.draw_rounded_rect = function(x, y, w, h, radius, color)
      tiles[#tiles + 1] = { x = x, y = y, w = w, h = h, radius = radius, color = color }
    end
    renderer.set_clip_rect = function() end

    titlebar:draw_titlebar_tabs()

    test.equal(#tiles, 1)
    test.equal(tiles[1].color, style.titlebar_tab_active)
    test.ok(tiles[1].radius > 0)

    local tab_x, tab_y, tab_w, tab_h =
      titlebar:get_titlebar_tab_rect("left", node, views, 1)
    test.ok(tiles[1].x > tab_x)
    test.ok(tiles[1].y > tab_y)
    test.ok(tiles[1].x + tiles[1].w < tab_x + tab_w)
    test.ok(tiles[1].y + tiles[1].h > tab_y + tab_h,
      "lower rounded corners should extend below the clipped Title Bar")
  end)

  test.it("shows hover feedback on the selected Pane Tab", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local view = {}
    local node = {
      views = { view },
      active_view = view,
      titlebar_tab_offset = 1,
      get_tab_title_font = function() return style.font end,
      draw_tab_title = function() end,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and node or nil
    end
    titlebar.hovered_tab_pane = "left"
    titlebar.hovered_tab_view = view

    context.original_draw_rect = renderer.draw_rect
    context.original_draw_rounded_rect = renderer.draw_rounded_rect
    context.original_set_clip_rect = renderer.set_clip_rect
    local hover_rects = {}
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function(x, y, w, h, radius, color)
      if color == style.titlebar_tab_hover then
        hover_rects[#hover_rects + 1] = { x = x, y = y, w = w, h = h, radius = radius }
      end
    end
    renderer.set_clip_rect = function() end

    titlebar:draw_titlebar_tabs()

    test.equal(#hover_rects, 1)
    test.ok(hover_rects[1].radius > 0)
  end)

  test.it("clips each Pane Tab label inside its minimum side padding", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local view = {}
    local title_rect
    local node = {
      views = { view },
      active_view = view,
      titlebar_tab_offset = 1,
      get_tab_title_font = function() return style.font end,
      draw_tab_title = function(_, _, _, _, _, x, y, w, h)
        title_rect = { x = x, y = y, w = w, h = h }
      end,
    }
    titlebar.get_tabs_node = function(_, pane)
      return pane == "left" and node or nil
    end

    context.original_draw_rect = renderer.draw_rect
    context.original_draw_rounded_rect = renderer.draw_rounded_rect
    context.original_set_clip_rect = renderer.set_clip_rect
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    local clips = {}
    renderer.set_clip_rect = function(x, y, w, h)
      clips[#clips + 1] = { x = x, y = y, w = w, h = h }
    end

    titlebar:draw_titlebar_tabs()

    test.not_nil(title_rect)
    local found_title_clip = false
    for _, clip in ipairs(clips) do
      if clip.x == title_rect.x and clip.y == title_rect.y
      and clip.w == title_rect.w and clip.h == title_rect.h then
        found_title_clip = true
        break
      end
    end
    test.ok(found_title_clip, "Pane Tab title drawing must not enter its side padding")
  end)

  test.it("fades Right Pane tabs while the Right Pane is hidden", function(context)
    local titlebar = TitleBar()
    titlebar.position.x, titlebar.position.y = 0, 0
    titlebar.size.x, titlebar.size.y = 1200 * SCALE, 32 * SCALE

    local view = { get_name = function() return "Right tab" end }
    local title_color
    local node = Node()
    node.views = { view }
    node.active_view = view
    node.titlebar_tab_offset = 1
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
    context.original_draw_rounded_rect = renderer.draw_rounded_rect
    context.original_set_clip_rect = renderer.set_clip_rect
    context.original_common_draw_text = common.draw_text
    renderer.draw_rect = function() end
    renderer.draw_rounded_rect = function() end
    renderer.set_clip_rect = function() end
    common.draw_text = function(_, color)
      title_color = color
    end

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
