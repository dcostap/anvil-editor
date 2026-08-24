local core = require "core"
local command = require "core.command"
local config = require "core.config"

local keymap = {}

---@alias keymap.shortcut string
---@alias keymap.command string
---@alias keymap.modkey string
---@alias keymap.pressed boolean
---@alias keymap.map table<keymap.shortcut,keymap.command|keymap.command[]>
---@alias keymap.rmap table<keymap.command, keymap.shortcut|keymap.shortcut[]>

---Pressed status of mod keys.
---@type table<keymap.modkey, keymap.pressed>
keymap.modkeys = {}

---List of commands assigned to a shortcut been the key of the map the shortcut.
---@type keymap.map
keymap.map = {}

---List of shortcuts assigned to a command been the key of the map the command.
---@type keymap.rmap
keymap.reverse_map = {}

local macos = PLATFORM == "Mac OS X"

-- Thanks to mathewmariani, taken from his lite-macos github repository.
local modkeys_os = require("core.modkeys-" .. (macos and "macos" or "generic"))

---@type table<keymap.modkey, keymap.modkey>
local modkey_map = modkeys_os.map

---@type keymap.modkey[]
local modkeys = modkeys_os.keys


---Normalizes a stroke sequence to follow the modkeys table
---@param stroke string
---@return string
local function normalize_stroke(stroke)
  local stroke_table = {}
  for key in stroke:gmatch("[^+]+") do
    table.insert(stroke_table, key)
  end
  table.sort(stroke_table, function(a, b)
    if a == b then return false end
    for _, mod in ipairs(modkeys) do
      if a == mod or b == mod then
        return a == mod
      end
    end
    return a < b
  end)
  return table.concat(stroke_table, "+")
end


---Generates a stroke sequence including currently pressed mod keys.
---@param key string
---@return string
local function shortcut_key_alias(key)
  if key == "+" or key == "keypad +" then return "plus" end
  return key
end

local function key_to_stroke(key)
  local keys = { shortcut_key_alias(key) }
  for _, mk in ipairs(modkeys) do
    if keymap.modkeys[mk] then
      table.insert(keys, mk)
    end
  end
  return normalize_stroke(table.concat(keys, "+"))
end


---Remove the given value from an array associated to a key in a table.
---@param tbl table<string, string> The table containing the key
---@param k string The key containing the array
---@param v? string The value to remove from the array
local function remove_only(tbl, k, v)
  if tbl[k] then
    if v then
      local j = 0
      for i=1, #tbl[k] do
        while tbl[k][i + j] == v do
          j = j + 1
        end
        tbl[k][i] = tbl[k][i + j]
      end
    else
      tbl[k] = nil
    end
  end
end


---Removes from a keymap.map the bindings that are already registered.
---@param map keymap.map
local function remove_duplicates(map)
  for stroke, commands in pairs(map) do
    local normalized_stroke = normalize_stroke(stroke)
    if type(commands) == "string" or type(commands) == "function" then
      commands = { commands }
    end
    if keymap.map[normalized_stroke] then
      for _, registered_cmd in ipairs(keymap.map[normalized_stroke]) do
        local j = 0
        for i=1, #commands do
          while commands[i + j] == registered_cmd do
            j = j + 1
          end
          commands[i] = commands[i + j]
        end
      end
    end
    if #commands < 1 then
      map[stroke] = nil
    else
      map[stroke] = commands
    end
  end
end

---Add bindings by replacing commands that were previously assigned to a shortcut.
---@param map keymap.map
function keymap.add_direct(map)
  for stroke, commands in pairs(map) do
    stroke = normalize_stroke(stroke)

    if type(commands) == "string" or type(commands) == "function" then
      commands = { commands }
    end
    if keymap.map[stroke] then
      for _, cmd in ipairs(keymap.map[stroke]) do
        remove_only(keymap.reverse_map, cmd, stroke)
      end
    end
    keymap.map[stroke] = commands
    for _, cmd in ipairs(commands) do
      keymap.reverse_map[cmd] = keymap.reverse_map[cmd] or {}
      table.insert(keymap.reverse_map[cmd], stroke)
    end
  end
