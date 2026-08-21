local common = require "core.common"
local recovery = require "plugins.untitled_recovery"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function read_file(path)
  local fp, err = io.open(path, "rb")
  test.not_nil(fp, err)
  local s = fp:read("*a")
  fp:close()
  return s
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  test.not_nil(fp, err)
  fp:write(text)
  fp:close()
end

test.describe("untitled recovery helpers", function()
  test.before_each(function(context)
    context.temp_root = USERDIR
      .. PATHSEP .. "untitled-recovery-runtime-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.temp_root))
  end)

  test.after_each(function(context)
    if context.project_for_manifest then
      local root = recovery.project_paths(context.project_for_manifest).root
      if system.get_file_info(root) then
        local ok, err = common.rm(root, true)
        test.ok(ok, err)
      end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("project keys are stable fixed-width hex and distinct for same-basename projects", function(context)
    local a = join_path(context.temp_root, "left", "repo")
    local b = join_path(context.temp_root, "right", "repo")
    test.equal(recovery.project_key(a), recovery.project_key(a))
    test.equal(#recovery.project_key(a), 16)
    test.ok(recovery.project_key(a):match("^[0-9a-f]+$"))
    test.not_equal(recovery.project_key(a), recovery.project_key(b))
  end)

  test.test("safe replace keeps the previous primary when durable synchronization fails", function(context)
    local path = join_path(context.temp_root, "buffer.txt")
    write_file(path, "old")

    local sync_file = system.sync_file
    system.sync_file = function() return false, "simulated sync failure" end
    local ok, err = recovery.safe_replace_bytes(path, "new")
    system.sync_file = sync_file

    test.equal(ok, false)
    test.ok(tostring(err):find("simulated sync failure", 1, true), tostring(err))
    test.equal(read_file(path), "old")
  end)

  test.test("safe replace synchronizes new content", function(context)
    local path = join_path(context.temp_root, "buffer.txt")
    write_file(path, "old")

    local sync_file = system.sync_file
    local sync_calls = 0
    system.sync_file = function(file)
      sync_calls = sync_calls + 1
      return sync_file(file)
    end
    local ok, err = recovery.safe_replace_bytes(path, "new")
    system.sync_file = sync_file

    test.ok(ok, err)
    test.equal(read_file(path), "new")
    test.ok(sync_calls > 0, "expected a durable file synchronization")
  end)

  test.test("buffer serialization preserves LF and CRLF policy", function()
    local buffer = { lines = { "a\n", "b\n" }, crlf = false }
    test.equal(recovery.serialize_buffer_text(buffer), "a\nb\n")
    buffer.crlf = true
    test.equal(recovery.serialize_buffer_text(buffer), "a\r\nb\r\n")
  end)

  test.test("missing primary manifest prefers valid temp over older backup", function(context)
    local project = join_path(context.temp_root, "project-temp-manifest")
    context.project_for_manifest = project
    local paths = recovery.project_paths(project)
    test.ok(common.mkdirp(paths.root))
    write_file(paths.manifest .. ".tmp", "return { buffers = { { id = \"from-temp\" } } }")
    write_file(paths.manifest_bak, "return { buffers = { { id = \"from-bak\" } } }")

    local loaded = recovery.load_manifest(project)
    test.equal(#loaded.buffers, 1)
    test.equal(loaded.buffers[1].id, "from-temp")
    test.equal(read_file(paths.manifest), "return { buffers = { { id = \"from-temp\" } } }")
  end)

  test.test("invalid primary manifest falls back to valid backup", function(context)
    local project = join_path(context.temp_root, "project-fallback")
    context.project_for_manifest = project
    local paths = recovery.project_paths(project)
    test.ok(common.mkdirp(paths.root))
    write_file(paths.manifest, "return { buffers = nil }")
    write_file(paths.manifest_bak, "return { buffers = { { id = \"from-bak\" } } }")

    local loaded = recovery.load_manifest(project)
    test.equal(#loaded.buffers, 1)
    test.equal(loaded.buffers[1].id, "from-bak")
    test.equal(read_file(paths.manifest), "return { buffers = { { id = \"from-bak\" } } }")
  end)

  test.test("manifest project mismatch is rejected", function(context)
    local project = join_path(context.temp_root, "project-mismatch")
    context.project_for_manifest = project
    local paths = recovery.project_paths(project)
    test.ok(common.mkdirp(paths.root))
    write_file(paths.manifest, "return { project = \"" .. join_path(context.temp_root, "other") .. "\", buffers = { { id = \"wrong-project\" } } }")

    local loaded = recovery.load_manifest(project)
    test.equal(#loaded.buffers, 0)
    test.equal(loaded.project, project)
  end)

  test.test("manifest write validates and reloads metadata", function(context)
    local project = join_path(context.temp_root, "project")
    context.project_for_manifest = project
    local manifest = {
      buffers = {
        { id = "abc", name = "Untitled-1", backing = "buffers" .. PATHSEP .. "abc.txt" }
      }
    }
    local ok, err = recovery.save_manifest(project, manifest)
    test.ok(ok, err)

    local loaded = recovery.load_manifest(project)
    test.equal(loaded.project_key, recovery.project_key(project))
    test.equal(#loaded.buffers, 1)
    test.equal(loaded.buffers[1].id, "abc")
  end)
end)
