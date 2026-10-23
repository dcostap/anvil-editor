-- Audit probes. These use only the isolated test runner's user folder.
local test = require "core.test"
local common = require "core.common"
local process = require "core.process"

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  assert(f:write(text)); assert(f:close())
end

test.describe("Recursive removal", function()
  test.it("recursive removal does not delete a junction target", function(context)
    if PLATFORM ~= "Windows" then test.skip("Windows junction probe") end
    local root = USERDIR .. PATHSEP .. "audit-junction-" .. math.floor(system.get_time() * 1000000)
    context.root = root
    local tree, target = root .. PATHSEP .. "tree", root .. PATHSEP .. "target"
    test.ok(common.mkdirp(tree)); test.ok(common.mkdirp(target))
    local sentinel = target .. PATHSEP .. "keep.txt"
    write_file(sentinel, "This file is outside the removed tree.\n")
    local link = tree .. PATHSEP .. "link"
    context.link = link
    local function ps_quote(s) return "'" .. s:gsub("'", "''") .. "'" end
    local proc = assert(process.start { "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
      "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path " .. ps_quote(link)
        .. " -Target " .. ps_quote(target) .. " | Out-Null" })
    local code = proc:wait(process.WAIT_INFINITE, 0.01)
    test.equal(code, 0, proc:read_stderr() or "junction creation failed")
    local info = system.get_file_info(link)
    test.ok(info and info.symlink, "junction creation failed")
    local removed, err = common.rm(tree, true)
    local kept = system.get_file_info(sentinel) ~= nil
    print(string.format("AUDIT junction removed=%s target_sentinel_kept=%s error=%s",
      tostring(removed), tostring(kept), tostring(err)))
    test.ok(kept, "recursive removal deleted the junction target's file")
    test.ok(removed, err)
    test.not_ok(system.get_file_info(tree), "selected tree remains")
  end)

  test.after_each(function(context)
    if context.link and system.get_file_info(context.link) then system.rmdir(context.link) end
    if context.root then test.ok(test.remove_tree(context.root)) end
  end)
end)
