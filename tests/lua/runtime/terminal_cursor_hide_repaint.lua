local common = require "core.common"
local test = require "core.test"

local function snapshot_text(snapshot)
  local parts = {}
  for _, row in ipairs(snapshot.rows or {}) do
    for _, run in ipairs(row.text_runs or {}) do
      parts[#parts + 1] = run.text
    end
    parts[#parts + 1] = "\n"
  end
  return table.concat(parts)
end

local function signal(path)
  local file = io.open(path, "wb")
  if not file then return false end
  local wrote = file:write("go")
  local closed = file:close()
  return wrote ~= nil and closed
end

local function exists(path)
  return system.get_file_info(path) ~= nil
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + timeout
  while system.get_time() < deadline do
    if predicate() then return true end
    coroutine.yield(0.01)
  end
  return predicate()
end

local function quote_argument(value)
  return '"' .. value:gsub('"', '""') .. '"'
end

local function make_fixture_command(paths, stay_hidden)
  local command = {
    "powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_cursor_hide_repaint.ps1",
    "-ReadySignal " .. quote_argument(paths.ready),
    "-HideSignal " .. quote_argument(paths.hide),
    "-HideWrittenSignal " .. quote_argument(paths.hide_written),
    "-ShowSignal " .. quote_argument(paths.show),
    "-ReleaseSignal " .. quote_argument(paths.release),
  }
  if stay_hidden then command[#command + 1] = "-StayHidden" end
  return table.concat(command, " ")
end

local function run_fixture(stay_hidden, run)
  test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
  local terminal_native = require "terminal_native"
  local root = common.normalize_path(USERDIR .. PATHSEP .. "terminal-cursor-hide-"
    .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
  test.ok(common.mkdirp(root))
  local paths = {
    ready = root .. PATHSEP .. "ready",
    hide = root .. PATHSEP .. "hide",
    hide_written = root .. PATHSEP .. "hide-written",
    show = root .. PATHSEP .. "show",
    release = root .. PATHSEP .. "release",
  }
  local session
  local ok, err = xpcall(function()
    local start_error
    session, start_error = terminal_native.new {
      cols = 80, rows = 8, cell_width = 8, cell_height = 16,
      cwd = system.getcwd(),
      shell = make_fixture_command(paths, stay_hidden),
    }
    test.ok(session, start_error)
    run({ session = session, paths = paths })
  end, debug.traceback)

  pcall(signal, paths.hide)
  pcall(signal, paths.show)
  pcall(signal, paths.release)
  if session then pcall(function() session:close() end) end
  local removed, remove_error = test.remove_tree(root)
  if not ok then error(err, 0) end
  test.ok(removed, remove_error)
end

local function wait_for_ready(fixture)
  local snapshot, text
  local ready = wait_until(function()
    fixture.session:update()
    snapshot = fixture.session:snapshot(snapshot)
    text = snapshot_text(snapshot)
    return exists(fixture.paths.ready)
      and text:find("ANVIL_REPAINT_READY", 1, true) ~= nil
      and snapshot.cursor.visible
  end, 10)
  test.ok(ready, text)
  return snapshot
end

local function start_hide(fixture)
  test.ok(signal(fixture.paths.hide), "could not signal the fixture to hide the cursor")
  test.ok(wait_until(function() return exists(fixture.paths.hide_written) end, 10),
    "the fixture did not write its cursor hide")
end

local function wait_for_deferred_hide(fixture, snapshot)
  local parsed_bytes = fixture.session:stats().output_bytes_parsed
  local deadline = system.get_time() + 10
  while system.get_time() < deadline do
    local published = fixture.session:update()
    local next_bytes = fixture.session:stats().output_bytes_parsed
    snapshot = fixture.session:snapshot(snapshot)
    if next_bytes > parsed_bytes and not published and snapshot.cursor.visible then
      return snapshot
    end
    parsed_bytes = next_bytes
    coroutine.yield(0.001)
  end
  test.fail("cursor hide output did not defer a frame while the cursor stayed visible")
end

local function wait_for_visible_done(fixture, snapshot)
  local text
  local done = wait_until(function()
    fixture.session:update()
    snapshot = fixture.session:snapshot(snapshot)
    text = snapshot_text(snapshot)
    return text:find("ANVIL_REPAINT_DONE", 1, true) ~= nil
      and snapshot.cursor.visible
  end, 10)
  test.ok(done, text)
  return snapshot
end

test.describe("Terminal cursor visibility during repaints", function()
  test.it("holds a visible cursor while hide output is parsed but not published", function()
    run_fixture(false, function(fixture)
      local snapshot = wait_for_ready(fixture)
      start_hide(fixture)
      snapshot = wait_for_deferred_hide(fixture, snapshot)
      test.ok(snapshot.cursor.visible, "the deferred update hid the visible cursor")
      test.ok(signal(fixture.paths.show), "could not signal the fixture to show the cursor")
      snapshot = wait_for_visible_done(fixture, snapshot)
      test.ok(snapshot.cursor.visible)
    end)
  end)

  test.it("publishes a cursor hide when the application keeps it hidden", function()
    run_fixture(true, function(fixture)
      local snapshot = wait_for_ready(fixture)
      start_hide(fixture)
      local hidden, marker_seen = false, false
      local deadline = system.get_time() + 10
      while system.get_time() < deadline do
        fixture.session:update()
        snapshot = fixture.session:snapshot(snapshot)
        hidden = hidden or not snapshot.cursor.visible
        marker_seen = marker_seen
          or snapshot_text(snapshot):find("ANVIL_REPAINT_HIDDEN", 1, true) ~= nil
        if hidden and marker_seen then break end
        coroutine.yield(0.001)
      end
      test.ok(hidden, "the terminal did not publish the persistent cursor hide")
      test.ok(marker_seen, "the fixture's hidden marker did not reach the screen")
    end)
  end)
end)
