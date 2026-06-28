local command = require "core.command"
local common = require "core.common"
local Doc = require "core.doc"
local DocView = require "core.docview"
local documents = require "core.lsp.documents"
local hover = require "core.lsp.hover"
local json = require "core.lsp.json"
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
    server_id = opts.server_id or "fake-hover-lsp",
    generation = opts.generation or 1,
    position_encoding = opts.position_encoding or "utf-16",
    capabilities = opts.capabilities or { hoverProvider = true },
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

local function saw_log_since(anchor, text)
  local start_index = 0
  if type(anchor) == "number" then
    start_index = anchor
  elseif anchor then
    for i = #core.log_items, 1, -1 do
      if core.log_items[i] == anchor then
        start_index = i
        break
      end
    end
  end
  for i = start_index + 1, #core.log_items do
    if core.log_items[i].text:find(text, 1, true) then return true end
  end
  return false
end

test.describe("core.lsp.hover", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-hover-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    context.original_active_view = core.active_view
    mkdir(temp_root)
    hover.clear()
  end)

  test.after_each(function(context)
    hover.clear()
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
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), opts and opts.text or "hover_target"))
    local client = fake_client(opts)
    documents.attach(client, doc, { language_id = "cpp" })
    return doc, client
  end

  test.test("normalizes Hover content forms", function(context)
    local doc, client = attach(context)
    test.equal(hover.map_result(client, doc, { contents = "plain" }).text, "plain")
    test.equal(hover.map_result(client, doc, { contents = { kind = "markdown", value = "**md**" } }).text, "**md**")
    test.equal(hover.map_result(client, doc, { contents = { language = "cpp", value = "int x;" } }).text, "```cpp\nint x;\n```")
    test.equal(hover.map_result(client, doc, { contents = { "one", { language = "c", value = "two" } } }).text, "one\n\n```c\ntwo\n```")
  end)

  test.test("maps nil and null hover results as empty", function(context)
    local doc, client = attach(context)
    test.ok(hover.map_result(client, doc, nil).empty)
    test.ok(hover.map_result(client, doc, json.null).empty)
  end)

  test.test("converts hover range when present", function(context)
    local doc, client = attach(context, { text = "abcd" })
    local mapped = hover.map_result(client, doc, {
      contents = "range",
      range = lsp_range(0, 1, 0, 3),
    })
    test.same({ mapped.range.line1, mapped.range.col1, mapped.range.line2, mapped.range.col2 }, { 1, 2, 1, 4 })
  end)

  test.test("manual command schedules textDocument/hover and logs on response", function(context)
    local doc, client = attach(context)
    local view = DocView(doc)
    core.active_view = view
    doc:set_selection(1, 3)
    local log_start = core.log_items[#core.log_items]

    test.ok(command.perform("lsp:hover-current-position", view))
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "textDocument/hover")
    test.equal(client.requests[1].params.position.line, 0)
    test.equal(client.requests[1].params.position.character, 2)

    complete_request(client, 1, { contents = { kind = "markdown", value = "hover docs" } })
    test.ok(saw_log_since(log_start, "LSP hover: hover docs"))
  end)

  test.test("fresh cached hover result is reused without another request", function(context)
    local doc, client = attach(context)
    doc:set_selection(1, 3)
    hover.request(doc, { show = false })
    complete_request(client, 1, { contents = "cached" })

    local mapped, _reason, status = hover.request(doc, { show = false })
    test.equal(status, "fresh")
    test.equal(mapped.text, "cached")
    test.equal(#client.requests, 1)
  end)

  test.test("stale version hover responses are discarded", function(context)
    local doc, client = attach(context)
    doc:set_selection(1, 3)
    hover.request(doc, { show = false })
    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "x" } })
    documents.flush(client, doc)
    complete_request(client, 1, { contents = "old" })

    hover.request(doc, { show = false })
    test.equal(#client.requests, 2)
  end)

  test.test("superseded hover response is cancelled and discarded", function(context)
    local doc, client = attach(context, { text = "abc def" })
    doc:set_selection(1, 3)
    hover.request(doc, { show = false })
    doc:set_selection(1, 7)
    hover.request(doc, { show = false })
    test.equal(#client.requests, 2)
    test.equal(client.sent[#client.sent].method, "$/cancelRequest")

    complete_request(client, 1, { contents = "old" })
    doc:set_selection(1, 3)
    local mapped, _reason, status = hover.request(doc, { show = false })
    test.not_equal(status, "fresh")
    test.is_nil(mapped)
    test.equal(#client.requests, 3)
  end)

  test.test("no hover server is a quiet no-op", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "hover_target"))
    local view = DocView(doc)
    core.active_view = view
    doc:set_selection(1, 3)

    test.ok(command.perform("lsp:hover-current-position", view))
  end)
end)
