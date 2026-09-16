local common = require "core.common"
local core = require "core"
local Buffer = require "core.buffer"
local Project = require "core.project"
local test = require "core.test"
local vault_index = require "core.markdown.vault_index"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_for_heading(index, source, target, line)
  local deadline = system.get_time() + 5
  repeat
    local result = index:resolve(target, source)
    if result.status == "resolved" and not result.subtarget_missing and result.line == line then
      return result
    end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  local result = index:resolve(target, source)
  test.ok(false, "Heading did not resolve: " .. tostring(result.reason or result.status))
end

test.describe("Markdown links after file loading", function()
  local root, path, source, index, buffer, old_projects

  test.before_each(function()
    root = USERDIR .. PATHSEP .. "markdown-vault-loading-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(root .. PATHSEP .. "notes"))
    path = root .. PATHSEP .. "notes" .. PATHSEP .. "Almacén (2026 2).md"
    source = root .. PATHSEP .. "Tasks.md"
    write_file(source, "# Tasks\n")
    old_projects = core.projects
    core.projects = { Project(root) }
    index = vault_index.get_index(root):rebuild("loading-test")
    test.equal(index.status, "ready", index.reason)
    write_file(path, "# Material\n\n## Notas\n")
  end)

  test.after_each(function()
    if buffer then buffer:on_close(); buffer = nil end
    core.projects = old_projects
    common.rm(root, true)
  end)

  test.it("resolves headings after opening a note without editing it", function()
    buffer = Buffer(path, path)

    local result = wait_for_heading(index, source, "Almacén (2026 2)#Notas", 3)
    test.equal(result.path, common.normalize_path(path))
  end)

  test.it("replaces heading targets when a tracked note reloads", function()
    buffer = Buffer(path, path)
    index:track_buffer(buffer)
    wait_for_heading(index, source, "Almacén (2026 2)#Notas", 3)

    write_file(path, "# Material\n\nText\n\n## Revised notes\n")
    buffer:reload()

    wait_for_heading(index, source, "Almacén (2026 2)#Revised notes", 5)
    local old = index:resolve("Almacén (2026 2)#Notas", source)
    test.equal(old.status, "resolved")
    test.equal(old.subtarget_missing, true)
  end)
end)
