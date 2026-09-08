local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local linewrapping = require "core.linewrapping"
local test = require "core.test"
local worker_pool = require "core.worker_pool"
local renwindow = require "renwindow"
local style = require "core.style"

local function check_alignment(prefix, wrapped, width)
    local source = prefix .. "CONSULTAS_VARIAS_SQL_CASTROSUA/: this is a massive dump of misc queries, mostly related to ERP."
    local identity = "caret-alignment-" .. #prefix .. "-" .. tostring(wrapped) .. "-" .. width .. ".md"
    local buffer = Buffer(identity, identity, true)
    buffer:insert(1, 1, source .. "\nplain\n")
    local view = Editor(buffer)
    view.size.x, view.size.y = width, 300
    view:set_wrapping_enabled(wrapped)
    buffer:set_selection(2, 1)
    markdown.live_render.refresh_view(view)
    local instance = model.peek(buffer)
    local deadline = system.get_time() + 5
    while instance.status ~= "ready" and system.get_time() < deadline do
      local pool = worker_pool.current_system()
      if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
      if instance.status ~= "ready" then coroutine.yield(0.01) end
    end
    test.equal(instance.status, "ready", instance.reason)
    linewrapping.complete_async_reconstruction(view)

    local col = test.not_nil(source:find("queries", 1, true))
    local drawn_x
    local old_draw_text = renderer.draw_text
    renderer.draw_text = function(font, text, x, y, color, opts)
      local at = text:find("queries", 1, true)
      if at then drawn_x = x + font:get_width(text:sub(1, at - 1), opts) end
      return old_draw_text(font, text, x, y, color, opts)
    end
    local window = renwindow.create("Markdown caret alignment", 800, 400)
    renderer.begin_frame(window)
    local ok, err = pcall(function() view:draw_line_text(1, 0, 0) end)
    renderer.end_frame()
    renderer.draw_text = old_draw_text
    if not ok then error(err, 0) end
    test.not_nil(drawn_x, "the test must draw the word under the caret")
    local caret_x = view:get_col_x_offset(1, col)
    model.close(buffer, "test")
    test.ok(math.abs(caret_x - drawn_x) < 0.5,
      string.format("caret x=%.3f, drawn text x=%.3f", caret_x, drawn_x))
end

test.describe("Markdown caret alignment", function()
  test.it("aligns list prose after a path", function()
    check_alignment("- ", true, 720)
  end)
  test.it("aligns list prose on a continuation row", function()
    check_alignment("- ", true, 420)
  end)
  test.it("aligns unwrapped list prose", function()
    check_alignment("- ", false, 720)
  end)
  test.it("aligns ordinary prose after a path", function()
    check_alignment("", true, 720)
  end)
  test.it("keeps caret boundaries inside shaped words and after tabs", function()
    local font = style.markdown_body_font
    local text = "office\tcafé "
    local layout = font:text_layout(text)
    test.ok(math.abs(layout:width() - font:get_width(text)) < 0.01)
    for offset = 0, #"office" do
      test.equal(layout:byte_at_x(layout:width_at(offset)), offset)
    end
    local after_tab = #"office\t"
    test.ok(math.abs(layout:width_at(after_tab)
      - font:get_width(text:sub(1, after_tab))) < 0.01)
    test.equal(layout:byte_at_x(layout:width()), #text)
  end)
end)
