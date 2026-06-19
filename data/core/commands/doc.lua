local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local encodings = require "core.doc.encodings"
local translate = require "core.doc.translate"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local tokenizer = require "core.tokenizer"


local function doc()
  return core.active_view.doc
end


local function doc_multiline_selections(sort)
  local iter, state, idx, line1, col1, line2, col2 = doc():get_selections(sort)
  return function()
    idx, line1, col1, line2, col2 = iter(state, idx)
    if idx and line2 > line1 and col2 == 1 then
      line2 = line2 - 1
      col2 = #doc().lines[line2]
    end
    return idx, line1, col1, line2, col2
  end
end

local function sort_positions(line1, col1, line2, col2)
  if line1 > line2 or line1 == line2 and col1 > col2 then
    return line2, col2, line1, col1, true
  end
  return line1, col1, line2, col2, false
end

local function append_line_if_last_line(line)
  if line >= #doc().lines then
    doc():insert(line, math.huge, "\n")
  end
end

local function append_line_if_last_line_for(target_doc, line)
  if line >= #target_doc.lines then
    target_doc:insert(line, math.huge, "\n")
  end
end

local function run_legacy_doc_edit_as_batch(source, change_type, fn)
  local temp = Doc()
  temp.lines = {}
  for i = 1, #source.lines do temp.lines[i] = source.lines[i] end
  temp.selections = { table.unpack(source.selections) }
  temp.last_selection = source.last_selection
  function temp:on_text_change() end

  fn(temp)

  local old_text = table.concat(source.lines)
  local new_text = table.concat(temp.lines)
  if old_text ~= new_text then
    source:apply_edits({
      { line1 = 1, col1 = 1, line2 = #source.lines, col2 = #source.lines[#source.lines], text = new_text:gsub("\n$", "") },
    }, {
      type = change_type or "batch",
      selections = temp.selections,
      last_selection = temp.last_selection,
      merge_cursors = false,
    })
  else
    source.selections = temp.selections
    source.last_selection = temp.last_selection
  end
  temp:on_close()
end

local function run_legacy_doc_command_as_batch(dv, change_type, fn)
  return run_legacy_doc_edit_as_batch(dv.doc, change_type, fn)
end

local function save(filename)
  local abs_filename
  if filename then
    filename = core.normalize_to_project_dir(filename)
    abs_filename = core.project_absolute_path(filename)
  end
  local ok, err = pcall(doc().save, doc(), filename, abs_filename)
  if ok then
    local saved_filename = doc().filename
    core.log("Saved \"%s\"", saved_filename)
  else
    core.error(err)
    if tostring(err):find("file changed on disk", 1, true) then return end
    core.nag_view:show("Saving failed", string.format("Couldn't save file \"%s\". Do you want to save to another location?", doc().filename), {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }, function(item)
      if item.text == "Yes" then
        core.add_thread(function()
          -- we need to run this in a thread because of the odd way the nagview is.
          command.perform("doc:save-as")
        end)
      end
    end)
  end
end

local function save_existing(doc)
  if not doc.filename then return end
  local ok, err = pcall(doc.save, doc)
  if not ok and not tostring(err):find("file changed on disk", 1, true) then
    core.error("Couldn't save file \"%s\": %s", doc.filename, err)
  end
end

local function cut_or_copy(delete)
  local full_text = ""
  local text = ""
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  for idx, line1, col1, line2, col2 in doc():get_selections(true, true) do
    if line1 ~= line2 or col1 ~= col2 then
      text = doc():get_text(line1, col1, line2, col2)
      full_text = full_text == "" and text or (text .. " " .. full_text)
      core.cursor_clipboard_whole_line[idx] = false
    else -- Cut/copy whole line
      -- Remove newline from the text. It will be added as needed on paste.
      text = string.sub(doc().lines[line1], 1, -2)
      full_text = full_text == "" and text .. "\n" or (text .. "\n" .. full_text)
      core.cursor_clipboard_whole_line[idx] = true
    end
    core.cursor_clipboard[idx] = text
  end
  if delete then
    run_legacy_doc_edit_as_batch(doc(), "remove", function(target_doc)
      for idx, line1, col1, line2, col2 in target_doc:get_selections(true, true) do
        if line1 ~= line2 or col1 ~= col2 then
          target_doc:delete_to_cursor(idx, 0)
        else
          if line1 < #target_doc.lines then
            target_doc:remove(line1, 1, line1 + 1, 1)
          elseif #target_doc.lines == 1 then
            target_doc:remove(line1, 1, line1, math.huge)
          else
            target_doc:remove(line1 - 1, math.huge, line1, math.huge)
          end
          target_doc:set_selections(idx, line1, col1, line2, col2)
        end
      end
      target_doc:merge_cursors()
    end)
  end
  core.cursor_clipboard["full"] = full_text
  system.set_clipboard(full_text)
end

local function set_primary_selection(doc)
  -- Doesn't work on Windows, so avoid spending time getting the text
  if PLATFORM ~= "Windows" then
    system.set_primary_selection(doc:get_selection_text())
  end
end

local function split_cursor(dv, direction)
  local new_cursors = {}
  local dv_translate = direction < 0
    and DocView.translate.previous_line
    or DocView.translate.next_line
  for _, line1, col1 in dv.doc:get_selections() do
    if line1 + direction >= 1 and line1 + direction <= #dv.doc.lines then
      table.insert(new_cursors, { dv_translate(dv.doc, line1, col1, dv) })
    end
  end
  -- add selections in the order that will leave the "last" added one as doc.last_selection
  local start, stop = 1, #new_cursors
  if direction < 0 then
    start, stop = #new_cursors, 1
  end
  for i = start, stop, direction do
    local v = new_cursors[i]
    dv.doc:add_selection(v[1], v[2])
  end
  core.blink_reset()
end

local function set_cursor(dv, x, y, snap_type)
  local line, col = dv:resolve_screen_position(x, y)
  dv.doc:set_selection(line, col, line, col)
  if snap_type == "word" or snap_type == "lines" then
    command.perform("doc:select-" .. snap_type)
  end
  dv.mouse_selecting = { line, col, snap_type }
  core.blink_reset()
end

local function set_encoding(doc, charset)
  doc.encoding = charset
  if doc.bom then
    doc.bom = encoding.get_charset_bom(charset)
  end
end

local function line_comment(comment, line1, col1, line2, col2)
  local start_comment = (type(comment) == 'table' and comment[1] or comment) .. " "
  local end_comment = (type(comment) == 'table' and " " .. comment[2])
  local uncomment = true
  local start_offset = math.huge
  for line = line1, line2 do
    local text = doc().lines[line]
    local s = text:find("%S")
    if s then
      local cs, ce = text:find(start_comment, s, true)
      if cs ~= s then
        uncomment = false
      end
      start_offset = math.min(start_offset, s)
    end
  end

  local end_line = col2 == #doc().lines[line2]
  local edits = {}
  for line = line1, line2 do
    local text = doc().lines[line]
    local s = text:find("%S")
    if s and uncomment then
      if end_comment and text:sub(#text - #end_comment, #text - 1) == end_comment then
        edits[#edits + 1] = { line1 = line, col1 = #text - #end_comment, line2 = line, col2 = #text, text = "" }
      end
      local cs, ce = text:find(start_comment, s, true)
      if ce then
        edits[#edits + 1] = { line1 = line, col1 = cs, line2 = line, col2 = ce + 1, text = "" }
      end
    elseif s then
      edits[#edits + 1] = { line1 = line, col1 = start_offset, line2 = line, col2 = start_offset, text = start_comment }
      if end_comment then
        edits[#edits + 1] = { line1 = line, col1 = #text, line2 = line, col2 = #text, text = " " .. comment[2] }
      end
    end
  end
  if #edits > 0 then
    doc():apply_edits(edits, {
      type = uncomment and "remove" or "insert",
      merge_cursors = false,
    })
  end
  col1 = col1 + (col1 > start_offset and #start_comment or 0) * (uncomment and -1 or 1)
  col2 = col2 + (col2 > start_offset and #start_comment or 0) * (uncomment and -1 or 1)
  if end_comment and end_line then
    col2 = col2 + #end_comment * (uncomment and -1 or 1)
  end
  return line1, col1, line2, col2
end

local function block_comment(comment, line1, col1, line2, col2)
  -- automatically skip spaces
  local word_start = doc():get_text(line1, col1, line1, math.huge):find("%S")
  local word_end = doc():get_text(line2, 1, line2, col2):find("%s*$")
  col1 = col1 + (word_start and (word_start - 1) or 0)
  col2 = word_end and word_end or col2

  local block_start = doc():get_text(line1, col1, line1, col1 + #comment[1])
  local block_end = doc():get_text(line2, col2 - #comment[2], line2, col2)

  if block_start == comment[1] and block_end == comment[2] then
    -- remove up to 1 whitespace after the comment
    local start_len, stop_len = #comment[1], #comment[2]
    if doc():get_text(line1, col1 + #comment[1], line1, col1 + #comment[1] + 1):find("%s$") then
      start_len = start_len + 1
    end
    if doc():get_text(line2, col2 - #comment[2] - 1, line2, col2):find("^%s") then
      stop_len = stop_len + 1
    end

    doc():apply_edits({
      { line1 = line1, col1 = col1, line2 = line1, col2 = col1 + start_len, text = "" },
      { line1 = line2, col1 = col2 - stop_len, line2 = line2, col2 = col2, text = "" },
    }, { type = "remove", merge_cursors = false })
    col2 = col2 - (line1 == line2 and start_len or 0)

    return line1, col1, line2, col2 - stop_len
  else
    local prefix = comment[1] .. " "
    local suffix = " " .. comment[2]
    if line1 == line2 and col1 == col2 then
      doc():apply_edits({
        { line1 = line1, col1 = col1, line2 = line1, col2 = col1, text = prefix .. suffix },
      }, { type = "insert", merge_cursors = false })
    else
      doc():apply_edits({
        { line1 = line1, col1 = col1, line2 = line1, col2 = col1, text = prefix },
        { line1 = line2, col1 = col2, line2 = line2, col2 = col2, text = suffix },
      }, { type = "insert", merge_cursors = false })
    end
    col2 = col2 + (line1 == line2 and #prefix or 0)

    return line1, col1, line2, col2 + #suffix
  end
end

local function newline_count(text)
  local n = 0
  for _ in tostring(text or ""):gmatch("\n") do n = n + 1 end
  return n
end

local smart_newline_pairs = { ["("] = ")", ["["] = "]", ["{"] = "}" }

local function leading_indent(text)
  return tostring(text or ""):match("^[\t ]*") or ""
end

local function one_indent_string(doc)
  local text = doc:get_indent_string(1)
  return text
end

local function line_end_col(text)
  local nl = tostring(text or ""):find("\n", 1, true)
  return nl or (#tostring(text or "") + 1)
end

local function token_at(doc, line, col)
  local column = 0
  for _, token_type, token_text in doc.highlighter:each_token(line) do
    column = column + #token_text
    if column >= col then return token_type end
  end
  return "normal"
end

local function token_is_code(token_type)
  return token_type ~= "comment" and token_type ~= "string"
end

local function position_is_code(doc, line, col)
  return token_is_code(token_at(doc, line, col))
end

local function previous_non_space_on_line(text, col)
  for i = col - 1, 1, -1 do
    local ch = text:sub(i, i)
    if ch == "\n" or ch == "\r" then return nil end
    if ch ~= " " and ch ~= "\t" then return ch, i end
  end
end

local function next_non_space_on_line(text, col)
  for i = col, #text do
    local ch = text:sub(i, i)
    if ch == "\n" or ch == "\r" then return nil end
    if ch ~= " " and ch ~= "\t" then return ch, i end
  end
end

local function opening_brace_is_unmatched(doc, line, col)
  local depth = 1
  for l = line, #doc.lines do
    local text = doc.lines[l]
    local start_col = l == line and col + 1 or 1
    for i = start_col, #text do
      local ch = text:sub(i, i)
      if (ch == "{" or ch == "}") and position_is_code(doc, l, i) then
        if ch == "{" then
          depth = depth + 1
        else
          depth = depth - 1
          if depth == 0 then return false end
        end
      end
    end
  end
  return true
end

local function edits_are_non_overlapping(doc, edits)
  local normalized = doc:plan_edits(edits)
  for i = 2, #normalized do
    local prev, cur = normalized[i - 1], normalized[i]
    if prev.end_offset > cur.start_offset
    or (prev.start_offset == prev.end_offset and cur.start_offset == cur.end_offset and prev.start_offset == cur.start_offset) then
      return false
    end
  end
  return true, normalized
end

local function smart_newline_edit(doc, line1, col1, line2, col2)
  if line1 ~= line2 or col1 ~= col2 then return nil end

  local text = doc.lines[line1] or ""
  local opener, opener_col = previous_non_space_on_line(text, col1)
  local closer = opener and smart_newline_pairs[opener]
  if not closer or not position_is_code(doc, line1, opener_col) then return nil end

  local base_indent = leading_indent(text)
  local inner_indent = base_indent .. one_indent_string(doc)
  local next_char, next_col = next_non_space_on_line(text, col1)

  if next_char == closer and position_is_code(doc, line1, next_col) then
    local insert_text = "\n" .. inner_indent .. "\n" .. base_indent
    return {
      line1 = line1,
      col1 = opener_col + 1,
      line2 = line1,
      col2 = next_col,
      text = insert_text,
      caret_offset = #("\n" .. inner_indent),
      reason = "between-pair",
    }
  end

  if next_char ~= nil then return nil end

  local edit_start = opener_col + 1
  local edit_end = line_end_col(text)
  if opener == "{" and opening_brace_is_unmatched(doc, line1, opener_col) then
    local insert_text = "\n" .. inner_indent .. "\n" .. base_indent .. "}"
    return {
      line1 = line1,
      col1 = edit_start,
      line2 = line1,
      col2 = edit_end,
      text = insert_text,
      caret_offset = #("\n" .. inner_indent),
      reason = "after-unmatched-brace",
    }
  end

  local insert_text = "\n" .. inner_indent
  return {
    line1 = line1,
    col1 = edit_start,
    line2 = line1,
    col2 = edit_end,
    text = insert_text,
    caret_offset = #insert_text,
    reason = "after-opener",
  }
end

local function paste_all_normal_clipboards(doc)
  local payloads = {}
  for cb_idx in ipairs(core.cursor_clipboard_whole_line) do
    payloads[#payloads + 1] = tostring(core.cursor_clipboard[cb_idx] or ""):gsub("\r", "")
  end
  if #payloads == 0 then return end

  local edits, final_by_idx = {}, {}
  for idx, line1, col1, line2, col2 in doc:get_selections(true) do
    local text, final_offsets = "", {}
    for _, payload in ipairs(payloads) do
      text = text .. payload
      final_offsets[#final_offsets + 1] = #text
    end
    edits[#edits + 1] = { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = text, idx = idx }
    final_by_idx[idx] = final_offsets
  end
  if #edits == 0 then return end
  return doc:apply_edits(edits, {
    type = "insert",
    selections = doc:selections_after_edits(edits, final_by_idx),
    last_selection = doc.last_selection,
    merge_cursors = false,
  })
end

local function paste_whole_lines_by_selection(doc, text_for_idx)
  local edits = {}
  local entries = {}
  for idx, line1, col1 in doc:get_selections(false) do
    local text = tostring(text_for_idx(idx) or ""):gsub("\r", "") .. "\n"
    edits[#edits + 1] = { line1 = line1, col1 = 1, line2 = line1, col2 = 1, text = text, idx = idx }
    entries[#entries + 1] = { idx = idx, line = line1, col = col1, line_delta = newline_count(text) }
  end
  if #edits == 0 then return end

  table.sort(entries, function(a, b)
    if a.line == b.line then return a.idx < b.idx end
    return a.line < b.line
  end)
  local selections = {}
  local cumulative_line_delta = 0
  for _, entry in ipairs(entries) do
    local line = entry.line + cumulative_line_delta + entry.line_delta
    selections[#selections + 1] = line
    selections[#selections + 1] = entry.col
    selections[#selections + 1] = line
    selections[#selections + 1] = entry.col
    cumulative_line_delta = cumulative_line_delta + entry.line_delta
  end
  return doc:apply_edits(edits, {
    type = "insert",
    selections = selections,
    last_selection = doc.last_selection,
    merge_cursors = false,
  })
end

local function paste_all_whole_line_clipboards(doc)
  local payloads = {}
  for cb_idx in ipairs(core.cursor_clipboard_whole_line) do
    payloads[#payloads + 1] = tostring(core.cursor_clipboard[cb_idx] or "")
  end
  if #payloads == 0 then return end
  local text = table.concat(payloads, "\n")
  return paste_whole_lines_by_selection(doc, function() return text end)
end

local function paste_matching_whole_lines(doc, text_by_idx)
  return paste_whole_lines_by_selection(doc, function(idx) return text_by_idx[idx] end)
end

local commands = {
  ["doc:select-none"] = function(dv)
    local l1, c1 = dv.doc:get_selection_idx(dv.doc.last_selection)
    if not l1 then
      l1, c1 = dv.doc:get_selection_idx(1)
    end
    dv.doc:set_selection(l1, c1)
    dv.doc:clear_search_selections()
  end,

  ["doc:cut"] = function()
    cut_or_copy(true)
  end,

  ["doc:copy"] = function()
    cut_or_copy(false)
  end,

  ["doc:undo"] = function(dv)
    dv.doc:undo()
  end,

  ["doc:redo"] = function(dv)
    dv.doc:redo()
  end,

  ["doc:paste"] = function(dv)
    local clipboard = system.get_clipboard()
    if not clipboard or clipboard == "" then
    	return
    end
    -- If the clipboard has changed since our last look, use that instead
    if core.cursor_clipboard["full"] ~= clipboard then
      core.cursor_clipboard = {}
      core.cursor_clipboard_whole_line = {}
      local text = clipboard:gsub("\r", "")
      dv.doc:text_input_by_selection(function() return text end, nil, { type = "insert" })
      return
    end
    -- Use internal clipboard(s)
    -- If there are mixed whole lines and normal lines, consider them all as normal
    local only_whole_lines = true
    for _,whole_line in pairs(core.cursor_clipboard_whole_line) do
      if not whole_line then
        only_whole_lines = false
        break
      end
    end
    if #core.cursor_clipboard_whole_line == (#dv.doc.selections/4) then
    -- If we have the same number of clipboards and selections,
    -- paste each clipboard into its corresponding selection
      if only_whole_lines then
        paste_matching_whole_lines(dv.doc, core.cursor_clipboard)
      else
        local text_by_idx = {}
        for idx in dv.doc:get_selections() do
          text_by_idx[idx] = tostring(core.cursor_clipboard[idx] or ""):gsub("\r", "")
        end
        dv.doc:text_input_by_selection(text_by_idx, nil, { type = "insert" })
      end
    else
      -- Paste every clipboard and add a selection at the end of each one
      if not only_whole_lines then
        paste_all_normal_clipboards(dv.doc)
        return
      end
      paste_all_whole_line_clipboards(dv.doc)
    end
  end,

  ["doc:paste-primary-selection"] = function(dv, x, y)
    if type(x) == "number" and type(y) == "number" then
      set_cursor(dv, x, y, "set")
      -- Workaround to avoid that a middle mouse drag starts selecting
      dv.mouse_selecting = nil
    end
    dv.doc:text_input(system.get_primary_selection() or "")
  end,

  ["doc:newline"] = function(dv)
    local text_by_idx = {}
    local normal_text_by_idx = {}
    local edits = {}
    local final_by_idx = {}
    local fallback = false
    local has_smart_newline = false
    for idx, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
      local line = line1
      local col = col1
      local indent = dv.doc.lines[line]:match("^[\t ]*")
      if col <= #indent then
        indent = indent:sub(#indent + 2 - col)
      end
      -- Remove current line if it contains only whitespace
      if not config.keep_newline_whitespace and dv.doc.lines[line]:match("^%s+$") then
        fallback = true
        break
      end

      normal_text_by_idx[idx] = "\n" .. indent
      local smart_edit = smart_newline_edit(dv.doc, line1, col1, line2, col2)
      local text
      if smart_edit then
        has_smart_newline = true
        text = smart_edit.text
        final_by_idx[idx] = smart_edit.caret_offset
        core.log_quiet("Smart newline %s in %s at %d:%d", smart_edit.reason, dv.doc:get_name(), line1, col1)
        edits[#edits + 1] = {
          line1 = smart_edit.line1,
          col1 = smart_edit.col1,
          line2 = smart_edit.line2,
          col2 = smart_edit.col2,
          text = text,
          idx = idx,
        }
      else
        text = "\n" .. indent
        final_by_idx[idx] = "end"
        edits[#edits + 1] = {
          line1 = line1,
          col1 = col1,
          line2 = line2,
          col2 = col2,
          text = text,
          idx = idx,
        }
      end
      text_by_idx[idx] = text
    end
    if fallback then
      local temp = Doc()
      temp.lines = {}
      for i = 1, #dv.doc.lines do temp.lines[i] = dv.doc.lines[i] end
      temp.selections = { table.unpack(dv.doc.selections) }
      temp.last_selection = dv.doc.last_selection
      function temp:on_text_change() end
      for idx, line, col in temp:get_selections(false, true) do
        local indent = temp.lines[line]:match("^[\t ]*")
        if col <= #indent then
          indent = indent:sub(#indent + 2 - col)
        end
        if not config.keep_newline_whitespace and temp.lines[line]:match("^%s+$") then
          temp:remove(line, 1, line, math.huge)
        end
        temp:text_input("\n" .. indent, idx)
      end
      local text = table.concat(temp.lines):gsub("\n$", "")
      dv.doc:apply_edits({
        { line1 = 1, col1 = 1, line2 = #dv.doc.lines, col2 = math.huge, text = text },
      }, {
        type = "insert",
        selections = temp.selections,
        last_selection = temp.last_selection,
        merge_cursors = false,
      })
      temp:on_close()
    elseif has_smart_newline then
      local non_overlapping, normalized = edits_are_non_overlapping(dv.doc, edits)
      if not non_overlapping then
        core.log_quiet("Smart newline skipped for %s because selections overlap", dv.doc:get_name())
        dv.doc:text_input_by_selection(normal_text_by_idx, nil, { type = "insert" })
        return
      end
      local selections, last_selection = dv.doc:selections_after_edits(normalized, final_by_idx, dv.doc.last_selection, { normalized = true })
      dv.doc:apply_edits(edits, {
        type = "insert",
        selections = selections,
        last_selection = last_selection,
        merge_cursors = false,
      })
    else
      dv.doc:text_input_by_selection(text_by_idx, nil, { type = "insert" })
    end
  end,

  ["doc:newline-below"] = function(dv)
    local edits = {}
    local entries = {}
    for idx, line in dv.doc:get_selections(false) do
      local indent = dv.doc.lines[line]:match("^[\t ]*")
      edits[#edits + 1] = { line1 = line, col1 = math.huge, line2 = line, col2 = math.huge, text = "\n" .. indent, idx = idx }
      entries[#entries + 1] = { idx = idx, line = line, col = #indent + 1 }
    end
    table.sort(entries, function(a, b)
      if a.line == b.line then return a.idx < b.idx end
      return a.line < b.line
    end)
    local selections = {}
    local cumulative_line_delta = 0
    for _, entry in ipairs(entries) do
      local line = entry.line + cumulative_line_delta + 1
      selections[#selections + 1] = line
      selections[#selections + 1] = entry.col
      selections[#selections + 1] = line
      selections[#selections + 1] = entry.col
      cumulative_line_delta = cumulative_line_delta + 1
    end
    dv.doc:apply_edits(edits, {
      type = "insert",
      selections = selections,
      last_selection = dv.doc.last_selection,
      merge_cursors = false,
    })
  end,

  ["doc:newline-above"] = function(dv)
    local edits = {}
    local entries = {}
    for idx, line in dv.doc:get_selections(false) do
      local indent = dv.doc.lines[line]:match("^[\t ]*")
      edits[#edits + 1] = { line1 = line, col1 = 1, line2 = line, col2 = 1, text = indent .. "\n", idx = idx }
      entries[#entries + 1] = { idx = idx, line = line, col = #indent + 1 }
    end
    table.sort(entries, function(a, b)
      if a.line == b.line then return a.idx < b.idx end
      return a.line < b.line
    end)
    local selections = {}
    local cumulative_line_delta = 0
    for _, entry in ipairs(entries) do
      local line = entry.line + cumulative_line_delta
      selections[#selections + 1] = line
      selections[#selections + 1] = entry.col
      selections[#selections + 1] = line
      selections[#selections + 1] = entry.col
      cumulative_line_delta = cumulative_line_delta + 1
    end
    dv.doc:apply_edits(edits, {
      type = "insert",
      selections = selections,
      last_selection = dv.doc.last_selection,
      merge_cursors = false,
    })
  end,

  ["doc:delete"] = function(dv)
    local fallback = false
    for _, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
      if line1 == line2 and col1 == col2 and dv.doc.lines[line1]:find("^%s*$", col1) then
        fallback = true
        break
      end
    end
    if fallback then
      local edits, final_by_idx = {}, {}
      for idx, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
        local start_line, start_col, end_line, end_col = line1, col1, line2, col2
        if line1 == line2 and col1 == col2 then
          if dv.doc.lines[line1]:find("^%s*$", col1) and line1 < #dv.doc.lines then
            end_line, end_col = line1 + 1, 1
          else
            local l2, c2 = dv.doc:position_offset(line1, col1, translate.next_char)
            start_line, start_col, end_line, end_col = sort_positions(line1, col1, l2, c2)
          end
        end
        edits[#edits + 1] = { line1 = start_line, col1 = start_col, line2 = end_line, col2 = end_col, text = "", idx = idx }
        final_by_idx[idx] = "start"
      end
      dv.doc:apply_edits(edits, {
        type = "remove",
        selections = dv.doc:selections_after_edits(edits, final_by_idx),
        last_selection = dv.doc.last_selection,
        merge_cursors = true,
      })
    else
      dv.doc:delete_to(translate.next_char)
    end
  end,

  ["doc:backspace"] = function(dv)
    local _, indent_size = dv.doc:get_indent_info()
    local fallback = false
    for _, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
      if line1 == line2 and col1 == col2 then
        local text = dv.doc:get_text(line1, 1, line1, col1)
        if #text >= indent_size and text:find("^ *$") then
          fallback = true
          break
        end
      end
    end
    if fallback then
      local edits, final_by_idx = {}, {}
      for idx, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
        local start_line, start_col, end_line, end_col = line1, col1, line2, col2
        if line1 == line2 and col1 == col2 then
          local text = dv.doc:get_text(line1, 1, line1, col1)
          local l2, c2
          if #text >= indent_size and text:find("^ *$") then
            l2, c2 = dv.doc:position_offset(line1, col1, 0, -indent_size)
          else
            l2, c2 = dv.doc:position_offset(line1, col1, translate.previous_char)
          end
          start_line, start_col, end_line, end_col = sort_positions(line1, col1, l2, c2)
        end
        edits[#edits + 1] = { line1 = start_line, col1 = start_col, line2 = end_line, col2 = end_col, text = "", idx = idx }
        final_by_idx[idx] = "start"
      end
      dv.doc:apply_edits(edits, {
        type = "remove",
        selections = dv.doc:selections_after_edits(edits, final_by_idx),
        last_selection = dv.doc.last_selection,
        merge_cursors = true,
      })
    else
      dv.doc:delete_to(translate.previous_char)
    end
  end,

  ["doc:select-all"] = function(dv)
    dv.doc:set_selection(1, 1, math.huge, math.huge)
    set_primary_selection(dv.doc)
    -- avoid triggering DocView:scroll_to_make_visible
    dv.last_line1 = 1
    dv.last_col1 = 1
    dv.last_line2 = #dv.doc.lines
    dv.last_col2 = #dv.doc.lines[#dv.doc.lines]
  end,

  ["doc:select-lines"] = function(dv)
    for idx, line1, _, line2 in dv.doc:get_selections(true) do
      append_line_if_last_line(line2)
      dv.doc:set_selections(idx, line2 + 1, 1, line1, 1)
    end
    set_primary_selection(dv.doc)
  end,

  ["doc:select-word"] = function(dv)
    for idx, line1, col1 in dv.doc:get_selections(true) do
      local line1, col1 = translate.start_of_word(dv.doc, line1, col1)
      local line2, col2 = translate.end_of_word(dv.doc, line1, col1)
      dv.doc:set_selections(idx, line2, col2, line1, col1)
    end
    set_primary_selection(dv.doc)
  end,

  ["doc:join-lines"] = function(dv)
    local actions, fallback = {}, false
    for idx, line1, col1, line2, col2 in dv.doc:get_selections(true) do
      if line1 == line2 then line2 = line2 + 1 end
      if line2 > #dv.doc.lines then fallback = true; break end
      local text = dv.doc:get_text(line1, 1, line2, math.huge)
      text = text:gsub("(.-)\n[\t ]*", function(x)
        return x:find("^%s*$") and x or x .. " "
      end)
      actions[#actions + 1] = { idx = idx, line1 = line1, line2 = line2, text = text, line_delta = line2 - line1 }
    end
    table.sort(actions, function(a, b) return a.line1 < b.line1 end)
    for i = 2, #actions do
      if actions[i - 1].line2 >= actions[i].line1 then fallback = true; break end
    end
    if fallback then
      for idx, line1, col1, line2, col2 in dv.doc:get_selections(true) do
        if line1 == line2 then line2 = line2 + 1 end
        local text = dv.doc:get_text(line1, 1, line2, math.huge)
        text = text:gsub("(.-)\n[\t ]*", function(x)
          return x:find("^%s*$") and x or x .. " "
        end)
        dv.doc:insert(line1, 1, text)
        dv.doc:remove(line1, #text + 1, line2, math.huge)
        if line1 ~= line2 or col1 ~= col2 then
          dv.doc:set_selections(idx, line1, math.huge)
        end
      end
      return
    end
    local edits, selections, removed_before = {}, {}, 0
    for _, action in ipairs(actions) do
      edits[#edits + 1] = {
        line1 = action.line1,
        col1 = 1,
        line2 = action.line2,
        col2 = #dv.doc.lines[action.line2],
        text = action.text,
        idx = action.idx,
      }
      local line = action.line1 - removed_before
      selections[#selections + 1] = line
      selections[#selections + 1] = #action.text + 1
      selections[#selections + 1] = line
      selections[#selections + 1] = #action.text + 1
      removed_before = removed_before + action.line_delta
    end
    dv.doc:apply_edits(edits, { type = "replace", selections = selections, last_selection = dv.doc.last_selection, merge_cursors = false })
  end,

  ["doc:indent"] = function(dv)
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      local l1, c1, l2, c2 = dv.doc:indent_text(false, line1, col1, line2, col2)
      if l1 then
        dv.doc:set_selections(idx, l1, c1, l2, c2)
      end
    end
  end,

  ["doc:unindent"] = function(dv)
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      local l1, c1, l2, c2 = dv.doc:indent_text(true, line1, col1, line2, col2)
      if l1 then
        dv.doc:set_selections(idx, l1, c1, l2, c2)
      end
    end
  end,

  ["doc:duplicate-lines"] = function(dv)
    local actions, fallback = {}, false
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      if line2 >= #dv.doc.lines then fallback = true; break end
      local text = doc():get_text(line1, 1, line2 + 1, 1)
      actions[#actions + 1] = { idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = text, n = line2 - line1 + 1 }
    end
    if fallback then
      run_legacy_doc_command_as_batch(dv, "insert", function(target_doc)
        for idx, line1, col1, line2, col2 in target_doc:get_selections(true) do
          if line2 > line1 and col2 == 1 then line2, col2 = line2 - 1, #target_doc.lines[line2 - 1] end
          append_line_if_last_line_for(target_doc, line2)
          local text = target_doc:get_text(line1, 1, line2 + 1, 1)
          target_doc:insert(line2 + 1, 1, text)
          local n = line2 - line1 + 1
          target_doc:set_selections(idx, line1 + n, col1, line2 + n, col2)
        end
      end)
      return
    end
    local edits, selections = {}, {}
    for _, action in ipairs(actions) do
      edits[#edits + 1] = { line1 = action.line2 + 1, col1 = 1, line2 = action.line2 + 1, col2 = 1, text = action.text, idx = action.idx }
      local inserted_before = 0
      for _, other in ipairs(actions) do
        if other.line2 < action.line1 then inserted_before = inserted_before + other.n end
      end
      selections[#selections + 1] = action.line1 + action.n + inserted_before
      selections[#selections + 1] = action.col1
      selections[#selections + 1] = action.line2 + action.n + inserted_before
      selections[#selections + 1] = action.col2
    end
    dv.doc:apply_edits(edits, { type = "insert", selections = selections, last_selection = dv.doc.last_selection, merge_cursors = false })
  end,

  ["doc:delete-lines"] = function(dv)
    local actions, fallback = {}, false
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      if line2 >= #dv.doc.lines then fallback = true; break end
      actions[#actions + 1] = { idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2, n = line2 - line1 + 1 }
    end
    if fallback then
      run_legacy_doc_command_as_batch(dv, "remove", function(target_doc)
        for idx, line1, col1, line2, col2 in target_doc:get_selections(true) do
          if line2 > line1 and col2 == 1 then line2, col2 = line2 - 1, #target_doc.lines[line2 - 1] end
          append_line_if_last_line_for(target_doc, line2)
          target_doc:remove(line1, 1, line2 + 1, 1)
          target_doc:set_selections(idx, line1, col1)
        end
      end)
      return
    end
    local edits, selections = {}, {}
    for _, action in ipairs(actions) do
      edits[#edits + 1] = { line1 = action.line1, col1 = 1, line2 = action.line2 + 1, col2 = 1, text = "", idx = action.idx }
      local removed_before = 0
      for _, other in ipairs(actions) do
        if other.line2 < action.line1 then removed_before = removed_before + other.n end
      end
      selections[#selections + 1] = action.line1 - removed_before
      selections[#selections + 1] = action.col1
      selections[#selections + 1] = action.line1 - removed_before
      selections[#selections + 1] = action.col1
    end
    dv.doc:apply_edits(edits, { type = "remove", selections = selections, last_selection = dv.doc.last_selection, merge_cursors = true })
  end,

  ["doc:move-lines-up"] = function(dv)
    local actions, fallback = {}, false
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      if line1 <= 1 or line2 >= #dv.doc.lines then fallback = true; break end
      actions[#actions + 1] = {
        idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2,
        start_line = line1 - 1, end_line = line2,
      }
    end
    table.sort(actions, function(a, b) return a.start_line < b.start_line end)
    for i = 2, #actions do
      if actions[i - 1].end_line >= actions[i].start_line then fallback = true; break end
    end
    if fallback then
      run_legacy_doc_command_as_batch(dv, "batch", function(target_doc)
        for idx, line1, col1, line2, col2 in target_doc:get_selections(true) do
          if line2 > line1 and col2 == 1 then line2, col2 = line2 - 1, #target_doc.lines[line2 - 1] end
          append_line_if_last_line_for(target_doc, line2)
          if line1 > 1 then
            local text = target_doc.lines[line1 - 1]
            target_doc:insert(line2 + 1, 1, text)
            target_doc:remove(line1 - 1, 1, line1, 1)
            target_doc:set_selections(idx, line1 - 1, col1, line2 - 1, col2)
          end
        end
      end)
      return
    end
    local edits, selections = {}, {}
    for _, action in ipairs(actions) do
      local block_text = dv.doc:get_text(action.line1, 1, action.line2 + 1, 1)
      local previous_line = dv.doc.lines[action.line1 - 1]
      edits[#edits + 1] = {
        line1 = action.line1 - 1, col1 = 1, line2 = action.line2 + 1, col2 = 1,
        text = block_text .. previous_line, idx = action.idx,
      }
      selections[#selections + 1] = action.line1 - 1
      selections[#selections + 1] = action.col1
      selections[#selections + 1] = action.line2 - 1
      selections[#selections + 1] = action.col2
    end
    dv.doc:apply_edits(edits, { type = "batch", selections = selections, last_selection = dv.doc.last_selection, merge_cursors = false })
  end,

  ["doc:move-lines-down"] = function(dv)
    local actions, fallback = {}, false
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      if line2 >= #dv.doc.lines then fallback = true; break end
      actions[#actions + 1] = {
        idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2,
        start_line = line1, end_line = line2 + 1,
      }
    end
    table.sort(actions, function(a, b) return a.start_line < b.start_line end)
    for i = 2, #actions do
      if actions[i - 1].end_line >= actions[i].start_line then fallback = true; break end
    end
    if fallback then
      run_legacy_doc_command_as_batch(dv, "batch", function(target_doc)
        for idx, line1, col1, line2, col2 in target_doc:get_selections(true) do
          if line2 > line1 and col2 == 1 then line2, col2 = line2 - 1, #target_doc.lines[line2 - 1] end
          append_line_if_last_line_for(target_doc, line2 + 1)
          if line2 < #target_doc.lines then
            local text = target_doc.lines[line2 + 1]
            target_doc:remove(line2 + 1, 1, line2 + 2, 1)
            target_doc:insert(line1, 1, text)
            target_doc:set_selections(idx, line1 + 1, col1, line2 + 1, col2)
          end
        end
      end)
      return
    end
    local edits, selections = {}, {}
    for _, action in ipairs(actions) do
      local block_text = dv.doc:get_text(action.line1, 1, action.line2 + 1, 1)
      local next_line = dv.doc.lines[action.line2 + 1]
      edits[#edits + 1] = {
        line1 = action.line1, col1 = 1, line2 = action.line2 + 2, col2 = 1,
        text = next_line .. block_text, idx = action.idx,
      }
      selections[#selections + 1] = action.line1 + 1
      selections[#selections + 1] = action.col1
      selections[#selections + 1] = action.line2 + 1
      selections[#selections + 1] = action.col2
    end
    dv.doc:apply_edits(edits, { type = "batch", selections = selections, last_selection = dv.doc.last_selection, merge_cursors = false })
  end,

  ["doc:toggle-block-comments"] = function(dv)
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      local current_syntax = dv.doc.syntax
      if line1 > 1 then
        -- Use the previous line state, as it will be the state
        -- of the beginning of the current line
        local state = dv.doc.highlighter:get_line(line1 - 1).state
        if state then
          local syntaxes = tokenizer.extract_subsyntaxes(dv.doc.syntax, state)
          -- Go through all the syntaxes until the first with `block_comment` defined
          for _, s in pairs(syntaxes) do
            if s.block_comment then
              current_syntax = s
              break
            end
          end
        end
      end
      local comment = current_syntax.block_comment
      if not comment then
        if dv.doc.syntax.comment then
          command.perform "doc:toggle-line-comments"
        end
        return
      end
      -- if nothing is selected, toggle the whole line
      if line1 == line2 and col1 == col2 then
        col1 = 1
        col2 = #dv.doc.lines[line2]
      end
      dv.doc:set_selections(idx, block_comment(comment, line1, col1, line2, col2))
    end
  end,

  ["doc:toggle-line-comments"] = function(dv)
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      local current_syntax = dv.doc.syntax
      if line1 > 1 then
        -- Use the previous line state, as it will be the state
        -- of the beginning of the current line
        local state = dv.doc.highlighter:get_line(line1 - 1).state
        if state then
          local syntaxes = tokenizer.extract_subsyntaxes(dv.doc.syntax, state)
          -- Go through all the syntaxes until the first with comments defined
          for _, s in pairs(syntaxes) do
            if s.comment or s.block_comment then
              current_syntax = s
              break
            end
          end
        end
      end
      local comment = current_syntax.comment or current_syntax.block_comment
      if comment then
        dv.doc:set_selections(idx, line_comment(comment, line1, col1, line2, col2))
      end
    end
  end,

  ["doc:upper-case"] = function(dv)
    dv.doc:replace(string.uupper)
  end,

  ["doc:lower-case"] = function(dv)
    dv.doc:replace(string.ulower)
  end,

  ["doc:go-to-line"] = function(dv)
    local items
    local function init_items()
      if items then return end
      items = {}
      local mt = { __tostring = function(x) return x.text end }
      for i, line in ipairs(dv.doc.lines) do
        local item = { text = line:sub(1, -2), line = i, info = "line: " .. i }
        table.insert(items, setmetatable(item, mt))
      end
    end

    core.global_prompt_bar:enter("Go To Line", {
      submit = function(text, item)
        local line = item and item.line or tonumber(text)
        if not line then
          core.error("Invalid line number or unmatched string")
          return
        end
        dv.doc:set_selection(line, 1  )
        dv:scroll_to_line(line, true)
      end,
      suggest = function(text)
        if not text:find("^%d*$") then
          init_items()
          return common.fuzzy_match(items, text)
        end
      end,
      draw_text = function(item, font, color, x, y, w, h)
        y = common.round(y + (h - font:get_height()) / 2)
        local tx = x
        local last_token = nil
        local tokens = dv.doc.highlighter:get_line(item.line).tokens
        local tokens_count = #tokens
        if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
          last_token = tokens_count - 1
        end
        for tidx, type, text in dv.doc.highlighter:each_token(item.line) do
          color = style.syntax[type] or style.syntax["normal"]
          -- do not render newline, fixes issue #1164
          if tidx == last_token then text = text:sub(1, -2) end
          tx = renderer.draw_text(font, text, tx, y, color)
          if tx > (x + w) - font:get_width(item.info) - style.padding.x * 2 then break end
        end
      end
    })
  end,

  ["doc:toggle-line-ending"] = function(dv)
    dv.doc.crlf = not dv.doc.crlf
  end,

  ["doc:change-encoding"] = function(dv)
    encodings.select_encoding("Select Output Encoding", function(charset)
      set_encoding(dv.doc, charset)
      save_existing(dv.doc)
    end)
  end,

  ["doc:reload-with-encoding"] = function(dv)
    encodings.select_encoding("Reload With Encoding", function(charset)
      set_encoding(dv.doc, charset)
      dv.doc:reload()
    end)
  end,

  ["doc:toggle-overwrite"] = function(dv)
    dv.doc.overwrite = not dv.doc.overwrite
    core.blink_reset() -- to show the cursor has changed edit modes
  end,

  ["doc:save-as"] = function(dv)
    local last_doc = core.last_active_view and core.last_active_view.doc
    local text
    if dv.doc.filename then
      text = dv.doc.filename
    elseif last_doc and last_doc.filename then
      local dirname, filename = core.last_active_view.doc.abs_filename:match("(.*)[/\\](.+)$")
      text = core.normalize_to_project_dir(dirname) .. PATHSEP
      if common.path_equals(text, core.root_project().path) then text = "" end
    end
    core.global_prompt_bar:enter("Save As", {
      text = text,
      submit = function(filename)
        save(common.home_expand(common.sanitize_prompt_path(filename)))
      end,
      suggest = function (text)
        return common.home_encode_list(common.path_suggest(common.home_expand(common.sanitize_prompt_path(text))))
      end
    })
  end,

  ["doc:save"] = function(dv)
    if dv.doc.filename then
      save()
    else
      command.perform("doc:save-as")
    end
  end,

  ["doc:reload"] = function(dv)
    dv.doc:reload()
  end,

  ["file:rename"] = function(dv)
    local old_filename = dv.doc.filename
    local old_abs_filename = dv.doc.abs_filename
    if not old_filename then
      core.error("Cannot rename unsaved doc")
      return
    end
    core.global_prompt_bar:enter("Rename", {
      text = old_filename,
      submit = function(filename)
        filename = common.sanitize_prompt_path(filename)
        local expanded_filename = common.home_expand(filename)
        local new_filename = core.normalize_to_project_dir(expanded_filename)
        local new_abs_filename = core.project_absolute_path(new_filename)
        save(expanded_filename)
        if not common.path_equals(dv.doc.abs_filename, new_abs_filename) then return end
        core.log("Renamed \"%s\" to \"%s\"", old_filename, filename)
        if not common.path_equals(new_abs_filename, old_abs_filename) then
          os.remove(old_abs_filename or old_filename)
        end
      end,
      suggest = function (text)
        return common.home_encode_list(common.path_suggest(common.home_expand(common.sanitize_prompt_path(text))))
      end
    })
  end,

  ["file:delete"] = function(dv)
    local filename = dv.doc.abs_filename
    if not filename then
      core.error("Cannot remove unsaved doc")
      return
    end
    for i,docview in ipairs(core.get_views_referencing_doc(dv.doc)) do
      local node = core.root_panel.root_node:get_node_for_view(docview)
      node:close_view(core.root_panel.root_node, docview)
    end
    os.remove(filename)
    core.log("Removed \"%s\"", filename)
  end,

  ["doc:select-to-cursor"] = function(dv, x, y, clicks)
    local line1, col1 = select(3, doc():get_selection())
    local line2, col2 = dv:resolve_screen_position(x, y)
    dv.mouse_selecting = { line1, col1, nil }
    dv.doc:set_selection(line2, col2, line1, col1)
    set_primary_selection(dv.doc)
  end,

  ["doc:create-cursor-previous-line"] = function(dv)
    split_cursor(dv, -1)
    dv.doc:merge_cursors()
  end,

  ["doc:create-cursor-next-line"] = function(dv)
    split_cursor(dv, 1)
    dv.doc:merge_cursors()
  end
}

command.add(function(x, y)
  if x == nil or y == nil or not core.active_view:extends(DocView) then return false end
  local dv = core.active_view
  local x1,y1,x2,y2 = dv.position.x, dv.position.y, dv.position.x + dv.size.x, dv.position.y + dv.size.y
  return x >= x1 + dv:get_gutter_width() and x < x2 and y >= y1 and y < y2, dv, x, y
end, {
  ["doc:set-cursor"] = function(dv, x, y)
    set_cursor(dv, x, y, "set")
  end,

  ["doc:set-cursor-word"] = function(dv, x, y)
    set_cursor(dv, x, y, "word")
  end,

  ["doc:set-cursor-line"] = function(dv, x, y, clicks)
    set_cursor(dv, x, y, "lines")
  end,

  ["doc:split-cursor"] = function(dv, x, y, clicks)
    local line, col = dv:resolve_screen_position(x, y)
    local removal_target = nil
    for idx, line1, col1 in dv.doc:get_selections(true) do
      if line1 == line and col1 == col and #doc().selections > 4 then
        removal_target = idx
      end
    end
    if removal_target then
      dv.doc:remove_selection(removal_target)
    else
      dv.doc:add_selection(line, col, line, col)
    end
    dv.mouse_selecting = { line, col, "set" }
  end
})

command.add(function()
  if not core.active_view:extends(DocView) then return false end
  local doc = core.active_view.doc
  local bom = encoding.get_charset_bom(doc.encoding or "none")
  return  bom ~= nil, doc, bom
end, {
  ["doc:disable-bom"] = function(doc)
    doc.bom = nil
    save_existing(doc)
  end,

  ["doc:enable-bom"] = function(doc, bom)
    doc.bom = bom
    save_existing(doc)
  end,

  ["doc:toggle-bom"] = function(doc, bom)
    if doc.bom then doc.bom = nil else doc.bom = bom end
    save_existing(doc)
  end,
})

local translations = {
  ["previous-char"] = translate,
  ["next-char"] = translate,
  ["previous-word-start"] = translate,
  ["next-word-end"] = translate,
  ["previous-block-start"] = translate,
  ["next-block-end"] = translate,
  ["start-of-doc"] = translate,
  ["end-of-doc"] = translate,
  ["start-of-line"] = translate,
  ["end-of-line"] = translate,
  ["start-of-word"] = translate,
  ["start-of-indentation"] = translate,
  ["end-of-word"] = translate,
  ["previous-line"] = DocView.translate,
  ["next-line"] = DocView.translate,
  ["previous-page"] = DocView.translate,
  ["next-page"] = DocView.translate,
}

for name, obj in pairs(translations) do
  commands["doc:move-to-" .. name] = function(dv)
    dv.doc:move_to(obj[name:gsub("-", "_")], dv)
  end
  commands["doc:select-to-" .. name] = function(dv)
    dv.doc:select_to(obj[name:gsub("-", "_")], dv)
    set_primary_selection(dv.doc)
  end
  commands["doc:delete-to-" .. name] = function(dv)
    dv.doc:delete_to(obj[name:gsub("-", "_")], dv)
  end
end

local function move_char_batch(dv, move_fn, collapse_to_end)
  local doc = dv.doc
  local selections = {}
  local last_selection = doc.last_selection
  for _, line1, col1, line2, col2 in doc:get_selections(true) do
    local line, col
    if line1 ~= line2 or col1 ~= col2 then
      if collapse_to_end then
        line, col = line2, col2
      else
        line, col = line1, col1
      end
    else
      line, col = move_fn(doc, line1, col1, dv)
    end
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line
    selections[#selections + 1] = col
  end
  doc:set_selection_list(selections, last_selection, { merge_cursors = true, sanitized = true })
end

commands["doc:move-to-previous-char"] = function(dv)
  move_char_batch(dv, translate.previous_char, false)
end

commands["doc:move-to-next-char"] = function(dv)
  move_char_batch(dv, translate.next_char, true)
end

local function move_line_batch(dv, line_offset)
  local doc = dv.doc
  local old = doc.selections
  local selections = {}
  local last_selection = doc.last_selection
  local last_line = #doc.lines
  local x_by_line_col = {}
  local col_by_line_x = {}
  local last_x_offset = dv.last_x_offset
  local has_relevant_syntax_fonts = false
  local syntax_name = tostring(doc.syntax and doc.syntax.name or ""):lower()
  local is_markdown = syntax_name:find("markdown", 1, true) ~= nil
  for name in pairs(style.syntax_fonts) do
    if is_markdown or not tostring(name):match("^markdown_") then
      has_relevant_syntax_fonts = true
      break
    end
  end
  local simple_line_cache = {}
  local seen = {}
  local mapped_last_selection = nil

  local function get_cached_x(line, col)
    local by_col = x_by_line_col[line]
    if not by_col then
      by_col = {}
      x_by_line_col[line] = by_col
    end
    local x = by_col[col]
    if x == nil then
      x = dv:get_col_x_offset(line, col)
      by_col[col] = x
    end
    return x
  end

  local function get_cached_col(line, x)
    local by_x = col_by_line_x[line]
    if not by_x then
      by_x = {}
      col_by_line_x[line] = by_x
    end
    local col = by_x[x]
    if col == nil then
      col = dv:get_x_offset_col(line, x)
      by_x[x] = col
    end
    return col
  end

  local function is_simple_line(line)
    if has_relevant_syntax_fonts then return false end
    local simple = simple_line_cache[line]
    if simple == nil then
      simple = not not doc.lines[line] and not doc.lines[line]:find("[\t\128-\255]")
      simple_line_cache[line] = simple
    end
    return simple
  end

  local function add_cursor(old_idx, line, col)
    local by_col = seen[line]
    if not by_col then
      by_col = {}
      seen[line] = by_col
    end
    local selection_idx = by_col[col]
    if not selection_idx then
      selection_idx = #selections / 4 + 1
      by_col[col] = selection_idx
      selections[#selections + 1] = line
      selections[#selections + 1] = col
      selections[#selections + 1] = line
      selections[#selections + 1] = col
    end
    if old_idx == last_selection then
      mapped_last_selection = selection_idx
    end
  end

  for i = 1, #old, 4 do
    local old_idx = (i - 1) / 4 + 1
    local line, col = old[i], old[i + 1]
    local target_line, target_col
    if line_offset < 0 and line <= 1 then
      target_line, target_col = 1, 1
    elseif line_offset > 0 and line >= last_line then
      target_line, target_col = last_line, #doc.lines[last_line]
    else
      target_line = line + line_offset
      if is_simple_line(line) and is_simple_line(target_line) then
        local x = (col - 1) * dv:get_font():get_width(" ")
        target_col = common.clamp(col, 1, #doc.lines[target_line])
        last_x_offset.offset = x
        last_x_offset.line = target_line
        last_x_offset.col = target_col
      else
        local x
        if last_x_offset.line == line and last_x_offset.col == col then
          x = last_x_offset.offset
        else
          x = get_cached_x(line, col)
        end
        target_col = common.clamp(get_cached_col(target_line, x), 1, #doc.lines[target_line])
        last_x_offset.offset = x
        last_x_offset.line = target_line
        last_x_offset.col = target_col
      end
    end
    add_cursor(old_idx, target_line, target_col)
  end

  doc:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
end

commands["doc:move-to-previous-line"] = function(dv)
  move_line_batch(dv, -1)
end

commands["doc:move-to-next-line"] = function(dv)
  move_line_batch(dv, 1)
end

local function move_collapsed_carets_batch(dv, move_fn)
  local doc = dv.doc
  local old = doc.selections
  local selections = {}
  local seen = {}
  local last_selection = doc.last_selection
  local mapped_last_selection = nil

  local function add_cursor(old_idx, line, col)
    local by_col = seen[line]
    if not by_col then
      by_col = {}
      seen[line] = by_col
    end
    local selection_idx = by_col[col]
    if not selection_idx then
      selection_idx = #selections / 4 + 1
      by_col[col] = selection_idx
      selections[#selections + 1] = line
      selections[#selections + 1] = col
      selections[#selections + 1] = line
      selections[#selections + 1] = col
    end
    if old_idx == last_selection then
      mapped_last_selection = selection_idx
    end
  end

  for i = 1, #old, 4 do
    local old_idx = (i - 1) / 4 + 1
    local line, col = move_fn(doc, old[i], old[i + 1])
    add_cursor(old_idx, line, col)
  end

  doc:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
end

local function move_to_end_of_line(doc, line)
  return line, #doc.lines[line]
end

local function move_to_start_of_indentation(doc, line, col)
  local _, indent_end = doc.lines[line]:find("^[\t ]*")
  local indent_col = indent_end + 1
  return line, col > indent_col and indent_col or (col == 1 and indent_col or 1)
end

commands["doc:move-to-end-of-line"] = function(dv)
  move_collapsed_carets_batch(dv, move_to_end_of_line)
end

commands["doc:move-to-start-of-indentation"] = function(dv)
  move_collapsed_carets_batch(dv, move_to_start_of_indentation)
end

local function add_selection_endpoint(selections, seen, old_idx, last_selection, mapped_last_selection, line1, col1, line2, col2)
  local by_col = seen[line1]
  if not by_col then
    by_col = {}
    seen[line1] = by_col
  end
  local selection_idx = by_col[col1]
  if not selection_idx then
    selection_idx = #selections / 4 + 1
    by_col[col1] = selection_idx
    selections[#selections + 1] = line1
    selections[#selections + 1] = col1
    selections[#selections + 1] = line2
    selections[#selections + 1] = col2
  end
  if old_idx == last_selection then
    mapped_last_selection = selection_idx
  end
  return mapped_last_selection
end

local function select_char_batch(dv, move_fn)
  local doc = dv.doc
  local old = doc.selections
  local selections = {}
  local seen = {}
  local last_selection = doc.last_selection
  local mapped_last_selection = nil

  for i = 1, #old, 4 do
    local old_idx = (i - 1) / 4 + 1
    local line, col = move_fn(doc, old[i], old[i + 1], dv)
    mapped_last_selection = add_selection_endpoint(
      selections, seen, old_idx, last_selection, mapped_last_selection,
      line, col, old[i + 2], old[i + 3]
    )
  end

  doc:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
  set_primary_selection(doc)
end

local function select_line_batch(dv, line_offset)
  local doc = dv.doc
  local old = doc.selections
  local selections = {}
  local seen = {}
  local last_selection = doc.last_selection
  local mapped_last_selection = nil
  local last_line = #doc.lines
  local x_by_line_col = {}
  local col_by_line_x = {}
  local last_x_offset = dv.last_x_offset
  local has_relevant_syntax_fonts = false
  local syntax_name = tostring(doc.syntax and doc.syntax.name or ""):lower()
  local is_markdown = syntax_name:find("markdown", 1, true) ~= nil
  for name in pairs(style.syntax_fonts) do
    if is_markdown or not tostring(name):match("^markdown_") then
      has_relevant_syntax_fonts = true
      break
    end
  end
  local simple_line_cache = {}

  local function get_cached_x(line, col)
    local by_col = x_by_line_col[line]
    if not by_col then
      by_col = {}
      x_by_line_col[line] = by_col
    end
    local x = by_col[col]
    if x == nil then
      x = dv:get_col_x_offset(line, col)
      by_col[col] = x
    end
    return x
  end

  local function get_cached_col(line, x)
    local by_x = col_by_line_x[line]
    if not by_x then
      by_x = {}
      col_by_line_x[line] = by_x
    end
    local col = by_x[x]
    if col == nil then
      col = dv:get_x_offset_col(line, x)
      by_x[x] = col
    end
    return col
  end

  local function is_simple_line(line)
    if has_relevant_syntax_fonts then return false end
    local simple = simple_line_cache[line]
    if simple == nil then
      simple = not not doc.lines[line] and not doc.lines[line]:find("[\t\128-\255]")
      simple_line_cache[line] = simple
    end
    return simple
  end

  for i = 1, #old, 4 do
    local old_idx = (i - 1) / 4 + 1
    local line, col = old[i], old[i + 1]
    local target_line, target_col
    if line_offset < 0 and line <= 1 then
      target_line, target_col = 1, 1
    elseif line_offset > 0 and line >= last_line then
      target_line, target_col = last_line, #doc.lines[last_line]
    else
      target_line = line + line_offset
      if is_simple_line(line) and is_simple_line(target_line) then
        local x = (col - 1) * dv:get_font():get_width(" ")
        target_col = common.clamp(col, 1, #doc.lines[target_line])
        last_x_offset.offset = x
        last_x_offset.line = target_line
        last_x_offset.col = target_col
      else
        local x
        if last_x_offset.line == line and last_x_offset.col == col then
          x = last_x_offset.offset
        else
          x = get_cached_x(line, col)
        end
        target_col = common.clamp(get_cached_col(target_line, x), 1, #doc.lines[target_line])
        last_x_offset.offset = x
        last_x_offset.line = target_line
        last_x_offset.col = target_col
      end
    end
    mapped_last_selection = add_selection_endpoint(
      selections, seen, old_idx, last_selection, mapped_last_selection,
      target_line, target_col, old[i + 2], old[i + 3]
    )
  end

  doc:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
  set_primary_selection(doc)
end

commands["doc:select-to-previous-char"] = function(dv)
  select_char_batch(dv, translate.previous_char)
end

commands["doc:select-to-next-char"] = function(dv)
  select_char_batch(dv, translate.next_char)
end

commands["doc:select-to-previous-line"] = function(dv)
  select_line_batch(dv, -1)
end

commands["doc:select-to-next-line"] = function(dv)
  select_line_batch(dv, 1)
end

command.add("core.docview", commands)
