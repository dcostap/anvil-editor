-- Shell probe helpers for the Project Sidebar's Context Menus. The Sidebar logs each menu that it opens, with its
-- Window, row and labels, in its session log. The shell logs when it shows and hides the menu. Probe keys choose an
-- item through the shell's input routing, as a user's keys do.
-- The probe runner copies this file to DATADIR. Use:
--   local menus = dofile(DATADIR .. "/shell_sidebar_menu.lua"){post = post, trace = trace, logs = USERDIR .. "/logs"}
-- `post(window, action, value)` posts the shell's routing probe message, and `trace()` reads the shell's log.
return function(probe)
  local menus = {}
  local KEYS = {right = 0x4000004F, ["return"] = 13, escape = 27}

  local function poll(fn, seconds)
    local deadline = system.get_time() + seconds
    repeat
      local value = fn()
      if value then return value end
      coroutine.yield(.01)
    until system.get_time() >= deadline
  end

  -- Every menu that the Sidebar opened, oldest first, as {window =, row =, labels =}.
  local function opened()
    local found = {}
    for _, name in ipairs(system.list_dir(probe.logs) or {}) do
      if name:match("%.log$") and not name:match("%-native") and not name:match("%-shutdown") then
        local file = io.open(probe.logs .. "/" .. name, "rb")
        if file then
          local text = file:read("*a"); file:close()
          for window, row, labels in text:gmatch("Sidebar menu: Window=(%d+) row=(%d+) labels=([^\r\n]-) opened=true") do
            found[#found + 1] = {window = tonumber(window), row = tonumber(row), labels = labels}
          end
        end
      end
    end
    return found
  end

  local function press(window, key)
    local code = KEYS[key] or key:byte()
    for action = 9, 10 do probe.post(window, action, code) end
  end

  local function popup_shown(mark, shown)
    return probe.trace():find("Shell Sidebar popup: Window=%d+ shown=" .. shown, mark + 1)
  end

  -- A Move can empty the menu's Window, and the shell then closes it with its menu.
  local function popup_hidden(mark)
    return popup_shown(mark, 0) or probe.trace():find("Shell removes Window: ", mark + 1, true)
  end

  ---Right-clicks the Sidebar at `at`, a packed point. Returns the menu that opens once the shell shows it, or nil
  ---when no menu opens within `seconds`.
  function menus.open(window, at, seconds)
    local count, mark = #opened(), #probe.trace()
    for action = 7, 8 do probe.post(window, action, at) end
    local menu = poll(function()
      local found = opened()
      return #found > count and found[#found]
    end, seconds or 5)
    if not menu then return nil end
    if not poll(function() return popup_shown(mark, 1) end, 5) then error("The shell did not show the Sidebar menu") end
    return menu
  end

  ---Chooses the item at the label path, such as "Snooze", "2 Hours". Each label's first letter selects the next
  ---item that starts with it, and Right opens a submenu. An empty path closes the menu with Escape.
  function menus.choose(window, ...)
    local path, mark = {...}, #probe.trace()
    if #path == 0 then press(window, "escape") end
    for index, label in ipairs(path) do
      press(window, label:sub(1, 1):lower())
      press(window, index < #path and "right" or "return")
    end
    if not poll(function() return popup_hidden(mark) end, 5) then
      error("The Sidebar menu stayed open after " .. (#path > 0 and table.concat(path, " > ") or "Escape"))
    end
  end

  ---Finds the row of the Sidebar's Project `row_id` in `window` by right-clicks down the Sidebar at x = 100. Each
  ---menu that opens closes again. Returns the packed point of the row.
  function menus.find_row(window, row_id, scale, bottom, message)
    for y = 40, bottom, 8 do
      local at = math.floor(100 * scale) + math.floor(y * scale) * 65536
      local menu = menus.open(window, at, .3)
      if menu then
        menus.choose(window)
        if menu.row == row_id then return at, menu end
      end
    end
    error(message)
  end

  return menus
end
