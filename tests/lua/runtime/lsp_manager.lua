local common = require "core.common"
local core_config = require "core.config"
local Doc = require "core.doc"
local diagnostics = require "core.lsp.diagnostics"
local documents = require "core.lsp.documents"
local manager = require "core.lsp.manager"
local provider = require "core.lsp.provider"
local test = require "core.test"

local fake_server_path = "tests/fixtures/lsp/fake_server.lua"

local function fake_command()
  return { EXEFILE, "run", system.absolute_path(fake_server_path) }
end

local function fake_definition(extra)
  extra = extra or {}
  local def = {
    id = extra.id or "fake-manager-lsp",
    command = extra.command or fake_command(),
    language_id = extra.language_id or "fakecpp",
    file_patterns = extra.file_patterns or { "%.fakecpp$" },
    root_markers = extra.root_markers or { "compile_commands.json", ".git" },
    initialization_options = {},
    settings = {},
    env = extra.env or { ANVIL_LSP_FAKE_SERVER_MODE = "manager_integration" },
    cwd_policy = "root",
    request_timeout = 3,
    source = "bundled",
  }
  return def
end

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function write_file(path, text)
  local fp = test.not_nil(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
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
  set_text(doc, text or "int main() {}")
  doc:set_filename(path, path)
  return doc
end

local function ready_entry_for_doc(doc)
  local client, entry = manager.client_for_doc(doc)
  return client and client.state == "ready" and entry or nil
end

local function wait_for(timeout, predicate)
  local ok, err = manager.pump_until(timeout or 3, predicate, 0.01)
  test.ok(ok, tostring(err) .. "\n" .. manager.status())
end

local function setup_project(context)
  local root = join_path(context.temp_root, "project")
  mkdir(root)
  write_file(join_path(root, "compile_commands.json"), "[]")
  return root
end

test.describe("core.lsp.manager", function()
  test.before_each(function(context)
    context.temp_root = USERDIR .. PATHSEP .. "lsp-manager-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    mkdir(context.temp_root)
    manager.reset_for_tests()
    context.original_lsp_config = core_config.lsp
    manager.set_sync_options({ debounce_seconds = 0.01 })
  end)

  test.after_each(function(context)
    manager.reset_for_tests()
    core_config.lsp = context.original_lsp_config
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

  test.test("auto-start waits for Doc(filename) load before didOpen sync", function(context)
    manager.set_server_definitions({ fake = fake_definition() })
    manager.set_auto_start(true)
    local root = setup_project(context)
    local path = write_file(join_path(root, "loaded.fakecpp"), "loaded-content\n")

    local doc = track_doc(context, Doc(path, path))
    wait_for(3, function()
      local client = manager.client_for_doc(doc)
      return client and (client.transport.stderr_tail or ""):find("didOpenText=loaded%-content", 1) ~= nil
    end)

    local client = manager.client_for_doc(doc)
    test.not_nil(client)
    test.ok(not (client.transport.stderr_tail or ""):find("didOpenTextLength=1\n", 1, true))
    manager.set_auto_start(false)
  end)

  test.test("explicit start for an already-loaded document syncs loaded contents", function(context)
    manager.set_server_definitions({ fake = fake_definition() })
    local root = setup_project(context)
    local path = write_file(join_path(root, "explicit.fakecpp"), "explicit-content\n")
    local doc = track_doc(context, Doc(path, path))

    test.not_nil(manager.ensure_doc(doc))
    wait_for(3, function()
      local client = manager.client_for_doc(doc)
      return client and (client.transport.stderr_tail or ""):find("didOpenText=explicit%-content", 1) ~= nil
    end)
  end)

  test.test("matching document starts fake client, reaches ready, syncs, and registers provider", function(context)
    manager.set_server_definitions({ fake = fake_definition() })
    local root = setup_project(context)
    local doc = track_doc(context, new_doc(join_path(root, "main.fakecpp"), "abcd"))

    test.not_nil(manager.ensure_doc(doc))
    wait_for(3, function() return ready_entry_for_doc(doc) ~= nil end)

    local client, entry = manager.client_for_doc(doc)
    test.not_nil(client)
    test.equal(client.state, "ready")
    test.equal(entry.root.root, common.normalize_path(root))
    test.not_nil(documents.state(client, doc))
    test.ok(provider.is_available(doc, "document_outline"))
    wait_for(3, function()
      return (client.transport.stderr_tail or ""):find("didOpen=", 1, true) ~= nil
    end)
  end)

  test.test("documents with same identity reuse one client", function(context)
    manager.set_server_definitions({ fake = fake_definition() })
    local root = setup_project(context)
    local doc1 = track_doc(context, new_doc(join_path(root, "one.fakecpp"), "one"))
    local doc2 = track_doc(context, new_doc(join_path(root, "two.fakecpp"), "two"))

    manager.ensure_doc(doc1)
    manager.ensure_doc(doc2)
    wait_for(3, function()
      local c1 = manager.client_for_doc(doc1)
      local c2 = manager.client_for_doc(doc2)
      return c1 and c2 and c1 == c2 and c1.state == "ready"
    end)

    local count = 0
    for _ in pairs(manager.entries()) do count = count + 1 end
    test.equal(count, 1)
    local client = manager.client_for_doc(doc1)
    test.not_nil(documents.state(client, doc1))
    test.not_nil(documents.state(client, doc2))
  end)

  test.test("missing executable no-ops without crashing and is visible in status", function(context)
    manager.set_server_definitions({ fake = fake_definition({ command = "definitely-missing-anvil-lsp-test-server" }) })
    local root = setup_project(context)
    local doc = track_doc(context, new_doc(join_path(root, "main.fakecpp"), "abcd"))

    local ok, err = manager.ensure_doc(doc)
    test.is_nil(ok)
    test.equal(err, "no available LSP server")
    local count = 0
    for _ in pairs(manager.entries()) do count = count + 1 end
    test.equal(count, 0)
    local status = manager.status()
    test.contains(status, "fake-manager-lsp for")
    test.contains(status, "missing executable definitely-missing-anvil-lsp-test-server")
  end)

  test.test("local config server override command path is honored", function(context)
    core_config.lsp = {
      servers = {
        fake_local = fake_definition({ id = "fake-local-config-lsp" }),
      },
    }
    local root = setup_project(context)
    local doc = track_doc(context, new_doc(join_path(root, "main.fakecpp"), "abcd"))

    test.not_nil(manager.ensure_doc(doc))
    wait_for(3, function() return ready_entry_for_doc(doc) ~= nil end)
    local client = manager.client_for_doc(doc)
    test.not_nil(client)
    test.equal(client.server_id, "fake-local-config-lsp")
  end)

  test.test("diagnostics notification flows into diagnostics storage", function(context)
    manager.set_server_definitions({ fake = fake_definition({
      env = {
        ANVIL_LSP_FAKE_SERVER_MODE = "manager_integration",
        ANVIL_LSP_FAKE_SERVER_PUBLISH_DIAGNOSTICS = "1",
      },
    }) })
    local root = setup_project(context)
    local doc = track_doc(context, new_doc(join_path(root, "main.fakecpp"), "abcd"))

    manager.ensure_doc(doc)
    wait_for(3, function() return #diagnostics.current_for_doc(doc) == 1 end)

    local items = diagnostics.current_for_doc(doc)
    test.equal(items[1].message, "fake diagnostic")
    test.equal(items[1].source, "fake-lsp")
  end)

  test.test("document sync sends didOpen and didChange through manager client", function(context)
    manager.set_server_definitions({ fake = fake_definition() })
    local root = setup_project(context)
    local doc = track_doc(context, new_doc(join_path(root, "main.fakecpp"), "abcd"))

    manager.ensure_doc(doc)
    wait_for(3, function() return ready_entry_for_doc(doc) ~= nil end)
    local client = manager.client_for_doc(doc)
    wait_for(3, function()
      return (client.transport.stderr_tail or ""):find("didOpen=", 1, true) ~= nil
    end)

    doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "x" } })
    wait_for(3, function()
      return (client.transport.stderr_tail or ""):find("didChange=1", 1, true) ~= nil
    end)
    local state = documents.state(client, doc)
    test.equal(state.lsp_version, 1)
  end)
end)
