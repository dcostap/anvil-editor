local core = require "core"
local style = require "core.style"
local test = require "core.test"

require "plugins.bracketmatch"

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_brace_view(context)
  local doc = core.open_doc()
  doc:text_input("{\n}")
  doc:set_selection(1, 1)
  local view = core.root_panel:open_doc(doc)
  core.set_active_view(view)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 320, 240
  view.scroll.x, view.scroll.to.x = 0, 0
  view.scroll.y, view.scroll.to.y = 0, 0
  view:update()
  context.view, context.doc = view, doc
  return view, doc
end

local function capture_frame_rects(view, line)
  local rects = {}
  local old_draw_rect = renderer.draw_rect
  local old_draw_text = renderer.draw_text
  local old_draw_text_known_bounds = renderer.draw_text_known_bounds
  renderer.draw_rect = function(x, y, w, h, color)
    if color == style.bracketmatch_frame_color then
      rects[#rects + 1] = { x = x, y = y, w = w, h = h }
    end
  end
  renderer.draw_text = function(font, text, x, _, _, opts)
    return x + font:get_width(text, opts)
  end
  renderer.draw_text_known_bounds = function(_, _, x, _, _, _, w)
    return x + w
  end
  local x, y = view:get_line_screen_position(line)
  local ok, err = pcall(function() view:draw_line_text(line, x, y) end)
  renderer.draw_rect = old_draw_rect
  renderer.draw_text = old_draw_text
  renderer.draw_text_known_bounds = old_draw_text_known_bounds
  if not ok then error(err, 0) end
  return rects
end

test.describe("Bracket match frame", function()
  test.after_each(function(context)
    local root = core.root_panel.root_node
    if context.view then
      local node = root:get_node_for_view(context.view)
      if node then node:remove_view(root, context.view) end
    end
    if context.doc then
      if context.doc:is_dirty() then context.doc:clean() end
      remove_doc(context.doc)
    end
  end)

  test.it("keeps every frame edge inside the document content clip", function(context)
    local view = open_brace_view(context)
    local frame = capture_frame_rects(view, 1)
    local content_x = select(1, view:get_line_screen_position(1, 1))
    test.equal(#frame, 4)
    for _, rect in ipairs(frame) do
      test.ok(rect.x >= content_x, "expected first-column frame edges to remain visible")
    end
  end)

  test.it("scales frame thickness with Zoom", function(context)
    local view = open_brace_view(context)
    local old_scale = SCALE
    SCALE = old_scale * 2
    local ok, frame = pcall(capture_frame_rects, view, 1)
    SCALE = old_scale
    if not ok then error(frame, 0) end

    local expected = math.max(1, old_scale * 2)
    test.equal(#frame, 4)
    test.equal(frame[1].h, expected)
    test.equal(frame[3].w, expected)
  end)
end)
