--- mod-version:3.1
-- IntelliJ-style custom editor actions and keybindings.

local core = require "core"
local keymap = require "core.keymap"
local command = require "core.command"
local common = require "core.common"
local search = require "core.buffer.search"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local file_context = require "core.file_context"
local panes = require "core.panes"

local function can_edit(dv, reason)
  return not (dv and dv.can_edit) or dv:can_edit(reason, { warn = true })
end

local function clone_caret_intellij(dv, direction)
  local TextView = require "core.textview"
  local buffer = dv.buffer
  local idx = buffer.last_selection or 1
  local line, col = buffer:get_selection_idx(idx)
  if not line then return false end
  if line + direction < 1 or line + direction > #buffer.lines then return false end

  local translate = direction < 0
    and TextView.translate.previous_line
    or TextView.translate.next_line
  local target_line, target_col = translate(buffer, line, col, dv)

  local existing_idx
  for i, l, c in buffer:get_selections(true) do
    if i ~= idx and l == target_line and c == target_col then
      existing_idx = i
      break
    end
  end

  if existing_idx and #buffer.selections > 4 then
    -- IntelliJ-like toggle while walking through carets: move to the target
    -- by removing the caret we came from when the target already has a caret.
    buffer:remove_selection(idx)
    buffer.last_selection = existing_idx > idx and existing_idx - 1 or existing_idx
  else
    buffer:add_selection(target_line, target_col, target_line, target_col)
  end
  core.blink_reset()
  return true
end

local function selection_key(line, col)
  return line .. ":" .. col
end

