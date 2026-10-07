local Buffer = require "core.buffer"
local test = require "core.test"

test.describe("Buffer snapshot replacement", function()
  test.after_each(function(context)
    if context.path then os.remove(context.path) end
  end)

  test.it("publishes loaded text without keeping editable undo history", function()
    local buffer = Buffer("snapshot.txt", "snapshot.txt", true)
    buffer:insert(1, 1, "old\ntext")
    local revision = buffer.text_revision
    local before, after
    buffer:add_text_change_listener("snapshot-test", {
      before_change = function(current)
        before = { text = current:get_text(1, 1, math.huge, math.huge), revision = current.text_revision }
      end,
      after_change = function(current, change)
        after = {
          text = current:get_text(1, 1, math.huge, math.huge),
          revision = current.text_revision,
          transaction = change.transaction,
        }
      end,
    })

    buffer:replace_snapshot("new\nloaded\ntext\n")

    test.equal(before.text, "old\ntext")
    test.equal(before.revision, revision)
    test.equal(after.text, "new\nloaded\ntext")
    test.ok(after.revision > revision, "loaded text must invalidate older parser results")
    test.ok(after.transaction.full_snapshot, "observers must receive a full replacement")
    test.equal(after.transaction.content_changed, true)
    buffer:undo()
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "new\nloaded\ntext")
  end)

  test.it("replaces binary display data and line endings with the new source", function()
    local buffer = Buffer("snapshot.txt", "snapshot.txt", true)
    buffer:replace_snapshot("a\255\r\n")
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "a\255")
    test.equal(buffer:get_utf8_line(1), "a\26\n")
    test.ok(buffer.binary)
    test.ok(buffer.crlf)

    buffer:replace_snapshot("plain\n")
    test.equal(buffer:get_utf8_line(1), "plain\n")
    test.equal(buffer.binary, false)
    test.equal(buffer.crlf, false)

    buffer:replace_snapshot("one\r\ntwo\r\n", { crlf = false })
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "one\ntwo")
    test.equal(buffer.crlf, false, "a saved line-ending choice must override detection")
  end)

  test.it("loads decoded file text through the snapshot publication contract", function(context)
    context.path = USERDIR .. PATHSEP .. "snapshot-utf16.txt"
    local file = test.not_nil(io.open(context.path, "wb"))
    file:write("\255\254o\0n\0e\0\r\0\n\0")
    file:close()
    local buffer = Buffer("snapshot-utf16.txt", context.path, true)
    local publication
    buffer:add_text_change_listener("decoded-snapshot", {
      after_change = function(current, change)
        publication = { text = current:get_text(1, 1, math.huge, math.huge), transaction = change.transaction }
      end,
    })
    buffer:load(context.path)
    test.equal(publication.text, "one")
    test.ok(publication.transaction.full_snapshot)
    test.ok(buffer.crlf)
    test.equal(buffer.binary, false)
  end)

  test.it("keeps text, selections, and undo history when file decoding fails", function(context)
    context.path = USERDIR .. PATHSEP .. "snapshot-decode-failure.txt"
    local file = test.not_nil(io.open(context.path, "wb"))
    file:write("new file text")
    file:close()
    local buffer = Buffer("snapshot-decode-failure.txt", context.path, true)
    buffer:insert(1, 1, "unsaved text")
    buffer:set_selection(1, 5)
    local revision = buffer.text_revision
    buffer.encoding = "ANVIL-UNKNOWN-CHARSET"

    local ok = pcall(buffer.load, buffer, context.path)
    test.equal(ok, false)
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "unsaved text")
    test.equal(buffer.text_revision, revision)
    local line, col = buffer:get_selection()
    test.equal(line, 1)
    test.equal(col, 5)
    test.ok(buffer:is_dirty())
    buffer:undo()
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "")
  end)
end)
