local common = require "core.common"
local test = require "core.test"
local ArtifactSession = require "core.treesitter.artifact_session"

local function write_file(path, text)
  local fp = test.not_nil(io.open(path, "wb"))
  fp:write(text or "artifact")
  fp:close()
end

test.describe("Tree-sitter artifact session", function()
  test.it("removes stale sessions while preserving current artifacts", function()
    local base = USERDIR .. PATHSEP .. "treesitter-artifact-session-test"
    common.rm(base, true)
    test.ok(common.mkdirp(base .. PATHSEP .. "session-stale"))
    write_file(base .. PATHSEP .. "session-stale" .. PATHSEP .. "old.lua")

    local session = ArtifactSession.new({ base_dir = base, pid = 42, nonce = "current" })
    local result = session:initialize()
    test.ok(result.removed_sessions >= 1)
    test.is_nil(system.get_file_info(base .. PATHSEP .. "session-stale"))
    test.not_nil(system.get_file_info(session.root))

    local current = session:index_dir() .. PATHSEP .. "live.lua"
    write_file(current)
    session:initialize()
    test.not_nil(system.get_file_info(current))

    test.ok(session:cleanup())
    test.is_nil(system.get_file_info(session.root))
    common.rm(base, true)
  end)

  test.it("removes configured legacy artifact roots once", function()
    local base = USERDIR .. PATHSEP .. "treesitter-artifact-session-legacy-test"
    local legacy = base .. "-legacy"
    common.rm(base, true)
    common.rm(legacy, true)
    test.ok(common.mkdirp(legacy))
    write_file(legacy .. PATHSEP .. "abandoned.lua")

    local session = ArtifactSession.new({ base_dir = base, pid = 43, nonce = "current", legacy_dirs = { legacy } })
    local result = session:initialize()
    test.equal(result.removed_legacy, 1)
    test.is_nil(system.get_file_info(legacy))
    common.rm(base, true)
  end)
end)
