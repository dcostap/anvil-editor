local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local linewrapping = require "core.linewrapping"
local intelligence = require "core.language_intelligence"
local encodings = require "core.doc.encodings"
local translate = require "core.doc.translate"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local tokenizer = require "core.tokenizer"


local function doc()
  return core.active_view.doc
end

local function can_edit(dv, reason, opts)
  if dv and dv.can_edit then
    return dv:can_edit(reason, common.merge({ warn = true }, opts or {}))
  end
  return true
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
    if not can_edit(core.active_view, "extend selection") then return false end
    doc():insert(line, math.huge, "\n")
  end
  return true
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

local prompt_save_as
local save_as_prompt_text

local function save(filename, target)
  local target_doc = target and target.doc or target or doc()
  local abs_filename
  if filename then
    filename = core.normalize_to_project_dir(filename)
    abs_filename = core.project_absolute_path(filename)
  end
  local ok, err = pcall(target_doc.save, target_doc, filename, abs_filename)
  if ok then
    local saved_filename = target_doc.filename
    core.log("Saved \"%s\"", saved_filename)
  else
    core.error(err)
    if tostring(err):find("file changed on disk", 1, true) then return end
    core.nag_view:show("Saving failed", string.format("Couldn't save file \"%s\". Do you want to save to another location?", target_doc.filename), {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }, function(item)
      if item.text == "Yes" then
        core.add_thread(function()
          -- we need to run this in a thread because of the odd way the nagview is.
          if target and target.doc then
            prompt_save_as(target, save_as_prompt_text(target))
          else
            command.perform("doc:save-as")
          end
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

function save_as_prompt_text(dv)
  local last_doc = core.last_active_view and core.last_active_view.doc
  if dv.doc.filename then
    return dv.doc.filename
  elseif last_doc and last_doc.filename then
    local dirname = core.last_active_view.doc.abs_filename:match("(.*)[/\\].+$")
    local text = core.normalize_to_project_dir(dirname) .. PATHSEP
    if common.path_equals(text, core.root_project().path) then text = "" end
    return text
  end
end

function prompt_save_as(dv, text)
  if not can_edit(dv, "save as") then return end
  core.global_prompt_bar:enter("Save As", {
    text = text,
    submit = function(filename)
      if not can_edit(dv, "save as") then return end
      local prompt_filename = common.sanitize_prompt_path(filename)
      local save_filename = common.home_expand(prompt_filename)
      local normalized = core.normalize_to_project_dir(save_filename)
      local abs_filename = core.project_absolute_path(normalized)
      if not dv.doc.filename and system.get_file_info(abs_filename) then
        core.nag_view:show(
          "Overwrite Existing File",
          string.format("%s already exists. Overwrite it?", normalized),
          {
            { text = "Overwrite", default_yes = false },
            { text = "Cancel", default_no = true },
          },
          function(item)
            if item.text == "Overwrite" then
              if not can_edit(dv, "save as") then return end
              save(save_filename, dv)
            else
              core.add_thread(function()
                prompt_save_as(dv, filename)
              end)
            end
          end
        )
      else
        save(save_filename, dv)
      end
    end,
    suggest = function (text)
      return common.home_encode_list(common.path_suggest(common.home_expand(common.sanitize_prompt_path(text))))
    end
  })
end

local function cut_or_copy(dv, delete)
  if delete and not can_edit(dv, "cut") then return end
  local target_doc = dv.doc
  local full_text = ""
  local text = ""
  local copied_ranges = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  for idx, line1, col1, line2, col2 in target_doc:get_selections(true, true) do
    if line1 ~= line2 or col1 ~= col2 then
      text = target_doc:get_text(line1, col1, line2, col2)
      full_text = full_text == "" and text or (text .. " " .. full_text)
      core.cursor_clipboard_whole_line[idx] = false
      copied_ranges[#copied_ranges + 1] = { line1, col1, line2, col2 }
    else -- Cut/copy whole line
      -- Remove newline from the text. It will be added as needed on paste.
      text = string.sub(target_doc.lines[line1], 1, -2)
      full_text = full_text == "" and text .. "\n" or (text .. "\n" .. full_text)
      core.cursor_clipboard_whole_line[idx] = true
      copied_ranges[#copied_ranges + 1] = { line1, 1, line1, #target_doc.lines[line1] }
    end
    core.cursor_clipboard[idx] = text
  end
  if delete then
    run_legacy_doc_edit_as_batch(target_doc, "remove", function(target_doc)
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
  if not delete and dv.show_copy_feedback then
    dv:show_copy_feedback(copied_ranges)
  end
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

local function apply_resolved_wrap_affinity(dv)
  linewrapping.apply_resolved_line_end_affinity(dv)
end

local function set_cursor(dv, x, y, snap_type)
  if dv.begin_line_render_interaction then dv:begin_line_render_interaction("mouse-selection") end
  local line, col = dv:resolve_screen_position(x, y)
  dv.doc:set_selection(line, col, line, col)
  if snap_type == "word" or snap_type == "lines" then
    command.perform("doc:select-" .. snap_type)
  end
  apply_resolved_wrap_affinity(dv)
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

local function syntax_newline_continuation(doc, line, col, line_text)
  local continuation = intelligence.newline_continuation(doc, line + 1, {
    event = "newline",
    line = line,
    col = col,
    previous_line_text = line_text,
    before_text = tostring(line_text or ""):sub(1, col - 1),
  })
  return type(continuation) == "string" and continuation or nil
end

local function syntax_newline_indent(doc, line, col, base_indent, full_indent, line_text)
  local indent = intelligence.indent_for_line(doc, line + 1, {
    event = "newline",
    line = line,
    col = col,
    base_indent = base_indent,
    full_indent = full_indent,
    previous_line_text = line_text,
    before_text = tostring(line_text or ""):sub(1, col - 1),
  })
  if type(indent) == "string" then return indent end
  return base_indent
end

local function syntax_line_indent(doc, line, col, line_text)
  local indent = intelligence.indent_for_line(doc, line, {
    event = "line",
    line = line,
    col = col,
    current_line_text = line_text,
    previous_line_text = line > 1 and doc.lines[line - 1] or "",
  })
  return type(indent) == "string" and indent or nil
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

local function position_is_inside_range(line, col, line1, col1, line2, col2)
  if not line1 then return false end
  return (line > line1 or line == line1 and col >= col1)
     and (line < line2 or line == line2 and col < col2)
end

local function opening_delimiter_is_unmatched(doc, line, col, opener, closer, skip_line1, skip_col1, skip_line2, skip_col2)
  local depth = 1
  for l = line, #doc.lines do
    local text = doc.lines[l]
    local start_col = l == line and col + 1 or 1
    for i = start_col, #text do
      local ch = text:sub(i, i)
      if not position_is_inside_range(l, i, skip_line1, skip_col1, skip_line2, skip_col2)
      and (ch == opener or ch == closer)
      and position_is_code(doc, l, i) then
        if ch == opener then
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
  if line1 ~= line2 then return nil end

  local text = doc.lines[line1] or ""
  local selection_delta = col2 - col1
  local virtual_text = text
  if selection_delta > 0 then
    virtual_text = text:sub(1, col1 - 1) .. text:sub(col2)
  end

  local function real_col(virtual_col, affinity)
    if selection_delta <= 0 or virtual_col < col1 then return virtual_col end
    if virtual_col == col1 and affinity == "start" then return col1 end
    return virtual_col + selection_delta
  end

  local opener, opener_col = previous_non_space_on_line(virtual_text, col1)
  local opener_real_col = opener_col and real_col(opener_col)
  local closer = opener and smart_newline_pairs[opener]
  if not closer or not position_is_code(doc, line1, opener_real_col) then return nil end

  local base_indent = leading_indent(virtual_text)
  local inner_indent = base_indent .. one_indent_string(doc)
  local next_char, next_col = next_non_space_on_line(virtual_text, col1)
  local next_real_col = next_col and real_col(next_col, "end")

  if next_char == closer and position_is_code(doc, line1, next_real_col) then
    local insert_text = "\n" .. inner_indent .. "\n" .. base_indent
    return {
      line1 = line1,
      col1 = real_col(opener_col + 1, "start"),
      line2 = line1,
      col2 = next_real_col,
      text = insert_text,
      caret_offset = #("\n" .. inner_indent),
      reason = "between-pair",
    }
  end

  if next_char ~= nil then return nil end

  local edit_start = real_col(opener_col + 1, "start")
  local edit_end = real_col(line_end_col(virtual_text), "end")
  if opening_delimiter_is_unmatched(doc, line1, opener_real_col, opener, closer, line1, col1, line2, col2) then
    local insert_text = "\n" .. inner_indent .. "\n" .. base_indent .. closer
    return {
      line1 = line1,
      col1 = edit_start,
      line2 = line1,
      col2 = edit_end,
      text = insert_text,
      caret_offset = #("\n" .. inner_indent),
      reason = "after-unmatched-delimiter",
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

local function leading_whitespace(text)
  return tostring(text or ""):match("^[\t ]*") or ""
end

local function common_leading_indent(lines)
  local common_indent
  for _, line in ipairs(lines) do
    if line:find("%S") then
      local indent = leading_whitespace(line)
      if not common_indent then
        common_indent = indent
      else
        local n = math.min(#common_indent, #indent)
        local i = 1
        while i <= n and common_indent:sub(i, i) == indent:sub(i, i) do i = i + 1 end
        common_indent = common_indent:sub(1, i - 1)
      end
    end
  end
  return common_indent or ""
end

local function remove_indent_prefix(line, indent)
  if indent ~= "" and line:sub(1, #indent) == indent then
    return line:sub(#indent + 1)
  end
  return line
end

local function smart_paste_text(doc, line, col, text)
  text = tostring(text or "")
  if not text:find("\n", 1, true) then return text end
  local line_text = doc.lines[line] or ""
  local before = line_text:sub(1, col - 1)
  local target_indent = before:match("^[\t ]*$") and before or leading_whitespace(line_text)
  if target_indent == "" then return text end

  local parts = {}
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      parts[#parts + 1] = text:sub(start)
      break
    end
    parts[#parts + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  local common_indent = common_leading_indent(parts)
  if common_indent == "" and parts[1] and parts[1]:find("%S") then
    common_indent = leading_whitespace(parts[1])
  end

  for i, part in ipairs(parts) do
    local stripped = remove_indent_prefix(part, common_indent)
    if i == 1 then
      parts[i] = stripped
    elseif stripped == "" then
      parts[i] = ""
    else
      parts[i] = target_indent .. stripped
    end
  end
  return table.concat(parts, "\n")
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

local function previous_indent_stop_start_col(doc, line, col, indent_size)
  if col <= 1 then return nil end
  indent_size = math.max(1, tonumber(indent_size) or 1)
  local text = doc.lines[line] or ""
  local leading = text:match("^[\t ]*") or ""
  if col > #leading + 1 then return nil end

  local visual_col = 0
  for i = 1, col - 1 do
    local ch = text:sub(i, i)
    if ch == "\t" then
      visual_col = visual_col + (indent_size - (visual_col % indent_size))
    elseif ch == " " then
      visual_col = visual_col + 1
    else
      return nil
    end
  end
  if visual_col <= 0 then return nil end

  local target_col = math.floor((visual_col - 1) / indent_size) * indent_size
  local scan_col = 0
  for i = 1, col - 1 do
    local ch = text:sub(i, i)
    if ch == "\t" then
      scan_col = scan_col + (indent_size - (scan_col % indent_size))
    else
      scan_col = scan_col + 1
    end
    if scan_col > target_col then return i end
  end
end

local function coalesce_overlapping_same_line_removes(edits)
  local sorted = { table.unpack(edits) }
  table.sort(sorted, function(a, b)
    if a.line1 ~= b.line1 then return a.line1 < b.line1 end
    if a.col1 ~= b.col1 then return a.col1 < b.col1 end
    if a.line2 ~= b.line2 then return a.line2 < b.line2 end
    return a.col2 < b.col2
  end)

  local result = {}
  for _, edit in ipairs(sorted) do
    local last = result[#result]
    if last
    and edit.text == ""
    and last.text == ""
    and edit.line1 == edit.line2
    and last.line1 == last.line2
    and edit.line1 == last.line1
    and edit.col1 <= last.col2 then
      last.col2 = math.max(last.col2, edit.col2)
    else
      result[#result + 1] = {
        line1 = edit.line1,
        col1 = edit.col1,
        line2 = edit.line2,
        col2 = edit.col2,
        text = edit.text,
        idx = edit.idx,
      }
    end
  end
  return result
end

local function coalesce_duplicate_replacements(edits)
  local seen = {}
  local result = {}
  local original_to_coalesced = {}
  for _, edit in ipairs(edits) do
    local key = table.concat({ edit.line1, edit.col1, edit.line2, edit.col2, edit.text }, "\0")
    local coalesced_idx = seen[key]
    if not coalesced_idx then
      result[#result + 1] = edit
      coalesced_idx = #result
      seen[key] = coalesced_idx
    end
    original_to_coalesced[edit.idx] = coalesced_idx
  end
  return result, original_to_coalesced
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

  ["doc:cut"] = function(dv)
    cut_or_copy(dv, true)
  end,

  ["doc:copy"] = function(dv)
    cut_or_copy(dv, false)
  end,

  ["doc:undo"] = function(dv)
    if not can_edit(dv, "undo") then return end
    dv.doc:undo()
  end,

  ["doc:redo"] = function(dv)
    if not can_edit(dv, "redo") then return end
    dv.doc:redo()
  end,

  ["doc:paste"] = function(dv)
    if not can_edit(dv, "paste") then return end
    if dv.paste_from_provider and dv:paste_from_provider() then return end
    local clipboard = system.get_clipboard()
    if not clipboard or clipboard == "" then
    	return
    end
    -- If the clipboard has changed since our last look, use that instead
    if core.cursor_clipboard["full"] ~= clipboard then
      core.cursor_clipboard = {}
      core.cursor_clipboard_whole_line = {}
      local text = clipboard:gsub("\r", "")
      dv.doc:text_input_by_selection(function(_, line1, col1)
        return smart_paste_text(dv.doc, line1, col1, text)
      end, nil, { type = "insert" })
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
        dv.doc:text_input_by_selection(function(idx, line1, col1)
          return smart_paste_text(dv.doc, line1, col1, tostring(core.cursor_clipboard[idx] or ""):gsub("\r", ""))
        end, nil, { type = "insert" })
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
    if not can_edit(dv, "paste") then return end
    if type(x) == "number" and type(y) == "number" then
      set_cursor(dv, x, y, "set")
      -- Workaround to avoid that a middle mouse drag starts selecting
      dv.mouse_selecting = nil
    end
    local text = tostring(system.get_primary_selection() or ""):gsub("\r", "")
    dv.doc:text_input_by_selection(function(_, line1, col1)
      return smart_paste_text(dv.doc, line1, col1, text)
    end, nil, { type = "insert" })
  end,

  ["doc:newline"] = function(dv)
    if not can_edit(dv, "newline") then return end
    local text_by_idx = {}
    local edits = {}
    local normal_edits = {}
    local original_normal_text_by_idx = {}
    local final_by_idx = {}
    local normal_final_by_idx = {}
    local projected_selections = {}
    local original_to_projected = {}
    local whitespace_line_owner = {}
    local has_whitespace_cleanup = false
    local has_smart_newline = false

    local function project_selection(idx, line1, col1, line2, col2)
      local projected_idx = #projected_selections / 4 + 1
      projected_selections[#projected_selections + 1] = line1
      projected_selections[#projected_selections + 1] = col1
      projected_selections[#projected_selections + 1] = line2
      projected_selections[#projected_selections + 1] = col2
      original_to_projected[idx] = projected_idx
      return projected_idx
    end

    local function projected_last_selection()
      local last = dv.doc.last_selection or 1
      return original_to_projected[last] or 1
    end

    local function projected_selections_after(normalized, finals)
      local projection = {
        lines = dv.doc.lines,
        selections = projected_selections,
        last_selection = projected_last_selection(),
      }
      return Doc.selections_after_edits(projection, normalized, finals, projection.last_selection, { normalized = true })
    end

    local selection_items = {}
    for idx, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
      selection_items[#selection_items + 1] = {
        idx = idx,
        line1 = line1,
        col1 = col1,
        line2 = line2,
        col2 = col2,
      }
    end
    table.sort(selection_items, function(a, b) return a.idx < b.idx end)

    for _, item in ipairs(selection_items) do
      local idx, line1, col1, line2, col2 = item.idx, item.line1, item.col1, item.line2, item.col2
      local line = line1
      local col = col1
      local line_text = dv.doc.lines[line] or ""
      local indent = line_text:match("^[\t ]*") or ""
      local full_indent = indent
      if col <= #indent then
        indent = indent:sub(#indent + 2 - col)
      end

      local whitespace_only_line = line1 == line2
        and col1 == col2
        and not config.keep_newline_whitespace
        and #full_indent > 0
        and line_text:match("^[\t ]*\n?$")

      original_normal_text_by_idx[idx] = "\n" .. indent

      if whitespace_only_line and whitespace_line_owner[line] then
        original_to_projected[idx] = whitespace_line_owner[line]
        core.log_quiet("Newline coalesced duplicate whitespace-only caret in %s at line %d", dv.doc:get_name(), line)
      else
        local projected_idx = project_selection(idx, line1, col1, line2, col2)
        local insert_indent = indent
        if not whitespace_only_line then
          insert_indent = syntax_newline_continuation(dv.doc, line, col, line_text)
            or syntax_newline_indent(dv.doc, line, col, indent, full_indent, line_text)
        end
        local text = "\n" .. insert_indent
        text_by_idx[projected_idx] = text
        normal_final_by_idx[projected_idx] = "end"

        if whitespace_only_line then
          has_whitespace_cleanup = true
          whitespace_line_owner[line] = projected_idx
          final_by_idx[projected_idx] = "end"
          local edit = {
            line1 = line,
            col1 = 1,
            line2 = line,
            col2 = math.huge,
            text = text,
            idx = projected_idx,
          }
          edits[#edits + 1] = edit
          normal_edits[#normal_edits + 1] = edit
        else
          local smart_edit = smart_newline_edit(dv.doc, line1, col1, line2, col2)
          if smart_edit then
            has_smart_newline = true
            final_by_idx[projected_idx] = smart_edit.caret_offset
            core.log_quiet("Smart newline %s in %s at %d:%d", smart_edit.reason, dv.doc:get_name(), line1, col1)
            edits[#edits + 1] = {
              line1 = smart_edit.line1,
              col1 = smart_edit.col1,
              line2 = smart_edit.line2,
              col2 = smart_edit.col2,
              text = smart_edit.text,
              idx = projected_idx,
            }
          else
            final_by_idx[projected_idx] = "end"
            edits[#edits + 1] = {
              line1 = line1,
              col1 = col1,
              line2 = line2,
              col2 = col2,
              text = text,
              idx = projected_idx,
            }
          end
          normal_edits[#normal_edits + 1] = {
            line1 = line1,
            col1 = col1,
            line2 = line2,
            col2 = col2,
            text = text,
            idx = projected_idx,
          }
        end
      end
    end

    if has_whitespace_cleanup or has_smart_newline then
      local non_overlapping, normalized = edits_are_non_overlapping(dv.doc, edits)
      if not non_overlapping then
        if has_smart_newline then
          core.log_quiet("Smart newline skipped for %s because selections overlap", dv.doc:get_name())
        end
        edits = normal_edits
        final_by_idx = normal_final_by_idx
        non_overlapping, normalized = edits_are_non_overlapping(dv.doc, edits)
        if not non_overlapping then
          dv.doc:text_input_by_selection(original_normal_text_by_idx, nil, { type = "insert" })
          return
        end
      end
      local selections, last_selection = projected_selections_after(normalized, final_by_idx)
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
    if not can_edit(dv, "newline") then return end
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
    if not can_edit(dv, "newline") then return end
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
    if not can_edit(dv, "delete") then return end
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
    if not can_edit(dv, "backspace") then return end
    local _, indent_size = dv.doc:get_indent_info()
    local fallback = false
    for _, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
      if line1 == line2 and col1 == col2
      and previous_indent_stop_start_col(dv.doc, line1, col1, indent_size) then
        fallback = true
        break
      end
    end
    if fallback then
      local edits, final_by_idx = {}, {}
      for idx, line1, col1, line2, col2 in dv.doc:get_selections(true, true) do
        local start_line, start_col, end_line, end_col = line1, col1, line2, col2
        if line1 == line2 and col1 == col2 then
          local stop_col = previous_indent_stop_start_col(dv.doc, line1, col1, indent_size)
          if stop_col then
            start_line, start_col, end_line, end_col = line1, stop_col, line1, col1
          else
            local l2, c2 = dv.doc:position_offset(line1, col1, translate.previous_char)
            start_line, start_col, end_line, end_col = sort_positions(line1, col1, l2, c2)
          end
        end
        edits[#edits + 1] = { line1 = start_line, col1 = start_col, line2 = end_line, col2 = end_col, text = "", idx = idx }
        final_by_idx[idx] = "start"
      end
      local non_overlapping, normalized = edits_are_non_overlapping(dv.doc, edits)
      if not non_overlapping then
        edits = coalesce_overlapping_same_line_removes(edits)
        final_by_idx = {}
        for _, edit in ipairs(edits) do final_by_idx[edit.idx] = "start" end
        non_overlapping, normalized = edits_are_non_overlapping(dv.doc, edits)
        if not non_overlapping then
          dv.doc:delete_to(translate.previous_char)
          return
        end
      end
      dv.doc:apply_edits(edits, {
        type = "remove",
        selections = dv.doc:selections_after_edits(normalized, final_by_idx, dv.doc.last_selection, { normalized = true }),
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
      if not append_line_if_last_line(line2) then return end
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
    if not can_edit(dv, "join lines") then return end
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
    if not can_edit(dv, "indent") then return end
    local repair_edits, final_by_idx = {}, {}
    local selection_count, repairable_count = 0, 0
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      selection_count = selection_count + 1
      local line_text = dv.doc.lines[line1] or ""
      local leading = line_text:match("^[\t ]*") or ""
      local collapsed = line1 == line2 and col1 == col2
      local in_leading = collapsed and col1 <= #leading + 1
      local expected = in_leading and syntax_line_indent(dv.doc, line1, col1, line_text) or nil
      if expected and expected ~= leading then
        repairable_count = repairable_count + 1
        repair_edits[#repair_edits + 1] = {
          line1 = line1,
          col1 = 1,
          line2 = line1,
          col2 = #leading + 1,
          text = expected,
          idx = idx,
        }
        final_by_idx[idx] = "end"
      end
    end
    if #repair_edits > 0 and repairable_count == selection_count then
      local original_to_coalesced
      repair_edits, original_to_coalesced = coalesce_duplicate_replacements(repair_edits)
      final_by_idx = {}
      for _, edit in ipairs(repair_edits) do final_by_idx[edit.idx] = "end" end
      local non_overlapping = edits_are_non_overlapping(dv.doc, repair_edits)
      if non_overlapping then
        local selections = {}
        for _, edit in ipairs(repair_edits) do
          selections[#selections + 1] = edit.line1
          selections[#selections + 1] = #edit.text + 1
          selections[#selections + 1] = edit.line1
          selections[#selections + 1] = #edit.text + 1
        end
        dv.doc:apply_edits(repair_edits, {
          type = "replace",
          selections = selections,
          last_selection = original_to_coalesced[dv.doc.last_selection or 1] or math.min(dv.doc.last_selection or 1, math.max(1, #selections / 4)),
          merge_cursors = false,
        })
        return
      end
    end

    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      local l1, c1, l2, c2 = dv.doc:indent_text(false, line1, col1, line2, col2)
      if l1 then
        dv.doc:set_selections(idx, l1, c1, l2, c2)
      end
    end
  end,

  ["doc:unindent"] = function(dv)
    if not can_edit(dv, "unindent") then return end
    for idx, line1, col1, line2, col2 in doc_multiline_selections(true) do
      local l1, c1, l2, c2 = dv.doc:indent_text(true, line1, col1, line2, col2)
      if l1 then
        dv.doc:set_selections(idx, l1, c1, l2, c2)
      end
    end
  end,

  ["doc:duplicate-lines"] = function(dv)
    if not can_edit(dv, "duplicate lines") then return end
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
    if not can_edit(dv, "delete lines") then return end
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
    if not can_edit(dv, "move lines") then return end
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
    if not can_edit(dv, "move lines") then return end
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
    if not can_edit(dv, "toggle comments") then return end
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
    if not can_edit(dv, "toggle comments") then return end
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
    if not can_edit(dv, "change case") then return end
    dv.doc:replace(string.uupper)
  end,

  ["doc:lower-case"] = function(dv)
    if not can_edit(dv, "change case") then return end
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
        if dv.select_and_reveal then
          dv:select_and_reveal(line, 1, line, 1, { reason = "go-to-line" })
        else
          dv.doc:set_selection(line, 1)
          dv:scroll_to_line(line, true)
        end
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
    if not can_edit(dv, "toggle line ending") then return end
    dv.doc.crlf = not dv.doc.crlf
  end,

  ["doc:change-encoding"] = function(dv)
    if not can_edit(dv, "change encoding") then return end
    encodings.select_encoding("Select Output Encoding", function(charset)
      if not can_edit(dv, "change encoding") then return end
      set_encoding(dv.doc, charset)
      save_existing(dv.doc)
    end)
  end,

  ["doc:reload-with-encoding"] = function(dv)
    if not can_edit(dv, "reload") then return end
    encodings.select_encoding("Reload With Encoding", function(charset)
      if not can_edit(dv, "reload") then return end
      set_encoding(dv.doc, charset)
      dv.doc:reload()
    end)
  end,

  ["doc:toggle-overwrite"] = function(dv)
    dv.doc.overwrite = not dv.doc.overwrite
    core.blink_reset() -- to show the cursor has changed edit modes
  end,

  ["doc:save-as"] = function(dv)
    if not can_edit(dv, "save as") then return end
    prompt_save_as(dv, save_as_prompt_text(dv))
  end,

  ["doc:save"] = function(dv)
    if not can_edit(dv, "save") then return end
    if dv.doc.filename then
      save(nil, dv)
    else
      command.perform("doc:save-as")
    end
  end,

  ["doc:reload"] = function(dv)
    if not can_edit(dv, "reload") then return end
    dv.doc:reload()
  end,

  ["file:rename"] = function(dv)
    if not can_edit(dv, "rename file") then return end
    local old_filename = dv.doc.filename
    local old_abs_filename = dv.doc.abs_filename
    if not old_filename then
      core.error("Cannot rename unsaved doc")
      return
    end
    core.global_prompt_bar:enter("Rename", {
      text = old_filename,
      submit = function(filename)
        if not can_edit(dv, "rename file") then return end
        filename = common.sanitize_prompt_path(filename)
        local expanded_filename = common.home_expand(filename)
        local new_filename = core.normalize_to_project_dir(expanded_filename)
        local new_abs_filename = core.project_absolute_path(new_filename)
        save(expanded_filename, dv)
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
    if not can_edit(dv, "delete file") then return end
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
    apply_resolved_wrap_affinity(dv)
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
    if dv.begin_line_render_interaction then dv:begin_line_render_interaction("mouse-selection") end
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
    apply_resolved_wrap_affinity(dv)
    dv.mouse_selecting = { line, col, "set" }
  end
})

local function active_bom_document(view)
  view = view or core.active_view
  if not (view and view.extends and view:extends(DocView)) then return nil end
  local doc = view.doc
  local bom = encoding.get_charset_bom(doc.encoding or "none")
  if not bom then return nil end
  return doc, bom
end

command.add_toggle("doc:toggle-bom", {
  predicate = function()
    return active_bom_document() ~= nil
  end,
  get = function(view)
    local doc = active_bom_document(view)
    return doc and doc.bom ~= nil
  end,
  set = function(enabled, view)
    view = view or core.active_view
    if not can_edit(view, "toggle BOM") then return end
    local doc, bom = active_bom_document(view)
    if not doc then return end
    doc.bom = enabled and bom or nil
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
    if not can_edit(dv, "delete") then return end
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
      target_line = dv.fold_aware_line_move and dv:fold_aware_line_move(line, line_offset) or line + line_offset
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
    local target_fold = dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
    if target_fold and target_fold.line1 == target_line then target_col = 1 end
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
      target_line = dv.fold_aware_line_move and dv:fold_aware_line_move(line, line_offset) or line + line_offset
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
    local target_fold = dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
    if target_fold and target_fold.line1 == target_line then target_col = 1 end
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

local unwrapped_navigation_commands = {}
for _, name in ipairs({
  "doc:move-to-previous-line",
  "doc:move-to-next-line",
  "doc:select-to-previous-line",
  "doc:select-to-next-line",
  "doc:move-to-next-char",
  "doc:select-to-next-char",
  "doc:move-to-next-word-end",
  "doc:select-to-next-word-end",
  "doc:move-to-end-of-word",
  "doc:select-to-end-of-word",
  "doc:move-to-next-block-end",
  "doc:select-to-next-block-end",
  "doc:move-to-end-of-doc",
  "doc:select-to-end-of-doc",
  "doc:move-to-start-of-line",
  "doc:select-to-start-of-line",
  "doc:delete-to-start-of-line",
  "doc:move-to-start-of-indentation",
  "doc:select-to-start-of-indentation",
  "doc:delete-to-start-of-indentation",
  "doc:move-to-end-of-line",
  "doc:select-to-end-of-line",
  "doc:delete-to-end-of-line",
}) do
  unwrapped_navigation_commands[name] = commands[name]
end

local function perform_unwrapped_navigation(name, dv, ...)
  local old = unwrapped_navigation_commands[name]
  if old then return old(dv, ...) end
end

local function add_line_end_affinity(positions, line, col, line_end)
  if line_end then positions[linewrapping.position_key(line, col)] = true end
end

local function wrapped_move_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings then return perform_unwrapped_navigation(name, dv, ...) end
  local selections = {}
  local affinity_positions = {}
  for _, line1, col1 in dv.doc:get_selections(false) do
    local line, col, line_end = move_fn(dv.doc, line1, col1, ...)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    add_line_end_affinity(affinity_positions, line, col, line_end)
  end
  dv.doc:set_selection_list(selections, dv.doc.last_selection, { merge_cursors = true })
  linewrapping.set_wrapped_line_end_affinity(dv, affinity_positions)
end

local function wrapped_select_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings then return perform_unwrapped_navigation(name, dv, ...) end
  local selections = {}
  local affinity_positions = {}
  for _, line1, col1, line2, col2 in dv.doc:get_selections(false) do
    local line, col, line_end = move_fn(dv.doc, line1, col1, ...)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line2
    selections[#selections + 1] = col2
    add_line_end_affinity(affinity_positions, line, col, line_end)
  end
  dv.doc:set_selection_list(selections, dv.doc.last_selection, { merge_cursors = true })
  linewrapping.set_wrapped_line_end_affinity(dv, affinity_positions)
  set_primary_selection(dv.doc)
end

local function wrapped_delete_to(dv, name, move_fn, ...)
  if not can_edit(dv, "delete") then return end
  if not dv.wrapped_settings then return perform_unwrapped_navigation(name, dv, ...) end
  local args = { n = select("#", ...), ... }
  return dv.doc:delete_to(function(target_doc, line, col)
    return move_fn(target_doc, line, col, table.unpack(args, 1, args.n))
  end, dv)
end

local function wrapped_forward_endpoint_command(dv, name, ...)
  if not dv.wrapped_settings then return perform_unwrapped_navigation(name, dv, ...) end
  local old_selections = linewrapping.copy_selection_list(dv.doc.selections)
  local result = perform_unwrapped_navigation(name, dv, ...)
  linewrapping.set_wrapped_line_end_affinity(dv, linewrapping.collect_forward_endpoint_affinity(dv, old_selections))
  return result
end

local function move_to_wrapped_previous_line(doc, line, col, dv)
  if dv and dv.has_collapsed_folds and dv:has_collapsed_folds() then
    local hidden, fold = dv:is_line_hidden_by_fold(math.max(1, (line or 1) - 1))
    if hidden and dv:get_visual_row_count_for_line(line) <= 1 then return fold.line1, 1 end
    return dv:folded_visual_line_position(line, col, -1)
  end
  local target_line, target_col, target_line_end = linewrapping.wrapped_visual_line_position(dv, line, col, -1)
  if dv and dv.is_line_hidden_by_fold then
    local current_fold = dv:get_collapsed_fold_at_line(line)
    local target_fold = dv:get_collapsed_fold_at_line(target_line)
    if dv:is_line_hidden_by_fold(target_line) or (current_fold and current_fold.line1 == line and target_line == line) then
      target_line = dv:fold_aware_line_move(line, -1)
      target_col = current_fold and current_fold.line1 == line and 1 or common.clamp(target_col, 1, #doc.lines[target_line])
    elseif target_fold and target_fold.line1 == target_line then
      target_col = 1
    end
  end
  local landed_fold = dv and dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
  if landed_fold and landed_fold.line1 == target_line then target_col = 1 end
  return target_line, target_col, target_line_end
end

local function move_to_wrapped_next_line(doc, line, col, dv)
  if dv and dv.has_collapsed_folds and dv:has_collapsed_folds() then
    return dv:folded_visual_line_position(line, col, 1)
  end
  local target_line, target_col, target_line_end = linewrapping.wrapped_visual_line_position(dv, line, col, 1)
  if dv and dv.is_line_hidden_by_fold then
    local current_fold = dv:get_collapsed_fold_at_line(line)
    local target_fold = dv:get_collapsed_fold_at_line(target_line)
    if dv:is_line_hidden_by_fold(target_line) or (current_fold and current_fold.line1 == line and target_line == line) then
      target_line = dv:fold_aware_line_move(line, 1)
      target_col = current_fold and current_fold.line1 == line and 1 or common.clamp(target_col, 1, #doc.lines[target_line])
    elseif target_fold and target_fold.line1 == target_line then
      target_col = 1
    end
  end
  local landed_fold = dv and dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
  if landed_fold and landed_fold.line1 == target_line then target_col = 1 end
  return target_line, target_col, target_line_end
end

local function move_to_wrapped_end_of_line(doc, line, col, dv)
  return linewrapping.wrapped_end_of_line_position(dv, doc, line, col, translate.end_of_line)
end

local function move_to_wrapped_start_of_line(doc, line, col, dv)
  return linewrapping.wrapped_start_of_line_position(dv, doc, line, col, translate.start_of_line)
end

local function move_to_wrapped_start_of_indentation(doc, line, col, dv)
  return linewrapping.wrapped_start_of_indentation_position(dv, doc, line, col, translate.start_of_indentation)
end

commands["doc:move-to-previous-line"] = function(dv)
  return wrapped_move_to(dv, "doc:move-to-previous-line", move_to_wrapped_previous_line, dv)
end
commands["doc:move-to-next-line"] = function(dv)
  return wrapped_move_to(dv, "doc:move-to-next-line", move_to_wrapped_next_line, dv)
end
commands["doc:select-to-previous-line"] = function(dv)
  return wrapped_select_to(dv, "doc:select-to-previous-line", move_to_wrapped_previous_line, dv)
end
commands["doc:select-to-next-line"] = function(dv)
  return wrapped_select_to(dv, "doc:select-to-next-line", move_to_wrapped_next_line, dv)
end

for _, name in ipairs({
  "doc:move-to-next-char",
  "doc:select-to-next-char",
  "doc:move-to-next-word-end",
  "doc:select-to-next-word-end",
  "doc:move-to-end-of-word",
  "doc:select-to-end-of-word",
  "doc:move-to-next-block-end",
  "doc:select-to-next-block-end",
  "doc:move-to-end-of-doc",
  "doc:select-to-end-of-doc",
}) do
  local command_name = name
  commands[command_name] = function(dv, ...)
    return wrapped_forward_endpoint_command(dv, command_name, ...)
  end
end

commands["doc:move-to-start-of-line"] = function(dv)
  return wrapped_move_to(dv, "doc:move-to-start-of-line", move_to_wrapped_start_of_line, dv)
end
commands["doc:select-to-start-of-line"] = function(dv)
  return wrapped_select_to(dv, "doc:select-to-start-of-line", move_to_wrapped_start_of_line, dv)
end
commands["doc:delete-to-start-of-line"] = function(dv)
  return wrapped_delete_to(dv, "doc:delete-to-start-of-line", move_to_wrapped_start_of_line, dv)
end
commands["doc:move-to-start-of-indentation"] = function(dv)
  return wrapped_move_to(dv, "doc:move-to-start-of-indentation", move_to_wrapped_start_of_indentation, dv)
end
commands["doc:select-to-start-of-indentation"] = function(dv)
  return wrapped_select_to(dv, "doc:select-to-start-of-indentation", move_to_wrapped_start_of_indentation, dv)
end
commands["doc:delete-to-start-of-indentation"] = function(dv)
  return wrapped_delete_to(dv, "doc:delete-to-start-of-indentation", move_to_wrapped_start_of_indentation, dv)
end
commands["doc:move-to-end-of-line"] = function(dv)
  return wrapped_move_to(dv, "doc:move-to-end-of-line", move_to_wrapped_end_of_line, dv)
end
commands["doc:select-to-end-of-line"] = function(dv)
  return wrapped_select_to(dv, "doc:select-to-end-of-line", move_to_wrapped_end_of_line, dv)
end
commands["doc:delete-to-end-of-line"] = function(dv)
  return wrapped_delete_to(dv, "doc:delete-to-end-of-line", move_to_wrapped_end_of_line, dv)
end

commands["doc:fold-at-caret"] = function(dv)
  local fold, err = dv:fold_at_caret()
  if not fold and err then core.log_quiet("Fold at caret skipped: %s", tostring(err)) end
end

commands["doc:unfold-at-caret"] = function(dv)
  dv:unfold_at_caret("command")
end

commands["doc:unfold-all"] = function(dv)
  dv:unfold_all("command")
end

command.add("core.docview", commands)

command.add_toggle("line-wrapping:toggle", {
  get = function(view)
    view = view or core.active_view
    return view and view.doc and view.extends and view:extends(DocView) and view:is_wrapping_enabled()
  end,
  set = function(enabled, view)
    view = view or core.active_view
    if view and view.doc and view.extends and view:extends(DocView) then
      view:set_wrapping_enabled(enabled)
    end
  end,
})

keymap.add {
  ["f10"] = "line-wrapping:toggle",
}

keymap.add_direct {
  ["ctrl+-"] = "doc:fold-at-caret",
  ["ctrl+shift+-"] = "doc:fold-at-caret",
  ["ctrl+="] = "doc:unfold-at-caret",
  ["ctrl+shift+="] = "doc:unfold-at-caret",
  ["ctrl+plus"] = "doc:unfold-at-caret",
  ["ctrl+shift+plus"] = "doc:unfold-at-caret",
}
