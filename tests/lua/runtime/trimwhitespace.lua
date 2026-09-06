local Buffer = require "core.buffer"
local test = require "core.test"
local trimwhitespace = require "plugins.trimwhitespace"

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

local function text(buffer)
  return table.concat(buffer.lines)
end

test.describe("trimwhitespace", function()
  test.it("preserves whitespace when saving a Buffer", function()
    local buffer = Buffer()
    set_text(buffer, "aa   \n\t \n\n")
    local expected = text(buffer)
    local path = USERDIR .. PATHSEP .. "trimwhitespace-save-test.txt"
    local ok, err = pcall(function()
      buffer:save(path, path)
      test.equal(text(buffer), expected)
      local file = assert(io.open(path, "rb"))
      local saved = file:read("*a")
      file:close()
      test.equal(saved:gsub("\r\n", "\n"), expected)
    end)
    os.remove(path)
    if not ok then error(err, 0) end
  end)

  test.it("trims trailing whitespace in one buffer edit", function()
    local buffer = Buffer()
    set_text(buffer, "aa   \nbb\t  \ncc")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    trimwhitespace.trim(buffer)

    test.equal(text(buffer), "aa\nbb\ncc\n")
    test.equal(changes, 1)
  end)

  test.it("preserves whitespace before the active caret while trimming other lines", function()
    local buffer = Buffer()
    set_text(buffer, "aa   \nbb   ")
    buffer:set_selection(1, 5, 1, 5)

    trimwhitespace.trim(buffer)

    test.equal(text(buffer), "aa  \nbb\n")
    test.same(buffer.selections, { 1, 5, 1, 5 })
  end)

  test.it("preserves whitespace before every caret while trimming other lines", function()
    local buffer = Buffer()
    set_text(buffer, "aa   \nbb   \ncc   ")
    buffer.selections = {
      1, 5, 1, 5,
      2, 4, 2, 4,
    }
    buffer.last_selection = 2

    trimwhitespace.trim(buffer)

    test.equal(text(buffer), "aa  \nbb \ncc\n")
    test.same(buffer.selections, {
      1, 5, 1, 5,
      2, 4, 2, 4,
    })
    test.equal(buffer.last_selection, 2)
  end)

  test.it("scans whitespace-heavy long lines without stalling", function()
    local buffer = Buffer()
    local line = string.rep(string.rep(" ", 1300) .. "x", 2000)
    set_text(buffer, line)

    local started = system.get_time()
    trimwhitespace.trim(buffer)
    local elapsed = system.get_time() - started

    test.equal(text(buffer), line .. "\n")
    test.ok(elapsed < 0.5, string.format(
      "trailing-whitespace scan stalled for %.3fs", elapsed
    ))
  end)

  test.it("removes trailing empty lines in one buffer edit", function()
    local buffer = Buffer()
    set_text(buffer, "aa\n\n\n")
    local changes = 0
    function buffer:on_text_change()
      changes = changes + 1
    end

    trimwhitespace.trim_empty_end_lines(buffer)

    test.equal(text(buffer), "aa\n")
    test.equal(changes, 1)
  end)
end)
