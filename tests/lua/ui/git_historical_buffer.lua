local test = require "core.test"

local historical = require "plugins.git.historical_buffer"

local function buffer_text(buffer)
  return table.concat(buffer.lines)
end

test.describe("Git Historical Buffer", function()
  test.after_each(function()
    for i = #core.buffers, 1, -1 do
      if core.buffers[i].git_historical_key then table.remove(core.buffers, i) end
    end
  end)

  test.test("creates reusable read-only Historical Buffers", function()
    local repo = { root = "C:/repo" }
    local buffer, created = historical.create_buffer(repo, "abc123", "src/app.lua", "return true\n")
    local again, created_again = historical.create_buffer(repo, "abc123", "src/app.lua", "different\n")

    test.equal(created, true)
    test.equal(created_again, false)
    test.equal(buffer, again)
    test.equal(buffer.filename, "src/app.lua")
    test.equal(buffer:get_name(), "src/app.lua @ abc123")
    test.equal(buffer_text(buffer), "return true\n")
    test.equal(buffer:is_dirty(), false)

    buffer:text_input("x")
    test.equal(buffer_text(buffer), "return true\n")
    local view = historical.View(buffer)
    test.equal(view:get_state(), nil)

    local ok = pcall(buffer.save, buffer)
    test.equal(ok, false)
  end)

  test.test("normalizes CRLF historical blobs to Buffer line semantics", function()
    local buffer = historical.create_buffer({ root = "C:/repo" }, "crlf123", "src/crlf.lua", "one\r\ntwo\r\n")
    test.equal(buffer_text(buffer), "one\ntwo\n")
  end)

  test.test("normalizes blobs without trailing newline to Buffer line invariants", function()
    local buffer = historical.create_buffer({ root = "C:/repo" }, "def456", "src/noeol.lua", "abc")
    test.equal(buffer_text(buffer), "abc\n")
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "abc")
  end)
end)
