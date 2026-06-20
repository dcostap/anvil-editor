local common = require "core.common"
local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local test = require "core.test"
local diagnostic_hints = require "core.lsp.diagnostic_hints"
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

local function fake_client(id)
  return {
    server_id = id or "fake-diagnostic-hints",
    position_encoding = "utf-16",
    notifications = {},
    on_notification = function(self, method, handler)
      self.notifications[method] = handler
    end,
    send_notification = function()
      return true
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

test.describe("LSP diagnostic Line Hints", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-diagnostic-hints-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    context.original_active_view = core.active_view
    mkdir(temp_root)
  end)

  test.after_each(function(context)
    core.active_view = context.original_active_view
    if context.original_style_warn then style.warn = context.original_style_warn end
    if context.docs then
      for _, doc in ipairs(context.docs) do pcall(function() doc:on_close() end) end
    end
    if context.clients then
      for _, client in ipairs(context.clients) do diagnostics.clear_client(client) end
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

  local function track_client(context, client)
    context.clients = context.clients or {}
    context.clients[#context.clients + 1] = client
    return client
  end

  local function setup(context)
    local path = join_path(temp_root, "main.cpp")
    local doc = track_doc(context, new_doc(path, "first\nsecond\nthird"))
    local client = track_client(context, fake_client())
    documents.attach(client, doc, { language_id = "cpp" })
    diagnostics.attach_client(client)
    return doc, client, uri.path_to_uri(path)
  end

  test.it("shows current error and warning diagnostics as line hints", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 2, message = "warning loses" },
        { range = lsp_range(0, 2, 0, 5), severity = 1, message = "error wins" },
        { range = lsp_range(1, 0, 1, 6), severity = 2, message = "warning shown" },
        { range = lsp_range(2, 0, 2, 5), severity = 3, message = "info hidden" },
        { range = lsp_range(2, 1, 2, 5), severity = 4, message = "hint hidden" },
      },
    })

    local view = DocView(doc)
    local error_hint = view:get_line_hint(1)
    test.equal(error_hint.text, "error wins")
    test.equal(error_hint.color, style.error)

    local warning_hint = view:get_line_hint(2)
    test.equal(warning_hint.text, "warning shown")
    test.equal(warning_hint.color, style.warn)

    test.is_nil(view:get_line_hint(3))
  end)

  test.it("uses the earliest diagnostic when severities tie", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 3, 0, 5), severity = 2, message = "later warning" },
        { range = lsp_range(0, 0, 0, 2), severity = 2, message = "earlier warning" },
      },
    })

    local view = DocView(doc)
    local hint = view:get_line_hint(1)
    test.equal(hint.text, "earlier warning")
    test.equal(hint.color, style.warn)
  end)

  test.it("keeps stale-tracked hints visible when document sync makes diagnostics stale", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "stale error" },
      },
    })

    local view = DocView(doc)
    test.equal(view:get_line_hint(1).text, "stale error")

    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "new " } })
    test.equal(view:get_line_hint(1).text, "stale error")
    documents.flush(client, doc)

    test.equal(view:get_line_hint(1).text, "stale error")
  end)

  test.it("shifts stale-tracked hints to the original diagnostic line when inserting newline at diagnostic start", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), severity = 1, message = "moves down" },
      },
    })

    local view = DocView(doc)
    doc:insert(2, 1, "\n")

    test.is_nil(view:get_line_hint(2))
    test.equal(view:get_line_hint(3).text, "moves down")
  end)

  test.it("preserves hints through broad replacements that keep diagnostic text", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), severity = 1, message = "preserved" },
      },
    })

    local view = DocView(doc)
    doc:apply_edits({
      { line1 = 1, col1 = 1, line2 = 3, col2 = #doc.lines[3], text = "zero\nfirst\nsecond\nthird\n" },
    })

    test.is_nil(view:get_line_hint(2))
    test.equal(view:get_line_hint(3).text, "preserved")
  end)

  test.it("shifts stale-tracked hints when inserting lines before diagnostics", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), severity = 1, message = "moves down" },
      },
    })

    local view = DocView(doc)
    test.is_nil(view:get_line_hint(1))
    test.equal(view:get_line_hint(2).text, "moves down")

    doc:insert(1, 1, "inserted\n")
    test.is_nil(view:get_line_hint(2))
    test.equal(view:get_line_hint(3).text, "moves down")

    documents.flush(client, doc)
    test.equal(view:get_line_hint(3).text, "moves down")
  end)

  test.it("resolves hint colors at read time", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 2, message = "theme warning" },
      },
    })

    local view = DocView(doc)
    context.original_style_warn = style.warn
    local replacement = { 1, 2, 3, 255 }
    test.equal(view:get_line_hint(1).color, context.original_style_warn)
    style.warn = replacement
    test.equal(view:get_line_hint(1).color, replacement)
  end)

  test.it("draws wrapped line hints on the last wrapped visual row", function(context)
    diagnostic_hints.install()
    require "plugins.linewrapping"

    local doc = track_doc(context, new_doc(join_path(temp_root, "wrapped.cpp"), "abcdefghi"))
    local view = DocView(doc)
    view.wrapped_settings = {}
    view.wrapped_lines = { 1, 1, 1, 6 }
    view.wrapped_line_to_idx = { [1] = 1, [2] = 3 }
    view.wrapped_line_offsets = { 0 }
    view.draw_line_text = function(self)
      return self:get_line_height() * 2
    end

    local calls = {}
    view.draw_line_hint = function(_, line, x, y)
      calls[#calls + 1] = { line = line, x = x, y = y }
    end

    local x, y = 100, 200
    local lh = view:get_line_height()
    view:draw_line_body(1, x, y)

    test.equal(#calls, 1)
    test.equal(calls[1].line, 1)
    test.equal(calls[1].x, x)
    test.equal(calls[1].y, y + lh)
  end)
end)
