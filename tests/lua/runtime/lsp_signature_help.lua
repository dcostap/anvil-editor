local common = require "core.common"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local documents = require "core.lsp.documents"
local json = require "core.lsp.json"
local signature_help = require "core.lsp.signature_help"
local test = require "core.test"

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

local function fake_client(opts)
  opts = opts or {}
  return {
    server_id = opts.server_id or "fake-signature-lsp",
    generation = opts.generation or 1,
    position_encoding = opts.position_encoding or "utf-16",
    capabilities = opts.capabilities or {
      signatureHelpProvider = {
        triggerCharacters = { "(", "," },
        retriggerCharacters = { "," },
      },
    },
    sent = {},
    requests = {},
    send_notification = function(self, method, params)
      self.sent[#self.sent + 1] = { method = method, params = params }
      return true
    end,
    send_request = function(self, method, params, callback, request_opts)
      local id = #self.requests + 1
      self.requests[#self.requests + 1] = {
        id = id,
        method = method,
        params = params,
        callback = callback,
        opts = request_opts,
      }
      return id
    end,
  }
end

local function complete_request(client, index, result, err)
  local request = test.not_nil(client.requests[index])
  request.callback(result, err)
end

local function saw_log_since(start_index, text)
  local first = start_index + 1
  if first > #core.log_items then
    first = math.max(1, #core.log_items - 5)
  end
  for i = first, #core.log_items do
    if core.log_items[i].text:find(text, 1, true) then return true end
  end
  return false
end

test.describe("core.lsp.signature_help", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-signature-help-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    context.original_active_view = core.active_view
    mkdir(temp_root)
    signature_help.clear()
  end)

  test.after_each(function(context)
    signature_help.clear()
    core.active_view = context.original_active_view
    if context.buffers then
      for _, buffer in ipairs(context.buffers) do pcall(function() buffer:on_close() end) end
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

  local function attach(context, opts)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), opts and opts.text or "fn(a, b)"))
    local client = fake_client(opts)
    documents.attach(client, buffer, { language_id = "cpp" })
    return buffer, client
  end

  test.test("normalizes SignatureHelp signatures parameters and active indices", function(context)
    local buffer, client = attach(context)
    local mapped = signature_help.map_result(client, buffer, {
      activeSignature = 0,
      activeParameter = 1,
      signatures = {
        {
          label = "fn(int a, float b)",
          documentation = { kind = "markdown", value = "buffers" },
          parameters = {
            { label = { 3, 8 }, documentation = "first" },
            { label = "float b", documentation = { value = "second" } },
          },
        },
      },
    })
    test.not_ok(mapped.empty)
    test.equal(mapped.active_signature, 1)
    test.equal(mapped.active_parameter, 2)
    test.equal(mapped.signatures[1].documentation, "buffers")
    test.equal(mapped.signatures[1].parameters[1].label, "int a")
    test.equal(mapped.signatures[1].parameters[2].documentation, "second")
    test.ok(mapped.signatures[1].parameters[2].active)
  end)

  test.test("nil null and empty signature help results are empty", function(context)
    local buffer, client = attach(context)
    test.ok(signature_help.map_result(client, buffer, nil).empty)
    test.ok(signature_help.map_result(client, buffer, json.null).empty)
    test.ok(signature_help.map_result(client, buffer, { signatures = {} }).empty)
  end)

  test.test("formats active signature and parameter for log UI", function(context)
    local buffer, client = attach(context)
    local mapped = signature_help.map_result(client, buffer, {
      activeSignature = 0,
      activeParameter = 0,
      signatures = {
        {
          label = "fn(int a)",
          documentation = "buffers",
          parameters = { { label = "int a", documentation = "first" } },
        },
      },
    })
    local text = signature_help.format(mapped)
    test.contains(text, "fn(int a)")
    test.contains(text, "buffers")
    test.contains(text, "Parameter: int a")
  end)

  test.test("manual request schedules textDocument/signatureHelp and logs on response", function(context)
    local buffer, client = attach(context)
    local view = TextView(buffer)
    core.active_view = view
    buffer:set_selection(1, 4)
    local log_start = #core.log_items

    signature_help.start_current_position(view)
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "textDocument/signatureHelp")
    test.equal(client.requests[1].params.position.line, 0)
    test.equal(client.requests[1].params.position.character, 3)
    test.equal(client.requests[1].params.context.triggerKind, 1)

    complete_request(client, 1, {
      activeSignature = 0,
      activeParameter = 0,
      signatures = { { label = "fn(int a)", parameters = { { label = "int a" } } } },
    })
    test.ok(saw_log_since(log_start, "LSP signature help: fn(int a)"))
  end)

  test.test("explicit trigger context is represented when requested", function(context)
    local buffer, client = attach(context)
    buffer:set_selection(1, 4)
    signature_help.request(buffer, { show = false, trigger_character = "(", trigger_kind = 2 })
    test.equal(client.requests[1].params.context.triggerKind, 2)
    test.equal(client.requests[1].params.context.triggerCharacter, "(")
  end)

  test.test("fresh cached signature help result is reused without another request", function(context)
    local buffer, client = attach(context)
    buffer:set_selection(1, 4)
    signature_help.request(buffer, { show = false })
    complete_request(client, 1, { signatures = { { label = "cached()" } } })

    local mapped, _reason, status = signature_help.request(buffer, { show = false })
    test.equal(status, "fresh")
    test.equal(mapped.signatures[1].label, "cached()")
    test.equal(#client.requests, 1)
  end)

  test.test("stale version signature-help responses are discarded", function(context)
    local buffer, client = attach(context)
    buffer:set_selection(1, 4)
    signature_help.request(buffer, { show = false })
    buffer:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "x" } })
    documents.flush(client, buffer)
    complete_request(client, 1, { signatures = { { label = "old()" } } })

    signature_help.request(buffer, { show = false })
    test.equal(#client.requests, 2)
  end)

  test.test("superseded signature-help response is cancelled and discarded", function(context)
    local buffer, client = attach(context, { text = "abc def" })
    buffer:set_selection(1, 3)
    signature_help.request(buffer, { show = false })
    buffer:set_selection(1, 7)
    signature_help.request(buffer, { show = false })
    test.equal(#client.requests, 2)
    test.equal(client.sent[#client.sent].method, "$/cancelRequest")

    complete_request(client, 1, { signatures = { { label = "old()" } } })
    buffer:set_selection(1, 3)
    local mapped, _reason, status = signature_help.request(buffer, { show = false })
    test.not_equal(status, "fresh")
    test.is_nil(mapped)
    test.equal(#client.requests, 3)
  end)

  test.test("no signature-help server is a quiet unavailable result", function(context)
    local buffer = track_buffer(context, new_buffer(join_path(temp_root, "main.cpp"), "fn(a)"))
    local view = TextView(buffer)
    core.active_view = view
    buffer:set_selection(1, 4)

    local result, _, status = signature_help.start_current_position(view)
    test.is_nil(result)
    test.equal(status, "unavailable")
  end)
end)
