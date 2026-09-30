local core = require "core"
local test = require "core.test"
local panes = require "core.panes"
local Editor = require "core.editor"
local pool = require "core.worker_pool"
require "plugins.autosave_fast"

test.it("saves edits made while a large View waits for close approval", function()
  local path = USERDIR .. PATHSEP .. "large-close.txt"
  local f = assert(io.open(path, "wb"))
  local original = ("ordinary source line for a large file\n"):rep(12000)
  f:write(original); f:close()
  local buffer = core.open_buffer(path)
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  buffer:insert(1, 1, "saved ")
  local approved = false
  view:can_close(function() approved = true end)
  local ok, err = pcall(function()
    test.equal(approved, false, "close must wait without blocking the input handler")
    buffer:insert(1, 1, "later ")
    local deadline = system.get_time() + 10
    repeat
      pool.system():drain { max_ms = 5 }
      if approved then break end
      coroutine.yield(.001)
    until system.get_time() > deadline
    test.ok(approved, "close approval must follow the completed save")
    local input = assert(io.open(path, "rb"))
    local written = input:read("*a"); input:close()
    test.equal(written, "later saved " .. original)
    test.equal(buffer:is_dirty(), false)
  end)
  buffer:clean()
  panes.reset_for_tests()
  os.remove(path)
  if not ok then error(err) end
end)
