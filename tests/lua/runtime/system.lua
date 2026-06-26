local common = require "core.common"
local test = require "core.test"

local temp_root
local original_cwd

test.describe("system", function()
  test.before_each(function(context)
    original_cwd = system.getcwd()
    if not original_cwd then
      original_cwd = USERDIR
      system.chdir(original_cwd)
    end
    temp_root = USERDIR
      .. PATHSEP .. "system-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    local ok, err = common.mkdirp(temp_root)
    test.ok(ok, err)
    context.original_cwd = original_cwd
    context.temp_root = temp_root
  end)

  test.after_each(function(context)
    if context.original_cwd then
      system.chdir(context.original_cwd)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("handles filesystem utilities", function(context)
    local absolute = system.absolute_path(context.temp_root)
    test.not_nil(absolute)

    local info = system.get_file_info(absolute)
    test.not_nil(info)
    test.equal(info.type, "dir")

    local nested = absolute .. PATHSEP .. "nested"
    local created, err = system.mkdir(nested)
    test.ok(created, err)

    local file = io.open(nested .. PATHSEP .. "sample.txt", "wb")
    test.not_nil(file)
    file:write("hello")
    file:close()

    local entries, list_err = system.list_dir(nested)
    test.not_nil(entries, list_err)
    test.contains(entries, "sample.txt")

    local removed, remove_err = os.remove(nested .. PATHSEP .. "sample.txt")
    test.ok(removed, remove_err)

    system.chdir(nested)
    test.equal(system.getcwd():gsub("[/\\]+$", ""), nested:gsub("[/\\]+$", ""))
    system.chdir(context.original_cwd)
    test.equal(system.getcwd():gsub("[/\\]+$", ""),
      context.original_cwd:gsub("[/\\]+$", ""))

    if PLATFORM == "Linux" then
      test.type(system.get_fs_type(nested), "string")
    end
  end)

  test.test("provides process, time and environment helpers", function()
    local pid = system.get_process_id()
    test.ok(pid > 0)

    local start_time = system.get_time()
    system.sleep(0.01)
    local end_time = system.get_time()
    test.ok(end_time >= start_time)

    local key = "ANVIL_SYSTEM_TEST_ENV_" .. pid
    test.ok(system.setenv(key, "ok"))
    test.equal(os.getenv(key), "ok")

    local current_scale, refresh_rate, width, height, default_scale =
      system.get_display_info()
    test.ok(current_scale > 0)
    test.ok(refresh_rate >= 0)
    test.ok(width > 0)
    test.ok(height > 0)
    test.ok(default_scale > 0)

    local sandbox = system.get_sandbox()
    test.ok(sandbox == "none"
      or sandbox == "unknown"
      or sandbox == "flatpak"
      or sandbox == "snap"
      or sandbox == "macos")
  end)

  test.test("supports basic window helpers on a temporary window", function()
    local window = renwindow.create("system-test-window", 96, 72)
    test.not_nil(window)

    test.no_error(function() system.set_cursor("arrow") end)
    test.type(system.has_pending_events(), "boolean")
    test.type(system.wait_event(0), "boolean")

    local window_id = system.get_window_id(window)
    test.type(window_id, "number")
    test.ok(window_id > 0)
    test.equal(system.get_last_event_window_id(), nil)

    local width, height, x, y = system.get_window_size(window)
    test.ok(width > 0)
    test.ok(height > 0)
    test.type(x, "number")
    test.type(y, "number")

    test.no_error(function() system.set_window_title(window, "system-test-window-2") end)
    test.no_error(function() system.set_window_mode(window, "normal") end)
    test.equal(system.get_window_mode(window), "normal")
    test.no_error(function() system.set_window_visible(window, false) end)
    test.no_error(function() system.set_window_visible(window, true) end)
    test.no_error(function() system.set_window_bordered(window, true) end)
    test.no_error(function() system.set_window_hit_test(window) end)
    test.no_error(function() system.text_input(window, false) end)
    test.no_error(function() system.set_text_input_rect(window, 0, 0, 1, 1) end)
    test.no_error(function() system.clear_ime(window) end)
    test.no_error(function() system.raise_window(window) end)

    test.ok(system.get_scale(window) > 0)
    test.type(system.window_has_focus(window), "boolean")
    test.type(system.set_window_opacity(window, 1.0), "boolean")

    system.set_window_size(window, 80, 60, x, y)
    local resized_width, resized_height = renwindow.get_size(window)
    test.ok(resized_width > 0)
    test.ok(resized_height > 0)
  end)
end)
