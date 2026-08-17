local common = require "core.common"
local core = require "core"
local test = require "core.test"

local function join(...)
  return table.concat({...}, PATHSEP)
end

local function remove_tree(path)
  if system.get_file_info(path) then common.rm(path, true) end
end

local function log_files(path)
  local files = {}
  for _, name in ipairs(system.list_dir(path) or {}) do
    if name:match("^anvil%-.+%.log$") then files[#files + 1] = name end
  end
  table.sort(files)
  return files
end

test.describe("session log", function()
  test.it("persists the active core log", function()
    test.ok(core.session_log, "expected an active core session log")
    local marker = "session log integration marker"
    core.log_quiet(marker)
    core.session_log:flush()
    local file = assert(io.open(core.session_log.path, "rb"))
    local text = file:read("*a")
    file:close()
    test.ok(text:find(marker, 1, true))
  end)

  test.it("writes and rolls one process session", function()
    local SessionLog = require "core.session_log"
    local root = join(USERDIR, "session-log-roll")
    remove_tree(root)

    local logger = assert(SessionLog.start(root, {
      max_file_bytes = 180,
      max_sessions = 20,
      max_total_bytes = 1024 * 1024,
      session_id = "anvil-20260817-212630-p123",
    }))
    for index = 1, 12 do
      logger:write("INFO", string.rep(tostring(index % 10), 40), "test.lua:1")
    end
    logger:close()

    local files = log_files(root)
    test.ok(#files > 1)
    local found_first, found_second = false, false
    for _, name in ipairs(files) do
      found_first = found_first or name == "anvil-20260817-212630-p123.log"
      found_second = found_second or name:find("-part02.log", 1, true) ~= nil
    end
    test.ok(found_first)
    test.ok(found_second)
    remove_tree(root)
  end)

  test.it("keeps only the newest session files", function()
    local SessionLog = require "core.session_log"
    local root = join(USERDIR, "session-log-prune")
    remove_tree(root)
    test.ok(common.mkdirp(root))
    for index = 1, 4 do
      local file = assert(io.open(join(root,
        string.format("anvil-2026081%d-120000-p%d.log", index, index)), "wb"))
      file:write(string.rep("x", 32))
      file:close()
    end

    local logger = assert(SessionLog.start(root, {
      max_file_bytes = 1024,
      max_sessions = 3,
      max_total_bytes = 1024 * 1024,
      session_id = "anvil-20260817-212630-p123",
    }))
    logger:close()

    local files = log_files(root)
    test.equal(#files, 3)
    test.equal(files[1], "anvil-20260813-120000-p3.log")
    test.equal(files[2], "anvil-20260814-120000-p4.log")
    test.equal(files[3], "anvil-20260817-212630-p123.log")
    remove_tree(root)
  end)

  test.it("removes old sessions above the total size limit", function()
    local SessionLog = require "core.session_log"
    local root = join(USERDIR, "session-log-total")
    remove_tree(root)
    test.ok(common.mkdirp(root))
    for index = 1, 2 do
      local file = assert(io.open(join(root,
        string.format("anvil-2026081%d-120000-p%d.log", index, index)), "wb"))
      file:write(string.rep("x", 256))
      file:close()
    end

    local logger = assert(SessionLog.start(root, {
      max_file_bytes = 1024,
      max_sessions = 20,
      max_total_bytes = 300,
      session_id = "anvil-20260817-212630-p123",
    }))
    logger:close()

    local files = log_files(root)
    test.equal(#files, 1)
    test.equal(files[1], "anvil-20260817-212630-p123.log")
    remove_tree(root)
  end)
end)
