local common = require "core.common"
local Buffer = require "core.buffer"
local test = require "core.test"
local client_module = require "core.lsp.client"
local diagnostic_markers = require "core.lsp.diagnostic_markers"
local diagnostics = require "core.lsp.diagnostics"
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

local function fake_client(id)
  return {
    server_id = id or "fake-server",
    position_encoding = "utf-16",
    notifications = {},
    sent = {},
    on_notification = function(self, method, handler)
      self.notifications[method] = handler
    end,
    send_notification = function(self, method, params)
      self.sent[#self.sent + 1] = { method = method, params = params }
      return true
    end,
  }
end

local function publish(client, params)
  local handler = client.notifications["textDocument/publishDiagnostics"]
  test.not_nil(handler, "diagnostics client was not attached")
  return handler(params)
end

local function range(sl, sc, el, ec)
  return {
    start = { line = sl, character = sc },
    ["end"] = { line = el, character = ec },
  }
end

test.describe("core.lsp.diagnostics", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-diagnostics-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    mkdir(temp_root)
  end)

  test.after_each(function(context)
    if context.buffers then
      for _, buffer in ipairs(context.buffers) do pcall(function() buffer:on_close() end) end
    end
    if context.clients then
      for _, client in ipairs(context.clients) do diagnostics.clear_client(client) end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function track_client(context, client)
    context.clients = context.clients or {}
    context.clients[#context.clients + 1] = client
    return client
  end

  local function track_buffer(context, buffer)
    context.buffers = context.buffers or {}
    context.buffers[#context.buffers + 1] = buffer
    return buffer
  end

  test.test("stores unopened-file diagnostics with raw ranges and metadata", function(context)
    local client = track_client(context, fake_client("fake-a"))
    diagnostics.attach_client(client)
    local path = join_path(temp_root, "unopened.cpp")
    local buffer_uri = uri.path_to_uri(path)
    publish(client, {
      textDocument = { uri = buffer_uri, version = 5 },
      diagnostics = {
        {
          range = range(0, 1, 0, 3),
          severity = 1,
          code = "E001",
          codeDescription = { href = "https://example.test/E001" },
          source = "fake",
          message = "boom",
          tags = { 1 },
          relatedInformation = {
            { location = { uri = buffer_uri, range = range(0, 0, 0, 1) }, message = "related" },
          },
          data = { token = "opaque" },
        },
      },
    })

    local items, entry = diagnostics.get(client, buffer_uri)
    test.equal(entry.version, 5)
    test.equal(#items, 1)
    local item = items[1]
    test.equal(item.uri, buffer_uri)
    test.equal(item.path, common.normalize_path(path))
    test.same(item.lsp_range, range(0, 1, 0, 3))
    test.equal(item.severity, 1)
    test.equal(item.code, "E001")
    test.equal(item.codeDescription.href, "https://example.test/E001")
    test.equal(item.code_description.href, "https://example.test/E001")
    test.equal(item.source, "fake")
    test.equal(item.message, "boom")
    test.equal(item.tags[1], 1)
    test.equal(item.relatedInformation[1].message, "related")
    test.equal(item.related_information[1].message, "related")
    test.equal(item.data.token, "opaque")
    test.equal(item.server_id, "fake-a")
    test.equal(item.version, 5)
    test.type(item.received_at, "number")
    test.not_ok(item.stale)
    test.ok(item.current)
    test.is_nil(item.buffer_range)
  end)

  test.test("lazily converts LSP ranges to Anvil buffer byte ranges for open buffers", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "a😀b"))
    local client = track_client(context, fake_client("fake-b"))
    documents.attach(client, buffer, { language_id = "cpp" })
    diagnostics.attach_client(client)

    publish(client, {
      textDocument = { uri = uri.path_to_uri(path), version = 0 },
      diagnostics = { { range = range(0, 1, 0, 3), message = "emoji", severity = 2 } },
    })

    local item = diagnostics.get(client, buffer)[1]
    test.is_nil(item.buffer_range)
    local buffer_range = diagnostics.buffer_range(item, buffer)
    test.equal(buffer_range.line1, 1)
    test.equal(buffer_range.col1, 2)
    test.equal(buffer_range.line2, 1)
    test.equal(buffer_range.col2, 6)
    test.equal(item.buffer_range, buffer_range)
  end)

  test.test("normalizes encoded drive-letter publish URIs to the open buffer URI", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "int main() {}"))
    local client = track_client(context, fake_client("fake-uri"))
    documents.attach(client, buffer, { language_id = "cpp" })
    diagnostics.attach_client(client)

    local buffer_uri = uri.path_to_uri(path)
    local encoded_drive_uri = buffer_uri:gsub("^file:///(%a):", "file:///%1%%3A")
    publish(client, {
      textDocument = { uri = encoded_drive_uri },
      diagnostics = { { range = range(0, 4, 0, 8), severity = 1, message = "encoded" } },
    })

    local items = diagnostics.current_for_buffer(buffer)
    test.equal(#items, 1)
    test.equal(items[1].uri, buffer_uri)
    test.equal(#diagnostic_markers.visual_buffer_items(buffer), 1)
  end)

  test.test("marks versioned diagnostics stale against synced buffer versions", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "abc"))
    local client = track_client(context, fake_client("fake-c"))
    local state = documents.attach(client, buffer, { language_id = "cpp" })
    diagnostics.attach_client(client)

    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    documents.flush(client, buffer)
    test.equal(state.lsp_version, 1)

    publish(client, {
      textDocument = { uri = uri.path_to_uri(path), version = 0 },
      diagnostics = { { range = range(0, 0, 0, 1), message = "old" } },
    })
    local old = diagnostics.get(client, buffer)[1]
    test.ok(old.stale)
    test.not_ok(old.current)
    test.equal(#diagnostics.current(client, buffer), 0)

    publish(client, {
      textDocument = { uri = uri.path_to_uri(path), version = nil },
      diagnostics = { { range = range(0, 0, 0, 1), message = "unversioned" } },
    })
    local unversioned = diagnostics.get(client, buffer)[1]
    test.not_ok(unversioned.stale)
    test.ok(unversioned.current)
  end)

  test.test("recomputes stale state for local edits before and after buffer sync advances", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "abc"))
    local client = track_client(context, fake_client("fake-d"))
    documents.attach(client, buffer, { language_id = "cpp" })
    diagnostics.attach_client(client)

    publish(client, {
      textDocument = { uri = uri.path_to_uri(path), version = 0 },
      diagnostics = { { range = range(0, 0, 0, 1), message = "current" } },
    })
    test.not_ok(diagnostics.get(client, buffer)[1].stale)

    buffer:apply_edits({ { line1 = 1, col1 = 4, line2 = 1, col2 = 4, text = "d" } })
    test.ok(diagnostics.get(client, buffer)[1].stale)
    test.equal(#diagnostics.current(client, buffer), 0)

    documents.flush(client, buffer)
    test.ok(diagnostics.get(client, buffer)[1].stale)
  end)

  test.test("replaces diagnostics per URI and clears on buffer close", function(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "abc"))
    local client = track_client(context, fake_client("fake-e"))
    documents.attach(client, buffer, { language_id = "cpp" })
    diagnostics.attach_client(client)

    publish(client, {
      textDocument = { uri = uri.path_to_uri(path), version = 0 },
      diagnostics = {
        { range = range(0, 0, 0, 1), message = "one" },
        { range = range(0, 1, 0, 2), message = "two" },
      },
    })
    test.equal(#diagnostics.get(client, buffer), 2)
    publish(client, {
      textDocument = { uri = uri.path_to_uri(path), version = 0 },
      diagnostics = { { range = range(0, 0, 0, 1), message = "replacement" } },
    })
    test.equal(#diagnostics.get(client, buffer), 1)

    buffer:on_close()
    test.equal(#diagnostics.get(client, uri.path_to_uri(path)), 0)
  end)

  test.test("clears diagnostics on client failure and exit cleanup", function(context)
    local client = track_client(context, client_module.new(nil))
    client.server_id = "fake-f"
    diagnostics.attach_client(client)
    local buffer_uri = uri.path_to_uri(join_path(temp_root, "main.cpp"))
    client.notification_handlers["textDocument/publishDiagnostics"]({
      textDocument = { uri = buffer_uri },
      diagnostics = { { range = range(0, 0, 0, 1), message = "boom" } },
    })
    test.equal(#diagnostics.get(client, buffer_uri), 1)
    client:_fail("test failure")
    test.equal(#diagnostics.get(client, buffer_uri), 0)

    local exiting = track_client(context, client_module.new(nil))
    exiting.server_id = "fake-g"
    diagnostics.attach_client(exiting)
    exiting.notification_handlers["textDocument/publishDiagnostics"]({
      textDocument = { uri = buffer_uri },
      diagnostics = { { range = range(0, 0, 0, 1), message = "boom" } },
    })
    test.equal(#diagnostics.get(exiting, buffer_uri), 1)
    diagnostics.clear_client(exiting)
    test.equal(#diagnostics.get(exiting, buffer_uri), 0)
  end)
end)
