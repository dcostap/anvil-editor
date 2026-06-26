local test = require "core.test"

local historical = require "plugins.git.historical_document"

local function doc_text(doc)
  return table.concat(doc.lines)
end

test.describe("Git Historical Document", function()
  test.after_each(function()
    for i = #core.docs, 1, -1 do
      if core.docs[i].git_historical_key then table.remove(core.docs, i) end
    end
  end)

  test.test("creates reusable read-only historical documents", function()
    local repo = { root = "C:/repo" }
    local doc, created = historical.create_document(repo, "abc123", "src/app.lua", "return true\n")
    local again, created_again = historical.create_document(repo, "abc123", "src/app.lua", "different\n")

    test.equal(created, true)
    test.equal(created_again, false)
    test.equal(doc, again)
    test.equal(doc.filename, "src/app.lua")
    test.equal(doc:get_name(), "src/app.lua @ abc123")
    test.equal(doc_text(doc), "return true\n")
    test.equal(doc:is_dirty(), false)

    doc:text_input("x")
    test.equal(doc_text(doc), "return true\n")
    local view = historical.View(doc)
    test.equal(view:get_state(), nil)

    local ok = pcall(doc.save, doc)
    test.equal(ok, false)
  end)

  test.test("normalizes CRLF historical blobs to Doc line semantics", function()
    local doc = historical.create_document({ root = "C:/repo" }, "crlf123", "src/crlf.lua", "one\r\ntwo\r\n")
    test.equal(doc_text(doc), "one\ntwo\n")
  end)

  test.test("normalizes blobs without trailing newline to Doc line invariants", function()
    local doc = historical.create_document({ root = "C:/repo" }, "def456", "src/noeol.lua", "abc")
    test.equal(doc_text(doc), "abc\n")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "abc")
  end)
end)