end


---Adds bindings by appending commands to already registered shortcut or by
---replacing currently assigned commands if overwrite is specified.
---@param map keymap.map
---@param overwrite? boolean
function keymap.add(map, overwrite)
  remove_duplicates(map)
  for stroke, commands in pairs(map) do
    if macos then
      if not stroke:match("%f[%a]cmd%f[%A]") then
        stroke = stroke:gsub("%f[%a]ctrl%f[%A]", "cmd")
      end
      stroke = stroke:gsub("%f[%a]alt%f[%A]", "option")
    end
    stroke = normalize_stroke(stroke)
    if overwrite then
      if keymap.map[stroke] then
        for _, cmd in ipairs(keymap.map[stroke]) do
          remove_only(keymap.reverse_map, cmd, stroke)
        end
      end
      keymap.map[stroke] = commands
    else
      keymap.map[stroke] = keymap.map[stroke] or {}
      for i = #commands, 1, -1 do
        table.insert(keymap.map[stroke], 1, commands[i])
      end
    end
    for _, cmd in ipairs(commands) do
      keymap.reverse_map[cmd] = keymap.reverse_map[cmd] or {}
      table.insert(keymap.reverse_map[cmd], stroke)
    end
  end
end


---Unregisters the given shortcut and associated command.
---@param shortcut string
---@param cmd string
function keymap.unbind(shortcut, cmd)
  shortcut = normalize_stroke(shortcut)
  remove_only(keymap.map, shortcut, cmd)
  remove_only(keymap.reverse_map, cmd, shortcut)
end


---Returns all the shortcuts associated to a command unpacked for easy assignment.
---@param cmd string
---@return ...
function keymap.get_binding(cmd)
  return table.unpack(keymap.reverse_map[cmd] or {})
end


---Returns all the shortcuts associated to a command packed in a table.
---@param cmd string
---@return table<integer, string> | nil shortcuts
function keymap.get_bindings(cmd)
  return keymap.reverse_map[cmd]
end


--------------------------------------------------------------------------------
-- Events listening
--------------------------------------------------------------------------------
function keymap.on_key_pressed(k, ...)
  local mk = modkey_map[k]
  if mk then
    keymap.modkeys[mk] = true
    -- work-around for windows where `altgr` is treated as `ctrl+alt`
    if mk == "altgr" then
      keymap.modkeys["ctrl"] = false
    end
  else
    local stroke = key_to_stroke(k)
    local commands, performed = keymap.map[stroke], false
    if commands then
      for _, cmd in ipairs(commands) do
        if type(cmd) == "function" then
          local ok, res = core.try(cmd, ...)
          if ok then
            performed = not (res == false)
          else
            performed = true
          end
        else
          performed = command.perform(cmd, ...)
        end
        if performed then break end
      end
      return performed
    end
  end
  return false
end

function keymap.on_mouse_wheel(delta_y, delta_x, ...)
  local y_direction = delta_y > 0 and "up" or "down"
  local x_direction = delta_x > 0 and "left" or "right"
  -- Try sending a "cumulative" event for both scroll directions
  if delta_y ~= 0 and delta_x ~= 0 then
    local result = keymap.on_key_pressed("wheel" .. y_direction .. x_direction, delta_y, delta_x, ...)
    if not result then
      result = keymap.on_key_pressed("wheelyx", delta_y, delta_x, ...)
    end
    if result then return true end
  end
  -- Otherwise send each direction as its own separate event
  local y_result, x_result
  if delta_y ~= 0 then
    y_result = keymap.on_key_pressed("wheel" .. y_direction, delta_y, ...)
    if not y_result then
      y_result = keymap.on_key_pressed("wheel", delta_y, ...)
    end
  end
  if delta_x ~= 0 then
    x_result = keymap.on_key_pressed("wheel" .. x_direction, delta_x, ...)
    if not x_result then
      x_result = keymap.on_key_pressed("hwheel", delta_x, ...)
    end
  end
  return y_result or x_result
end

