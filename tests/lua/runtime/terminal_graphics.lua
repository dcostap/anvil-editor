local test = require "core.test"
local native = require "terminal_native"
local session

local function open(session_id)
  local err
  local options = {
    cols = 40, rows = 10, cell_width = 8, cell_height = 16,
    cwd = system.getcwd(), session_id = session_id,
    shell = [[powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_graphics.ps1]],
  }
  if session_id then
    local record = assert(load(assert(native.read_session_record(session_id)), "session", "t", {}))()
    options.host_pid = record.host_pid
    options.host_creation_time = record.host_creation_time
    options.pipe_name = record.pipe_name
  end
  session, err = native.new(options)
  test.ok(session, err)
end

local function wait_for(marker, snapshot)
  local deadline = system.get_time() + 30
  repeat
    session:update()
    snapshot = session:snapshot(snapshot)
    local text = {}
    for _, row in ipairs(snapshot and snapshot.rows or {}) do
      for _, run in ipairs(row.text_runs or {}) do text[#text + 1] = run.text end
    end
    if table.concat(text):find(marker, 1, true) then return snapshot end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.fail("Missing terminal output: " .. marker)
end

test.describe("Terminal inline images", function()
  test.after_each(function() if session then session:close(); session = nil end end)

  test.it("exposes image pixels and placement, then replaces and deletes the image", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    open()
    local snapshot = wait_for("GRAPHICS_READY")
    test.ok(snapshot.images and #snapshot.images == 1, "Expected one inline image")
    local image = snapshot.images[1]
    test.equal(image.x, 16)
    test.equal(image.y, 16)
    test.equal(image.width, 32)
    test.equal(image.height, 32)
    test.equal(image.canvas:get_pixels(), string.char(255, 0, 0, 255))

    test.ok(session:write("crop\r\n"))
    snapshot = wait_for("GRAPHICS_CROP", snapshot)
    test.equal(#snapshot.images, 1)
    test.equal(snapshot.images[1].canvas:get_pixels(), string.char(0, 0, 255, 255))

    test.ok(session:write("replace\r\n"))
    snapshot = wait_for("GRAPHICS_BLUE", snapshot)
    test.equal(#snapshot.images, 1)
    test.equal(snapshot.images[1].canvas:get_pixels(), string.char(0, 0, 255, 255))

    test.ok(session:write("png\r\n"))
    snapshot = wait_for("GRAPHICS_PNG", snapshot)
    test.equal(#snapshot.images, 1)
    test.equal(snapshot.images[1].canvas:get_pixels(), string.char(255, 0, 0, 255))

    test.ok(session:write("scroll\r\n"))
    snapshot = wait_for("GRAPHICS_SCROLLED", snapshot)
    test.equal(#snapshot.images, 1)
    test.equal(snapshot.images[1].y, 0)

    test.ok(session:write("delete\r\n"))
    snapshot = wait_for("GRAPHICS_DELETED", snapshot)
    test.equal(#snapshot.images, 0)
  end)

  test.it("accepts retransmitted images after reconnecting to the same shell", function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
    open()
    wait_for("GRAPHICS_READY")
    local stats = session:stats()
    session:detach()
    open(stats.session_id)
    wait_for("GRAPHICS_READY")
    test.equal(session:stats().shell_pid, stats.shell_pid)
    test.ok(session:write("replace\r\n"))
    local snapshot = wait_for("GRAPHICS_BLUE")
    test.equal(#snapshot.images, 1)
    test.equal(snapshot.images[1].canvas:get_pixels(), string.char(0, 0, 255, 255))
  end)
end)
