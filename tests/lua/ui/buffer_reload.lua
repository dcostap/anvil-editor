local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local test = require "core.test"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

local function numbered_lines(first, last, prefix)
  local out = {}
  for i = first, last do out[#out + 1] = string.format("%s %d\n", prefix, i) end
  return table.concat(out)
end

local function caret(view)
  local selections = view:get_selection_state().selections
  return selections[1], selections[2]
end

local function open(context, text, line, col)
  write_file(context.path, text)
  local view = assert(core.open_file(context.path, { placement = "new", line = line or 1, col = col or 1 }))
  test.not_ok(view.buffer:is_loading())
  return view, view.buffer
end

test.describe("Reload from disk", function()
  test.before_each(function(context)
    context.old_cwd = system.getcwd()
    panes.reset_for_tests()
    context.root = USERDIR .. PATHSEP .. "buffer-reload-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.path = context.root .. PATHSEP .. "note.txt"
  end)

  test.after_each(function(context)
    panes.reset_for_tests()
    core.buffer_registry:collect()
    -- Opening a file moves the working folder into it, which locks it on Windows.
    system.chdir(context.old_cwd)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("keeps the caret on its text when lines appear above it", function(context)
    local view, buffer = open(context, numbered_lines(1, 100, "line"), 50, 3)

    write_file(context.path, numbered_lines(1, 20, "new") .. numbered_lines(1, 100, "line"))
    buffer:reload()

    local line, col = caret(view)
    test.equal(buffer.lines[line], "line 50\n")
    test.equal(col, 3)
  end)

  test.it("keeps the caret on its word when words change before it in the same line", function(context)
    local text = "The date is Friday.\n"
    local view, buffer = open(context, text, 1, text:find("Friday", 1, true))

    write_file(context.path, "The delivery date is Friday.\n")
    buffer:reload()

    local line, col = caret(view)
    test.equal(line, 1)
    test.equal(buffer.lines[1]:sub(col, col + 5), "Friday")
  end)

  for _, name in ipairs { "note.txt", "note.md" } do
    test.it("keeps the visible text in place when lines appear above the viewport of " .. name, function(context)
      context.path = context.root .. PATHSEP .. name
      local view, buffer = open(context, numbered_lines(1, 200, "line"), 100, 1)
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 400, 300
      local _, top_y = view:get_line_screen_position(80)
      view.scroll.y = top_y - view.position.y
      view.scroll.to.y = view.scroll.y
      local _, before_y = view:get_line_screen_position(80)

      write_file(context.path, numbered_lines(1, 30, "new") .. numbered_lines(1, 200, "line"))
      buffer:reload()

      test.equal(buffer.lines[110], "line 80\n")
      local _, after_y = view:get_line_screen_position(110)
      test.equal(after_y, before_y)
    end)
  end

  test.it("saves edits made after a reload without a disk conflict", function(context)
    local view, buffer = open(context, "one\n")

    write_file(context.path, "one\ntwo\n")
    buffer:reload()
    buffer:insert(2, #buffer.lines[2], "\nthree")
    buffer:save()

    local file = assert(io.open(context.path, "rb"))
    local saved = file:read("*a")
    file:close()
    test.equal(saved, "one\ntwo\nthree\n")
    test.not_ok(buffer:is_dirty())
  end)

  test.it("reloads as one undo step and leaves the Buffer clean", function(context)
    local old_text = numbered_lines(1, 10, "line")
    local _, buffer = open(context, old_text)

    write_file(context.path, "intro\n" .. old_text:gsub("line 5\n", "line five\n"))
    buffer:reload()

    test.not_ok(buffer:is_dirty())
    test.equal(buffer.lines[1], "intro\n")
    test.equal(buffer.lines[6], "line five\n")

    buffer:undo()
    test.equal(table.concat(buffer.lines), old_text)
    test.ok(buffer:is_dirty())
  end)
end)
