local test = require "core.test"
local native_pool = require "worker_pool_native"

test.describe("shutdown diagnostics", function()
  local pool
  local path = USERDIR .. PATHSEP .. "shutdown-diagnostics-é.log"

  test.after_each(function()
    if pool then pool:shutdown({ cancel_running = true }); pool = nil end
    if system.set_shutdown_log then system.set_shutdown_log(nil) end
    os.remove(path)
  end)

  test.it("records a running job and completed shutdown in a separate log", function()
    pool = native_pool.new({ name = "shutdown-diagnostics", worker_count = 1 })
    local job = pool:submit({ kind = "test_count", count = 10000, sleep_ms = 1 })
    local deadline = system.get_time() + 5
    while pool:status(job).status ~= "running" and system.get_time() < deadline do
      coroutine.yield(0.001)
    end
    test.equal(pool:status(job).status, "running")
    test.ok(system.set_shutdown_log(path))
    system.log_shutdown("test shutdown requested")
    pool:shutdown({ cancel_running = true })
    pool = nil
    -- Read before closing the log. A blocked shutdown must leave readable evidence.
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    test.ok(text:find("test shutdown requested", 1, true))
    test.ok(text:find("kind=test_count", 1, true))
    test.ok(text:find("native pool shutdown complete", 1, true))
  end)

  test.it("keeps and removes shutdown logs with their session", function()
    local SessionLog = require "core.session_log"
    local root = USERDIR .. PATHSEP .. "shutdown-retention"
    local old_id = "anvil-20260916-120000-p123"
    local new_id = "anvil-20260916-130000-p123"
    local old = assert(SessionLog.start(root, { session_id = old_id, max_sessions = 1 }))
    local old_path = old.path
    local old_shutdown = root .. PATHSEP .. old_id .. "-shutdown.log"
    test.ok(system.set_shutdown_log(old_shutdown))
    system.set_shutdown_log(nil)
    old:close()
    test.ok(system.get_file_info(old_path))
    test.ok(system.get_file_info(old_shutdown))

    local current = assert(SessionLog.start(root, { session_id = new_id, max_sessions = 1 }))
    local current_path = current.path
    local current_shutdown = root .. PATHSEP .. new_id .. "-shutdown.log"
    test.ok(system.set_shutdown_log(current_shutdown))
    system.set_shutdown_log(nil)
    current:close()
    test.equal(system.get_file_info(old_path), nil)
    test.equal(system.get_file_info(old_shutdown), nil)
    test.ok(system.get_file_info(current_path))
    test.ok(system.get_file_info(current_shutdown))
    os.remove(current_path)
    os.remove(current_shutdown)
    os.remove(root)
  end)

  test.it("identifies files processed by Project index workers", function()
    local common = require "core.common"
    local root = USERDIR .. PATHSEP .. "shutdown-index"
    test.ok(common.mkdirp(root))
    local paths = {}
    for _, name in ipairs({ "alpha", "beta" }) do
      local file_path = root .. PATHSEP .. name .. ".c"
      paths[#paths + 1] = file_path
      local file = assert(io.open(file_path, "wb"))
      file:write("int " .. name .. "(void) { return 0; }\n")
      file:close()
    end
    test.ok(system.set_shutdown_log(path))
    pool = native_pool.new({ name = "shutdown-index", worker_count = 1 })
    local job = test.not_nil(pool:submit({
      kind = "treesitter_project_run", project_root = root,
      project_scoped = true, scan_paths = paths, project_usage_cap = 100,
      max_file_bytes = 1024 * 1024,
      languages = {{
        id = "c", grammar = "c", files = { "%.c$" },
        outline_query = [[(function_definition declarator:
          (function_declarator declarator: (identifier) @name)) @outline.function]],
      }},
    }))
    local deadline = system.get_time() + 5
    while system.get_time() < deadline do
      local status = pool:status(job).status
      if status ~= "queued" and status ~= "running" then break end
      coroutine.yield(0.001)
    end
    test.equal(pool:status(job).status, "complete")
    pool:shutdown({ cancel_running = true })
    pool = nil
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a")
    file:close()
    test.ok(text:find("kind=treesitter_project_run", 1, true))
    for _, file_path in ipairs(paths) do
      test.ok(text:find(file_path, 1, true), "expected the indexed file path in diagnostics")
      os.remove(file_path)
    end
    os.remove(root)
  end)
end)