function keymap.on_mouse_pressed(button, x, y, clicks)
  local click_number = (((clicks - 1) % config.max_clicks) + 1)
  return not (keymap.on_key_pressed(click_number  .. button:sub(1,1) .. "click", x, y, clicks) or
    keymap.on_key_pressed(button:sub(1,1) .. "click", x, y, clicks) or
    keymap.on_key_pressed(click_number .. "click", x, y, clicks) or
    keymap.on_key_pressed("click", x, y, clicks))
end

function keymap.on_key_released(k)
  local mk = modkey_map[k]
  if mk then
    keymap.modkeys[mk] = false
  end
end


--------------------------------------------------------------------------------
-- Register default bindings
--------------------------------------------------------------------------------
if macos then
  local keymap_macos = require("core.keymap-macos")
  keymap_macos(keymap)
  return keymap
end

keymap.add_direct {
  ["ctrl+,"] = "core:open_user_module",
  ["ctrl+alt+r"] = "core:restart",
  ["alt+return"] = "core:toggle_fullscreen",
  ["f11"] = "core:toggle_fullscreen",

  ["ctrl+w"] = "core:close_pane",
  ["ctrl+tab"] = "core:focus_next_pane",
  ["ctrl+shift+tab"] = "core:focus_previous_pane",
  ["ctrl+0"] = "core:split_pane_right",
  ["ctrl+9"] = "core:split_pane_down",
  ["ctrl+pageup"] = "core:move_pane_previous",
  ["ctrl+pagedown"] = "core:move_pane_next",
  ["alt+`"] = "core:rotate_panes_clockwise",
  ["alt+1"] = "core:focus_pane_1",
  ["alt+2"] = "core:focus_pane_2",
  ["alt+3"] = "core:focus_pane_3",
  ["alt+4"] = "core:focus_pane_4",
  ["alt+5"] = "core:focus_pane_5",
  ["alt+6"] = "core:focus_pane_6",
  ["alt+7"] = "core:focus_pane_7",
  ["alt+8"] = "core:focus_pane_8",
  ["alt+9"] = "core:focus_pane_9",
  ["wheel"] = "core:scroll",
  ["hwheel"] = "core:horizontal_scroll",
  ["shift+wheel"] = "core:horizontal_scroll",

  ["ctrl+f"] = "editor:find",
  ["ctrl+r"] = "editor:replace",
  ["f3"] = "editor:repeat_find",
  ["shift+f3"] = "editor:previous_find",
  ["ctrl+i"] = "editor:toggle_sensitivity",
  ["ctrl+shift+i"] = "editor:toggle_regex",
  ["ctrl+g"] = "editor:go_to_line",
  ["ctrl+s"] = "editor:save",
  ["ctrl+shift+s"] = "editor:save_as",

  ["ctrl+z"] = "core:undo",
  ["ctrl+y"] = "core:redo",
  ["ctrl+shift+z"] = "core:redo",
  ["ctrl+x"] = "core:cut",
  ["ctrl+c"] = "core:copy",
  ["ctrl+v"] = { "markdown:table_paste", "core:paste" },
  ["insert"] = "core:toggle_overwrite",
  ["ctrl+insert"] = "core:copy",
  ["shift+insert"] = { "markdown:table_paste", "core:paste" },
  ["escape"] = { "core:close_prompt", "core:select_none", "core:select_dialog_no" },
  ["tab"] = { "core:complete_prompt", "markdown:table_next_cell", "core:indent" },
  ["shift+tab"] = { "markdown:table_previous_cell", "core:unindent" },
  ["backspace"] = { "markdown:table_backspace", "core:backspace" },
  ["shift+backspace"] = { "markdown:table_backspace", "core:backspace" },
  ["ctrl+backspace"] = "core:delete_to_previous_word_start",
  ["ctrl+shift+backspace"] = "core:delete_to_previous_word_start",
  ["delete"] = { "markdown:table_delete", "core:delete" },
  ["shift+delete"] = { "markdown:table_delete", "core:delete" },
  ["ctrl+delete"] = "core:delete_to_next_word_end",
  ["ctrl+shift+delete"] = "core:delete_to_next_word_end",
  ["return"] = { "core:submit_prompt", "markdown:table_cell_below", "core:newline", "core:select_dialog_entry" },
  ["keypad enter"] = { "core:submit_prompt", "markdown:table_cell_below", "core:newline", "core:select_dialog_entry" },
  ["shift+return"] = "markdown:table_insert_cell_break",
  ["shift+keypad enter"] = "markdown:table_insert_cell_break",
  ["ctrl+return"] = "core:newline_below",
  ["ctrl+shift+return"] = "core:newline_above",
  ["ctrl+j"] = "editor:join_lines",
  ["ctrl+a"] = "core:select_all",
  ["ctrl+d"] = { "editor:add_selection_next_match", "core:select_word" },
  ["ctrl+f3"] = "editor:select_next",
  ["ctrl+shift+f3"] = "editor:select_previous",
  ["ctrl+l"] = "core:select_lines",
  ["ctrl+shift+l"] = { "editor:add_all_matching_selections", "core:select_word" },
  ["ctrl+/"] = "editor:toggle_line_comments",
  ["ctrl+shift+/"] = "editor:toggle_block_comments",
  ["ctrl+up"] = "editor:move_lines_up",
  ["ctrl+down"] = "editor:move_lines_down",
  ["ctrl+shift+d"] = "editor:duplicate_lines",
  ["ctrl+shift+k"] = "editor:delete_lines",

  ["left"] = { "markdown:table_previous_char", "core:move_to_previous_char", "core:select_previous_dialog_entry" },
  ["right"] = { "markdown:table_next_char", "core:move_to_next_char", "core:select_next_dialog_entry"},
  ["up"] = { "core:select_previous_prompt_item", "markdown:table_cell_up", "core:move_to_previous_line" },
  ["down"] = { "core:select_next_prompt_item", "markdown:table_cell_down", "core:move_to_next_line" },
  ["ctrl+left"] = "core:move_to_previous_word_start",
  ["ctrl+right"] = "core:move_to_next_word_end",
  ["ctrl+["] = "core:move_to_previous_block_start",
  ["ctrl+]"] = "core:move_to_next_block_end",
  ["home"] = "core:move_to_start_of_indentation",
  ["end"] = "core:move_to_end_of_line",
  ["ctrl+home"] = "core:move_to_start_of_buffer",
  ["ctrl+end"] = "core:move_to_end_of_buffer",
  ["pageup"] = "core:move_to_previous_page",
  ["pagedown"] = "core:move_to_next_page",

  ["shift+1lclick"] = "core:select_to_cursor",
  ["ctrl+1lclick"] = "core:split_cursor",
  ["1lclick"] = "core:set_cursor",
  ["2lclick"] = "core:set_cursor_word",
  ["3lclick"] = "core:set_cursor_line",
  ["mclick"] = { "markdown:table_paste_primary", "core:paste_primary_selection" },
  ["shift+left"] = { "markdown:table_select_previous_char", "core:select_to_previous_char" },
  ["shift+right"] = { "markdown:table_select_next_char", "core:select_to_next_char" },
  ["shift+up"] = { "markdown:table_select_up", "core:select_to_previous_line" },
  ["shift+down"] = { "markdown:table_select_down", "core:select_to_next_line" },
  ["ctrl+shift+left"] = "core:select_to_previous_word_start",
  ["ctrl+shift+right"] = "core:select_to_next_word_end",
  ["ctrl+shift+["] = "core:select_to_previous_block_start",
  ["ctrl+shift+]"] = "core:select_to_next_block_end",
  ["shift+home"] = "core:select_to_start_of_indentation",
  ["shift+end"] = "core:select_to_end_of_line",
  ["ctrl+shift+home"] = "core:select_to_start_of_buffer",
  ["ctrl+shift+end"] = "core:select_to_end_of_buffer",
  ["shift+pageup"] = "core:select_to_previous_page",
  ["shift+pagedown"] = "core:select_to_next_page",
  ["ctrl+shift+up"] = "editor:create_cursor_previous_line",
  ["ctrl+shift+down"] = "editor:create_cursor_next_line"
}

return keymap
