local test = require "core.test"
local core = require "core"
local Editor = require "core.editor"
local panes = require "core.panes"
local common = require "core.common"
local storage = require "core.storage"
require "plugins.workspace"

local function wait_for(fn, seconds)
  local deadline = system.get_time() + seconds
  repeat
    if fn() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return fn()
end
local function write_file(path, text)
  local f = assert(io.open(path, "wb")); assert(f:write(text)); assert(f:close())
end
local function stored_workspace()
  local root = core.root_project().path
  for _, key in ipairs(storage.keys("ws")) do
    local saved = storage.load("ws", key)
    if saved and saved.path and common.path_equals(saved.path, root) then return saved end
  end
end
local function contains_path(value, path)
  if type(value) ~= "table" then return type(value) == "string" and common.path_equals(value, path) end
  for _, child in pairs(value) do if contains_path(child, path) then return true end end
  return false
end

test.describe("Workspace save failure audit", function()
  local old_open, old_view, root
  local started = false
  test.before_each(function()
    if not started then
      test.ok(wait_for(function() return panes.count() > 0 end, 30), "initial Workspace did not open")
      started = true
    end
    old_open, old_view = io.open, core.active_view
    panes.reset_for_tests()
    root = USERDIR .. PATHSEP .. "workspace-retry-" .. math.floor(system.get_time() * 1000000)
    assert(common.mkdirp(root))
  end)
  test.after_each(function()
    io.open = old_open
    panes.reset_for_tests()
    core.active_view = old_view
    test.ok(test.remove_tree(root))
  end)
  for _, explicit_retry in ipairs { true, false } do
  test.it("retries an unchanged Workspace " .. (explicit_retry and "on request" or "without another request"), function()
    core.save_workspace()
    local path = root .. PATHSEP .. "retry.txt"
    write_file(path, "audit\n")
    panes.create { factory = function() return Editor(core.open_buffer(path)) end }
    local denied = 0
    io.open = function(name, mode)
      if mode == "wb" and name:find("storage", 1, true) and name:find(".tmp-", 1, true) then
        denied = denied + 1
        return nil, "audit: temporary storage write failure"
      end
      return old_open(name, mode)
    end
    core.request_workspace_save("audit failed save", 0)
    test.ok(wait_for(function() return denied > 0 end, 15), "no Workspace save attempt")
    io.open = old_open
    test.not_ok(contains_path(stored_workspace(), path), "failure injection did not block the write")
    if explicit_retry then core.request_workspace_save("audit retry", 0) end
    local recovered = wait_for(function() return contains_path(stored_workspace(), path) end, 30)
    print(string.format("AUDIT workspace denied=%d recovered_after_retry=%s", denied, tostring(recovered)))
    test.ok(recovered, "unchanged Workspace was not retried after storage recovered")
  end)
  end
end)
