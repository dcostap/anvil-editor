local command = require "core.command"
local common = require "core.common"
local Doc = require "core.doc"
local DocView = require "core.docview"
local autocomplete = require "plugins.autocomplete"
local completion = require "core.lsp.completion"
local documents = require "core.lsp.documents"
local test = require "core.test"

require "core.commands.lsp"

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

local function fake_client(opts)
  opts = opts or {}
  return {
    server_id = opts.server_id or "fake-completion-lsp",
    generation = opts.generation or 1,
    position_encoding = opts.position_encoding or "utf-16",
    capabilities = opts.capabilities or {
      completionProvider = {
        triggerCharacters = { "." },
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

local function lsp_range(sl, sc, el, ec)
  return {
    start = { line = sl, character = sc },
    ["end"] = { line = el, character = ec },
  }
end

test.describe("core.lsp.completion", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-completion-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    context.original_active_view = core.active_view
    mkdir(temp_root)
    completion.clear()
    autocomplete.close()
  end)

  test.after_each(function(context)
    autocomplete.close()
    completion.clear()
    core.active_view = context.original_active_view
    if context.docs then
      for _, doc in ipairs(context.docs) do pcall(function() doc:on_close() end) end
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

  local function attach(context, opts)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), opts and opts.text or "foo"))
    local client = fake_client(opts)
    documents.attach(client, doc, { language_id = "cpp" })
    return doc, client
  end

  test.test("maps CompletionItem array responses", function(context)
    local doc, client = attach(context)
    local items, incomplete = completion.map_items(client, doc, {
      { label = "printf", kind = 3, detail = "int printf", documentation = "docs" },
      { label = "value", kind = 6 },
    })
    test.not_ok(incomplete)
    test.equal(#items, 2)
    test.equal(items[1].label, "printf")
    test.equal(items[1].info, "int printf")
    test.equal(items[1].desc, "docs")
    test.equal(items[2].info, "variable")
  end)

  test.test("maps CompletionList responses", function(context)
    local doc, client = attach(context)
    local items, incomplete = completion.map_items(client, doc, {
      isIncomplete = true,
      items = { { label = "member", insertText = "member()", kind = 2 } },
    })
    test.ok(incomplete)
    test.equal(items[1].label, "member")
    test.equal(items[1].text, "member")
    test.equal(items[1].insert_text, "member()")
    test.equal(items[1].info, "method")
  end)

  test.test("function-like completions display base labels without changing insertion text", function(context)
    local doc, client = attach(context)
    local items = completion.map_items(client, doc, {
      {
        label = "printf",
        kind = 3,
        detail = "int printf(const char *format, ...)",
        insertText = "printf",
      },
      {
        label = "push_back(const T &value)",
        kind = 2,
        labelDetails = { detail = "(const T &value)", description = "void" },
      },
    })
    test.equal(items[1].display_label, "printf")
    test.equal(items[1].text, "printf")
    test.equal(items[1].insert_text, "printf")
    test.equal(items[1].info, "int printf(const char *format, ...)")
    test.equal(items[2].display_label, "push_back")
    test.equal(items[2].info, "(const T &value) void")
  end)

  test.test("general autocomplete trigger schedules textDocument/completion and opens autocomplete on response", function(context)
    local doc, client = attach(context, { text = "pri" })
    local view = DocView(doc)
    core.active_view = view
    doc:set_selection(1, 4)

    test.ok(command.perform("autocomplete:trigger", view))
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "textDocument/completion")
    test.equal(client.requests[1].params.context.triggerKind, 1)
    test.not_ok(autocomplete.is_open())

    complete_request(client, 1, { items = { { label = "printf", insertText = "printf", kind = 3 } } })
    test.ok(autocomplete.is_open())
  end)

  test.test("fresh cached completion result is reused without another request", function(context)
    local doc, client = attach(context, { text = "pri" })
    doc:set_selection(1, 4)
    completion.request(doc, { show = false })
    complete_request(client, 1, { { label = "printf" } })

    local items, _reason, status = completion.request(doc, { show = false })
    test.equal(status, "fresh")
    test.equal(#items, 1)
    test.equal(#client.requests, 1)
  end)

  test.test("stale version completion responses are discarded", function(context)
    local doc, client = attach(context, { text = "pri" })
    doc:set_selection(1, 4)
    completion.request(doc, { show = false })
    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "x" } })
    documents.flush(client, doc)
    complete_request(client, 1, { { label = "printf" } })

    completion.request(doc, { show = false })
    test.equal(#client.requests, 2)
  end)

  test.test("superseded completion response is cancelled and discarded", function(context)
    local doc, client = attach(context, { text = "abc def" })
    doc:set_selection(1, 4)
    completion.request(doc, { show = false })
    doc:set_selection(1, 8)
    completion.request(doc, { show = false })
    test.equal(#client.requests, 2)
    test.equal(client.sent[#client.sent].method, "$/cancelRequest")

    complete_request(client, 1, { { label = "old" } })
    local items, _reason, status = completion.request(doc, { show = false })
    test.not_equal(status, "fresh")
    test.is_nil(items)
  end)

  test.test("textEdit completion applies server range and leaves cursor at insertion end", function(context)
    local doc, client = attach(context, { text = "pri" })
    local items = completion.map_items(client, doc, {
      {
        label = "printf",
        textEdit = {
          range = lsp_range(0, 0, 0, 3),
          newText = "printf",
        },
      },
    })
    test.ok(items[1].onselect())
    test.equal(doc:get_text(1, 1, 1, 7), "printf")
    test.same({ doc:get_selection() }, { 1, 7, 1, 7 })
  end)

  test.test("insertText completion replaces current partial conservatively", function(context)
    local doc, client = attach(context, { text = "pri" })
    local view = DocView(doc)
    core.active_view = view
    doc:set_selection(1, 4)
    local items = completion.map_items(client, doc, { { label = "printf", insertText = "printf" } })
    test.ok(items[1].onselect())
    test.equal(doc:get_text(1, 1, 1, 7), "printf")
  end)

  test.test("no completion server leaves existing behavior untouched", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "pri"))
    local view = DocView(doc)
    core.active_view = view
    doc:set_selection(1, 4)

    test.ok(command.perform("autocomplete:trigger", view))
    test.not_ok(autocomplete.is_open())
  end)
end)
