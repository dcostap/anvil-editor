local core = require "core"
local test = require "core.test"
local View = require "core.view"
local diffview = require "plugins.diffview"

test.describe("Diff gap boundaries", function()
  test.before_each(function(context)
    context.active_view = core.active_view
    core.active_view = View()
  end)

  test.after_each(function(context)
    if context.view then context.view:on_close() end
    core.active_view = context.active_view
  end)

  for _, side in ipairs({ "left", "right" }) do
    test.it("keeps a changed block together on the " .. side, function(context)
      local tail = "end\nnext_step();\nfinish();\n"
      local short = "begin\n  prepare(new_name);\n  save(new_name);\n  unlink(new_name);\n" .. tail
      local lines = { "begin", "  prepare(old_name);" }
      for i = 1, 16 do lines[#lines + 1] = "  removed_step_" .. i .. "();" end
      local long = table.concat(lines, "\n")
        .. "\n  save(old_name);\n  unlink(old_name);\n" .. tail
      local view = diffview.string_to_string(side == "left" and short or long,
        side == "left" and long or short, "left", "right", true)
      context.view = view
      local deadline = system.get_time() + 2
      while view.updater_idx do
        test.ok(system.get_time() < deadline, "diff computation did not finish")
        coroutine.yield(0.01)
      end
      view.size.x, view.size.y = 900, 600
      view:update()
      local small = side == "left" and view.buffer_view_a or view.buffer_view_b
      local large = side == "left" and view.buffer_view_b or view.buffer_view_a
      local _, first_y = small:get_line_screen_position(2)
      local _, last_y = small:get_line_screen_position(4)
      test.equal(last_y - first_y, small:get_line_height() * 2,
        "alignment must not split the changed statements")
      local _, small_y = small:get_line_screen_position(6)
      local _, large_y = large:get_line_screen_position(22)
      test.equal(small_y, large_y, "unchanged content after the block must align")
    end)

    for _, indent in ipairs({ "  ", "\t" }) do
      test.it("prefers the function boundary over an internal blank on the " .. side
        .. (indent == "\t" and " with tabs" or " with spaces"), function(context)
        local short = "function first() {\n}\n\nfunction second() {\n"
          .. indent .. "prepare();\n\n" .. indent .. "shared();\n" .. indent .. "finish();\n}\n"
        local lines = { "function first() {" }
        for i = 1, 8 do lines[#lines + 1] = indent .. "added" .. i .. "();" end
        local long = table.concat(lines, "\n") .. "\n}\n\nfunction second() {\n"
          .. indent .. "prepare();\n\n" .. indent .. "inserted();\n"
          .. indent .. "shared();\n" .. indent .. "finish();\n}\n"
        local view = diffview.string_to_string(side == "left" and short or long,
          side == "left" and long or short, "left", "right", true)
        context.view = view
        local deadline = system.get_time() + 2
        while view.updater_idx do
          test.ok(system.get_time() < deadline, "diff computation did not finish")
          coroutine.yield(0.01)
        end
        view.size.x, view.size.y = 900, 600
        view:update()
        local small = side == "left" and view.buffer_view_a or view.buffer_view_b
        local large = side == "left" and view.buffer_view_b or view.buffer_view_a
        local _, header_y = small:get_line_screen_position(4)
        local _, body_y = small:get_line_screen_position(7)
        test.equal(body_y - header_y, small:get_line_height() * 3,
          "alignment must not expand the blank inside the function")
        local _, other_y = large:get_line_screen_position(16)
        test.equal(body_y, other_y, "the shared body must align")
      end)
    end

    test.it("places alignment space before a small function on the " .. side, function(context)
      local tail = "}\n\nfunction second() {\n  shared();\n  finish();\n}\n"
      local short = "function first() {\n" .. tail
      local lines = { "function first() {" }
      for i = 1, 8 do lines[#lines + 1] = "  added" .. i .. "();" end
      local long = table.concat(lines, "\n") .. "\n}\n\nfunction second() {\n  inserted();\n  shared();\n  finish();\n}\n"
      local view = diffview.string_to_string(side == "left" and short or long,
        side == "left" and long or short, "left", "right", true)
      context.view = view
      local deadline = system.get_time() + 2
      while view.updater_idx do
        test.ok(system.get_time() < deadline, "diff computation did not finish")
        coroutine.yield(0.01)
      end
      view.size.x, view.size.y = 900, 600
      view:update()
      local small = side == "left" and view.buffer_view_a or view.buffer_view_b
      local large = side == "left" and view.buffer_view_b or view.buffer_view_a
      local _, header_y = small:get_line_screen_position(4)
      local _, body_y = small:get_line_screen_position(5)
      test.equal(body_y - header_y, small:get_line_height(), "the function must remain together")
      local _, other_y = large:get_line_screen_position(14)
      test.equal(body_y, other_y, "the shared body must align")
    end)

    test.it("keeps the closing brace with its body on the " .. side, function(context)
      local short = "function first() {\n  old();\n}\n\nfunction second() {\n  shared();\n}\n"
      local lines = { "function first() {" }
      for i = 1, 12 do lines[#lines + 1] = "  added" .. i .. "();" end
      lines[#lines + 1] = "}\n\nfunction second() {\n  shared();\n}\n"
      local long = table.concat(lines, "\n")
      local view = diffview.string_to_string(side == "left" and short or long,
        side == "left" and long or short, "left", "right", true)
      context.view = view
      local deadline = system.get_time() + 2
      while view.updater_idx do
        test.ok(system.get_time() < deadline, "diff computation did not finish")
        coroutine.yield(0.01)
      end
      view.size.x, view.size.y = 900, 600
      view:update()
      local small = side == "left" and view.buffer_view_a or view.buffer_view_b
      local large = side == "left" and view.buffer_view_b or view.buffer_view_a
      local _, body_y = small:get_line_screen_position(2)
      local _, brace_y = small:get_line_screen_position(3)
      test.equal(brace_y - body_y, small:get_line_height(), "the gap must not split the closing brace")
      local _, small_y = small:get_line_screen_position(5)
      local _, large_y = large:get_line_screen_position(16)
      test.equal(small_y, large_y, "the next function must align")
    end)
  end
end)
