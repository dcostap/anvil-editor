local command = require "core.command"
local common = require "core.common"
local Buffer = require "core.buffer"
local test = require "core.test"
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
    server_id = id or "fake-diagnostics-ui",
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

local function fake_view(buffer)
  return {
    buffer = buffer,
    scrolled = {},
    with_selection_state = function(_self, fn, ...)
      return fn(...)
    end,
    scroll_to_make_visible = function(self, line, col)
      self.scrolled[#self.scrolled + 1] = { line = line, col = col }
    end,
  }
end

local function lsp_range(sl, sc, el, ec)
  return {
    start = { line = sl, character = sc },
    ["end"] = { line = el, character = ec },
  }
end

local function publish(client, params)
  local handler = client.notifications["textDocument/publishDiagnostics"]
  test.not_nil(handler)
  handler(params)
end

local function selection4(buffer)
  local line1, col1, line2, col2 = buffer:get_selection(true)
  return { line1, col1, line2, col2 }
end

test.describe("core.lsp.diagnostics UI/navigation helpers", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-diagnostics-ui-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    context.original_active_view = core.active_view
    mkdir(temp_root)
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
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

  local function track_buffer(context, buffer)
    context.buffers = context.buffers or {}
    context.buffers[#context.buffers + 1] = buffer
    return buffer
  end

  local function track_client(context, client)
    context.clients = context.clients or {}
    context.clients[#context.clients + 1] = client
    return client
  end

  local function setup(context)
    local path = join_path(temp_root, "main.cpp")
    local buffer = track_buffer(context, new_buffer(path, "first\nsecond\nthird"))
    local client = track_client(context, fake_client())
    documents.attach(client, buffer, { language_id = "cpp" })
    diagnostics.attach_client(client)
    return buffer, client, uri.path_to_uri(path)
  end

  test.test("next and previous diagnostic commands navigate same-buffer current diagnostics", function(context)
    local buffer, client, buffer_uri = setup(context)
    local view = fake_view(buffer)
    publish(client, {
      textDocument = { uri = buffer_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), message = "second" },
        { range = lsp_range(2, 0, 2, 5), message = "third" },
      },
    })

    buffer:set_selection(1, 1)
    test.ok(command.perform("lsp:next-diagnostic", view))
    test.same(selection4(buffer), { 2, 1, 2, 7 })
    test.equal(view.scrolled[1].line, 2)

    test.ok(command.perform("lsp:next-diagnostic", view))
    test.same(selection4(buffer), { 3, 1, 3, 6 })

    test.ok(command.perform("lsp:previous-diagnostic", view))
    test.same(selection4(buffer), { 2, 1, 2, 7 })
  end)

  test.test("no-diagnostic command is a no-op", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "first"))
    local view = fake_view(buffer)
    buffer:set_selection(1, 2)

    test.ok(command.perform("lsp:next-diagnostic", view))
    test.same(selection4(buffer), { 1, 2, 1, 2 })
    test.equal(#view.scrolled, 0)
  end)

  test.test("stale diagnostics are hidden from navigation immediately after local edits", function(context)
    local buffer, client, buffer_uri = setup(context)
    local view = fake_view(buffer)
    publish(client, {
      textDocument = { uri = buffer_uri, version = 0 },
      diagnostics = { { range = lsp_range(0, 0, 0, 5), message = "old" } },
    })
    buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "new " } })

    buffer:set_selection(1, 1)
    test.ok(command.perform("lsp:next-diagnostic", view))
    test.same(selection4(buffer), { 1, 1, 1, 1 })

    documents.flush(client, buffer)
    test.ok(command.perform("lsp:next-diagnostic", view))
    test.same(selection4(buffer), { 1, 1, 1, 1 })
  end)

  test.test("cross-file diagnostics are ignored by current-buffer navigation", function(context)
    local buffer, client = setup(context)
    local view = fake_view(buffer)
    local other_uri = uri.path_to_uri(join_path(temp_root, "other.cpp"))
    publish(client, {
      textDocument = { uri = other_uri, version = nil },
      diagnostics = { { range = lsp_range(0, 0, 0, 5), message = "other" } },
    })

    buffer:set_selection(1, 1)
    test.ok(command.perform("lsp:next-diagnostic", view))
    test.same(selection4(buffer), { 1, 1, 1, 1 })
  end)

  test.test("summary reports current diagnostics only", function(context)
    local buffer, client, buffer_uri = setup(context)
    publish(client, {
      textDocument = { uri = buffer_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "one" },
        { range = lsp_range(1, 0, 1, 6), severity = 2, message = "two" },
      },
    })
    local summary, counts = diagnostics.summary(buffer)
    test.equal(summary, "2 current LSP diagnostics")
    test.equal(counts[1], 1)
    test.equal(counts[2], 1)

    buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "new " } })
    documents.flush(client, buffer)
    summary = diagnostics.summary(buffer)
    test.equal(summary, "No current LSP diagnostics")
  end)
end)
