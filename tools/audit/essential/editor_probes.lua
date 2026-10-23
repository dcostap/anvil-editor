local test = require "core.test"
local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local panes = require "core.panes"
local command = require "core.command"
local common = require "core.common"
local storage = require "core.storage"
require "plugins.workspace"
require "plugins.bracketmatch"

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
  if type(value) ~= "table" then return value == path end
  for _, child in pairs(value) do if contains_path(child, path) then return true end end
  return false
end

test.describe("Workspace save failure audit", function()
  local old_open, old_view, root
  test.before_each(function()
    old_open, old_view = io.open, core.active_view
    root = USERDIR .. PATHSEP .. "audit-workspace"
    assert(common.mkdirp(root))
  end)
  test.after_each(function()
    io.open = old_open
    panes.reset_for_tests()
    core.active_view = old_view
    test.ok(test.remove_tree(root))
  end)
  test.it("retries an unchanged Workspace after a temporary write failure", function()
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
    core.request_workspace_save("audit retry", 0)
    local recovered = wait_for(function() return contains_path(stored_workspace(), path) end, 10)
    print(string.format("AUDIT workspace denied=%d recovered_after_retry=%s", denied, tostring(recovered)))
    test.ok(recovered, "unchanged Workspace was not retried after storage recovered")
  end)
end)

test.describe("Bracket navigation audit", function()
  local old_view
  test.before_each(function() old_view = core.active_view; panes.reset_for_tests() end)
  test.after_each(function() panes.reset_for_tests(); core.active_view = old_view end)
  test.it("matching brackets ignores a closing bracket inside a string", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_syntax(require("core.syntax").get("probe.lua"))
    buffer:insert(1, 1, 'print(")")')
    panes.create { factory = function() return Editor(buffer) end }
    buffer:set_selection(1, 6)
    test.ok(command.perform("editor:move_to_matching"))
    local line, col = buffer:get_selection()
    print(string.format("AUDIT bracket expected=1:10 actual=%d:%d", line, col))
    test.equal(col, 10, "jump stopped inside the string instead of the call's closing bracket")
  end)
end)

test.describe("Buffer edit scaling audit", function()
  test.it("measures single-character edits on plain Buffers", function()
    for _, lines in ipairs { 10000, 100000, 500000 } do
      local buffer = Buffer(nil, nil, true)
      buffer.disable_language_services = true
      buffer.disable_treesitter = true
      buffer:insert(1, 1, string.rep("ordinary text\n", lines - 1))
      buffer:clear_undo_redo()
      collectgarbage("collect")
      local samples = {}
      for i = 1, 25 do
        buffer:set_selection(1, 1)
        local started = system.get_time()
        buffer:text_input("a")
        samples[i] = (system.get_time() - started) * 1000
      end
      table.sort(samples)
      print(string.format("AUDIT edit lines=%d median_ms=%.3f p96_ms=%.3f max_ms=%.3f",
        lines, samples[13], samples[24], samples[25]))
      buffer:on_close()
    end
  end)
end)
