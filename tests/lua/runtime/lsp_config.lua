local common = require "core.common"
local test = require "core.test"
local lsp_config = require "core.lsp.config"
local uri = require "core.lsp.uri"

local temp_root

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function write_file(path, content)
  local file = test.not_nil(io.open(path, "wb"))
  file:write(content or "")
  file:close()
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function fake_server_definition(overrides)
  local def = {
    id = "fake-cpp",
    command = { join_path(temp_root, PLATFORM == "Windows" and "fake-lsp.exe" or "fake-lsp") },
    language_id = "cpp",
    file_patterns = { "%.cpp$", "%.hpp$" },
    root_markers = { "compile_commands.json", ".clangd", ".git" },
    initialization_options = { fake = true },
    settings = { level = 1 },
    env = { FAKE_LSP = "1" },
    cwd_policy = "root",
    request_timeout = 7,
    source = "bundled",
  }
  for key, value in pairs(overrides or {}) do
    def[key] = value
  end
  return def
end

test.describe("core.lsp.config", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-config-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    mkdir(temp_root)
    write_file(join_path(temp_root, PLATFORM == "Windows" and "fake-lsp.exe" or "fake-lsp"), "fake executable")
  end)

  test.after_each(function(context)
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("normalizes server definitions with schema defaults", function()
    local raw = fake_server_definition()
    raw.initialization_options = nil
    raw.settings = nil
    raw.env = nil
    raw.request_timeout = nil
    local def = test.not_nil(lsp_config.normalize_server_definition(raw))
    test.equal(def.id, "fake-cpp")
    test.equal(def.language_id, "cpp")
    test.equal(def.cwd_policy, "root")
    test.equal(def.request_timeout, lsp_config.DEFAULT_REQUEST_TIMEOUT)
    test.same(def.initialization_options, {})
    test.same(def.settings, {})
    test.same(def.env, {})
  end)

  test.test("rejects invalid server definitions", function()
    local def, err = lsp_config.normalize_server_definition({ id = "bad" })
    test.is_nil(def)
    test.contains(err, "command")

    def, err = lsp_config.normalize_server_definition(fake_server_definition({ request_timeout = -1 }))
    test.is_nil(def)
    test.contains(err, "request_timeout")
  end)

  test.test("matches server definitions by Lua file patterns", function()
    local matches = test.not_nil(lsp_config.matching_servers({ fake_server_definition() }, join_path(temp_root, "main.cpp")))
    test.equal(#matches, 1)
    test.equal(matches[1].id, "fake-cpp")

    matches = test.not_nil(lsp_config.matching_servers({ fake_server_definition() }, join_path(temp_root, "README.md")))
    test.equal(#matches, 0)
  end)

  test.test("detects roots by marker priority before fallback roots", function()
    local project = mkdir(join_path(temp_root, "project"))
    local src = mkdir(join_path(project, "src"))
    local deep = mkdir(join_path(src, "deep"))
    write_file(join_path(project, "compile_commands.json"), "{}")
    write_file(join_path(src, ".clangd"), "CompileFlags: {}")
    mkdir(join_path(deep, ".git"))
    local doc = join_path(deep, "main.cpp")
    write_file(doc, "int main() {}")

    local root = test.not_nil(lsp_config.find_root(doc, fake_server_definition(), {
      fallback_roots = { temp_root },
    }))
    test.equal(root.root, common.normalize_path(project))
    test.equal(root.marker, "compile_commands.json")
    test.equal(root.source, "marker")
    test.equal(root.root_uri, uri.path_to_uri(project))
  end)

  test.test("falls back to containing project root then document directory", function()
    local project = mkdir(join_path(temp_root, "project"))
    local src = mkdir(join_path(project, "src"))
    local doc = join_path(src, "main.cpp")
    write_file(doc, "int main() {}")

    local root = test.not_nil(lsp_config.find_root(doc, fake_server_definition(), {
      fallback_roots = { project },
    }))
    test.equal(root.root, common.normalize_path(project))
    test.equal(root.source, "fallback_root")

    root = test.not_nil(lsp_config.find_root(doc, fake_server_definition({ root_markers = {} })))
    test.equal(root.root, common.normalize_path(src))
    test.equal(root.source, "document_dir")
  end)

  test.test("reports missing executables without crashing", function()
    local status = test.not_nil(lsp_config.executable_status(fake_server_definition({
      command = { join_path(temp_root, "missing-fake-lsp") },
    })))
    test.equal(status.available, false)
    test.equal(status.reason, "missing_executable")
  end)

  test.test("selects available fake server with root and identity", function()
    local project = mkdir(join_path(temp_root, "project"))
    write_file(join_path(project, ".clangd"), "CompileFlags: {}")
    local doc = join_path(project, "main.cpp")
    write_file(doc, "int main() {}")

    local selected = test.not_nil(lsp_config.select_for_path({ fake_server_definition() }, doc, {
      settings_generation = 3,
    }))
    test.equal(#selected, 1)
    test.not_equal(selected[1].available, false)
    test.equal(selected[1].definition.id, "fake-cpp")
    test.equal(selected[1].root.root, common.normalize_path(project))
    test.equal(selected[1].identity.server_id, "fake-cpp")
    test.equal(selected[1].identity.root_uri, uri.path_to_uri(project))
    test.equal(selected[1].identity.settings_generation, 3)
    test.contains(selected[1].identity.key, "fake-cpp")
  end)

  test.test("client identity includes config fingerprint, root, language, toolchain, and settings generation", function()
    local def = test.not_nil(lsp_config.normalize_server_definition(fake_server_definition()))
    local root = { root = temp_root, root_uri = uri.path_to_uri(temp_root) }
    local one = lsp_config.client_identity(def, root, { settings_generation = 1, toolchain = "toolchain-a" })
    local two = lsp_config.client_identity(def, root, { settings_generation = 2, toolchain = "toolchain-a" })
    local changed_def = test.not_nil(lsp_config.normalize_server_definition(fake_server_definition({ settings = { level = 2 } })))
    local three = lsp_config.client_identity(changed_def, root, { settings_generation = 1, toolchain = "toolchain-a" })

    test.not_equal(one.key, two.key)
    test.not_equal(one.key, three.key)
    test.equal(one.root_uri, uri.path_to_uri(temp_root))
    test.equal(one.language_id, "cpp")
    test.equal(one.toolchain, "toolchain-a")
  end)

  test.test("represents future workspace executable trust policy without enabling it", function()
    local def = fake_server_definition({ source = "workspace" })
    test.not_ok(lsp_config.workspace_executable_config_allowed(def.trust_policy, { trusted = true }))

    local project = mkdir(join_path(temp_root, "project"))
    local doc = join_path(project, "main.cpp")
    write_file(doc, "int main() {}")
    local selected = test.not_nil(lsp_config.select_for_path({ def }, doc, { trusted = true }))
    test.equal(#selected, 0)
  end)

  test.test("bundles OLS for Odin files rooted by ols.json", function()
    local ols = test.not_nil(lsp_config.DEFAULT_SERVER_DEFINITIONS.ols)
    local def = test.not_nil(lsp_config.normalize_server_definition(ols))
    test.equal(def.id, "ols")
    test.equal(def.language_id, "odin")
    test.equal(def.command[1], "ols")
    test.equal(def.root_markers[1], "ols.json")

    write_file(join_path(temp_root, PLATFORM == "Windows" and "ols.exe" or "ols"), "fake ols executable")
    local project = mkdir(join_path(temp_root, "odin-project"))
    local src = mkdir(join_path(project, "src"))
    write_file(join_path(project, "ols.json"), "{}")
    local doc = join_path(src, "main.odin")
    write_file(doc, "package main\n")

    local selected = test.not_nil(lsp_config.select_for_path(lsp_config.DEFAULT_SERVER_DEFINITIONS, doc, {
      executable = { path_entries = { temp_root } },
    }))
    test.equal(#selected, 1)
    test.equal(selected[1].definition.id, "ols")
    test.equal(selected[1].root.root, common.normalize_path(project))
    test.equal(selected[1].root.marker, "ols.json")
  end)
end)
