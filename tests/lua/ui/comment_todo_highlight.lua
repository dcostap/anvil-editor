local Buffer = require "core.buffer"
local Editor = require "core.editor"
local TextView = require "core.textview"
local line_packets = require "core.textview_line_packets"
local style = require "core.style"
local test = require "core.test"
local treesitter = require "core.treesitter"

local function make_buffer(text, name)
  local buffer = Buffer()
  buffer:insert(1, 1, text)
  buffer:set_filename(name, name)
  return buffer
end

local function wait_ready(buffer)
  local deadline = system.get_time() + 3
  while system.get_time() < deadline do
    treesitter.poll_buffer(buffer)
    if buffer.treesitter and buffer.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function drawn_colors(view, line)
  local calls = {}
  local old = renderer.draw_text
  renderer.draw_text = function(_, text, x, _, color)
    calls[#calls + 1] = { text = text, color = color }
    return x + #text
  end
  local ok, err = pcall(function() view:draw_line_text(line, 0, 0) end)
  renderer.draw_text = old
  if not ok then error(err) end
  local by_text = {}
  for _, call in ipairs(calls) do
    for word in call.text:gmatch("[%w_]+") do by_text[word] = call.color end
  end
  return by_text
end

test.describe("TODO comment highlighting", function()
  test.it("colors comments from the TODO line downward without coloring earlier comments or code", function()
    local buffer = make_buffer(table.concat({
      'const char *literal = "TODO: keep plain";',
      '//',
      '// first line',
      '// todo: finish this',
      '// last line',
      'int value = 1; // unrelated',
      '// TODO without colon',
      '',
      '// separate line',
    }, "\n"), "comment_todo.cpp")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    -- Draw a continuation first to check that draw order does not affect colors.
    for _, line in ipairs({ 5, 4 }) do
      local colors = drawn_colors(view, line)
      for word, color in pairs(colors) do
        test.equal(color, style.syntax.todo, word .. " on line " .. line)
      end
    end
    test.not_equal(drawn_colors(view, 1).TODO, style.syntax.todo)
    test.not_equal(drawn_colors(view, 3).first, style.syntax.todo)
    test.not_equal(drawn_colors(view, 6).unrelated, style.syntax.todo)
    test.equal(drawn_colors(view, 7).TODO, style.syntax.todo)
    test.not_equal(drawn_colors(view, 9).separate, style.syntax.todo)
    buffer:on_close()
  end)

  test.it("colors only comment text in a multiline block with inline code", function()
    local buffer = make_buffer("int before; /* TODO: start\n * continue\n */ int after;", "comment_todo_block.cpp")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    test.equal(drawn_colors(view, 1).start, style.syntax.todo)
    test.equal(drawn_colors(view, 2).continue, style.syntax.todo)
    test.not_equal(drawn_colors(view, 1).before, style.syntax.todo)
    test.not_equal(drawn_colors(view, 3).after, style.syntax.todo)
    buffer:on_close()
  end)

  test.it("colors Lua comments without Tree-sitter", function()
    local buffer = make_buffer("-- TODO: plan\n-- next step\nprint('TODO: plain')", "comment_todo.lua")
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    test.equal(drawn_colors(view, 1).plan, style.syntax.todo)
    test.equal(drawn_colors(view, 2).next, style.syntax.todo)
    test.not_equal(drawn_colors(view, 3).TODO, style.syntax.todo)
    buffer:on_close()
  end)

  test.it("leaves block comment lines above a TODO unchanged", function()
    local buffer = make_buffer("/* first\n * TODO: start\n * continue\n */", "comment_todo_late_block.cpp")
    test.ok(wait_ready(buffer))
    local view = TextView(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    test.equal(drawn_colors(view, 3).continue, style.syntax.todo)
    test.not_equal(drawn_colors(view, 1).first, style.syntax.todo)
    test.equal(drawn_colors(view, 2).start, style.syntax.todo)
    buffer:on_close()
  end)

  test.it("updates cached comment lines when the TODO marker changes", function()
    local buffer = make_buffer("-- first\n-- TODO: middle\n-- last", "comment_todo_packets.lua")
    local view = Editor(buffer)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    view.__test_force_line_packets = true
    view:set_wrapping_enabled(false)

    local function color_on(line)
      local y = (line - 1) * view:get_line_height()
      local ok, err = pcall(line_packets.draw_content, view, line, 0, y)
      test.ok(ok, tostring(err))
      for _, item in ipairs(line_packets.inspect_line(view, line) or {}) do
        if item.type == "text" then
          return table.concat(item.color, ",")
        end
      end
    end

    local todo = table.concat(style.syntax.todo, ",")
    test.not_equal(color_on(1), todo)
    test.equal(color_on(3), todo)
    buffer:remove(2, 4, 2, 9)
    test.not_equal(color_on(3), todo)
    buffer:insert(2, 4, "TODO:")
    test.equal(color_on(3), todo)
    test.not_equal(color_on(1), todo)
    buffer:on_close()
  end)
end)
