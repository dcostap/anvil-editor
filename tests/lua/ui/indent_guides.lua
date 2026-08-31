local common = require "core.common"
local core = require "core"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

require "plugins.indent_guides"

local function set_text(buffer, text)
  buffer.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    buffer.lines[#buffer.lines + 1] = line
  end
  if #buffer.lines == 0 then buffer.lines[1] = "\n" end
  buffer:clear_undo_redo()
  buffer:clean()
  buffer:set_selection(1, 1)
end

local function new_view(text)
  local buffer = Buffer()
  set_text(buffer, text or "")
  local view = TextView(buffer)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 80, 200
  return buffer, view
end

local function write_file(path)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:close()
end

local function find_line(view, text)
  for line, source in ipairs(view.buffer.lines) do
    if source:gsub("\n$", "") == text then return line end
  end
end

local function guide_count(view, line)
  local count = 0
  local old_draw_rect = renderer.draw_rect
  local old_draw_rect_grid = renderer.draw_rect_grid
  local old_draw_text = renderer.draw_text
  local old_draw_line_hint = view.draw_line_hint
  renderer.draw_rect = function(_, _, _, _, color)
    if color == style.indent_guide then count = count + 1 end
  end
  renderer.draw_rect_grid = function(_, _, _, _, _, rect_count, color)
    if color == style.indent_guide then count = count + rect_count end
  end
  renderer.draw_text = function(_, text, x)
    return x + #tostring(text)
  end
  view.draw_line_hint = function() end

  local ok, err = pcall(function()
    local x, y = view:get_line_screen_position(line)
    view:draw_line_body(line, x, y)
  end)
  renderer.draw_rect = old_draw_rect
  renderer.draw_rect_grid = old_draw_rect_grid
  renderer.draw_text = old_draw_text
  view.draw_line_hint = old_draw_line_hint
  if not ok then error(err, 0) end
  return count
end

test.describe("indent guide drawing", function()
  test.it("batches visible guide rects with draw_rect_grid", function()
    local buffer, view = new_view(string.rep(" ", 1000) .. "x")
    local rect_grid_calls = 0
    local guide_rect_calls = 0
    local old_draw_rect = renderer.draw_rect
    local old_draw_rect_grid = renderer.draw_rect_grid
    local old_draw_text = renderer.draw_text

    renderer.draw_rect = function(_, _, _, _, color)
      if color == style.indent_guide then guide_rect_calls = guide_rect_calls + 1 end
    end
    renderer.draw_rect_grid = function(_, _, _, _, _, count, color)
      if color == style.indent_guide then rect_grid_calls = rect_grid_calls + 1 end
    end
    renderer.draw_text = function(_, text, x)
      return x + #tostring(text)
    end

    local ok, err = pcall(function()
      local x, y = view:get_line_screen_position(1)
      view:draw_line_body(1, x, y)
    end)
    renderer.draw_rect = old_draw_rect
    renderer.draw_rect_grid = old_draw_rect_grid
    renderer.draw_text = old_draw_text
    if not ok then error(err) end

    test.ok(rect_grid_calls > 0, "expected indent guides to use renderer.draw_rect_grid")
    test.equal(guide_rect_calls, 0)
    buffer:on_close()
  end)

  test.it("removes guides from rows shifted by a File Tree collapse", function(context)
    local root = core.root_project().path .. PATHSEP .. "indent-guide-filetree-tests-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local nested = root .. PATHSEP .. "a" .. PATHSEP .. "b"
    test.ok(common.mkdirp(nested))
    context.root = root
    write_file(nested .. PATHSEP .. "child.txt")
    write_file(root .. PATHSEP .. "z.txt")
    write_file(root .. PATHSEP .. "zz.txt")

    local view = test.not_nil(require("plugins.filetree").new(root))
    context.view = view
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 400, 400

    local a_line = test.not_nil(find_line(view, "a/"))
    local a_entry = test.not_nil(view:entry_for_line(a_line))
    view:expand_folder(a_line, a_entry, false)
    local b_line = test.not_nil(find_line(view, "\tb/"))
    local b_entry = test.not_nil(view:entry_for_line(b_line))
    view:expand_folder(b_line, b_entry, false)

    local child_line = test.not_nil(find_line(view, "\t\tchild.txt"))
    test.ok(guide_count(view, child_line) > 0)

    view:collapse_folder(a_line, view:entry_for_line(a_line))
    test.equal(find_line(view, "zz.txt"), child_line)
    test.equal(guide_count(view, child_line), 0)
  end)

  test.after_each(function(context)
    if context.view then context.view:on_close() end
    if context.root and system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
  end)
end)
