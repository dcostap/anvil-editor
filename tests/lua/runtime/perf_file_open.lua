local core = require "core"
local common = require "core.common"
local command = require "core.command"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local panes = require "core.panes"
local perf = require "core.perf"
local test = require "core.test"

local function write_file(path, text)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(text)
  file:close()
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local text = file:read("*a")
  file:close()
  return text
end

test.describe("file-open performance recording", function()
  local path

  local function remove_artifacts(frames_path)
    if not frames_path then return end
    for _, suffix in ipairs {
      "_frames.csv", "_draw_scopes.csv", "_file_opens.csv", "_summary.txt",
      "_lua_samples.csv", "_api_calls.csv", "_details.csv",
    } do
      os.remove(frames_path:gsub("_frames%.csv$", suffix))
    end
  end

  test.before_each(function(context)
    path = USERDIR .. PATHSEP .. "perf-file-open-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000) .. ".lua"
    write_file(path, "local answer = 42\nreturn answer\n")
    context.frames_path = nil
  end)

  test.after_each(function(context)
    if perf.is_recording() then perf.stop_recording() end
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.reset_for_tests()
    remove_artifacts(context.frames_path)
    os.remove(path)
  end)

  test.it("records the fuzzy file-open lifecycle through first present", function(context)
    local frames_path = perf.start_recording()
    context.frames_path = frames_path
    local picker = fuzzy_searcher.open("")
    picker.results = { { kind = "file", file = path, text = path } }
    picker.selected = 1
    test.ok(command.perform("fuzzy:confirm"))

    local view = core.active_view
    test.not_nil(view)
    test.equal(view.buffer.abs_filename, common.normalize_path(path))
    core.redraw = true
    local deadline = system.get_time() + 1
    while perf.file_open_status() and system.get_time() < deadline do
      coroutine.yield(0.01)
    end
    test.is_nil(perf.file_open_status())

    local summary_path = perf.stop_recording()
    local trace_path = frames_path:gsub("_frames%.csv$", "_file_opens.csv")
    local trace = read_file(trace_path)
    local summary = read_file(summary_path)

    test.match(trace, "begin")
    test.match(trace, "fuzzy_searcher")
    test.match(trace, "fuzzy_close_picker")
    test.match(trace, "fuzzy_core_open_file")
    test.match(trace, "fuzzy_restore_selection_and_scroll")
    test.match(trace, "core_open_file")
    test.match(trace, "core_open_buffer")
    test.match(trace, "buffer_load")
    test.match(trace, "buffer_file_open")
    test.match(trace, "buffer_reset_after_open")
    test.match(trace, "buffer_file_read")
    test.match(trace, "first_view_update")
    test.match(trace, "first_view_draw")
    test.match(trace, "first_update_complete")
    test.match(trace, "first_draw_complete")
    test.match(trace, "first_present")
    test.match(summary, "status=completed completion=first_present")
    test.match(summary, "File%-open lifecycle captures: 1")
    remove_artifacts(frames_path)
    context.frames_path = nil
  end)
end)
