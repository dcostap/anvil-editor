local common = require "core.common"
local Buffer = require "core.buffer"
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

local function new_buffer(path, text)
  local buffer = Buffer()
  set_text(buffer, text or "")
  buffer:set_filename(path, path)
  return buffer
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
    if context.buffers then
      for _, buffer in ipairs(context.buffers) do
        pcall(function() buffer:on_close() end)
      end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function track_buffer(context, buffer)
    context.buffers = context.buffers or {}
    context.buffers[#context.buffers + 1] = buffer
    return buffer
  end

  test.test("sends didOpen with LF-normalized full text", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "int main() {\n  return 0;\n}"))
    buffer.crlf = true
    local client = fake_client("cpp")

    local state = test.not_nil(documents.attach(client, buffer, { language_id = "cpp" }))
    test.equal(state.lsp_version, 0)
    local opens = messages(client, "textDocument/didOpen")
    test.equal(#opens, 1)
    test.equal(opens[1].params.textDocument.uri, uri.path_to_uri(path))
    test.equal(opens[1].params.textDocument.languageId, "cpp")
    test.equal(opens[1].params.textDocument.version, 0)
    test.equal(opens[1].params.textDocument.text, "int main() {\n  return 0;\n}\n")
  end)

  test.test("debounces full didChange and increments LSP versions", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    local state = test.not_nil(documents.attach(client, buffer, {
      language_id = "cpp",
      debounce_seconds = 10,
    }))

    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    test.ok(state.pending_full_sync)
    test.equal(#messages(client, "textDocument/didChange"), 0)
    documents.update(system.get_time() + 1)
    test.equal(#messages(client, "textDocument/didChange"), 0)

    documents.flush_before_request(client, buffer)
    local changes = messages(client, "textDocument/didChange")
    test.equal(#changes, 1)
    test.equal(changes[1].params.textDocument.version, 1)
    test.equal(changes[1].params.contentChanges[1].text, "abcd\n")
    test.equal(state.lsp_version, 1)

    buffer:apply_edits({ { line1 = 1, col1 = 5, line2 = 1, col2 = 5, text = "e" } })
    state.pending_due_at = system.get_time() - 1
    documents.update()
    changes = messages(client, "textDocument/didChange")
    test.equal(#changes, 2)
    test.equal(changes[2].params.textDocument.version, 2)
    test.equal(changes[2].params.contentChanges[1].text, "abcde\n")
  end)

  test.test("tracks snapshots and current/stale metadata", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    local state = test.not_nil(documents.attach(client, buffer, { language_id = "cpp" }))
    local open_change_id = buffer:get_change_id()
    test.ok(documents.is_current(state, 0, open_change_id))
    test.not_nil(documents.snapshot_for_version(state, 0))
    test.not_nil(documents.snapshot_for_change_id(state, open_change_id))

    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    documents.flush(client, buffer)
    test.ok(documents.is_current(state, 1, buffer:get_change_id()))
    test.not_ok(documents.is_current(state, 0, buffer:get_change_id()))
    test.not_nil(documents.snapshot_for_version(state, 1))
  end)

  test.test("sends didSave helper without affecting CRLF save state", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    buffer.crlf = true
    local client = fake_client("cpp")
    documents.attach(client, buffer, { language_id = "cpp", include_save_text = true })

    test.ok(documents.did_save(client, buffer))
    local saves = messages(client, "textDocument/didSave")
    test.equal(#saves, 1)
    test.equal(saves[1].params.textDocument.uri, uri.path_to_uri(buffer.abs_filename))
    test.equal(saves[1].params.text, "abc\n")
    test.ok(buffer.crlf)
  end)

  test.test("uses server save includeText capability by default", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    client.capabilities = { textDocumentSync = { save = { includeText = true } } }
    documents.attach(client, buffer, { language_id = "cpp" })

    test.ok(documents.did_save(client, buffer))
    local saves = messages(client, "textDocument/didSave")
    test.equal(#saves, 1)
    test.equal(saves[1].params.text, "abc\n")
  end)

  test.test("does not send didSave when server did not advertise save support", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    client.capabilities = { textDocumentSync = { change = 2 } }
    documents.attach(client, buffer, { language_id = "cpp", did_save_after_open = true })

    test.ok(documents.did_save(client, buffer))
    test.equal(#messages(client, "textDocument/didOpen"), 1)
    test.equal(#messages(client, "textDocument/didSave"), 0)
  end)

  test.test("can send didSave immediately after didOpen for save-triggered diagnostics", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    client.capabilities = { textDocumentSync = { save = { includeText = true } } }
    documents.attach(client, buffer, { language_id = "cpp", did_save_after_open = true })

    local opens = messages(client, "textDocument/didOpen")
    local saves = messages(client, "textDocument/didSave")
    test.equal(#opens, 1)
    test.equal(#saves, 1)
    test.equal(saves[1].params.text, "abc\n")
  end)

  test.test("skips didSave-after-open for dirty buffers", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    local client = fake_client("cpp")
    client.capabilities = { textDocumentSync = { save = { includeText = true } } }
    documents.attach(client, buffer, { language_id = "cpp", did_save_after_open = true })

    test.equal(#messages(client, "textDocument/didOpen"), 1)
    test.equal(#messages(client, "textDocument/didSave"), 0)
  end)

  test.test("Buffer:save flushes pending changes and sends didSave", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "abc"))
    local client = fake_client("cpp")
    client.capabilities = { textDocumentSync = { save = { includeText = true } } }
    documents.attach(client, buffer, { language_id = "cpp", debounce_seconds = 10 })

    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    buffer:save()

    local changes = messages(client, "textDocument/didChange")
    local saves = messages(client, "textDocument/didSave")
    test.equal(#changes, 1)
    test.equal(changes[1].params.contentChanges[1].text, "abcd\n")
    test.equal(#saves, 1)
    test.equal(saves[1].params.textDocument.uri, uri.path_to_uri(path))
    test.equal(saves[1].params.text, "abcd\n")
  end)

  test.test("sends didClose, removes state, and runs centralized close handlers", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local client = fake_client("cpp")
    documents.attach(client, buffer, { language_id = "cpp" })
    local closed_buffer
    documents.register_buffer_close_handler("test-close-handler", function(closing_buffer)
      closed_buffer = closing_buffer
    end)

    buffer:on_close()
    documents.unregister_buffer_close_handler("test-close-handler")
    local closes = messages(client, "textDocument/didClose")
    test.equal(#closes, 1)
    test.is_nil(documents.state(client, buffer))
    test.equal(closed_buffer, buffer)
  end)

  test.test("does not sync unsupported documents", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "README.md"), "abc"))
    local client = fake_client(nil)
    client.language_id = nil
    local state = test.not_nil(documents.attach(client, buffer, { supported = false }))

    test.equal(state.disabled_reason, "unsupported")
    test.equal(#client.sent, 0)
    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    documents.flush(client, buffer)
    test.equal(#client.sent, 0)
  end)

  test.test("does not open too-large documents and closes if a synced buffer grows too large", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abcdef"))
    local client = fake_client("cpp")
    local state = test.not_nil(documents.attach(client, buffer, {
      language_id = "cpp",
      max_file_bytes = 4,
    }))
    test.equal(state.disabled_reason, "too_large")
    test.equal(#client.sent, 0)

    local small = track_buffer(context, new_buffer(join_path(temp_root, "small.cpp"), "abc"))
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
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "abc"))
    local a = fake_client("cpp")
    local b = fake_client("cpp")
    local state_a = test.not_nil(documents.attach(a, buffer, { language_id = "cpp" }))
    local state_b = test.not_nil(documents.attach(b, buffer, { language_id = "cpp" }))

    test.not_equal(state_a, state_b)
    test.equal(documents.attach(a, buffer, { language_id = "cpp" }), state_a)
    test.equal(#messages(a, "textDocument/didOpen"), 1)
    test.equal(#messages(b, "textDocument/didOpen"), 1)
  end)

  test.test("filename updates close old URI and open new URI centrally", function(context)
    local old_path = join_path(temp_root, "old.cpp")
    local new_path = join_path(temp_root, "new.cpp")
    local buffer = track_buffer(context, new_buffer(old_path, "abc"))
    local client = fake_client("cpp")
    documents.attach(client, buffer, { language_id = "cpp" })

    buffer:set_filename(new_path, new_path)
    local opens = messages(client, "textDocument/didOpen")
    local closes = messages(client, "textDocument/didClose")
    test.equal(#closes, 1)
    test.equal(closes[1].params.textDocument.uri, uri.path_to_uri(old_path))
    test.equal(#opens, 2)
    test.equal(opens[2].params.textDocument.uri, uri.path_to_uri(new_path))
    test.not_nil(documents.state(client, uri.path_to_uri(new_path)))
  end)
end)
