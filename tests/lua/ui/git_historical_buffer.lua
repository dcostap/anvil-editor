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

  test.test("does not attach Tree-sitter to disabled preview buffers", function()
    local buffer = historical.create_preview_buffer(
      { root = "C:/repo" }, "preview123", "src/app.cpp", "return true\n", {
        disable_language_services = true,
        disable_treesitter = true,
      }
    )

    test.equal(buffer.treesitter, nil)
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

  test.test("strips a UTF-8 BOM from historical text", function()
    local buffer = historical.create_buffer(
      { root = "C:/repo" }, "bom123", "src/bom.lua", "\239\187\191return true\n"
    )
    test.equal(buffer_text(buffer), "return true\n")
  end)

  test.test("decodes a BOM-marked UTF-16 historical blob", function()
    local buffer = historical.create_buffer(
      { root = "C:/repo" }, "utf16-123", "src/utf16.lua",
      "\255\254r\0e\0t\0u\0r\0n\0 \0t\0r\0u\0e\0\n\0"
    )
    test.equal(buffer_text(buffer), "return true\n")
  end)

  test.test("rejects binary historical text", function()
    local buffer, err = historical.create_buffer(
      { root = "C:/repo" }, "binary123", "data/blob.bin", "text\0binary"
    )
    test.equal(buffer, nil)
    test.equal(err.kind, "binary")

  end)
end)