local function clone_caret_until_edge_intellij(dv, direction)
  local TextView = require "core.textview"
  local buffer = dv.buffer
  local changed = false

  dv:with_selection_state(function()
    local idx = buffer.last_selection or 1
    local line, col = buffer:get_selection_idx(idx)
    if not line then return end

    local translate = direction < 0
      and TextView.translate.previous_line
      or TextView.translate.next_line
    local existing = {}
    for _, l, c in buffer:get_selections(true) do
      existing[selection_key(l, c)] = true
    end

    local additions = {}
    local target_line, target_col = line, col
    while target_line + direction >= 1 and target_line + direction <= #buffer.lines do
      target_line, target_col = translate(buffer, target_line, target_col, dv)
      local key = selection_key(target_line, target_col)
      if existing[key] then
        -- Existing-caret toggling is uncommon for the bulk edge command and is
        -- subtle because removing the previous caret changes the walk origin.
        -- Keep that path exact and only use the fast path for pure additions.
        while clone_caret_intellij(dv, direction) do
          changed = true
        end
        return
      end
      existing[key] = true
      additions[#additions + 1] = { target_line, target_col }
    end

    if #additions == 0 then return end

    local merged = {}
    for _, l, c, l2, c2 in buffer:get_selections() do
      merged[#merged + 1] = { l, c, l2, c2 }
    end
    for _, pos in ipairs(additions) do
      merged[#merged + 1] = { pos[1], pos[2], pos[1], pos[2] }
    end
    table.sort(merged, function(a, b)
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end)

    local last_line, last_col = additions[#additions][1], additions[#additions][2]
    local last_selection = 1
    local selections = {}
    for i, sel in ipairs(merged) do
      selections[#selections + 1] = sel[1]
      selections[#selections + 1] = sel[2]
      selections[#selections + 1] = sel[3]
      selections[#selections + 1] = sel[4]
      if sel[1] == last_line and sel[2] == last_col and sel[3] == last_line and sel[4] == last_col then
        last_selection = i
      end
    end
    buffer.selections = selections
    buffer.last_selection = last_selection
    changed = true
  end)

  if changed then
    core.log_quiet("IntelliJ actions: cloned carets %s until buffer edge", direction < 0 and "above" or "below")
    core.blink_reset()
  end
end

command.add(nil, {
  ["user:disabled-intellij-conflict"] = function()
    -- Intentionally no-op: reserved because the same shortcut means something
    -- unrelated in the user's IntelliJ keymap.
  end,
})

command.add(function()
  local TextView = require "core.textview"
  return core.active_view and core.active_view:extends(TextView), core.active_view
end, {
  ["user:clone-caret-above-intellij"] = function(dv)
    clone_caret_intellij(dv, -1)
  end,
  ["user:clone-caret-below-intellij"] = function(dv)
    clone_caret_intellij(dv, 1)
  end,
  ["user:clone-caret-above-until-first-line-intellij"] = function(dv)
    clone_caret_until_edge_intellij(dv, -1)
  end,
  ["user:clone-caret-below-until-last-line-intellij"] = function(dv)
    clone_caret_until_edge_intellij(dv, 1)
  end,
})

local selection_history = setmetatable({}, { __mode = "k" })
local selection_origin = setmetatable({}, { __mode = "k" })
local add_next_occurrence_state = setmetatable({}, { __mode = "k" })
local closed_tabs = {}
local suppress_origin_clear = false

local function selection_state_key(buffer)
  local view = buffer and buffer.bound_selection_view
  if not view and buffer then
    local ok, TextView = pcall(require, "core.textview")
    if ok and TextView.get_buffer_mirror_owner_view then
      view = TextView.get_buffer_mirror_owner_view(buffer)
    end
  end
  return view or buffer
end

local function key_belongs_to_buffer(key, buffer)
  return key == buffer or (type(key) == "table" and key.buffer == buffer)
end

local function clear_selection_origin(buffer, all_views)
  if all_views then
    for key in pairs(selection_history) do
      if key_belongs_to_buffer(key, buffer) then selection_history[key] = nil end
    end
    for key in pairs(selection_origin) do
      if key_belongs_to_buffer(key, buffer) then selection_origin[key] = nil end
    end
    for key in pairs(add_next_occurrence_state) do
      if key_belongs_to_buffer(key, buffer) then add_next_occurrence_state[key] = nil end
    end
    return
  end
  local key = selection_state_key(buffer)
  selection_history[key] = nil
  selection_origin[key] = nil
end

local function with_origin_clear_suppressed(fn, ...)
  suppress_origin_clear = true
  local ok, a, b, c, d, e = pcall(fn, ...)
  suppress_origin_clear = false
  if not ok then error(a) end
  return a, b, c, d, e
end

local buffer_set_selection = Buffer.set_selection
function Buffer:set_selection(...)
  if not suppress_origin_clear then clear_selection_origin(self) end
  return buffer_set_selection(self, ...)
end

local buffer_set_selections = Buffer.set_selections
function Buffer:set_selections(...)
  if not suppress_origin_clear then clear_selection_origin(self) end
  return buffer_set_selections(self, ...)
end

local buffer_set_selection_list = Buffer.set_selection_list
function Buffer:set_selection_list(...)
  if not suppress_origin_clear then clear_selection_origin(self) end
  return buffer_set_selection_list(self, ...)
end

local function sync_selection_list_assignment(buffer)
  local bound_view = buffer.bound_selection_view
  if bound_view and bound_view.selection_state then
    bound_view.selection_state.selections = buffer.selections
    bound_view.selection_state.last_selection = buffer.last_selection
  elseif not buffer.__selection_text_adjusting then
    local ok, TextView = pcall(require, "core.textview")
    if ok and TextView.sync_buffer_mirror_owner_state then
      TextView.sync_buffer_mirror_owner_state(buffer)
    end
  end
end

local function set_selection_list(buffer, selections, last_selection)
  selections = selections or {}
  if #selections < 4 then
    with_origin_clear_suppressed(buffer_set_selection, buffer, 1, 1, 1, 1)
    return
  end

  local normalized = {}
  local usable_count = #selections - (#selections % 4)
  for i = 1, usable_count, 4 do
    local line1, col1 = buffer:sanitize_position(selections[i], selections[i + 1])
    local line2, col2 = buffer:sanitize_position(selections[i + 2], selections[i + 3])
    normalized[#normalized + 1] = line1
    normalized[#normalized + 1] = col1
    normalized[#normalized + 1] = line2
    normalized[#normalized + 1] = col2
  end

  buffer.selections = normalized
  buffer.last_selection = common.clamp(
    math.floor(tonumber(last_selection) or 1),
    1,
    math.max(1, math.floor(#normalized / 4))
  )
  sync_selection_list_assignment(buffer)
end

local buffer_insert = core.intellij_actions_original_buffer_insert or Buffer.insert
local buffer_remove = core.intellij_actions_original_buffer_remove or Buffer.remove
core.intellij_actions_original_buffer_insert = buffer_insert
core.intellij_actions_original_buffer_remove = buffer_remove

function Buffer:insert(...)
  if not suppress_origin_clear then clear_selection_origin(self, true) end
  return buffer_insert(self, ...)
end

function Buffer:remove(...)
  if not suppress_origin_clear then clear_selection_origin(self, true) end
  return buffer_remove(self, ...)
end

local function active_file_path(view)
  local path = file_context.view_file_path(view)
  if path then return path end
  -- FileTreeView: the view's buffer is the filetree listing, not a file; extract
  -- the path from the filetree entry at the cursor line instead.
  if view and view.entry_for_line then
    local line = view.buffer and view.buffer:get_selection(true)
    if line then
      local entry = view:entry_for_line(line)
      if entry then return entry.abs end
    end
  end
end

local function is_file_bound_view(view)
  if not view then return false end
  local GlobalPromptBar = require "core.global_prompt_bar"
  if view:is(GlobalPromptBar) then return false end
  -- FileTreeView: the view's buffer is the filetree listing; treat it as file-bound
  -- so commands like reveal-in-explorer work from the filetree cursor.
  if view.entry_for_line then return true end
  return file_context.is_file_view(view)
end

local function active_file_or_error(dv)
  local path = active_file_path(dv)
  if not path then
    core.error("No active file")
    return nil
  end
  return path
end

local function copy_text_to_clipboard(label, text)
  system.set_clipboard(text)
  core.log("Copied %s: %s", label, text)
end

local function copy_absolute_filepath(dv)
  local path = active_file_or_error(dv)
  if path then copy_text_to_clipboard("absolute filepath", path) end
end

local function copy_absolute_filepath_with_line(dv)
  local path = active_file_or_error(dv)
  if not path then return end
  local buffer = dv and dv.buffer
  local line = buffer and buffer:get_selection(false) or 1
  copy_text_to_clipboard("absolute filepath with line", string.format("%s:%d", path, line or 1))
end

local function copy_relative_filepath(dv)
  local path = active_file_or_error(dv)
  if not path then return end
  local root = core.root_project and core.root_project()
  local root_path = root and common.normalize_path(root.path)
  if not root_path or not common.path_belongs_to(path, root_path) then
    core.error("Active file is not inside the project: %s", path)
    return
  end
  copy_text_to_clipboard("relative filepath", common.relative_path(root_path, path):gsub("\\", "/"))
end

local function copy_project_path()
  local project = core.root_project and core.root_project()
  local path = project and project.path
  if not path or path == "" then
    core.error("No Root Project")
    return
  end
  copy_text_to_clipboard("project path", path)
end

local function copy_filename(dv)
  local path = active_file_or_error(dv)
  if path then copy_text_to_clipboard("filename", common.basename(path)) end
end

local function open_file_as_raw_text(dv)
  local path = active_file_or_error(dv)
  if not path then return end
  local buffer = core.open_buffer(path)
  core.root_panel:open_buffer(buffer)
end

local function open_file_in_associated_program(dv)
  local path = active_file_or_error(dv)
  if not path then return end

  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then
    core.error("Active file does not exist on disk: %s", path)
    return
  end

  if not common.open_in_system(path) then
    core.error("Could not open file in associated OS program: %s", path)
  end
end

local function reveal_active_file_in_explorer(dv)
  local path = active_file_path(dv)
  if not path or path == "" then
    core.error("No active file to reveal")
    return
  end

  local info = system.get_file_info(path)
  if not info or (info.type ~= "file" and info.type ~= "dir") then
    core.error("Active file does not exist on disk: %s", path)
    return
  end

  if PLATFORM == "Windows" then
    local win_path = path:gsub("/", "\\"):gsub('"', '\\"')
    -- Explorer's /select argument is picky: when the path contains spaces it
    -- must be quoted inside the same /select, argument, otherwise Explorer can
    -- ignore it and fall back to the default Documents location.
    system.exec(string.format('explorer.exe /select,"%s"', win_path))
  else
    common.open_in_system(path:match("^(.*)[/\\][^/\\]+$") or path)
  end
end

local function shell_quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function try_start_terminal_process(command_args, cwd)
  local ok, process = pcall(require, "core.process")
  if not ok or not process or not process.start then return false end

  local proc = process.start(command_args, {
    cwd = cwd,
    detach = true,
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_DISCARD,
    stderr = process.REDIRECT_DISCARD,
  })
  return proc ~= nil
end

local function open_os_terminal_at_directory(dir)
  if PLATFORM == "Windows" then
    if try_start_terminal_process({ "wt.exe", "-d", dir }, dir) then
      return true
    end

    core.log_quiet("Windows Terminal unavailable; falling back to cmd.exe")
    local win_dir = dir:gsub("/", "\\"):gsub('"', '\\"')
    system.exec(string.format('start /D "%s" cmd.exe', win_dir))
    return true
  end

  if PLATFORM == "Mac OS X" then
    system.exec("open -a Terminal " .. shell_quote(dir))
    return true
  end

  for _, args in ipairs({
    { "x-terminal-emulator" },
    { "gnome-terminal" },
    { "konsole" },
    { "xfce4-terminal" },
    { "xterm" },
  }) do
    if try_start_terminal_process(args, dir) then return true end
  end

  return false
end

local function open_terminal_at_active_file(dv)
  local path = active_file_path(dv)
  if not path or path == "" then
    core.error("No active file for terminal")
    return
  end

  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then
    core.error("Active file does not exist on disk: %s", path)
    return
  end

  local dir = common.dirname(path)
  if not dir or dir == "" then
    core.error("Could not determine active file directory: %s", path)
    return
  end

  core.log_quiet("Opening OS terminal at active file directory: %s", dir)
  if not open_os_terminal_at_directory(dir) then
    core.error("Could not open OS terminal at: %s", dir)
  end
end

local function record_navigation_place(reason)
  panes.record_location()
end

local editor_on_close = Editor.on_close
function Editor:on_close()
  local path = active_file_path(self)
  if path then
    table.insert(closed_tabs, path)
  end
  return editor_on_close(self)
end

local selection_debug_log = USERDIR .. PATHSEP .. "selection-expansion-debug.log"

local function selection_debug_write(message)
  local fp = io.open(selection_debug_log, "a")
  if fp then
    fp:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), " ", message, "\n")
    fp:close()
  end
end

local function selection_debug_repr(text)
  text = tostring(text or "")
  text = text:gsub("\r", "\\r"):gsub("\n", "\\n")
  if #text > 500 then text = text:sub(1, 500) .. "..." end
  return text
end

local function build_text_index(buffer)
  local starts, text, offset = {}, {}, 0
  for i, line in ipairs(buffer.lines) do
    starts[i] = offset
    text[#text + 1] = line
    offset = offset + #line
  end
  return table.concat(text), starts
end

local function pos_to_offset(starts, line, col)
  return starts[line] + col - 1
end

local function offset_to_pos(buffer, starts, offset)
  offset = math.max(0, offset)
  for line = 1, #starts do
    local next_start = starts[line + 1]
    if not next_start or offset < next_start then
      return buffer:sanitize_position(line, offset - starts[line] + 1)
    end
  end
  return buffer:sanitize_position(#buffer.lines, math.huge)
end

local function monotonic_offset_to_pos(buffer, starts)
  local line = 1
  return function(offset)
    offset = math.max(0, offset)
    while starts[line + 1] and offset >= starts[line + 1] do
      line = line + 1
    end
    return buffer:sanitize_position(line, offset - starts[line] + 1)
  end
end

local function is_identifier_char(ch)
  return ch ~= nil and ch:match("[%w_$]") ~= nil
end

local function is_lower_or_digit(ch)
  return ch ~= nil and ch:match("[%l%d]") ~= nil
end

local function is_upper(ch)
  return ch ~= nil and ch:match("%u") ~= nil
end

local function is_letter_or_digit(ch)
  return ch ~= nil and ch:match("[%w]") ~= nil
end

local function is_whitespace(ch)
  return ch ~= nil and ch:match("%s") ~= nil
end

local function is_punctuation(ch)
  return ch ~= nil and not is_identifier_char(ch) and not is_whitespace(ch)
end

local function is_hump_bound(text, offset, is_start)
  if offset <= 0 or offset >= #text then return false end
  local prev = text:sub(offset, offset)
  local curr = text:sub(offset + 1, offset + 1)
  local nextc = offset + 1 < #text and text:sub(offset + 2, offset + 2) or nil
  local hump = is_start and curr or prev
  local neighbor = is_start and prev or curr

  return (is_lower_or_digit(prev) and is_upper(curr))
      or (neighbor == "_" and hump ~= "_")
      or (neighbor == "$" and is_letter_or_digit(hump))
      or (is_upper(prev) and is_upper(curr) and is_lower_or_digit(nextc) and not nextc:match("%d"))
end

local function is_word_boundary(text, offset, camel, is_start)
  if offset < 0 or offset > #text then return false end
  local prev = offset > 0 and text:sub(offset, offset) or nil
  local curr = offset < #text and text:sub(offset + 1, offset + 1) or nil
  local word = is_start and curr or prev
  local neighbor = is_start and prev or curr

  if is_identifier_char(word) then
    if not is_identifier_char(neighbor) then return true end
    if camel and is_hump_bound(text, offset, is_start) then return true end
  end
  if is_punctuation(word) and not is_punctuation(neighbor) then return true end
  return false
end

local function is_word_start(text, offset, camel)
  return is_word_boundary(text, offset, camel, true)
end

local function is_word_end(text, offset, camel)
  return is_word_boundary(text, offset, camel, false)
end

local function move_caret_camel_word_with_selection(dv, direction)
  local buffer = dv.buffer
  local text, starts = build_text_index(buffer)
  local selections = {}

  for idx, l1, c1, l2, c2 in buffer:get_selections(false) do
    local offset = pos_to_offset(starts, l1, c1)
    local line = select(1, offset_to_pos(buffer, starts, offset))
    local target = offset

    if direction > 0 then
      local line_end = starts[line] + #(buffer.lines[line] or "") - 1
      for new_offset = offset + 1, math.min(#text, line_end) do
        if new_offset == line_end or is_word_end(text, new_offset, true) then
          target = new_offset
          break
        end
      end
    else
      local line_start = starts[line]
      for new_offset = offset - 1, line_start, -1 do
        if new_offset == line_start or is_word_start(text, new_offset, true) then
          target = new_offset
          break
        end
      end
    end

    local nl, nc = offset_to_pos(buffer, starts, target)
    selections[#selections + 1] = { idx = idx, l1 = nl, c1 = nc, l2 = l2, c2 = c2 }
  end

  for _, sel in ipairs(selections) do
    with_origin_clear_suppressed(buffer_set_selections, buffer, sel.idx, sel.l1, sel.c1, sel.l2, sel.c2)
  end

  local l, c = buffer:get_selection(false)
  if l and c then dv:scroll_to_make_visible(l, c) end
  clear_selection_origin(buffer)
end

local function smart_selection_blocks(text)
  local blocks, stack = {}, {}
  local opens = { ["("] = ")", ["["] = "]", ["{"] = "}" }
  local closes = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
  local quote_open = {}

  for i = 1, #text do
    local ch = text:sub(i, i)
    local prev = i > 1 and text:sub(i - 1, i - 1) or ""
    if (ch == '"' or ch == "'" or ch == "`") and prev ~= "\\" then
      if quote_open[ch] then
        local open = quote_open[ch]
        if not text:sub(open, i):find("\n", 1, true) then
          blocks[#blocks + 1] = { open = open - 1, close = i - 1, kind = "quote" }
        end
        quote_open[ch] = nil
      else
        quote_open[ch] = i
      end
    elseif opens[ch] then
      stack[#stack + 1] = { ch = ch, index = i }
    elseif closes[ch] then
      for s = #stack, 1, -1 do
        if stack[s].ch == closes[ch] then
          local open = stack[s].index
          blocks[#blocks + 1] = { open = open - 1, close = i - 1, kind = "bracket" }
          table.remove(stack, s)
          break
        end
      end
    end
  end

  table.sort(blocks, function(a, b)
    if (a.close - a.open) == (b.close - b.open) then return a.open > b.open end
    return (a.close - a.open) < (b.close - b.open)
  end)
  return blocks
end

local function set_selection_offsets(buffer, starts, start_offset, end_offset, reason)
  local caret_l, caret_c, anchor_l, anchor_c = buffer:get_selection(false)
  local old_l1, old_c1, old_l2, old_c2 = buffer:get_selection(true)
  local old_start = pos_to_offset(starts, old_l1, old_c1)
  local old_end = pos_to_offset(starts, old_l2, old_c2)
  local caret_offset = pos_to_offset(starts, caret_l, caret_c)
  local old_text = buffer:get_text(old_l1, old_c1, old_l2, old_c2)
  local l1, c1 = offset_to_pos(buffer, starts, start_offset)
  local l2, c2 = offset_to_pos(buffer, starts, end_offset)
  local new_text = buffer:get_text(l1, c1, l2, c2)
  selection_debug_write(string.format(
    "reason=%s old=%d..%d (%d:%d-%d:%d) caret=%d (%d:%d) new=%d..%d (%d:%d-%d:%d) old_text=\"%s\" new_text=\"%s\"",
    tostring(reason or "unknown"), old_start, old_end, old_l1, old_c1, old_l2, old_c2,
    caret_offset, caret_l, caret_c, start_offset, end_offset, l1, c1, l2, c2,
    selection_debug_repr(old_text), selection_debug_repr(new_text)
  ))

  -- Anvil selections can only place the caret at one end of the range.
  -- Preserve the caret side instead of always forcing it to the selection start:
  -- if the caret was at/near the left edge, keep it on the left; otherwise keep
  -- it on the right. This matches IntelliJ's stable-caret feel as closely as the
  -- selection model allows and prevents expand from always jumping to start.
  local old_mid = old_start + (old_end - old_start) / 2
  if caret_offset <= old_mid then
    with_origin_clear_suppressed(buffer_set_selection, buffer, l1, c1, l2, c2)
  else
    with_origin_clear_suppressed(buffer_set_selection, buffer, l2, c2, l1, c1)
  end
  core.blink_reset()
end

local function push_selection_history(buffer, start_offset, end_offset)
  local key = selection_state_key(buffer)
  local history = selection_history[key] or {}
  selection_history[key] = history
  if #history == 0 and not selection_origin[key] then
    local caret_l, caret_c = buffer:get_selection(false)
    selection_origin[key] = pos_to_offset(select(2, build_text_index(buffer)), caret_l, caret_c)
  end
  history[#history + 1] = { start_offset, end_offset }
end

local function next_selection_candidate(sel_start, sel_end, candidates)
  table.sort(candidates, function(a, b)
    local as, bs = a.end_offset - a.start_offset, b.end_offset - b.start_offset
    if as == bs then return a.start_offset > b.start_offset end
    return as < bs
  end)
  for _, cand in ipairs(candidates) do
    if cand.start_offset <= sel_start and cand.end_offset >= sel_end
       and (cand.start_offset < sel_start or cand.end_offset > sel_end)
       and cand.start_offset < cand.end_offset then
      return cand
    end
  end
end

local function select_next_candidate(buffer, starts, sel_start, sel_end, candidates)
  local cand = next_selection_candidate(sel_start, sel_end, candidates)
  if cand then
    push_selection_history(buffer, sel_start, sel_end)
    set_selection_offsets(buffer, starts, cand.start_offset, cand.end_offset, cand.reason)
    return true
  end
  return false
end

local function add_block_candidates(candidates, blocks, sel_start, sel_end)
  for _, b in ipairs(blocks) do
    if b.open <= sel_start and b.close >= sel_end then
      candidates[#candidates + 1] = { start_offset = b.open + 1, end_offset = b.close, reason = "block-content" }
      candidates[#candidates + 1] = { start_offset = b.open, end_offset = b.close + 1, reason = "block-full" }
    end
  end
end

local function innermost_enclosing_block(blocks, sel_start, sel_end)
  local best
  for _, b in ipairs(blocks) do
    if b.open <= sel_start and b.close >= sel_end then
      if not best or (b.close - b.open) < (best.close - best.open) then
        best = b
      end
    end
  end
  return best
end

local function block_opening_on_line(blocks, starts, line, line_text)
  local line_start = starts[line]
  local line_end = line_start + #(line_text or "")
  local best
  for _, b in ipairs(blocks) do
    if b.kind ~= "quote" and b.open >= line_start and b.open <= line_end then
      if not best or b.open < best.open then best = b end
    end
  end
  return best
end

local function set_selection_offsets_idx(buffer, starts, idx, caret_l, caret_c, l1, c1, l2, c2, start_offset, end_offset)
  local old_start = pos_to_offset(starts, l1, c1)
  local old_end = pos_to_offset(starts, l2, c2)
  local caret_offset = pos_to_offset(starts, caret_l, caret_c)
  local nl1, nc1 = offset_to_pos(buffer, starts, start_offset)
  local nl2, nc2 = offset_to_pos(buffer, starts, end_offset)

  local old_mid = old_start + (old_end - old_start) / 2
  if caret_offset <= old_mid then
    with_origin_clear_suppressed(buffer_set_selections, buffer, idx, nl1, nc1, nl2, nc2)
  else
    with_origin_clear_suppressed(buffer_set_selections, buffer, idx, nl2, nc2, nl1, nc1)
  end
end

local function expand_block_selection(dv)
  local buffer = dv.buffer
  local text, starts = build_text_index(buffer)
  local blocks = smart_selection_blocks(text)

  if #buffer.selections <= 4 then
    local l1, c1, l2, c2 = buffer:get_selection(true)
    local sel_start, sel_end = pos_to_offset(starts, l1, c1), pos_to_offset(starts, l2, c2)
    local candidates = {}
    add_block_candidates(candidates, blocks, sel_start, sel_end)
    select_next_candidate(buffer, starts, sel_start, sel_end, candidates)
    return
  end

  local updates = {}
  for idx, caret_l, caret_c, anchor_l, anchor_c in buffer:get_selections(false) do
    local l1, c1, l2, c2 = buffer:get_selection_idx(idx, true)
    local sel_start, sel_end = pos_to_offset(starts, l1, c1), pos_to_offset(starts, l2, c2)
    local candidates = {}
    add_block_candidates(candidates, blocks, sel_start, sel_end)
    local cand = next_selection_candidate(sel_start, sel_end, candidates)
    if cand then
      updates[#updates + 1] = {
        idx = idx,
        caret_l = caret_l, caret_c = caret_c,
        l1 = l1, c1 = c1, l2 = l2, c2 = c2,
        start_offset = cand.start_offset,
        end_offset = cand.end_offset,
      }
    end
  end

  for _, update in ipairs(updates) do
    set_selection_offsets_idx(
      buffer, starts, update.idx, update.caret_l, update.caret_c,
      update.l1, update.c1, update.l2, update.c2,
      update.start_offset, update.end_offset
    )
  end
  core.blink_reset()
end

local function is_code_paragraph_blank(line)
  local s = (line or ""):match("^%s*(.-)%s*$") or ""
  return s == ""
      or s:match("^//") or s:match("^#") or s:match("^%-%-")
      or s:match("^/%*") or s:match("^%*") or s:match("^%*/")
      -- Treat structural delimiter-only lines as paragraph boundaries too.
      or s:match("^[%(%[%{%}%]%),;]+$")
end

local function first_nonblank_col(line)
  return (line or ""):find("%S") or 1
end

local function move_caret_paragraph(dv, direction)
  -- Mirrors IntelliJ's ForwardParagraphAction / BackwardParagraphAction:
  -- paragraphs are separated only by truly empty lines; target is the start of
  -- the separator line after the current paragraph, or the start of the next
  -- paragraph when moving backward.
  local buffer = dv.buffer
  local line, col = buffer:get_selection(false)
  local current = line
  local target_line, target_col

  local function is_empty(idx)
    return ((buffer.lines[idx] or ""):match("^%s*$") ~= nil)
  end

  if direction > 0 then
    if is_empty(current) then
      current = current + 1
      while current <= #buffer.lines and is_empty(current) do
        current = current + 1
      end
    end

    target_line, target_col = #buffer.lines, #(buffer.lines[#buffer.lines] or "") + 1
    current = current + 1
    while current <= #buffer.lines do
      if is_empty(current) then
        target_line, target_col = current, 1
        break
      end
      current = current + 1
    end
  else
    local at_line_start = col == 1
    if is_empty(current) or at_line_start then
      current = current - 1
      while current >= 1 and is_empty(current) do
        current = current - 1
      end
    end

    current = current - 1
    while current >= 1 do
      if is_empty(current) then break end
      current = current - 1
    end

    if current >= 1 then
      target_line = current
      target_col = 1
    else
      target_line, target_col = 1, 1
    end
  end

  if target_line ~= line or target_col ~= col then record_navigation_place("paragraph") end
  buffer:set_selection(target_line, target_col, target_line, target_col)
  dv:scroll_to_make_visible(target_line, target_col)
end

local function block_depth_at(text, offset)
  local depth = 0
  local opens = { ["("] = true, ["["] = true, ["{"] = true }
  local closes = { [")"] = true, ["]"] = true, ["}"] = true }
  for i = 1, math.min(#text, offset) do
    local ch = text:sub(i, i)
    if opens[ch] then depth = depth + 1 end
    if closes[ch] then depth = math.max(0, depth - 1) end
  end
  return depth
end

local function smart_selection_candidates(buffer, text, starts, blocks, l1, c1, l2, c2)
  local sel_start, sel_end = pos_to_offset(starts, l1, c1), pos_to_offset(starts, l2, c2)
  local candidates = {}

  -- IntelliJ-ish granular growth: word -> line -> code paragraph -> bracket/quote blocks -> buffer.
  local line_text = buffer.lines[l1] or ""
  local line_start = starts[l1]
  local line_end = starts[l1 + 1] or (starts[l1] + #line_text)

  local word_start, word_end = sel_start, sel_end
  while word_start > line_start and text:sub(word_start, word_start):match("[%w_]") do
    word_start = word_start - 1
  end
  while word_end < line_end and text:sub(word_end + 1, word_end + 1):match("[%w_]") do
    word_end = word_end + 1
  end
  candidates[#candidates + 1] = { start_offset = word_start, end_offset = word_end, reason = "word" }

  local content_start_col = line_text:find("%S")
  local sentence_start = content_start_col and (line_start + content_start_col - 1) or line_start
  local sentence_end = line_start + #(line_text:match("^(.-)%s*$") or line_text)
  candidates[#candidates + 1] = { start_offset = sentence_start, end_offset = sentence_end, reason = "sentence" }

  local opens_named_block = false
  local line_block = block_opening_on_line(blocks, starts, l1, line_text)
  if line_block and sel_start >= line_start and sel_end <= line_block.close + 1 then
    opens_named_block = true
    candidates[#candidates + 1] = { start_offset = line_start, end_offset = line_block.close + 1, reason = "named-block-full" }
  end

  if not opens_named_block then
    candidates[#candidates + 1] = { start_offset = line_start, end_offset = line_end, reason = "line" }
  end

  local block = innermost_enclosing_block(blocks, sel_start, sel_end)
  local block_content_start = block and (block.open + 1) or 0
  local block_content_end = block and block.close or #text
  local block_start_line = select(1, offset_to_pos(buffer, starts, block_content_start))
  local block_end_line = select(1, offset_to_pos(buffer, starts, block_content_end))

  local base_depth = block_depth_at(text, sel_start)
  local p1, p2 = l1, l2
  while p1 > block_start_line
    and not is_code_paragraph_blank(buffer.lines[p1 - 1])
    and block_depth_at(text, starts[p1 - 1]) == base_depth do
    p1 = p1 - 1
  end
  while p2 < block_end_line
    and not is_code_paragraph_blank(buffer.lines[p2 + 1])
    and block_depth_at(text, starts[p2 + 1]) == base_depth do
    local next_block = block_opening_on_line(blocks, starts, p2 + 1, buffer.lines[p2 + 1])
    if next_block and next_block.open >= sel_end then
      local close_line = select(1, offset_to_pos(buffer, starts, next_block.close + 1))
      p2 = math.min(close_line, block_end_line)
      break
    end
    p2 = p2 + 1
  end
  if not opens_named_block then
    local paragraph_end
    if is_code_paragraph_blank(buffer.lines[p2]) then
      paragraph_end = starts[p2]
    else
      paragraph_end = starts[p2 + 1] or (starts[p2] + #(buffer.lines[p2] or ""))
    end
    candidates[#candidates + 1] = {
      start_offset = math.max(starts[p1], block_content_start),
      end_offset = math.min(paragraph_end, block_content_end),
      reason = "paragraph"
    }
  end

  add_block_candidates(candidates, blocks, sel_start, sel_end)
  candidates[#candidates + 1] = { start_offset = 0, end_offset = #text, reason = "buffer" }
  return candidates, sel_start, sel_end
end

local function push_multi_selection_history(buffer)
  local key = selection_state_key(buffer)
  local history = selection_history[key] or {}
  selection_history[key] = history
  history[#history + 1] = { multi = true, selections = { table.unpack(buffer.selections) }, last_selection = buffer.last_selection }
end

local function try_treesitter_expand_selection(buffer)
  local ok, treesitter = pcall(require, "core.treesitter")
  if not ok or not treesitter or not treesitter.expand_selection then return false end
  local expanded, reason = treesitter.expand_selection(buffer)
  if expanded then return true end
  if core.log_quiet then core.log_quiet("Tree-sitter smart selection expand fallback: %s", tostring(reason)) end
  return false
end

local function try_treesitter_shrink_selection(buffer)
  local ok, treesitter = pcall(require, "core.treesitter")
  if not ok or not treesitter or not treesitter.shrink_selection then return false end
  local shrunk, reason = treesitter.shrink_selection(buffer)
  if shrunk then return true end
  if core.log_quiet then core.log_quiet("Tree-sitter smart selection shrink fallback: %s", tostring(reason)) end
  return false
end

local function extend_smart_selection(dv)
  local buffer = dv.buffer
  if try_treesitter_expand_selection(buffer) then return end
  local text, starts = build_text_index(buffer)
  local blocks = smart_selection_blocks(text)

  if #buffer.selections <= 4 then
    local l1, c1, l2, c2 = buffer:get_selection(true)
    local candidates, sel_start, sel_end = smart_selection_candidates(buffer, text, starts, blocks, l1, c1, l2, c2)
    select_next_candidate(buffer, starts, sel_start, sel_end, candidates)
    return
  end

  local updates = {}
  for idx, caret_l, caret_c in buffer:get_selections(false) do
    local l1, c1, l2, c2 = buffer:get_selection_idx(idx, true)
    local candidates, sel_start, sel_end = smart_selection_candidates(buffer, text, starts, blocks, l1, c1, l2, c2)
    local cand = next_selection_candidate(sel_start, sel_end, candidates)
    if cand then
      updates[#updates + 1] = {
        idx = idx, caret_l = caret_l, caret_c = caret_c,
        l1 = l1, c1 = c1, l2 = l2, c2 = c2,
        start_offset = cand.start_offset, end_offset = cand.end_offset,
      }
    end
  end

  if #updates == 0 then return end
  push_multi_selection_history(buffer)
  for _, update in ipairs(updates) do
    set_selection_offsets_idx(buffer, starts, update.idx, update.caret_l, update.caret_c,
      update.l1, update.c1, update.l2, update.c2, update.start_offset, update.end_offset)
  end
  core.blink_reset()
end

local function shrink_smart_selection(dv)
  local buffer = dv.buffer
  if try_treesitter_shrink_selection(buffer) then return end
  local key = selection_state_key(buffer)
  local history = selection_history[key]
  if not history or #history == 0 then return end
  local text, starts = build_text_index(buffer)
  local prev = table.remove(history)
  if #history == 0 then selection_origin[key] = nil end
  if prev.multi then
    set_selection_list(buffer, prev.selections, prev.last_selection)
    core.blink_reset()
  else
    set_selection_offsets(buffer, starts, prev[1], prev[2], "shrink-history")
  end
end

local function restore_selection_origin_or_select_none(dv)
  local buffer = dv.buffer
  local key = selection_state_key(buffer)
  local origin = selection_origin[key]
  selection_history[key] = nil
  selection_origin[key] = nil
  if origin then
    local _, starts = build_text_index(buffer)
    local line, col = offset_to_pos(buffer, starts, origin)
    with_origin_clear_suppressed(buffer_set_selection, buffer, line, col, line, col)
    core.blink_reset()
  else
    command.perform("text:select-none")
  end
end

local function duplicate_current_line(dv)
  if not can_edit(dv, "duplicate line") then return end
  local buffer = dv.buffer
  local actions = {}
  local last_selection = buffer.last_selection or 1

  for idx, l1, c1, l2, c2 in buffer:get_selections(true) do
    local first_line, last_line = l1, l2
    if c2 == 1 and l2 > l1 then last_line = l2 - 1 end

    local lines = {}
    for line = first_line, last_line do
      lines[#lines + 1] = buffer.lines[line]
    end

    actions[#actions + 1] = {
      idx = idx,
      l1 = l1,
      c1 = c1,
      l2 = l2,
      c2 = c2,
      first_line = first_line,
      last_line = last_line,
      line_count = #lines,
      text = table.concat(lines),
    }
  end

  local edits = {}
  for _, action in ipairs(actions) do
    if action.last_line >= #buffer.lines then
      -- Buffer positions are clamped to existing characters.  Inserting at
      -- line_count + 1 on the final line lands before the final newline (or
      -- before the last character in a no-newline EOF), which appends the copy
      -- to the same visual line.  Insert at the final line's clamp point with
      -- an explicit separator instead.
      local final_text = buffer.lines[#buffer.lines] or "\n"
      local col = math.max(1, #final_text)
      local text
      if final_text:find("\n$") then
        text = "\n" .. action.text:gsub("\n$", "")
      else
        text = final_text:sub(-1) .. "\n" .. action.text:sub(1, -2)
      end
      edits[#edits + 1] = { line1 = #buffer.lines, col1 = col, line2 = #buffer.lines, col2 = col, text = text, idx = action.idx }
    else
      edits[#edits + 1] = { line1 = action.last_line + 1, col1 = 1, line2 = action.last_line + 1, col2 = 1, text = action.text, idx = action.idx }
    end
  end

  table.sort(actions, function(a, b)
    return a.idx < b.idx
  end)

  local new_selections = {}
  for _, action in ipairs(actions) do
    local lines_inserted_before = 0
    for _, other in ipairs(actions) do
      if other.last_line < action.first_line then
        lines_inserted_before = lines_inserted_before + other.line_count
      end
    end
    new_selections[#new_selections + 1] = action.l1 + lines_inserted_before + action.line_count
    new_selections[#new_selections + 1] = action.c1
    new_selections[#new_selections + 1] = action.l2 + lines_inserted_before + action.line_count
    new_selections[#new_selections + 1] = action.c2
  end
  if #edits > 0 then
    with_origin_clear_suppressed(function()
      buffer:apply_edits(edits, {
        type = "insert",
        selections = new_selections,
        last_selection = math.min(last_selection, #actions),
        merge_cursors = false,
      })
    end)
  else
    set_selection_list(buffer, new_selections, math.min(last_selection, #actions))
  end
  clear_selection_origin(buffer)
end

local function move_to_matching_bracket_with_history(dv)
  command.perform("bracket-match:move-to-matching")
end

local function reopen_last_closed_tab()
  while #closed_tabs > 0 do
    local filename = table.remove(closed_tabs)
    if system.get_file_info(filename) then
      core.open_file(filename)
      return
    end
  end
end

command.add(nil, {
  ["user:reopen-last-closed-tab"] = reopen_last_closed_tab,
})

local function line_comment_at_start(dv)
  if not can_edit(dv, "toggle comments") then return end
  local buffer = dv.buffer
  local comment = (buffer.syntax and buffer.syntax.comment) or "//"
  if type(comment) == "table" then comment = comment[1] end
  comment = tostring(comment or "//")

  local l1, c1, l2, c2 = buffer:get_selection(true)
  local first_line, last_line = l1, l2
  if c2 == 1 and l2 > l1 then last_line = l2 - 1 end

  local uncomment = true
  for line = first_line, last_line do
    if buffer.lines[line]:sub(1, #comment) ~= comment then
      uncomment = false
      break
    end
  end

  local edits = {}
  for line = first_line, last_line do
    if uncomment then
      edits[#edits + 1] = { line1 = line, col1 = 1, line2 = line, col2 = #comment + 1, text = "" }
    else
      edits[#edits + 1] = { line1 = line, col1 = 1, line2 = line, col2 = 1, text = comment }
    end
  end

  local delta = uncomment and -#comment or #comment
  local function adjust_col(line, col)
    if line >= first_line and line <= last_line then
      return math.max(1, col + delta)
    end
    return col
  end
  local selections = { l1, adjust_col(l1, c1), l2, adjust_col(l2, c2) }
  if #edits > 0 then
    with_origin_clear_suppressed(function()
      buffer:apply_edits(edits, {
        type = uncomment and "remove" or "insert",
        selections = selections,
        last_selection = buffer.last_selection,
        merge_cursors = false,
      })
    end)
  else
    buffer:set_selection(table.unpack(selections))
  end
  clear_selection_origin(buffer)
end

local function offset_in_any_selection(buffer, starts, offset)
  for _, l1, c1, l2, c2 in buffer:get_selections(true) do
    local s, e = pos_to_offset(starts, l1, c1), pos_to_offset(starts, l2, c2)
    if offset >= s and offset < e then return true end
  end
  return false
end

local function selection_text_for_occurrences(dv)
  local buffer = dv.buffer
  if not buffer:has_selection() then
    command.perform("text:select-word")
  end

  local text, compare_text
  for _, l1, c1, l2, c2 in buffer:get_selections(true) do
    local selection = buffer:get_text(l1, c1, l2, c2)
    local compare_selection = config.select_add_next_no_case and selection:lower() or selection
    if not text then
      text = selection
      compare_text = compare_selection
    end
    if compare_selection ~= compare_text or selection == "" then return nil end
  end
  return text
end

local function add_selection_for_next_occurrence(dv)
  local buffer = dv.buffer
  local key = selection_state_key(buffer)
  local had_selection = buffer:has_selection()
  local text = selection_text_for_occurrences(dv)
  if not text then return end
  if not had_selection then
    add_next_occurrence_state[key] = nil
    return
  end

  local full_text, starts = build_text_index(buffer)

  -- Continue from the active/last-added selection, not from the bottom-most
  -- selection. After wrap-around, the active selection is above older ones.
  local _, _, active_l2, active_c2 = buffer:get_selection_idx(buffer.last_selection, true)
  local last_end_offset = pos_to_offset(starts, active_l2, active_c2)

  local state = add_next_occurrence_state[key]
  local wrap_armed = state and state.text == text and state.armed
  local start_offset = wrap_armed and 0 or last_end_offset
  local find_text = config.select_add_next_no_case and text:lower() or text
  local haystack = config.select_add_next_no_case and full_text:lower() or full_text

  local function find_unselected_from(search_at)
    while true do
      local s, e = haystack:find(find_text, search_at, true)
      if not s then return nil, nil end
      local off = s - 1
      if not offset_in_any_selection(buffer, starts, off) then
        return off, e
      end
      search_at = e + 1
    end
  end

  local found_start, found_end = find_unselected_from(start_offset + 1)

  if not found_start then
    -- First press at EOF only arms wrap and does nothing. Press again to wrap.
    add_next_occurrence_state[key] = { text = text, armed = true }
    return
  end

  local l1, c1 = offset_to_pos(buffer, starts, found_start)
  local l2, c2 = offset_to_pos(buffer, starts, found_end)
  buffer:add_selection(l2, c2, l1, c1)
  dv:scroll_to_make_visible(l2, c2)
  add_next_occurrence_state[key] = nil
end

local function select_all_occurrences(dv)
  local buffer = dv.buffer
  local text = selection_text_for_occurrences(dv)
  if not text then return end

  local full_text, starts = build_text_index(buffer)
  local find_text = config.select_add_next_no_case and text:lower() or text
  local haystack = config.select_add_next_no_case and full_text:lower() or full_text
  local search_at = 1
  local to_pos = monotonic_offset_to_pos(buffer, starts)
  local new_selections = {}

  while true do
    local s, e = haystack:find(find_text, search_at, true)
    if not s then break end
    local l1, c1 = to_pos(s - 1)
    local l2, c2 = to_pos(e)
    new_selections[#new_selections + 1] = l2
    new_selections[#new_selections + 1] = c2
    new_selections[#new_selections + 1] = l1
    new_selections[#new_selections + 1] = c1
    search_at = e + 1
  end

  if #new_selections == 0 then return end
  buffer:set_selection_list(new_selections, 1, { sanitized = true })
  add_next_occurrence_state[selection_state_key(buffer)] = nil
end

command.add(function()
  local TextView = require "core.textview"
  local GlobalPromptBar = require "core.global_prompt_bar"
  local view = core.active_view
  return view and view:extends(TextView) and not view:is(GlobalPromptBar), view
end, {
  ["user:extend-selection-smart"] = extend_smart_selection,
  ["user:shrink-selection-smart"] = shrink_smart_selection,
  ["user:expand-selection-block"] = expand_block_selection,
  ["user:add-selection-next-occurrence"] = add_selection_for_next_occurrence,
  ["user:select-all-occurrences"] = select_all_occurrences,
  ["user:comment-with-line-comment-at-start"] = line_comment_at_start,
  ["user:restore-selection-origin-or-select-none"] = restore_selection_origin_or_select_none,
  ["user:duplicate-current-line"] = duplicate_current_line,
  ["user:move-to-matching-bracket-with-history"] = move_to_matching_bracket_with_history,
  ["user:move-caret-previous-paragraph"] = function(dv)
    move_caret_paragraph(dv, -1)
  end,
  ["user:move-caret-next-paragraph"] = function(dv)
    move_caret_paragraph(dv, 1)
  end,
  ["user:select-previous-camel-hump"] = function(dv)
    move_caret_camel_word_with_selection(dv, -1)
  end,
  ["user:select-next-camel-hump"] = function(dv)
    move_caret_camel_word_with_selection(dv, 1)
  end,
})

command.add(nil, {
  ["user:copy-project-path"] = copy_project_path,
})

command.add(function(target)
  if type(target) == "string" and target ~= "" then return true, target end
  local view = core.active_view
  return is_file_bound_view(view), view
end, {
  ["user:copy-absolute-filepath"] = copy_absolute_filepath,
  ["user:copy-absolute-filepath-with-line"] = copy_absolute_filepath_with_line,
  ["user:copy-relative-filepath"] = copy_relative_filepath,
  ["user:copy-filename"] = copy_filename,
  ["user:open-file-as-raw-text"] = open_file_as_raw_text,
  ["user:open-file-in-associated-program"] = open_file_in_associated_program,
  ["user:reveal-active-file-in-explorer"] = reveal_active_file_in_explorer,
  ["user:open-terminal-at-active-file"] = open_terminal_at_active_file,
})

keymap.add({
  ["ctrl+alt+n"] = "user:clone-caret-above-intellij",
  ["ctrl+alt+m"] = "user:clone-caret-below-intellij",
  ["ctrl+alt+shift+n"] = "user:clone-caret-above-until-first-line-intellij",
  ["ctrl+alt+shift+m"] = "user:clone-caret-below-until-last-line-intellij",
  ["alt+w"] = "user:move-to-matching-bracket-with-history",
  ["alt+shift+p"] = "user:expand-selection-block",
  ["alt+p"] = "user:add-selection-next-occurrence",
  ["alt+e"] = "user:comment-with-line-comment-at-start",
  ["alt+shift+o"] = "user:extend-selection-smart",
  ["alt+shift+u"] = "user:shrink-selection-smart",
  ["ctrl+alt+u"] = "user:select-previous-camel-hump",
  ["ctrl+alt+o"] = "user:select-next-camel-hump",
  ["ctrl+d"] = "user:duplicate-current-line",
  ["ctrl+n"] = "text:move-lines-up",
  ["ctrl+m"] = "text:move-lines-down",
  ["ctrl+shift+t"] = "user:reopen-last-closed-tab",
  ["ctrl+shift+w"] = "pane:close-all-others",
  ["alt+z"] = "pane:focus-previous",
  ["alt+x"] = "pane:focus-next",
  ["ctrl+l"] = "filetree:focus-current-file",
  ["ctrl+shift+l"] = "user:reveal-active-file-in-explorer",
  ["ctrl+alt+t"] = "terminal:open",
  ["ctrl+up"] = "user:move-caret-previous-paragraph",
  ["ctrl+down"] = "user:move-caret-next-paragraph",
  ["ctrl+alt+up"] = "poi:previous",
  ["ctrl+alt+down"] = "poi:next",
  ["ctrl+alt+,"] = "poi:previous",
  ["ctrl+alt+."] = "poi:next",
  ["ctrl+pageup"] = "poi:previous",
  ["ctrl+pagedown"] = "poi:next",
  ["f6"] = "poi:previous",
  ["f7"] = "poi:next",
}, true)

-- Keep Escape cooperative: plugin panels (GlobalPromptBar, project search,
-- search/replace, fuzzy searcher, etc.) should get their normal close handlers,
-- and this editor-only fallback runs only when those predicates do not apply.
keymap.add({
  ["escape"] = "user:restore-selection-origin-or-select-none",
})

core.intellij_actions_disable_conflict_shortcuts = function()
  keymap.add_direct({
    ["ctrl+g"] = "user:disabled-intellij-conflict",
    ["ctrl+shift+k"] = "user:disabled-intellij-conflict",
    ["ctrl+return"] = "user:disabled-intellij-conflict",
    ["ctrl+alt+p"] = "user:select-all-occurrences",
    ["alt+return"] = "user:disabled-intellij-conflict",
    ["ctrl+alt+r"] = "user:disabled-intellij-conflict",
    ["shift+alt+i"] = "user:disabled-intellij-conflict",
    ["shift+alt+k"] = "user:disabled-intellij-conflict",
  })
end

core.intellij_actions_disable_conflict_shortcuts()
core.add_thread(function()
  coroutine.yield(0.1)
  core.intellij_actions_disable_conflict_shortcuts()
end)

