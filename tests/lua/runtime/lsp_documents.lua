local common = require "core.common"
local Doc = require "core.doc"
local test = require "core.test"
local documents = require "core.lsp.documents"
local uri = require "core.lsp.uri"

local temp_root

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_doc(path, text)
  local doc = Doc()
  set_text(doc, text or "")
  doc:set_filename(path, path)
  return doc
end

local function fake_client(language_id)
  return {
    language_id = language_id or "cpp",
    sent = {},
    send_notification = function(self, method, params)
      self.sent[#self.sent + 1] = { method = method, params = params }
      return true
    end,
  }
end

local function messages(client, method)
  local out = {}
  for _, item in ipairs(client.sent) do
    if not method or item.method == method then out[#out + 1] = item end
  end
  return out
end

test.describe("core.lsp.documents", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-documents-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    mkdir(temp_root)
  end)

  test.after_each(function(context)
    if context.docs then
      for _, doc in ipairs(context.docs) do
        pcall(function() doc:on_close() end)
      end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function track_doc(context, doc)
    context.docs = context.docs or {}
    context.docs[#context.docs + 1] = doc
    return doc
  end

  test.test("sends didOpen with LF-normalized full text", function(context)
    local path = join_path(temp_root, "main.cpp")
    local doc = track_doc(context, new_doc(path, "int main() {\n  return 0;\n}"))
    doc.crlf = true
    local client = fake_client("cpp")

    local state = test.not_nil(documents.attach(client, doc, { language_id = "cpp" }))
    test.equal(state.lsp_version, 0)
    local opens = messages(client, "textDocument/didOpen")
    test.equal(#opens, 1)
    test.equal(opens[1].params.textDocument.uri, uri.path_to_uri(path))
    test.equal(opens[1].params.textDocument.languageId, "cpp")
    test.equal(opens[1].params.textDocument.version, 0)
    test.equal(opens[1].params.textDocument.text, "int main() {\n  return 0;\n}\n")
  end)

  test.test("debounces full didChange and increments LSP versions", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    local state = test.not_nil(documents.attach(client, doc, {
      language_id = "cpp",
      debounce_seconds = 10,
    }))

    doc:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    test.ok(state.pending_full_sync)
    test.equal(#messages(client, "textDocument/didChange"), 0)
    documents.update(system.get_time() + 1)
    test.equal(#messages(client, "textDocument/didChange"), 0)

    documents.flush_before_request(client, doc)
    local changes = messages(client, "textDocument/didChange")
    test.equal(#changes, 1)
    test.equal(changes[1].params.textDocument.version, 1)
    test.equal(changes[1].params.contentChanges[1].text, "abcd\n")
    test.equal(state.lsp_version, 1)

    doc:apply_edits({ { line1 = 1, col1 = 5, line2 = 1, col2 = 5, text = "e" } })
    state.pending_due_at = system.get_time() - 1
    documents.update()
    changes = messages(client, "textDocument/didChange")
    test.equal(#changes, 2)
    test.equal(changes[2].params.textDocument.version, 2)
    test.equal(changes[2].params.contentChanges[1].text, "abcde\n")
  end)

  test.test("tracks snapshots and current/stale metadata", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    local state = test.not_nil(documents.attach(client, doc, { language_id = "cpp" }))
    local open_change_id = doc:get_change_id()
    test.ok(documents.is_current(state, 0, open_change_id))
    test.not_nil(documents.snapshot_for_version(state, 0))
    test.not_nil(documents.snapshot_for_change_id(state, open_change_id))

    doc:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    documents.flush(client, doc)
    test.ok(documents.is_current(state, 1, doc:get_change_id()))
    test.not_ok(documents.is_current(state, 0, doc:get_change_id()))
    test.not_nil(documents.snapshot_for_version(state, 1))
  end)

  test.test("sends didSave helper without affecting CRLF save state", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "abc"))
    doc.crlf = true
    local client = fake_client("cpp")
    documents.attach(client, doc, { language_id = "cpp", include_save_text = true })

    test.ok(documents.did_save(client, doc))
    local saves = messages(client, "textDocument/didSave")
    test.equal(#saves, 1)
    test.equal(saves[1].params.textDocument.uri, uri.path_to_uri(doc.abs_filename))
    test.equal(saves[1].params.text, "abc\n")
    test.ok(doc.crlf)
  end)

  test.test("sends didClose and removes state on document close", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    documents.attach(client, doc, { language_id = "cpp" })

    doc:on_close()
    local closes = messages(client, "textDocument/didClose")
    test.equal(#closes, 1)
    test.is_nil(documents.state(client, doc))
  end)

  test.test("does not sync unsupported documents", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "README.md"), "abc"))
    local client = fake_client(nil)
    client.language_id = nil
    local state = test.not_nil(documents.attach(client, doc, { supported = false }))

    test.equal(state.disabled_reason, "unsupported")
    test.equal(#client.sent, 0)
    doc:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    documents.flush(client, doc)
    test.equal(#client.sent, 0)
  end)

  test.test("does not open too-large documents and closes if a synced doc grows too large", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "abcdef"))
    local client = fake_client("cpp")
    local state = test.not_nil(documents.attach(client, doc, {
      language_id = "cpp",
      max_file_bytes = 4,
    }))
    test.equal(state.disabled_reason, "too_large")
    test.equal(#client.sent, 0)

    local small = track_doc(context, new_doc(join_path(temp_root, "small.cpp"), "abc"))
    local small_state = test.not_nil(documents.attach(client, small, {
      language_id = "cpp",
      max_file_bytes = 6,
    }))
    test.equal(#messages(client, "textDocument/didOpen"), 1)
    small:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "defgh" } })
    documents.flush(client, small)
    test.equal(small_state.disabled_reason, "too_large")
    test.equal(#messages(client, "textDocument/didChange"), 0)
    test.equal(#messages(client, "textDocument/didClose"), 1)
  end)

  test.test("uses one DocumentState per client and URI", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "abc"))
    local a = fake_client("cpp")
    local b = fake_client("cpp")
    local state_a = test.not_nil(documents.attach(a, doc, { language_id = "cpp" }))
    local state_b = test.not_nil(documents.attach(b, doc, { language_id = "cpp" }))

    test.not_equal(state_a, state_b)
    test.equal(documents.attach(a, doc, { language_id = "cpp" }), state_a)
    test.equal(#messages(a, "textDocument/didOpen"), 1)
    test.equal(#messages(b, "textDocument/didOpen"), 1)
  end)

  test.test("filename updates close old URI and open new URI centrally", function(context)
    local old_path = join_path(temp_root, "old.cpp")
    local new_path = join_path(temp_root, "new.cpp")
    local doc = track_doc(context, new_doc(old_path, "abc"))
    local client = fake_client("cpp")
    documents.attach(client, doc, { language_id = "cpp" })

    doc:set_filename(new_path, new_path)
    local opens = messages(client, "textDocument/didOpen")
    local closes = messages(client, "textDocument/didClose")
    test.equal(#closes, 1)
    test.equal(closes[1].params.textDocument.uri, uri.path_to_uri(old_path))
    test.equal(#opens, 2)
    test.equal(opens[2].params.textDocument.uri, uri.path_to_uri(new_path))
    test.not_nil(documents.state(client, uri.path_to_uri(new_path)))
  end)
end)
