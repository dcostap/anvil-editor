local core = require "core"
local common = require "core.common"
local Doc = require "core.doc"
local documents = require "core.lsp.documents"
local provider = require "core.lsp.provider"
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
    server_id = opts.server_id or "fake-semantic-lsp",
    generation = opts.generation or 1,
    position_encoding = opts.position_encoding or "utf-16",
    capabilities = opts.capabilities or {
      semanticTokensProvider = {
        legend = {
          tokenTypes = { "function", "class", "variable" },
          tokenModifiers = { "readonly" },
        },
        full = true,
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

local function has_token(tokens, token_type, text)
  for i = 1, #(tokens or {}), 2 do
    if tokens[i] == token_type and tokens[i + 1] == text then return true end
  end
  return false
end

test.describe("core.lsp.provider semantic tokens", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-semantic-token-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    mkdir(temp_root)
    provider.clear()
  end)

  test.after_each(function(context)
    core.render_frame_active = false
    core.perf_frame_stats = nil
    provider.clear()
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
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), opts and opts.text or "int main = 1"))
    local client = fake_client(opts)
    documents.attach(client, doc, { language_id = "cpp" })
    provider.register_client(client)
    return doc, client
  end

  test.test("decodes LSP integer stream using legend and document positions", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "int main = 1"))
    local tokens = provider.decode_semantic_tokens(doc, { 0, 4, 4, 0, 0 }, {
      tokenTypes = { "function" },
      tokenModifiers = {},
    }, "utf-16")
    test.equal(#tokens, 1)
    test.equal(tokens[1].line1, 1)
    test.equal(tokens[1].col1, 5)
    test.equal(tokens[1].col2, 9)
    test.equal(tokens[1].style, "function")
  end)

  test.test("semantic token types preserve hierarchical customization keys", function()
    test.equal(provider.semantic_style("class"), "type.class")
    test.equal(provider.semantic_style("struct"), "type.struct")
    test.equal(provider.semantic_style("enum"), "type.enum")
    test.equal(provider.semantic_style("interface"), "type.interface")
    test.equal(provider.semantic_style("typeParameter"), "type.parameter")
    test.equal(provider.semantic_style("enumMember"), "constant.enum_member")
    test.equal(provider.semantic_style("property"), "variable.property")
    test.equal(provider.semantic_style("method"), "function.method")
    test.equal(provider.semantic_style("macro"), "function.macro")
    test.equal(provider.semantic_style("regexp"), "string.regexp")
    test.equal(provider.semantic_style("decorator"), "annotation.decorator")
  end)

  test.test("semantic token modifiers append granular child keys", function()
    test.equal(provider.semantic_style("variable", { readonly = true }), "variable.readonly")
    test.equal(provider.semantic_style("property", { readonly = true }), "variable.property.readonly")
    test.equal(provider.semantic_style("function", { deprecated = true }), "function.deprecated")
    test.equal(provider.semantic_style("class", { defaultLibrary = true }), "type.class.default_library")
    test.equal(provider.semantic_style("method", { static = true, deprecated = true }), "function.method.deprecated")
  end)

  test.test("semantic tokens overlay base tokens conservatively", function()
    local tokens = provider.overlay_semantic_tokens("abc def\n", {
      "keyword", "abc",
      "normal", " def\n",
    }, 0, {
      { start_byte = 4, end_byte = 7, style = "function" },
    })
    test.same(tokens, {
      "keyword", "abc",
      "normal", " ",
      "function", "def",
      "normal", "\n",
    })
  end)

  test.test("pending semanticTokens/full request falls back to base rendering", function(context)
    local doc, client = attach(context)
    local line = doc.highlighter:get_render_line(1)
    test.not_equal(line.source, "lsp")
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "textDocument/semanticTokens/full")
  end)

  test.test("fresh semantic tokens overlay render tokens and are cached", function(context)
    local doc, client = attach(context)
    doc.highlighter:get_render_line(1)
    complete_request(client, 1, { data = { 0, 4, 4, 0, 0 } })

    local line = doc.highlighter:get_render_line(1)
    test.equal(line.source, "lsp")
    test.ok(has_token(line.tokens, "function", "main"))
    doc.highlighter:get_render_line(1)
    test.equal(#client.requests, 1)
  end)

  test.test("render line cache avoids duplicate semantic lookup only within a draw frame", function(context)
    local doc, client = attach(context)
    doc.highlighter:get_render_line(1)
    complete_request(client, 1, { data = { 0, 4, 4, 0, 0 } })

    local stats = {}
    core.perf_frame_stats = stats
    core.render_frame_id = (core.render_frame_id or 0) + 1
    core.render_frame_active = true
    local line1 = doc.highlighter:get_render_line(1)
    local line2 = doc.highlighter:get_render_line(1)
    test.equal(line1.source, "lsp")
    test.equal(line2.source, "lsp")
    test.equal(stats.lsp_render_tokens_calls, 1)

    core.render_frame_id = core.render_frame_id + 1
    local line3 = doc.highlighter:get_render_line(1)
    test.equal(line3.source, "lsp")
    test.equal(stats.lsp_render_tokens_calls, 2)
  end)

  test.test("semantic token cache is not reused while local edits are pending", function(context)
    local doc, client = attach(context)
    doc.highlighter:get_render_line(1)
    complete_request(client, 1, { data = { 0, 4, 4, 0, 0 } })
    test.equal(doc.highlighter:get_render_line(1).source, "lsp")

    doc:insert(1, 1, "x")
    local line = doc.highlighter:get_render_line(1)

    test.not_equal(line.source, "lsp")
    test.equal(#client.requests, 2)
    test.equal(client.sent[#client.sent].method, "textDocument/didChange")
  end)

  test.test("stale version semantic token responses are discarded", function(context)
    local doc, client = attach(context)
    doc.highlighter:get_render_line(1)
    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "x" } })
    documents.flush(client, doc)
    complete_request(client, 1, { data = { 0, 4, 4, 0, 0 } })

    local line = doc.highlighter:get_render_line(1)
    test.not_equal(line.source, "lsp")
    test.equal(#client.requests, 2)
  end)

  test.test("semantic token cache key includes legend", function(context)
    local doc, client = attach(context)
    doc.highlighter:get_render_line(1)
    complete_request(client, 1, { data = { 0, 4, 4, 0, 0 } })
    test.equal(doc.highlighter:get_render_line(1).source, "lsp")

    client.capabilities.semanticTokensProvider.legend = {
      tokenTypes = { "class" },
      tokenModifiers = {},
    }
    local line = doc.highlighter:get_render_line(1)
    test.not_equal(line.source, "lsp")
    test.equal(#client.requests, 2)
  end)

  test.test("readonly variable sample maps through legend to hierarchical Anvil style", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "main.cpp"), "const value = 1"))
    local tokens = provider.decode_semantic_tokens(doc, { 0, 6, 5, 0, 1 }, {
      tokenTypes = { "variable" },
      tokenModifiers = { "readonly" },
    }, "utf-16")
    test.equal(tokens[1].token_type, "variable")
    test.ok(tokens[1].token_modifiers.readonly)
    test.equal(tokens[1].style, "variable.readonly")
  end)

  test.test("unsupported semantic token capability stays unavailable", function(context)
    local doc, client = attach(context, { capabilities = {} })
    local line = doc.highlighter:get_render_line(1)
    test.not_equal(line.source, "lsp")
    test.equal(#client.requests, 0)
  end)
end)
