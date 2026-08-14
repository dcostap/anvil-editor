local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local linewrapping = require "core.linewrapping"
local intelligence = require "core.language_intelligence"
local encodings = require "core.buffer.encodings"
local translate = require "core.buffer.translate"
local style = require "core.style"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local Editor = require "core.editor"
local tokenizer = require "core.tokenizer"
local panes = require "core.panes"


local function buffer()
  return core.active_view.buffer
end

local function can_edit(dv, reason, opts)
  if dv and dv.can_edit then
    return dv:can_edit(reason, common.merge({ warn = true }, opts or {}))
  end
  return true
end


local function buffer_multiline_selections(sort)
  local iter, state, idx, line1, col1, line2, col2 = buffer():get_selections(sort)
  return function()
    idx, line1, col1, line2, col2 = iter(state, idx)
    if idx and line2 > line1 and col2 == 1 then
      line2 = line2 - 1
      col2 = #buffer().lines[line2]
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

local function sort_line_actions(actions)
  table.sort(actions, function(a, b)
    if a.line1 ~= b.line1 then return a.line1 < b.line1 end
    if a.line2 ~= b.line2 then return a.line2 < b.line2 end
    return a.idx < b.idx
  end)
end

local function append_line_if_last_line(line)
  if line >= #buffer().lines then
    if not can_edit(core.active_view, "extend selection") then return false end
    buffer():insert(line, math.huge, "\n")
  end
  return true
end

local function merge_overlapping_removals(target_buffer, edits)
  local normalized = target_buffer:plan_edits(edits)
  local merged = {}
  for _, edit in ipairs(normalized) do
    local previous = merged[#merged]
    if previous and edit.start_offset <= previous.end_offset then
      if edit.end_offset > previous.end_offset then
        previous.line2 = edit.line2
        previous.col2 = edit.col2
        previous.end_offset = edit.end_offset
      end
    else
      merged[#merged + 1] = {
        line1 = edit.line1,
        col1 = edit.col1,
        line2 = edit.line2,
        col2 = edit.col2,
        text = "",
        end_offset = edit.end_offset,
      }
    end
  end
  return merged
end

local prompt_save_as
local save_as_prompt_text

local function save(filename, target)
  local target_buffer = target and target.buffer or target or buffer()
  local abs_filename
  if filename then
    filename = core.normalize_to_project_dir(filename)
    abs_filename = core.project_absolute_path(filename)
  end
  local ok, err = pcall(target_buffer.save, target_buffer, filename, abs_filename)
  if ok then
    local saved_filename = target_buffer.filename
    core.log("Saved \"%s\"", saved_filename)
  else
    core.error(err)
    if tostring(err):find("file changed on disk", 1, true) then return end
    core.nag_view:show("Saving failed", string.format("Couldn't save file \"%s\". Do you want to save to another location?", target_buffer.filename), {
      { text = "Yes", default_yes = true },
      { text = "No", default_no = true }
    }, function(item)
      if item.text == "Yes" then
        core.add_thread(function()
          -- we need to run this in a thread because of the odd way the nagview is.
          if target and target.buffer then
            prompt_save_as(target, save_as_prompt_text(target))
          else
            command.perform("text:save-as")
          end
        end)
      end
    end)
  end
end

local function save_existing(buffer)
  if not buffer.filename then return end
  local ok, err = pcall(buffer.save, buffer)
  if not ok and not tostring(err):find("file changed on disk", 1, true) then
    core.error("Couldn't save file \"%s\": %s", buffer.filename, err)
  end
end

function save_as_prompt_text(dv)
  local last_buffer = core.last_active_view and core.last_active_view.buffer
  if dv.buffer.filename then
    return dv.buffer.filename
  elseif last_buffer and last_buffer.filename then
    local dirname = core.last_active_view.buffer.abs_filename:match("(.*)[/\\].+$")
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
      if not dv.buffer.filename and system.get_file_info(abs_filename) then
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
  local target_buffer = dv.buffer
  local full_text = ""
  local text = ""
  local copied_ranges = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  for idx, line1, col1, line2, col2 in target_buffer:get_selections(true, true) do
    if line1 ~= line2 or col1 ~= col2 then
      text = target_buffer:get_text(line1, col1, line2, col2)
      full_text = full_text == "" and text or (text .. " " .. full_text)
      core.cursor_clipboard_whole_line[idx] = false
      copied_ranges[#copied_ranges + 1] = { line1, col1, line2, col2 }
    else -- Cut/copy whole line
      -- Remove newline from the text. It will be added as needed on paste.
      text = string.sub(target_buffer.lines[line1], 1, -2)
      full_text = full_text == "" and text .. "\n" or (text .. "\n" .. full_text)
      core.cursor_clipboard_whole_line[idx] = true
      copied_ranges[#copied_ranges + 1] = { line1, 1, line1, #target_buffer.lines[line1] }
    end
    core.cursor_clipboard[idx] = text
  end
  if delete then
    local edits = {}
    for idx, line1, col1, line2, col2 in target_buffer:get_selections(true, true) do
      if line1 ~= line2 or col1 ~= col2 then
        edits[#edits + 1] = {
          line1 = line1, col1 = col1, line2 = line2, col2 = col2,
          text = "", idx = idx,
        }
      elseif line1 < #target_buffer.lines then
        edits[#edits + 1] = {
          line1 = line1, col1 = 1, line2 = line1 + 1, col2 = 1,
          text = "", idx = idx,
        }
      elseif #target_buffer.lines == 1 then
        edits[#edits + 1] = {
          line1 = line1, col1 = 1, line2 = line1, col2 = #target_buffer.lines[line1],
          text = "", idx = idx,
        }
      else
        edits[#edits + 1] = {
          line1 = line1 - 1, col1 = #target_buffer.lines[line1 - 1],
          line2 = line1, col2 = #target_buffer.lines[line1],
          text = "", idx = idx,
        }
      end
    end
    if #edits > 0 then
      edits = merge_overlapping_removals(target_buffer, edits)
      target_buffer:apply_edits(edits, {
        type = "remove",
        last_selection = target_buffer.last_selection,
        merge_cursors = true,
      })
    end
  end
  core.cursor_clipboard["full"] = full_text
  system.set_clipboard(full_text)
  if not delete and dv.show_copy_feedback then
    dv:show_copy_feedback(copied_ranges)
  end
end

local function set_primary_selection(buffer)
  -- Doesn't work on Windows, so avoid spending time getting the text
  if PLATFORM ~= "Windows" then
    system.set_primary_selection(buffer:get_selection_text())
  end
end

local function split_cursor(dv, direction)
  local new_cursors = {}
  local dv_translate = direction < 0
    and TextView.translate.previous_line
    or TextView.translate.next_line
  for _, line1, col1 in dv.buffer:get_selections() do
    if line1 + direction >= 1 and line1 + direction <= #dv.buffer.lines then
      table.insert(new_cursors, { dv_translate(dv.buffer, line1, col1, dv) })
    end
  end
  -- add selections in the order that will leave the "last" added one as buffer.last_selection
  local start, stop = 1, #new_cursors
  if direction < 0 then
    start, stop = #new_cursors, 1
  end
  for i = start, stop, direction do
    local v = new_cursors[i]
    dv.buffer:add_selection(v[1], v[2])
  end
  core.blink_reset()
end

local function apply_resolved_wrap_affinity(dv)
  linewrapping.apply_resolved_line_end_affinity(dv)
  if dv.apply_resolved_line_render_position_row_affinity then
    dv:apply_resolved_line_render_position_row_affinity()
  end
end

local function set_cursor(dv, x, y, snap_type)
  if dv.begin_line_render_interaction then dv:begin_line_render_interaction("mouse-selection") end
  local line, col = dv:resolve_screen_position(x, y)
  dv.buffer:set_selection(line, col, line, col)
  if snap_type == "word" or snap_type == "lines" then
    command.perform("text:select-" .. snap_type)
  end
  apply_resolved_wrap_affinity(dv)
  dv.mouse_selecting = { line, col, snap_type }
  core.blink_reset()
end

local function set_encoding(buffer, charset)
  buffer.encoding = charset
  if buffer.bom then
    buffer.bom = encoding.get_charset_bom(charset)
  end
end

local function line_comment(comment, line1, col1, line2, col2)
  local start_comment = (type(comment) == 'table' and comment[1] or comment) .. " "
  local end_comment = (type(comment) == 'table' and " " .. comment[2])
  local uncomment = true
  local start_offset = math.huge
  for line = line1, line2 do
    local text = buffer().lines[line]
    local s = text:find("%S")
    if s then
      local cs, ce = text:find(start_comment, s, true)
      if cs ~= s then
        uncomment = false
      end
      start_offset = math.min(start_offset, s)
    end
  end

  local end_line = col2 == #buffer().lines[line2]
  local edits = {}
  for line = line1, line2 do
    local text = buffer().lines[line]
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
    buffer():apply_edits(edits, {
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
  local word_start = buffer():get_text(line1, col1, line1, math.huge):find("%S")
  local word_end = buffer():get_text(line2, 1, line2, col2):find("%s*$")
  col1 = col1 + (word_start and (word_start - 1) or 0)
  col2 = word_end and word_end or col2

  local block_start = buffer():get_text(line1, col1, line1, col1 + #comment[1])
  local block_end = buffer():get_text(line2, col2 - #comment[2], line2, col2)

  if block_start == comment[1] and block_end == comment[2] then
    -- remove up to 1 whitespace after the comment
    local start_len, stop_len = #comment[1], #comment[2]
    if buffer():get_text(line1, col1 + #comment[1], line1, col1 + #comment[1] + 1):find("%s$") then
      start_len = start_len + 1
    end
    if buffer():get_text(line2, col2 - #comment[2] - 1, line2, col2):find("^%s") then
      stop_len = stop_len + 1
    end

    buffer():apply_edits({
      { line1 = line1, col1 = col1, line2 = line1, col2 = col1 + start_len, text = "" },
      { line1 = line2, col1 = col2 - stop_len, line2 = line2, col2 = col2, text = "" },
    }, { type = "remove", merge_cursors = false })
    col2 = col2 - (line1 == line2 and start_len or 0)

    return line1, col1, line2, col2 - stop_len
  else
    local prefix = comment[1] .. " "
    local suffix = " " .. comment[2]
    if line1 == line2 and col1 == col2 then
      buffer():apply_edits({
        { line1 = line1, col1 = col1, line2 = line1, col2 = col1, text = prefix .. suffix },
      }, { type = "insert", merge_cursors = false })
    else
      buffer():apply_edits({
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

local function indent_visual_width(text, tab_size)
  local indent = leading_indent(text)
  local width = 0
  tab_size = math.max(1, tonumber(tab_size) or 1)
  for i = 1, #indent do
    if indent:sub(i, i) == "\t" then
      width = width + tab_size - (width % tab_size)
    else
      width = width + 1
    end
  end
  return width, #indent + 1
end

local function one_indent_string(buffer)
  local text = buffer:get_indent_string(1)
  return text
end

local function syntax_newline_continuation(buffer, line, col, line_text)
  local continuation = intelligence.newline_continuation(buffer, line + 1, {
    event = "newline",
    line = line,
    col = col,
    previous_line_text = line_text,
    before_text = tostring(line_text or ""):sub(1, col - 1),
  })
  return type(continuation) == "string" and continuation or nil
end

local function syntax_newline_indent(buffer, line, col, base_indent, full_indent, line_text)
  local indent = intelligence.indent_for_line(buffer, line + 1, {
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

local function syntax_line_indent(buffer, line, col, line_text)
  local indent = intelligence.indent_for_line(buffer, line, {
    event = "line",
    line = line,
    col = col,
    current_line_text = line_text,
    previous_line_text = line > 1 and buffer.lines[line - 1] or "",
  })
  return type(indent) == "string" and indent or nil
end

local function line_end_col(text)
  local nl = tostring(text or ""):find("\n", 1, true)
  return nl or (#tostring(text or "") + 1)
end

local function markdown_empty_list_item(buffer, line, col, line_text)
  local syntax_name = tostring(buffer and buffer.syntax and buffer.syntax.name or ""):lower()
  if not syntax_name:find("markdown", 1, true) then return false end
  local end_col = line_end_col(line_text)
  if col ~= end_col then return false end
  local content = tostring(line_text or ""):sub(1, end_col - 1)
  return content:match("^%s*[-%+%*]%s+$")
    or content:match("^%s*%d+%.%s+$")
    or content:match("^%s*%d+%)%s+$")
    or content:match("^%s*[-%+%*]%s+%[[ xX]%]%s*$")
    or content:match("^%s*%d+%.%s+%[[ xX]%]%s*$")
    or content:match("^%s*%d+%)%s+%[[ xX]%]%s*$")
end

local function markdown_list_content_start(buffer, line, line_text, allow_empty)
  local syntax_name = tostring(buffer and buffer.syntax and buffer.syntax.name or ""):lower()
  if not syntax_name:find("markdown", 1, true) then return nil end
  local end_col = line_end_col(line_text)
  local content = tostring(line_text or ""):sub(1, end_col - 1)

  local indent, marker, spaces = content:match(
    "^([\t ]*)([-%*%+])([\t ]+)"
  )
  if not indent then
    indent, marker, spaces = content:match(
      "^([\t ]*)(%d+[%.%)])([\t ]+)"
    )
  end
  if not indent then return nil end

  local content_start = #indent + #marker + #spaces + 1
  local task, after_task = content:sub(content_start):match(
    "^(%[[ xX]%])([\t ]*)"
  )
  local task_start
  if task then
    local after_col = content_start + #task + #after_task
    if #after_task > 0 or after_col == #content + 1 then
      task_start = content_start
      content_start = after_col
    end
  end
  if allow_empty or content:sub(content_start):match("^%S") then
    return content_start, #indent, task_start
  end
end

local function markdown_indent_width(indent)
  local width = 0
  for i = 1, #(indent or "") do
    if indent:byte(i) == 9 then
      width = width + 4 - width % 4
    else
      width = width + 1
    end
  end
  return width
end

local function markdown_list_indent_width(buffer, line, line_text)
  local content_start, indent_length = markdown_list_content_start(
    buffer, line, line_text, true
  )
  if not content_start then return nil end
  return markdown_indent_width(tostring(line_text or ""):sub(1, indent_length))
end

local function markdown_list_can_indent(buffer, line, line_text)
  local indent_width = markdown_list_indent_width(buffer, line, line_text)
  if indent_width == nil then return false end
  for previous_line = line - 1, 1, -1 do
    local previous_width = markdown_list_indent_width(
      buffer, previous_line, buffer.lines[previous_line] or ""
    )
    if previous_width ~= nil then
      if previous_width == indent_width then return true end
      if previous_width < indent_width then return false end
    end
  end
  return false
end

local function markdown_space_indent(line_text, indent_length)
  return string.rep(
    " ", markdown_indent_width(tostring(line_text or ""):sub(1, indent_length))
  )
end

local function markdown_marker_only_task_end_col(line_text)
  local text = tostring(line_text or ""):gsub("\n$", "")
  if text:match("^[\t ]*[-%+%*][\t ]+%[[ xX]%]$")
    or text:match("^[\t ]*%d+[%.%)][\t ]+%[[ xX]%]$")
  then
    return #text + 1
  end
end

local function marker_only_task_selection_positions(dv)
  local positions = {}
  local count = 0
  for _, line1, col1, line2, col2 in dv.buffer:get_selections(false) do
    local end_col = line1 == line2 and markdown_marker_only_task_end_col(
      dv.buffer.lines[line1]
    )
    if end_col and col1 == end_col and col2 == end_col then
      positions[linewrapping.position_key(line1, col1)] = true
      count = count + 1
    else
      return nil
    end
  end
  return count > 0 and positions or nil
end

local function clear_markdown_task_source_affinity(dv)
  if not dv.__markdown_task_source_affinity then return false end
  dv.__markdown_task_source_affinity = nil
  dv:invalidate_line_render("markdown-task-source-affinity")
  return true
end

local function has_markdown_task_source_affinity(dv)
  local affinity = dv.__markdown_task_source_affinity
  if affinity and (
    affinity.text_revision ~= (dv.buffer.text_revision or 0)
    or affinity.selection_key ~= linewrapping.selection_state_key(dv.buffer)
  ) then
    clear_markdown_task_source_affinity(dv)
    affinity = nil
  end
  return affinity ~= nil
end

local function set_markdown_task_source_affinity(dv)
  local positions = marker_only_task_selection_positions(dv)
  if not positions then return false end
  dv.__markdown_task_source_affinity = {
    text_revision = dv.buffer.text_revision or 0,
    selection_key = linewrapping.selection_state_key(dv.buffer),
    positions = positions,
  }
  dv:invalidate_line_render("markdown-task-source-affinity")
  return true
end

local function reveal_markdown_task_source_from_implicit_content(dv)
  if has_markdown_task_source_affinity(dv) then return false end
  return set_markdown_task_source_affinity(dv)
end

local function markdown_list_join_info(buffer, line, line_text)
  local content_start = markdown_list_content_start(buffer, line, line_text)
  if not content_start then return nil end
  local end_col = line_end_col(line_text)
  local content = tostring(line_text or ""):sub(1, end_col - 1)
  local indent, bullet = content:match("^([\t ]*)([-%+%*])")
  if bullet then
    return {
      kind = "unordered", marker = bullet,
      indent = indent, content_start = content_start,
    }
  end
  local number, delimiter
  indent, number, delimiter = content:match("^([\t ]*)(%d+)([%.%)])")
  if number then
    return {
      kind = "ordered", marker = delimiter,
      indent = indent, content_start = content_start,
    }
  end
end

local function markdown_list_join_content_col(buffer, line, line_text, next_line_text)
  local current = markdown_list_join_info(buffer, line, line_text)
  local following = markdown_list_join_info(buffer, line + 1, next_line_text)
  if not current or not following
    or current.kind ~= following.kind
    or current.marker ~= following.marker
    or current.indent ~= following.indent
  then
    return nil
  end
  return following.content_start
end

local function markdown_list_marker_delete_end(buffer, line, line_text, col)
  local syntax_name = tostring(buffer and buffer.syntax and buffer.syntax.name or ""):lower()
  if not syntax_name:find("markdown", 1, true) then return nil end
  local end_col = line_end_col(line_text)
  local content = tostring(line_text or ""):sub(1, end_col - 1)
  local indent, bullet, spaces = content:match("^([\t ]*)([-%+%*])([\t ]+)")
  if bullet and col == #indent + 1 then
    return #indent + #bullet + #spaces + 1
  end
  local number, delimiter
  indent, number, delimiter, spaces = content:match(
    "^([\t ]*)(%d+)([%.%)])([\t ]+)"
  )
  if number and col == #indent + 1 then
    return #indent + #number + #delimiter + #spaces + 1
  end
end

local function markdown_join_lines_text(buffer, line1, line2)
  local result = ""
  for line = line1, line2 do
    local raw = buffer.lines[line] or ""
    local current = raw:gsub("\n$", "")
    if line == line1 then
      result = current
    else
      local previous_raw = buffer.lines[line - 1] or ""
      local next_content_col = markdown_list_join_content_col(
        buffer, line - 1, previous_raw, raw
      )
      if next_content_col then
        local separator = result:sub(-1):match("[ \t]") and "" or " "
        result = result .. separator .. current:sub(next_content_col)
      else
        local leading = current:match("^[\t ]*") or ""
        if previous_raw:gsub("\n$", ""):match("^%s*$") then
          result = result .. current:sub(#leading + 1)
        else
          result = result .. " " .. current:sub(#leading + 1)
        end
      end
    end
  end
  return result
end

local function token_at(buffer, line, col)
  local column = 0
  for _, token_type, token_text in buffer.highlighter:each_token(line) do
    column = column + #token_text
    if column >= col then return token_type end
  end
  return "normal"
end

local function token_is_code(token_type)
  return token_type ~= "comment" and token_type ~= "string"
end

local function position_is_code(buffer, line, col)
  return token_is_code(token_at(buffer, line, col))
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

local function opening_delimiter_is_unmatched(buffer, line, col, opener, closer, skip_line1, skip_col1, skip_line2, skip_col2)
  local depth = 1
  local _, indent_size = buffer:get_indent_info()
  local opener_indent_width = indent_visual_width(buffer.lines[line], indent_size)
  for l = line, #buffer.lines do
    local text = buffer.lines[l]
    local start_col = l == line and col + 1 or 1
    for i = start_col, #text do
      local ch = text:sub(i, i)
      if not position_is_inside_range(l, i, skip_line1, skip_col1, skip_line2, skip_col2)
      and (ch == opener or ch == closer)
      and position_is_code(buffer, l, i) then
        if ch == opener then
          depth = depth + 1
        else
          if depth == 1 and l > line then
            local closer_indent_width, first_content_col = indent_visual_width(text, indent_size)
            if i == first_content_col and closer_indent_width < opener_indent_width then
              core.log_quiet(
                "Smart newline kept outer closer in %s at %d:%d for nested opener at %d:%d",
                buffer:get_name(), l, i, line, col
              )
              return true
            end
          end
          depth = depth - 1
          if depth == 0 then return false end
        end
      end
    end
  end
  return true
end

local function edits_are_non_overlapping(buffer, edits)
  local normalized = buffer:plan_edits(edits)
  for i = 2, #normalized do
    local prev, cur = normalized[i - 1], normalized[i]
    if prev.end_offset > cur.start_offset
    or (prev.start_offset == prev.end_offset and cur.start_offset == cur.end_offset and prev.start_offset == cur.start_offset) then
      return false
    end
  end
  return true, normalized
end

local function smart_newline_edit(buffer, line1, col1, line2, col2)
  local has_selection = line1 ~= line2 or col1 ~= col2
  local virtual_text = buffer.lines[line1] or ""
  if has_selection then
    virtual_text = virtual_text:sub(1, col1 - 1) .. (buffer.lines[line2] or ""):sub(col2)
  end

  local function real_position(virtual_col, affinity)
    if not has_selection or virtual_col < col1 then return line1, virtual_col end
    if virtual_col == col1 and affinity == "start" then return line1, col1 end
    return line2, col2 + virtual_col - col1
  end

  local opener, opener_col = previous_non_space_on_line(virtual_text, col1)
  local opener_real_line, opener_real_col = real_position(opener_col or col1, "start")
  local closer = opener and smart_newline_pairs[opener]
  if not closer or not position_is_code(buffer, opener_real_line, opener_real_col) then return nil end

  local base_indent = leading_indent(virtual_text)
  local inner_indent = base_indent .. one_indent_string(buffer)
  local next_char, next_col = next_non_space_on_line(virtual_text, col1)
  local next_real_line, next_real_col
  if next_col then next_real_line, next_real_col = real_position(next_col, "end") end

  if next_char == closer and position_is_code(buffer, next_real_line, next_real_col) then
    local insert_text = "\n" .. inner_indent .. "\n" .. base_indent
    local edit_start_line, edit_start_col = real_position(opener_col + 1, "start")
    return {
      line1 = edit_start_line,
      col1 = edit_start_col,
      line2 = next_real_line,
      col2 = next_real_col,
      text = insert_text,
      caret_offset = #("\n" .. inner_indent),
      reason = "between-pair",
    }
  end

  if next_char ~= nil then return nil end

  local edit_start_line, edit_start_col = real_position(opener_col + 1, "start")
  local edit_end_line, edit_end_col = real_position(line_end_col(virtual_text), "end")
  if opening_delimiter_is_unmatched(buffer, opener_real_line, opener_real_col, opener, closer, line1, col1, line2, col2) then
    local insert_text = "\n" .. inner_indent .. "\n" .. base_indent .. closer
    return {
      line1 = edit_start_line,
      col1 = edit_start_col,
      line2 = edit_end_line,
      col2 = edit_end_col,
      text = insert_text,
      caret_offset = #("\n" .. inner_indent),
      reason = "after-unmatched-delimiter",
    }
  end

  local insert_text = "\n" .. inner_indent
  return {
    line1 = edit_start_line,
    col1 = edit_start_col,
    line2 = edit_end_line,
    col2 = edit_end_col,
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

local function smart_paste_text(buffer, line, col, text)
  text = tostring(text or "")
  if not text:find("\n", 1, true) then return text end
  local line_text = buffer.lines[line] or ""
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

local function paste_all_normal_clipboards(buffer)
  local payloads = {}
  for cb_idx in ipairs(core.cursor_clipboard_whole_line) do
    payloads[#payloads + 1] = tostring(core.cursor_clipboard[cb_idx] or ""):gsub("\r", "")
  end
  if #payloads == 0 then return end

  local edits, final_by_idx = {}, {}
  for idx, line1, col1, line2, col2 in buffer:get_selections(true) do
    local text, final_offsets = "", {}
    for _, payload in ipairs(payloads) do
      text = text .. payload
      final_offsets[#final_offsets + 1] = #text
    end
    edits[#edits + 1] = { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = text, idx = idx }
    final_by_idx[idx] = final_offsets
  end
  if #edits == 0 then return end
  return buffer:apply_edits(edits, {
    type = "insert",
    selections = buffer:selections_after_edits(edits, final_by_idx),
    last_selection = buffer.last_selection,
    merge_cursors = false,
  })
end

local function paste_whole_lines_by_selection(buffer, text_for_idx)
  local starts, offset = {}, 0
  for line, line_text in ipairs(buffer.lines) do
    starts[line] = offset
    offset = offset + #line_text
  end

  local actions = {}
  for idx, line1, col1, line2, col2 in buffer:get_selections(true) do
    local text = tostring(text_for_idx(idx) or ""):gsub("\r", "") .. "\n"
    actions[#actions + 1] = {
      idx = idx,
      line1 = line1,
      col1 = col1,
      line2 = line2,
      col2 = col2,
      text = text,
      line_start_offset = starts[line1],
      selection_start_offset = starts[line1] + col1 - 1,
      selection_end_offset = starts[line2] + col2 - 1,
    }
  end
  if #actions == 0 then return end
  table.sort(actions, function(a, b)
    if a.line_start_offset ~= b.line_start_offset then
      return a.line_start_offset < b.line_start_offset
    end
    if a.selection_start_offset ~= b.selection_start_offset then
      return a.selection_start_offset < b.selection_start_offset
    end
    if a.selection_end_offset ~= b.selection_end_offset then
      return a.selection_end_offset < b.selection_end_offset
    end
    return a.idx < b.idx
  end)

  -- Whole-line paste inserts at the start of each caret line, so otherwise
  -- disjoint selections on the same line have intersecting edit ranges. Build
  -- one exact replacement for each intersecting cluster instead of replaying
  -- mutations against a temporary Buffer.
  local clusters = {}
  for _, action in ipairs(actions) do
    local cluster = clusters[#clusters]
    local touches_nonempty_cluster = cluster
      and action.line_start_offset == cluster.end_offset
      and cluster.start_offset < cluster.end_offset
    if not cluster or action.line_start_offset > cluster.end_offset or touches_nonempty_cluster then
      cluster = {
        line1 = action.line1,
        start_offset = action.line_start_offset,
        end_offset = action.selection_end_offset,
        line2 = action.line2,
        col2 = action.col2,
        actions = {},
      }
      clusters[#clusters + 1] = cluster
    elseif action.selection_end_offset > cluster.end_offset then
      cluster.end_offset = action.selection_end_offset
      cluster.line2 = action.line2
      cluster.col2 = action.col2
    end
    cluster.actions[#cluster.actions + 1] = action
  end

  local edits = {}
  for _, cluster in ipairs(clusters) do
    local source = buffer:get_text(cluster.line1, 1, cluster.line2, cluster.col2)
    local buffer = source
    for _, action in ipairs(cluster.actions) do
      action.current_line_start = action.line_start_offset - cluster.start_offset
      action.current_start = action.selection_start_offset - cluster.start_offset
      action.current_end = action.selection_end_offset - cluster.start_offset
      action.marker = action.current_start
    end

    local function map_remove(value, start_offset, end_offset)
      if value < start_offset then return value end
      if value <= end_offset then return start_offset end
      return value - (end_offset - start_offset)
    end

    -- Positions are updated after every operation, so actions can be replayed
    -- in stable spatial/index order. This keeps distinct payloads targeting the
    -- same line in clipboard-selection order instead of reversing them.
    for i = 1, #cluster.actions do
      local action = cluster.actions[i]
      local start_offset, end_offset = action.current_start, action.current_end
      if end_offset > start_offset then
        buffer = buffer:sub(1, start_offset) .. buffer:sub(end_offset + 1)
        for _, tracked in ipairs(cluster.actions) do
          tracked.current_line_start = map_remove(tracked.current_line_start, start_offset, end_offset)
          tracked.current_start = map_remove(tracked.current_start, start_offset, end_offset)
          tracked.current_end = map_remove(tracked.current_end, start_offset, end_offset)
          tracked.marker = map_remove(tracked.marker, start_offset, end_offset)
        end
      end

      local insert_offset = action.current_line_start
      buffer = buffer:sub(1, insert_offset) .. action.text .. buffer:sub(insert_offset + 1)
      local inserted = #action.text
      for _, tracked in ipairs(cluster.actions) do
        if tracked.current_line_start >= insert_offset then tracked.current_line_start = tracked.current_line_start + inserted end
        if tracked.current_start >= insert_offset then tracked.current_start = tracked.current_start + inserted end
        if tracked.current_end >= insert_offset then tracked.current_end = tracked.current_end + inserted end
        if tracked.marker >= insert_offset then tracked.marker = tracked.marker + inserted end
      end
    end

    cluster.source = source
    cluster.text = buffer
    edits[#edits + 1] = {
      line1 = cluster.line1,
      col1 = 1,
      line2 = cluster.line2,
      col2 = cluster.col2,
      text = buffer,
    }
  end

  local selections = { table.unpack(buffer.selections) }
  local line_delta = 0
  for _, cluster in ipairs(clusters) do
    local new_start_line = cluster.line1 + line_delta
    for _, action in ipairs(cluster.actions) do
      local prefix = cluster.text:sub(1, action.marker)
      local newlines = newline_count(prefix)
      local last_newline = prefix:match(".*()\n")
      local line = new_start_line + newlines
      local col = last_newline and (#prefix - last_newline + 1) or (#prefix + 1)
      local selection_offset = (action.idx - 1) * 4
      selections[selection_offset + 1] = line
      selections[selection_offset + 2] = col
      selections[selection_offset + 3] = line
      selections[selection_offset + 4] = col
    end
    line_delta = line_delta + newline_count(cluster.text) - newline_count(cluster.source)
  end

  return buffer:apply_edits(edits, {
    type = "insert",
    selections = selections,
    last_selection = buffer.last_selection,
    merge_cursors = false,
  })
end

local function paste_all_whole_line_clipboards(buffer)
  local payloads = {}
  for cb_idx in ipairs(core.cursor_clipboard_whole_line) do
    payloads[#payloads + 1] = tostring(core.cursor_clipboard[cb_idx] or "")
  end
  if #payloads == 0 then return end
  local text = table.concat(payloads, "\n")
  return paste_whole_lines_by_selection(buffer, function() return text end)
end

local function paste_matching_whole_lines(buffer, text_by_idx)
  return paste_whole_lines_by_selection(buffer, function(idx) return text_by_idx[idx] end)
end

local function previous_indent_stop_start_col(buffer, line, col, indent_size)
  if col <= 1 then return nil end
  indent_size = math.max(1, tonumber(indent_size) or 1)
  local text = buffer.lines[line] or ""
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
  ["text:select-none"] = function(dv)
    local l1, c1 = dv.buffer:get_selection_idx(dv.buffer.last_selection)
    if not l1 then
      l1, c1 = dv.buffer:get_selection_idx(1)
    end
    dv.buffer:set_selection(l1, c1)
    dv.buffer:clear_search_selections()
  end,

  ["text:cut"] = function(dv)
    cut_or_copy(dv, true)
  end,

  ["text:copy"] = function(dv)
    cut_or_copy(dv, false)
  end,

  ["text:undo"] = function(dv)
    if not can_edit(dv, "undo") then return end
    dv.buffer:undo()
  end,

  ["text:redo"] = function(dv)
    if not can_edit(dv, "redo") then return end
    dv.buffer:redo()
  end,

  ["text:paste"] = function(dv)
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
      dv.buffer:text_input_by_selection(function(_, line1, col1)
        return smart_paste_text(dv.buffer, line1, col1, text)
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
    if #core.cursor_clipboard_whole_line == (#dv.buffer.selections/4) then
    -- If we have the same number of clipboards and selections,
    -- paste each clipboard into its corresponding selection
      if only_whole_lines then
        paste_matching_whole_lines(dv.buffer, core.cursor_clipboard)
      else
        dv.buffer:text_input_by_selection(function(idx, line1, col1)
          return smart_paste_text(dv.buffer, line1, col1, tostring(core.cursor_clipboard[idx] or ""):gsub("\r", ""))
        end, nil, { type = "insert" })
      end
    else
      -- Paste every clipboard and add a selection at the end of each one
      if not only_whole_lines then
        paste_all_normal_clipboards(dv.buffer)
        return
      end
      paste_all_whole_line_clipboards(dv.buffer)
    end
  end,

  ["text:paste-primary-selection"] = function(dv, x, y)
    if not can_edit(dv, "paste") then return end
    if type(x) == "number" and type(y) == "number" then
      set_cursor(dv, x, y, "set")
      -- Workaround to avoid that a middle mouse drag starts selecting
      dv.mouse_selecting = nil
    end
    local text = tostring(system.get_primary_selection() or ""):gsub("\r", "")
    dv.buffer:text_input_by_selection(function(_, line1, col1)
      return smart_paste_text(dv.buffer, line1, col1, text)
    end, nil, { type = "insert" })
  end,

  ["text:newline"] = function(dv)
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
    local has_empty_list_item = false

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
      local last = dv.buffer.last_selection or 1
      return original_to_projected[last] or 1
    end

    local function projected_selections_after(normalized, finals)
      local projection = {
        lines = dv.buffer.lines,
        selections = projected_selections,
        last_selection = projected_last_selection(),
      }
      return Buffer.selections_after_edits(projection, normalized, finals, projection.last_selection, { normalized = true })
    end

    local selection_items = {}
    for idx, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
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
      local line_text = dv.buffer.lines[line] or ""
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
        core.log_quiet("Newline coalesced duplicate whitespace-only caret in %s at line %d", dv.buffer:get_name(), line)
      else
        local projected_idx = project_selection(idx, line1, col1, line2, col2)
        local insert_indent = indent
        if not whitespace_only_line then
          insert_indent = syntax_newline_continuation(dv.buffer, line, col, line_text)
            or syntax_newline_indent(dv.buffer, line, col, indent, full_indent, line_text)
        end
        local text = "\n" .. insert_indent
        text_by_idx[projected_idx] = text
        normal_final_by_idx[projected_idx] = "end"

        local content_start = not whitespace_only_line
          and line1 == line2 and col1 == col2
          and markdown_list_content_start(dv.buffer, line, line_text)
        local previous_line = line > 1 and (dv.buffer.lines[line - 1] or "") or nil
        local exits_split_list_boundary = content_start == col1
          and previous_line ~= nil
          and markdown_empty_list_item(
            dv.buffer, line - 1, line_end_col(previous_line), previous_line
          )

        if exits_split_list_boundary then
          has_empty_list_item = true
          final_by_idx[projected_idx] = "start"
          core.log_quiet(
            "Markdown newline exited split list boundary in %s at %d:%d",
            dv.buffer:get_name(), line1, col1
          )
          edits[#edits + 1] = {
            line1 = line,
            col1 = 1,
            line2 = line,
            col2 = col,
            text = "",
            idx = projected_idx,
          }
          normal_edits[#normal_edits + 1] = {
            line1 = line1,
            col1 = col1,
            line2 = line2,
            col2 = col2,
            text = text,
            idx = projected_idx,
          }
        elseif not whitespace_only_line
        and line1 == line2 and col1 == col2
        and markdown_empty_list_item(dv.buffer, line, col, line_text)
        then
          has_empty_list_item = true
          final_by_idx[projected_idx] = "start"
          core.log_quiet("Markdown newline exited empty list item in %s at %d:%d", dv.buffer:get_name(), line1, col1)
          edits[#edits + 1] = {
            line1 = line,
            col1 = 1,
            line2 = line,
            col2 = col,
            text = "",
            idx = projected_idx,
          }
          normal_edits[#normal_edits + 1] = {
            line1 = line1,
            col1 = col1,
            line2 = line2,
            col2 = col2,
            text = text,
            idx = projected_idx,
          }
        elseif whitespace_only_line then
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
          local smart_edit = smart_newline_edit(dv.buffer, line1, col1, line2, col2)
          if smart_edit then
            has_smart_newline = true
            final_by_idx[projected_idx] = smart_edit.caret_offset
            core.log_quiet("Smart newline %s in %s at %d:%d", smart_edit.reason, dv.buffer:get_name(), line1, col1)
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

    if has_whitespace_cleanup or has_smart_newline or has_empty_list_item then
      local non_overlapping, normalized = edits_are_non_overlapping(dv.buffer, edits)
      if not non_overlapping then
        if has_smart_newline then
          core.log_quiet("Smart newline skipped for %s because selections overlap", dv.buffer:get_name())
        end
        edits = normal_edits
        final_by_idx = normal_final_by_idx
        non_overlapping, normalized = edits_are_non_overlapping(dv.buffer, edits)
        if not non_overlapping then
          dv.buffer:text_input_by_selection(original_normal_text_by_idx, nil, { type = "insert" })
          return
        end
      end
      local selections, last_selection = projected_selections_after(normalized, final_by_idx)
      dv.buffer:apply_edits(edits, {
        type = "insert",
        selections = selections,
        last_selection = last_selection,
        merge_cursors = false,
      })
    else
      dv.buffer:text_input_by_selection(text_by_idx, nil, { type = "insert" })
    end
  end,

  ["text:newline-below"] = function(dv)
    if not can_edit(dv, "newline") then return end
    local edits = {}
    local entries = {}
    for idx, line in dv.buffer:get_selections(false) do
      local indent = dv.buffer.lines[line]:match("^[\t ]*")
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
    dv.buffer:apply_edits(edits, {
      type = "insert",
      selections = selections,
      last_selection = dv.buffer.last_selection,
      merge_cursors = false,
    })
  end,

  ["text:newline-above"] = function(dv)
    if not can_edit(dv, "newline") then return end
    local edits = {}
    local entries = {}
    for idx, line in dv.buffer:get_selections(false) do
      local indent = dv.buffer.lines[line]:match("^[\t ]*")
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
    dv.buffer:apply_edits(edits, {
      type = "insert",
      selections = selections,
      last_selection = dv.buffer.last_selection,
      merge_cursors = false,
    })
  end,

  ["text:delete"] = function(dv)
    if not can_edit(dv, "delete") then return end
    local selections = {}
    for idx, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
      selections[#selections + 1] = {
        idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2,
      }
    end
    local list_join_edits, list_join_finals = {}, {}
    for _, selection in ipairs(selections) do
      if selection.line1 == selection.line2 and selection.col1 == selection.col2
        and selection.line1 < #dv.buffer.lines
      then
        local line_text = dv.buffer.lines[selection.line1] or ""
        local end_col = line_end_col(line_text)
        if selection.col1 == end_col then
          local next_line_text = dv.buffer.lines[selection.line1 + 1] or ""
          local next_content_col = markdown_list_join_content_col(
            dv.buffer, selection.line1, line_text, next_line_text
          )
          if next_content_col then
            local before = line_text:sub(1, end_col - 1)
            local join_text = before:sub(-1):match("[ \t]") and "" or " "
            list_join_edits[#list_join_edits + 1] = {
              line1 = selection.line1,
              col1 = end_col,
              line2 = selection.line1 + 1,
              col2 = next_content_col,
              text = join_text,
              idx = selection.idx,
            }
            list_join_finals[selection.idx] = "end"
          end
        end
      end
    end
    if #list_join_edits == #selections and #list_join_edits > 0 then
      local after, last_selection = dv.buffer:selections_after_edits(
        list_join_edits, list_join_finals, dv.buffer.last_selection
      )
      dv.buffer:apply_edits(list_join_edits, {
        type = "remove",
        selections = after,
        last_selection = last_selection,
        merge_cursors = true,
      })
      core.log_quiet("Markdown delete joined adjacent list items in %s", dv.buffer:get_name())
      return
    end
    local list_marker_edits, list_marker_finals = {}, {}
    for _, selection in ipairs(selections) do
      if selection.line1 == selection.line2 and selection.col1 == selection.col2 then
        local line_text = dv.buffer.lines[selection.line1] or ""
        local delete_end = markdown_list_marker_delete_end(
          dv.buffer, selection.line1, line_text, selection.col1
        )
        if delete_end then
          list_marker_edits[#list_marker_edits + 1] = {
            line1 = selection.line1,
            col1 = selection.col1,
            line2 = selection.line1,
            col2 = delete_end,
            text = "",
            idx = selection.idx,
          }
          list_marker_finals[selection.idx] = "start"
        end
      end
    end
    if #list_marker_edits == #selections and #list_marker_edits > 0 then
      local after, last_selection = dv.buffer:selections_after_edits(
        list_marker_edits, list_marker_finals, dv.buffer.last_selection
      )
      dv.buffer:apply_edits(list_marker_edits, {
        type = "remove",
        selections = after,
        last_selection = last_selection,
        merge_cursors = true,
      })
      core.log_quiet("Markdown delete removed list markers in %s", dv.buffer:get_name())
      return
    end
    local fallback = false
    for _, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
      if line1 == line2 and col1 == col2 and dv.buffer.lines[line1]:find("^%s*$", col1) then
        fallback = true
        break
      end
    end
    if fallback then
      local edits, final_by_idx = {}, {}
      for idx, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
        local start_line, start_col, end_line, end_col = line1, col1, line2, col2
        if line1 == line2 and col1 == col2 then
          if dv.buffer.lines[line1]:find("^%s*$", col1) and line1 < #dv.buffer.lines then
            end_line, end_col = line1 + 1, 1
          else
            local l2, c2 = dv.buffer:position_offset(line1, col1, translate.next_char)
            start_line, start_col, end_line, end_col = sort_positions(line1, col1, l2, c2)
          end
        end
        edits[#edits + 1] = { line1 = start_line, col1 = start_col, line2 = end_line, col2 = end_col, text = "", idx = idx }
        final_by_idx[idx] = "start"
      end
      dv.buffer:apply_edits(edits, {
        type = "remove",
        selections = dv.buffer:selections_after_edits(edits, final_by_idx),
        last_selection = dv.buffer.last_selection,
        merge_cursors = true,
      })
    else
      dv.buffer:delete_to(translate.next_char)
    end
  end,

  ["text:backspace"] = function(dv)
    if not can_edit(dv, "backspace") then return end
    local list_actions = {}
    local selection_count, list_action_count = 0, 0
    for idx, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
      selection_count = selection_count + 1
      if line1 == line2 and col1 == col2 then
        local line_text = dv.buffer.lines[line1] or ""
        local content_start, indent_length, task_start = markdown_list_content_start(
          dv.buffer, line1, line_text
        )
        indent_length = indent_length or #(line_text:match("^[\t ]*") or "")
        local empty_list_item = markdown_empty_list_item(
          dv.buffer, line1, col1, line_text
        )
        local action
        if empty_list_item then
          action = indent_length > 0 and "outdent" or "clear"
        elseif content_start and col1 == content_start then
          action = task_start and "remove_task" or "remove_marker"
        end
        if action then
          list_action_count = list_action_count + 1
          list_actions[#list_actions + 1] = {
            idx = idx,
            line1 = line1,
            col1 = col1,
            line2 = line2,
            col2 = col2,
            indent_length = indent_length,
            prefix_start = task_start or (indent_length + 1),
            action = action,
          }
        end
      end
    end
    if selection_count > 0 and list_action_count == selection_count then
      for _, item in ipairs(list_actions) do
        if item.action == "clear" then
          local edit = {
            line1 = item.line1,
            col1 = 1,
            line2 = item.line1,
            col2 = item.col1,
            text = "",
            idx = item.idx,
          }
          local selections, last_selection = dv.buffer:selections_after_edits(
            { edit }, { [item.idx] = "start" }, dv.buffer.last_selection
          )
          dv.buffer:apply_edits({ edit }, {
            type = "remove",
            selections = selections,
            last_selection = last_selection,
            merge_cursors = false,
          })
          core.log_quiet("Markdown backspace removed empty list marker in %s at %d:%d", dv.buffer:get_name(), item.line1, item.col1)
        elseif item.action == "remove_task" or item.action == "remove_marker" then
          local edit = {
            line1 = item.line1,
            col1 = item.prefix_start,
            line2 = item.line1,
            col2 = item.col1,
            text = "",
            idx = item.idx,
          }
          local selections, last_selection = dv.buffer:selections_after_edits(
            { edit }, { [item.idx] = "start" }, dv.buffer.last_selection
          )
          dv.buffer:apply_edits({ edit }, {
            type = "remove",
            selections = selections,
            last_selection = last_selection,
            merge_cursors = false,
          })
          core.log_quiet(
            "Markdown backspace removed %s in %s at %d:%d",
            item.action == "remove_task" and "task marker" or "list marker",
            dv.buffer:get_name(), item.line1, item.col1
          )
        else
          local line1, col1, line2, col2 = dv.buffer:indent_text(
            true, item.line1, item.col1, item.line2, item.col2
          )
          local content_col = math.max(1, item.col1 - item.indent_length)
          dv.buffer:set_selections(item.idx, line1, content_col, line2, content_col)
          core.log_quiet("Markdown backspace outdented list item in %s at %d:%d", dv.buffer:get_name(), item.line1, item.col1)
        end
      end
      return
    end
    local _, indent_size = dv.buffer:get_indent_info()
    local fallback = false
    for _, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
      if line1 == line2 and col1 == col2
      and previous_indent_stop_start_col(dv.buffer, line1, col1, indent_size) then
        fallback = true
        break
      end
    end
    if fallback then
      local edits, final_by_idx = {}, {}
      for idx, line1, col1, line2, col2 in dv.buffer:get_selections(true, true) do
        local start_line, start_col, end_line, end_col = line1, col1, line2, col2
        if line1 == line2 and col1 == col2 then
          local stop_col = previous_indent_stop_start_col(dv.buffer, line1, col1, indent_size)
          if stop_col then
            start_line, start_col, end_line, end_col = line1, stop_col, line1, col1
          else
            local l2, c2 = dv.buffer:position_offset(line1, col1, translate.previous_char)
            start_line, start_col, end_line, end_col = sort_positions(line1, col1, l2, c2)
          end
        end
        edits[#edits + 1] = { line1 = start_line, col1 = start_col, line2 = end_line, col2 = end_col, text = "", idx = idx }
        final_by_idx[idx] = "start"
      end
      local non_overlapping, normalized = edits_are_non_overlapping(dv.buffer, edits)
      if not non_overlapping then
        edits = coalesce_overlapping_same_line_removes(edits)
        final_by_idx = {}
        for _, edit in ipairs(edits) do final_by_idx[edit.idx] = "start" end
        non_overlapping, normalized = edits_are_non_overlapping(dv.buffer, edits)
        if not non_overlapping then
          dv.buffer:delete_to(translate.previous_char)
          return
        end
      end
      dv.buffer:apply_edits(edits, {
        type = "remove",
        selections = dv.buffer:selections_after_edits(normalized, final_by_idx, dv.buffer.last_selection, { normalized = true }),
        last_selection = dv.buffer.last_selection,
        merge_cursors = true,
      })
    else
      dv.buffer:delete_to(translate.previous_char)
    end
  end,

  ["text:select-all"] = function(dv)
    dv.buffer:set_selection(1, 1, math.huge, math.huge)
    set_primary_selection(dv.buffer)
    -- avoid triggering TextView:scroll_to_make_visible
    dv.last_line1 = 1
    dv.last_col1 = 1
    dv.last_line2 = #dv.buffer.lines
    dv.last_col2 = #dv.buffer.lines[#dv.buffer.lines]
  end,

  ["text:select-lines"] = function(dv)
    for idx, line1, _, line2 in dv.buffer:get_selections(true) do
      if not append_line_if_last_line(line2) then return end
      dv.buffer:set_selections(idx, line2 + 1, 1, line1, 1)
    end
    set_primary_selection(dv.buffer)
  end,

  ["text:select-word"] = function(dv)
    for idx, line1, col1 in dv.buffer:get_selections(true) do
      local line1, col1 = translate.start_of_word(dv.buffer, line1, col1)
      local line2, col2 = translate.end_of_word(dv.buffer, line1, col1)
      dv.buffer:set_selections(idx, line2, col2, line1, col1)
    end
    set_primary_selection(dv.buffer)
  end,

  ["text:join-lines"] = function(dv)
    if not can_edit(dv, "join lines") then return end
    local actions = {}
    for idx, line1, col1, line2, col2 in dv.buffer:get_selections(true) do
      if line1 == line2 then line2 = line2 + 1 end
      if line2 <= #dv.buffer.lines then
        actions[#actions + 1] = { line1 = line1, line2 = line2, indices = { idx } }
      end
    end
    table.sort(actions, function(a, b) return a.line1 < b.line1 end)
    local merged = {}
    for _, action in ipairs(actions) do
      local previous = merged[#merged]
      if previous and action.line1 <= previous.line2 then
        previous.line2 = math.max(previous.line2, action.line2)
        for _, idx in ipairs(action.indices) do previous.indices[#previous.indices + 1] = idx end
      else
        merged[#merged + 1] = action
      end
    end

    local edits = {}
    for _, action in ipairs(merged) do
      action.text = markdown_join_lines_text(dv.buffer, action.line1, action.line2)
      edits[#edits + 1] = {
        line1 = action.line1,
        col1 = 1,
        line2 = action.line2,
        col2 = #dv.buffer.lines[action.line2],
        text = action.text,
        idx = 0,
      }
    end
    if #edits == 0 then return end

    local selections = dv.buffer:selections_after_edits(edits)
    local removed_before = 0
    for _, action in ipairs(merged) do
      local line = action.line1 - removed_before
      for _, idx in ipairs(action.indices) do
        local offset = (idx - 1) * 4
        selections[offset + 1] = line
        selections[offset + 2] = #action.text + 1
        selections[offset + 3] = line
        selections[offset + 4] = #action.text + 1
      end
      removed_before = removed_before + action.line2 - action.line1
    end
    dv.buffer:apply_edits(edits, { type = "replace", selections = selections, last_selection = dv.buffer.last_selection, merge_cursors = false })
  end,

  ["text:indent"] = function(dv)
    if not can_edit(dv, "indent") then return end
    local list_indent_edits, list_indent_lines = {}, {}
    local selection_count, list_indent_count = 0, 0
    for _, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      selection_count = selection_count + 1
      if line1 == line2 and col1 == col2 then
        local line_text = dv.buffer.lines[line1] or ""
        local content_start, indent_length = markdown_list_content_start(
          dv.buffer, line1, line_text, true
        )
        local prefix_start = (indent_length or 0) + 1
        if content_start and col1 >= prefix_start and col1 <= content_start then
          list_indent_count = list_indent_count + 1
          if markdown_list_can_indent(dv.buffer, line1, line_text)
            and not list_indent_lines[line1]
          then
            local indent_end = line_text:find("[^\t ]")
            indent_end = indent_end and indent_end - 1 or 0
            -- A literal tab before a Markdown marker is parsed as indented
            -- code by the semantic grammar. Use the interoperable four-space
            -- nesting step and expand the existing prefix to spaces even when
            -- the Buffer otherwise prefers tabs.
            local indent = markdown_space_indent(line_text, indent_end) .. "    "
            list_indent_lines[line1] = true
            list_indent_edits[#list_indent_edits + 1] = {
              line1 = line1,
              col1 = 1,
              line2 = line1,
              col2 = (indent_end or 0) + 1,
              text = indent,
              idx = 0,
            }
          end
        end
      end
    end
    if selection_count > 0 and list_indent_count == selection_count then
      if #list_indent_edits > 0 then
        local selections, last_selection = dv.buffer:selections_after_edits(
          list_indent_edits, nil, dv.buffer.last_selection
        )
        dv.buffer:apply_edits(list_indent_edits, {
          type = "insert",
          selections = selections,
          last_selection = last_selection,
          merge_cursors = false,
        })
      end
      core.log_quiet(
        "Markdown indent moved %d eligible list item(s) at their content start in %s",
        #list_indent_edits, dv.buffer:get_name()
      )
      return
    end
    local repair_edits, final_by_idx = {}, {}
    local selection_count, repairable_count = 0, 0
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      selection_count = selection_count + 1
      local line_text = dv.buffer.lines[line1] or ""
      local leading = line_text:match("^[\t ]*") or ""
      local collapsed = line1 == line2 and col1 == col2
      local in_leading = collapsed and col1 <= #leading + 1
      local expected = in_leading and syntax_line_indent(dv.buffer, line1, col1, line_text) or nil
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
      local non_overlapping = edits_are_non_overlapping(dv.buffer, repair_edits)
      if non_overlapping then
        local selections = {}
        for _, edit in ipairs(repair_edits) do
          selections[#selections + 1] = edit.line1
          selections[#selections + 1] = #edit.text + 1
          selections[#selections + 1] = edit.line1
          selections[#selections + 1] = #edit.text + 1
        end
        dv.buffer:apply_edits(repair_edits, {
          type = "replace",
          selections = selections,
          last_selection = original_to_coalesced[dv.buffer.last_selection or 1] or math.min(dv.buffer.last_selection or 1, math.max(1, #selections / 4)),
          merge_cursors = false,
        })
        return
      end
    end

    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      local l1, c1, l2, c2 = dv.buffer:indent_text(false, line1, col1, line2, col2)
      if l1 then
        dv.buffer:set_selections(idx, l1, c1, l2, c2)
      end
    end
  end,

  ["text:unindent"] = function(dv)
    if not can_edit(dv, "unindent") then return end
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      local l1, c1, l2, c2 = dv.buffer:indent_text(true, line1, col1, line2, col2)
      if l1 then
        dv.buffer:set_selections(idx, l1, c1, l2, c2)
      end
    end
  end,

  ["text:duplicate-lines"] = function(dv)
    if not can_edit(dv, "duplicate lines") then return end
    local actions = {}
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      actions[#actions + 1] = { idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2 }
    end
    sort_line_actions(actions)

    local blocks = {}
    for _, action in ipairs(actions) do
      local block = blocks[#blocks]
      if block and action.line1 <= block.line2 then
        block.line2 = math.max(block.line2, action.line2)
        block.members[#block.members + 1] = action
      else
        blocks[#blocks + 1] = { line1 = action.line1, line2 = action.line2, members = { action } }
      end
    end

    local edits = {}
    for _, block in ipairs(blocks) do
      block.n = block.line2 - block.line1 + 1
      if block.line2 < #dv.buffer.lines then
        block.text = buffer():get_text(block.line1, 1, block.line2 + 1, 1)
        edits[#edits + 1] = { line1 = block.line2 + 1, col1 = 1, line2 = block.line2 + 1, col2 = 1, text = block.text }
      else
        block.text = buffer():get_text(block.line1, 1, block.line2, #dv.buffer.lines[block.line2])
        edits[#edits + 1] = {
          line1 = block.line2, col1 = #dv.buffer.lines[block.line2],
          line2 = block.line2, col2 = #dv.buffer.lines[block.line2],
          text = "\n" .. block.text,
        }
      end
    end

    local selections = { table.unpack(dv.buffer.selections) }
    for _, block in ipairs(blocks) do
      local inserted_before = 0
      for _, other in ipairs(blocks) do
        if other.line2 < block.line1 then inserted_before = inserted_before + other.n end
      end
      for _, member in ipairs(block.members) do
        local offset = (member.idx - 1) * 4
        selections[offset + 1] = member.line1 + block.n + inserted_before
        selections[offset + 2] = member.col1
        selections[offset + 3] = member.line2 + block.n + inserted_before
        selections[offset + 4] = member.col2
      end
    end
    if #edits > 0 then
      dv.buffer:apply_edits(edits, { type = "insert", selections = selections, last_selection = dv.buffer.last_selection, merge_cursors = false })
    end
  end,

  ["text:delete-lines"] = function(dv)
    if not can_edit(dv, "delete lines") then return end
    local actions = {}
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      actions[#actions + 1] = { idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2 }
    end
    sort_line_actions(actions)

    local blocks = {}
    for _, action in ipairs(actions) do
      local block = blocks[#blocks]
      if block and action.line1 <= block.line2 + 1 then
        block.line2 = math.max(block.line2, action.line2)
        block.members[#block.members + 1] = action
      else
        blocks[#blocks + 1] = {
          line1 = action.line1,
          line2 = action.line2,
          members = { action },
        }
      end
    end

    local edits = {}
    for _, block in ipairs(blocks) do
      if block.line2 < #dv.buffer.lines then
        edits[#edits + 1] = { line1 = block.line1, col1 = 1, line2 = block.line2 + 1, col2 = 1, text = "", idx = 0 }
      elseif block.line1 > 1 then
        edits[#edits + 1] = {
          line1 = block.line1 - 1, col1 = #dv.buffer.lines[block.line1 - 1],
          line2 = block.line2, col2 = #dv.buffer.lines[block.line2], text = "", idx = 0,
        }
      else
        edits[#edits + 1] = {
          line1 = 1, col1 = 1,
          line2 = block.line2, col2 = #dv.buffer.lines[block.line2], text = "", idx = 0,
        }
      end
    end
    if #edits == 0 then return end

    local selections = dv.buffer:selections_after_edits(edits)
    local removed_before = 0
    for _, block in ipairs(blocks) do
      local target_line = block.line2 < #dv.buffer.lines
        and block.line1 - removed_before
        or math.max(1, block.line1 - removed_before - 1)
      for _, member in ipairs(block.members) do
        local offset = (member.idx - 1) * 4
        selections[offset + 1] = target_line
        selections[offset + 2] = member.col1
        selections[offset + 3] = target_line
        selections[offset + 4] = member.col1
      end
      removed_before = removed_before + block.line2 - block.line1 + 1
    end
    dv.buffer:apply_edits(edits, { type = "remove", selections = selections, last_selection = dv.buffer.last_selection, merge_cursors = true })
  end,

  ["text:move-lines-up"] = function(dv)
    if not can_edit(dv, "move lines") then return end
    local actions = {}
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      actions[#actions + 1] = {
        idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2,
      }
    end
    sort_line_actions(actions)
    local blocks = {}
    for _, action in ipairs(actions) do
      local block = blocks[#blocks]
      if block and action.line1 <= block.line2 + 1 then
        block.line2 = math.max(block.line2, action.line2)
        block.members[#block.members + 1] = action
      else
        blocks[#blocks + 1] = { line1 = action.line1, line2 = action.line2, members = { action } }
      end
    end

    local edits = {}
    local selections = { table.unpack(dv.buffer.selections) }
    for _, block in ipairs(blocks) do
      local delta = block.line1 > 1 and -1 or 0
      if delta ~= 0 then
        local parts = {}
        for line = block.line1, block.line2 do parts[#parts + 1] = dv.buffer.lines[line] end
        local replacement = table.concat(parts) .. dv.buffer.lines[block.line1 - 1]
        if block.line2 < #dv.buffer.lines then
          edits[#edits + 1] = {
            line1 = block.line1 - 1, col1 = 1, line2 = block.line2 + 1, col2 = 1,
            text = replacement,
          }
        else
          edits[#edits + 1] = {
            line1 = block.line1 - 1, col1 = 1,
            line2 = block.line2, col2 = #dv.buffer.lines[block.line2],
            text = replacement:gsub("\n$", ""),
          }
        end
      end
      for _, member in ipairs(block.members) do
        local offset = (member.idx - 1) * 4
        selections[offset + 1] = member.line1 + delta
        selections[offset + 2] = member.col1
        selections[offset + 3] = member.line2 + delta
        selections[offset + 4] = member.col2
      end
    end
    if #edits > 0 then
      dv.buffer:apply_edits(edits, { type = "batch", selections = selections, last_selection = dv.buffer.last_selection, merge_cursors = false })
    else
      dv.buffer:set_selection_list(selections, dv.buffer.last_selection)
    end
  end,

  ["text:move-lines-down"] = function(dv)
    if not can_edit(dv, "move lines") then return end
    local actions = {}
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      actions[#actions + 1] = {
        idx = idx, line1 = line1, col1 = col1, line2 = line2, col2 = col2,
      }
    end
    sort_line_actions(actions)
    local blocks = {}
    for _, action in ipairs(actions) do
      local block = blocks[#blocks]
      if block and action.line1 <= block.line2 + 1 then
        block.line2 = math.max(block.line2, action.line2)
        block.members[#block.members + 1] = action
      else
        blocks[#blocks + 1] = { line1 = action.line1, line2 = action.line2, members = { action } }
      end
    end

    local edits = {}
    local selections = { table.unpack(dv.buffer.selections) }
    for _, block in ipairs(blocks) do
      local delta = block.line2 < #dv.buffer.lines and 1 or 0
      if delta ~= 0 then
        local parts = {}
        for line = block.line1, block.line2 do parts[#parts + 1] = dv.buffer.lines[line] end
        local replacement = dv.buffer.lines[block.line2 + 1] .. table.concat(parts)
        if block.line2 + 1 < #dv.buffer.lines then
          edits[#edits + 1] = {
            line1 = block.line1, col1 = 1, line2 = block.line2 + 2, col2 = 1,
            text = replacement,
          }
        else
          edits[#edits + 1] = {
            line1 = block.line1, col1 = 1,
            line2 = block.line2 + 1, col2 = #dv.buffer.lines[block.line2 + 1],
            text = replacement:gsub("\n$", ""),
          }
        end
      end
      for _, member in ipairs(block.members) do
        local offset = (member.idx - 1) * 4
        selections[offset + 1] = member.line1 + delta
        selections[offset + 2] = member.col1
        selections[offset + 3] = member.line2 + delta
        selections[offset + 4] = member.col2
      end
    end
    if #edits > 0 then
      dv.buffer:apply_edits(edits, { type = "batch", selections = selections, last_selection = dv.buffer.last_selection, merge_cursors = false })
    else
      dv.buffer:set_selection_list(selections, dv.buffer.last_selection)
    end
  end,

  ["text:toggle-block-comments"] = function(dv)
    if not can_edit(dv, "toggle comments") then return end
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      local current_syntax = dv.buffer.syntax
      if line1 > 1 then
        -- Use the previous line state, as it will be the state
        -- of the beginning of the current line
        local state = dv.buffer.highlighter:get_line(line1 - 1).state
        if state then
          local syntaxes = tokenizer.extract_subsyntaxes(dv.buffer.syntax, state)
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
        if dv.buffer.syntax.comment then
          command.perform "text:toggle-line-comments"
        end
        return
      end
      -- if nothing is selected, toggle the whole line
      if line1 == line2 and col1 == col2 then
        col1 = 1
        col2 = #dv.buffer.lines[line2]
      end
      dv.buffer:set_selections(idx, block_comment(comment, line1, col1, line2, col2))
    end
  end,

  ["text:toggle-line-comments"] = function(dv)
    if not can_edit(dv, "toggle comments") then return end
    for idx, line1, col1, line2, col2 in buffer_multiline_selections(true) do
      local current_syntax = dv.buffer.syntax
      if line1 > 1 then
        -- Use the previous line state, as it will be the state
        -- of the beginning of the current line
        local state = dv.buffer.highlighter:get_line(line1 - 1).state
        if state then
          local syntaxes = tokenizer.extract_subsyntaxes(dv.buffer.syntax, state)
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
        dv.buffer:set_selections(idx, line_comment(comment, line1, col1, line2, col2))
      end
    end
  end,

  ["text:upper-case"] = function(dv)
    if not can_edit(dv, "change case") then return end
    dv.buffer:replace(string.uupper)
  end,

  ["text:lower-case"] = function(dv)
    if not can_edit(dv, "change case") then return end
    dv.buffer:replace(string.ulower)
  end,

  ["text:go-to-line"] = function(dv)
    local items
    local function init_items()
      if items then return end
      items = {}
      local mt = { __tostring = function(x) return x.text end }
      for i, line in ipairs(dv.buffer.lines) do
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
          dv.buffer:set_selection(line, 1)
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
        local tokens = dv.buffer.highlighter:get_line(item.line).tokens
        local tokens_count = #tokens
        if tokens_count > 0 and string.sub(tokens[tokens_count], -1) == "\n" then
          last_token = tokens_count - 1
        end
        for tidx, type, text in dv.buffer.highlighter:each_token(item.line) do
          color = style.syntax[type] or style.syntax["normal"]
          -- do not render newline, fixes issue #1164
          if tidx == last_token then text = text:sub(1, -2) end
          tx = renderer.draw_text(font, text, tx, y, color)
          if tx > (x + w) - font:get_width(item.info) - style.padding.x * 2 then break end
        end
      end
    })
  end,

  ["text:toggle-line-ending"] = function(dv)
    if not can_edit(dv, "toggle line ending") then return end
    dv.buffer.crlf = not dv.buffer.crlf
  end,

  ["text:change-encoding"] = function(dv)
    if not can_edit(dv, "change encoding") then return end
    encodings.select_encoding("Select Output Encoding", function(charset)
      if not can_edit(dv, "change encoding") then return end
      set_encoding(dv.buffer, charset)
      save_existing(dv.buffer)
    end)
  end,

  ["text:reload-with-encoding"] = function(dv)
    if not can_edit(dv, "reload") then return end
    encodings.select_encoding("Reload With Encoding", function(charset)
      if not can_edit(dv, "reload") then return end
      set_encoding(dv.buffer, charset)
      dv.buffer:reload()
    end)
  end,

  ["text:toggle-overwrite"] = function(dv)
    dv.buffer.overwrite = not dv.buffer.overwrite
    core.blink_reset() -- to show the cursor has changed edit modes
  end,

  ["text:save-as"] = function(dv)
    if not can_edit(dv, "save as") then return end
    prompt_save_as(dv, save_as_prompt_text(dv))
  end,

  ["text:save"] = function(dv)
    if not can_edit(dv, "save") then return end
    if dv.buffer.filename then
      save(nil, dv)
    else
      command.perform("text:save-as")
    end
  end,

  ["text:reload"] = function(dv)
    if not can_edit(dv, "reload") then return end
    dv.buffer:reload()
  end,

  ["file:rename"] = function(dv)
    if not can_edit(dv, "rename file") then return end
    local old_filename = dv.buffer.filename
    local old_abs_filename = dv.buffer.abs_filename
    if not old_filename then
      core.error("Cannot rename unsaved buffer")
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
        if not common.path_equals(dv.buffer.abs_filename, new_abs_filename) then return end
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
    local filename = dv.buffer.abs_filename
    if not filename then
      core.error("Cannot remove unsaved buffer")
      return
    end
    for _, textview in ipairs(core.get_views_referencing_buffer(dv.buffer)) do
      local pane = panes.pane_for_view(textview)
      if pane then panes.close_view(pane, { view = textview, force = true }) end
    end
    os.remove(filename)
    core.log("Removed \"%s\"", filename)
  end,

  ["text:select-to-cursor"] = function(dv, x, y, clicks)
    local line1, col1 = select(3, buffer():get_selection())
    local line2, col2 = dv:resolve_screen_position(x, y)
    dv.mouse_selecting = { line1, col1, nil }
    dv.buffer:set_selection(line2, col2, line1, col1)
    apply_resolved_wrap_affinity(dv)
    set_primary_selection(dv.buffer)
  end,

  ["text:create-cursor-previous-line"] = function(dv)
    split_cursor(dv, -1)
    dv.buffer:merge_cursors()
  end,

  ["text:create-cursor-next-line"] = function(dv)
    split_cursor(dv, 1)
    dv.buffer:merge_cursors()
  end
}

command.add(function(x, y)
  if x == nil or y == nil or not core.active_view
      or not core.active_view:extends(TextView) then return false end
  local dv = core.active_view
  local x1,y1,x2,y2 = dv.position.x, dv.position.y, dv.position.x + dv.size.x, dv.position.y + dv.size.y
  return x >= x1 + dv:get_gutter_width() and x < x2 and y >= y1 and y < y2, dv, x, y
end, {
  ["text:set-cursor"] = function(dv, x, y)
    set_cursor(dv, x, y, "set")
  end,

  ["text:set-cursor-word"] = function(dv, x, y)
    set_cursor(dv, x, y, "word")
  end,

  ["text:set-cursor-line"] = function(dv, x, y, clicks)
    set_cursor(dv, x, y, "lines")
  end,

  ["text:split-cursor"] = function(dv, x, y, clicks)
    if dv.begin_line_render_interaction then dv:begin_line_render_interaction("mouse-selection") end
    local line, col = dv:resolve_screen_position(x, y)
    local removal_target = nil
    for idx, line1, col1 in dv.buffer:get_selections(true) do
      if line1 == line and col1 == col and #buffer().selections > 4 then
        removal_target = idx
      end
    end
    if removal_target then
      dv.buffer:remove_selection(removal_target)
    else
      dv.buffer:add_selection(line, col, line, col)
    end
    apply_resolved_wrap_affinity(dv)
    dv.mouse_selecting = { line, col, "set" }
  end
})

local function active_bom_buffer(view)
  view = view or core.active_view
  if not (view and view.extends and view:extends(TextView)) then return nil end
  local buffer = view.buffer
  local bom = encoding.get_charset_bom(buffer.encoding or "none")
  if not bom then return nil end
  return buffer, bom
end

command.add_toggle("text:toggle-bom", {
  predicate = function()
    return active_bom_buffer() ~= nil
  end,
  get = function(view)
    local buffer = active_bom_buffer(view)
    return buffer and buffer.bom ~= nil
  end,
  set = function(enabled, view)
    view = view or core.active_view
    if not can_edit(view, "toggle BOM") then return end
    local buffer, bom = active_bom_buffer(view)
    if not buffer then return end
    buffer.bom = enabled and bom or nil
    save_existing(buffer)
  end,
})

local translations = {
  ["previous-char"] = translate,
  ["next-char"] = translate,
  ["previous-word-start"] = translate,
  ["next-word-end"] = translate,
  ["previous-block-start"] = translate,
  ["next-block-end"] = translate,
  ["start-of-buffer"] = translate,
  ["end-of-buffer"] = translate,
  ["start-of-line"] = translate,
  ["end-of-line"] = translate,
  ["start-of-word"] = translate,
  ["start-of-indentation"] = translate,
  ["end-of-word"] = translate,
  ["previous-line"] = TextView.translate,
  ["next-line"] = TextView.translate,
  ["previous-page"] = TextView.translate,
  ["next-page"] = TextView.translate,
}

for name, obj in pairs(translations) do
  commands["text:move-to-" .. name] = function(dv)
    dv.buffer:move_to(obj[name:gsub("-", "_")], dv)
  end
  commands["text:select-to-" .. name] = function(dv)
    dv.buffer:select_to(obj[name:gsub("-", "_")], dv)
    set_primary_selection(dv.buffer)
  end
  commands["text:delete-to-" .. name] = function(dv)
    if not can_edit(dv, "delete") then return end
    dv.buffer:delete_to(obj[name:gsub("-", "_")], dv)
  end
end

local function move_char_batch(dv, move_fn, collapse_to_end)
  clear_markdown_task_source_affinity(dv)
  local buffer = dv.buffer
  local selections = {}
  local last_selection = buffer.last_selection
  for _, line1, col1, line2, col2 in buffer:get_selections(true) do
    local line, col
    if line1 ~= line2 or col1 ~= col2 then
      if collapse_to_end then
        line, col = line2, col2
      else
        line, col = line1, col1
      end
    else
      line, col = move_fn(buffer, line1, col1, dv)
    end
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line
    selections[#selections + 1] = col
  end
  buffer:set_selection_list(selections, last_selection, { merge_cursors = true, sanitized = true })
end

commands["text:move-to-previous-char"] = function(dv)
  if reveal_markdown_task_source_from_implicit_content(dv) then return end
  move_char_batch(dv, translate.previous_char, false)
end

commands["text:move-to-next-char"] = function(dv)
  move_char_batch(dv, translate.next_char, true)
  set_markdown_task_source_affinity(dv)
end

local function move_line_batch(dv, line_offset)
  local buffer = dv.buffer
  local old = buffer.selections
  local selections = {}
  local last_selection = buffer.last_selection
  local last_line = #buffer.lines
  local x_by_line_col = {}
  local col_by_line_x = {}
  local last_x_offset = dv.last_x_offset
  local has_relevant_syntax_fonts = false
  local syntax_name = tostring(buffer.syntax and buffer.syntax.name or ""):lower()
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
      simple = not not buffer.lines[line] and not buffer.lines[line]:find("[\t\128-\255]")
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
      target_line, target_col = last_line, #buffer.lines[last_line]
    else
      target_line = dv.fold_aware_line_move and dv:fold_aware_line_move(line, line_offset) or line + line_offset
      if is_simple_line(line) and is_simple_line(target_line) then
        local x = (col - 1) * dv:get_font():get_width(" ")
        target_col = common.clamp(col, 1, #buffer.lines[target_line])
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
        target_col = common.clamp(get_cached_col(target_line, x), 1, #buffer.lines[target_line])
        last_x_offset.offset = x
        last_x_offset.line = target_line
        last_x_offset.col = target_col
      end
    end
    local target_fold = dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
    if target_fold and target_fold.line1 == target_line then target_col = 1 end
    add_cursor(old_idx, target_line, target_col)
  end

  buffer:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
end

commands["text:move-to-previous-line"] = function(dv)
  move_line_batch(dv, -1)
end

commands["text:move-to-next-line"] = function(dv)
  move_line_batch(dv, 1)
end

local function move_collapsed_carets_batch(dv, move_fn)
  local buffer = dv.buffer
  local old = buffer.selections
  local selections = {}
  local seen = {}
  local last_selection = buffer.last_selection
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
    local line, col = move_fn(buffer, old[i], old[i + 1])
    add_cursor(old_idx, line, col)
  end

  buffer:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
end

local function move_to_end_of_line(buffer, line)
  return line, #buffer.lines[line]
end

local function move_to_markdown_list_content(buffer, line, col)
  local list_content_col = markdown_list_content_start(
    buffer, line, buffer.lines[line], true
  )
  if list_content_col and col > list_content_col then
    return line, list_content_col
  end
end

local function move_to_start_of_line(buffer, line, col)
  local target_line, target_col = move_to_markdown_list_content(buffer, line, col)
  if target_line then return target_line, target_col end
  return translate.start_of_line(buffer, line, col)
end

local function move_to_start_of_indentation(buffer, line, col)
  local target_line, target_col = move_to_markdown_list_content(buffer, line, col)
  if target_line then return target_line, target_col end
  local _, indent_end = buffer.lines[line]:find("^[\t ]*")
  local indent_col = indent_end + 1
  return line, col > indent_col and indent_col or (col == 1 and indent_col or 1)
end

commands["text:move-to-end-of-line"] = function(dv)
  move_collapsed_carets_batch(dv, move_to_end_of_line)
end

commands["text:move-to-start-of-line"] = function(dv)
  move_collapsed_carets_batch(dv, move_to_start_of_line)
end

commands["text:move-to-start-of-indentation"] = function(dv)
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
  local buffer = dv.buffer
  local old = buffer.selections
  local selections = {}
  local seen = {}
  local last_selection = buffer.last_selection
  local mapped_last_selection = nil

  for i = 1, #old, 4 do
    local old_idx = (i - 1) / 4 + 1
    local line, col = move_fn(buffer, old[i], old[i + 1], dv)
    mapped_last_selection = add_selection_endpoint(
      selections, seen, old_idx, last_selection, mapped_last_selection,
      line, col, old[i + 2], old[i + 3]
    )
  end

  buffer:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
  set_primary_selection(buffer)
end

local function select_line_batch(dv, line_offset)
  local buffer = dv.buffer
  local old = buffer.selections
  local selections = {}
  local seen = {}
  local last_selection = buffer.last_selection
  local mapped_last_selection = nil
  local last_line = #buffer.lines
  local x_by_line_col = {}
  local col_by_line_x = {}
  local last_x_offset = dv.last_x_offset
  local has_relevant_syntax_fonts = false
  local syntax_name = tostring(buffer.syntax and buffer.syntax.name or ""):lower()
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
      simple = not not buffer.lines[line] and not buffer.lines[line]:find("[\t\128-\255]")
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
      target_line, target_col = last_line, #buffer.lines[last_line]
    else
      target_line = dv.fold_aware_line_move and dv:fold_aware_line_move(line, line_offset) or line + line_offset
      if is_simple_line(line) and is_simple_line(target_line) then
        local x = (col - 1) * dv:get_font():get_width(" ")
        target_col = common.clamp(col, 1, #buffer.lines[target_line])
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
        target_col = common.clamp(get_cached_col(target_line, x), 1, #buffer.lines[target_line])
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

  buffer:set_selection_list(selections, mapped_last_selection or last_selection, { sanitized = true, take_ownership = true })
  set_primary_selection(buffer)
end

commands["text:select-to-previous-char"] = function(dv)
  select_char_batch(dv, translate.previous_char)
end

commands["text:select-to-next-char"] = function(dv)
  select_char_batch(dv, translate.next_char)
end

commands["text:select-to-previous-line"] = function(dv)
  select_line_batch(dv, -1)
end

commands["text:select-to-next-line"] = function(dv)
  select_line_batch(dv, 1)
end

local unwrapped_navigation_commands = {}
for _, name in ipairs({
  "text:move-to-previous-line",
  "text:move-to-next-line",
  "text:select-to-previous-line",
  "text:select-to-next-line",
  "text:move-to-next-char",
  "text:select-to-next-char",
  "text:move-to-next-word-end",
  "text:select-to-next-word-end",
  "text:move-to-end-of-word",
  "text:select-to-end-of-word",
  "text:move-to-next-block-end",
  "text:select-to-next-block-end",
  "text:move-to-end-of-buffer",
  "text:select-to-end-of-buffer",
  "text:move-to-start-of-line",
  "text:select-to-start-of-line",
  "text:delete-to-start-of-line",
  "text:move-to-start-of-indentation",
  "text:select-to-start-of-indentation",
  "text:delete-to-start-of-indentation",
  "text:move-to-end-of-line",
  "text:select-to-end-of-line",
  "text:delete-to-end-of-line",
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
  if not dv.wrapped_settings
  and not (dv.needs_line_render_position_navigation
    and dv:needs_line_render_position_navigation(name))
  then
    return perform_unwrapped_navigation(name, dv, ...)
  end
  if dv.clear_pending_line_render_position_row_affinity then
    dv:clear_pending_line_render_position_row_affinity()
  end
  local selections = {}
  local affinity_positions = {}
  for _, line1, col1 in dv.buffer:get_selections(false) do
    local line, col, line_end = move_fn(dv.buffer, line1, col1, ...)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    add_line_end_affinity(affinity_positions, line, col, line_end)
  end
  dv.buffer:set_selection_list(selections, dv.buffer.last_selection, { merge_cursors = true })
  linewrapping.set_wrapped_line_end_affinity(dv, affinity_positions)
  if dv.apply_pending_line_render_position_row_affinity then
    dv:apply_pending_line_render_position_row_affinity()
  end
end

local function wrapped_select_to(dv, name, move_fn, ...)
  if not dv.wrapped_settings
  and not (dv.needs_line_render_position_navigation
    and dv:needs_line_render_position_navigation(name))
  then
    return perform_unwrapped_navigation(name, dv, ...)
  end
  if dv.clear_pending_line_render_position_row_affinity then
    dv:clear_pending_line_render_position_row_affinity()
  end
  local selections = {}
  local affinity_positions = {}
  for _, line1, col1, line2, col2 in dv.buffer:get_selections(false) do
    local line, col, line_end = move_fn(dv.buffer, line1, col1, ...)
    selections[#selections + 1] = line
    selections[#selections + 1] = col
    selections[#selections + 1] = line2
    selections[#selections + 1] = col2
    add_line_end_affinity(affinity_positions, line, col, line_end)
  end
  dv.buffer:set_selection_list(selections, dv.buffer.last_selection, { merge_cursors = true })
  linewrapping.set_wrapped_line_end_affinity(dv, affinity_positions)
  if dv.apply_pending_line_render_position_row_affinity then
    dv:apply_pending_line_render_position_row_affinity()
  end
  set_primary_selection(dv.buffer)
end

local function wrapped_delete_to(dv, name, move_fn, ...)
  if not can_edit(dv, "delete") then return end
  if not dv.wrapped_settings
  and not (dv.needs_line_render_position_navigation
    and dv:needs_line_render_position_navigation(name))
  then
    return perform_unwrapped_navigation(name, dv, ...)
  end
  local args = { n = select("#", ...), ... }
  return dv.buffer:delete_to(function(target_buffer, line, col)
    return move_fn(target_buffer, line, col, table.unpack(args, 1, args.n))
  end, dv)
end

local function wrapped_forward_endpoint_command(dv, name, ...)
  if not dv.wrapped_settings then return perform_unwrapped_navigation(name, dv, ...) end
  local old_selections = linewrapping.copy_selection_list(dv.buffer.selections)
  local result = perform_unwrapped_navigation(name, dv, ...)
  linewrapping.set_wrapped_line_end_affinity(dv, linewrapping.collect_forward_endpoint_affinity(dv, old_selections))
  return result
end

local function move_to_wrapped_previous_line(buffer, line, col, dv)
  if dv and dv.move_within_line_render_position_rows then
    local target_line, target_col = dv:move_within_line_render_position_rows(
      line, col, -1
    )
    if target_line then return target_line, target_col, false end
  end
  if dv and dv.has_collapsed_folds and dv:has_collapsed_folds() then
    local hidden, fold = dv:is_line_hidden_by_fold(math.max(1, (line or 1) - 1))
    if hidden and dv:get_visual_row_count_for_line(line) <= 1 then return fold.line1, 1 end
    local target_line, target_col, target_line_end =
      dv:folded_visual_line_position(line, col, -1)
    if target_line ~= line and dv.land_on_line_render_position_row then
      target_col = dv:land_on_line_render_position_row(
        target_line, target_col, -1,
        dv.last_x_offset and dv.last_x_offset.offset or 0
      )
    end
    return target_line, target_col, target_line_end
  end
  local target_line, target_col, target_line_end = linewrapping.wrapped_visual_line_position(dv, line, col, -1)
  if dv and dv.is_line_hidden_by_fold then
    local current_fold = dv:get_collapsed_fold_at_line(line)
    local target_fold = dv:get_collapsed_fold_at_line(target_line)
    if dv:is_line_hidden_by_fold(target_line) or (current_fold and current_fold.line1 == line and target_line == line) then
      target_line = dv:fold_aware_line_move(line, -1)
      target_col = current_fold and current_fold.line1 == line and 1 or common.clamp(target_col, 1, #buffer.lines[target_line])
    elseif target_fold and target_fold.line1 == target_line then
      target_col = 1
    end
  end
  local landed_fold = dv and dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
  if landed_fold and landed_fold.line1 == target_line then target_col = 1 end
  if dv and target_line ~= line and dv.land_on_line_render_position_row then
    target_col = dv:land_on_line_render_position_row(
      target_line, target_col, -1,
      dv.last_x_offset and dv.last_x_offset.offset or 0
    )
  end
  return target_line, target_col, target_line_end
end

local function move_to_wrapped_next_line(buffer, line, col, dv)
  if dv and dv.move_within_line_render_position_rows then
    local target_line, target_col = dv:move_within_line_render_position_rows(
      line, col, 1
    )
    if target_line then return target_line, target_col, false end
  end
  if dv and dv.has_collapsed_folds and dv:has_collapsed_folds() then
    local target_line, target_col, target_line_end =
      dv:folded_visual_line_position(line, col, 1)
    if target_line ~= line and dv.land_on_line_render_position_row then
      target_col = dv:land_on_line_render_position_row(
        target_line, target_col, 1,
        dv.last_x_offset and dv.last_x_offset.offset or 0
      )
    end
    return target_line, target_col, target_line_end
  end
  local target_line, target_col, target_line_end = linewrapping.wrapped_visual_line_position(dv, line, col, 1)
  if dv and dv.is_line_hidden_by_fold then
    local current_fold = dv:get_collapsed_fold_at_line(line)
    local target_fold = dv:get_collapsed_fold_at_line(target_line)
    if dv:is_line_hidden_by_fold(target_line) or (current_fold and current_fold.line1 == line and target_line == line) then
      target_line = dv:fold_aware_line_move(line, 1)
      target_col = current_fold and current_fold.line1 == line and 1 or common.clamp(target_col, 1, #buffer.lines[target_line])
    elseif target_fold and target_fold.line1 == target_line then
      target_col = 1
    end
  end
  local landed_fold = dv and dv.get_collapsed_fold_at_line and dv:get_collapsed_fold_at_line(target_line)
  if landed_fold and landed_fold.line1 == target_line then target_col = 1 end
  if dv and target_line ~= line and dv.land_on_line_render_position_row then
    target_col = dv:land_on_line_render_position_row(
      target_line, target_col, 1,
      dv.last_x_offset and dv.last_x_offset.offset or 0
    )
  end
  return target_line, target_col, target_line_end
end

local function move_to_wrapped_end_of_line(buffer, line, col, dv)
  if dv and dv.get_line_render_position_row_bounds then
    local _, row_end, row_index = dv:get_line_render_position_row_bounds(line, col)
    if row_end and col ~= row_end then
      if dv.queue_line_render_position_row_affinity then
        dv:queue_line_render_position_row_affinity(line, row_end, row_index)
      end
      return line, row_end, false
    end
  end
  return linewrapping.wrapped_end_of_line_position(dv, buffer, line, col, translate.end_of_line)
end

local function move_to_wrapped_start_of_line(buffer, line, col, dv, logical_start)
  if dv and dv.get_line_render_position_row_bounds then
    local row_start, _, row_index = dv:get_line_render_position_row_bounds(line, col)
    if row_start and col ~= row_start then
      if dv.queue_line_render_position_row_affinity then
        dv:queue_line_render_position_row_affinity(line, row_start, row_index)
      end
      return line, row_start, false
    end
  end
  return linewrapping.wrapped_start_of_line_position(
    dv, buffer, line, col, logical_start or translate.start_of_line
  )
end

local function move_to_wrapped_start_of_indentation(buffer, line, col, dv, logical_start)
  if dv and dv.get_line_render_position_row_bounds then
    local row_start, _, row_index = dv:get_line_render_position_row_bounds(line, col)
    if row_start and row_start ~= 1 and col ~= row_start then
      if dv.queue_line_render_position_row_affinity then
        dv:queue_line_render_position_row_affinity(line, row_start, row_index)
      end
      return line, row_start, false
    end
  end
  return linewrapping.wrapped_start_of_indentation_position(
    dv, buffer, line, col, logical_start or translate.start_of_indentation
  )
end

commands["text:move-to-previous-line"] = function(dv)
  return wrapped_move_to(
    dv, "text:move-to-previous-line", move_to_wrapped_previous_line, dv
  )
end
commands["text:move-to-next-line"] = function(dv)
  return wrapped_move_to(
    dv, "text:move-to-next-line", move_to_wrapped_next_line, dv
  )
end
commands["text:select-to-previous-line"] = function(dv)
  return wrapped_select_to(dv, "text:select-to-previous-line", move_to_wrapped_previous_line, dv)
end
commands["text:select-to-next-line"] = function(dv)
  return wrapped_select_to(dv, "text:select-to-next-line", move_to_wrapped_next_line, dv)
end

for _, name in ipairs({
  "text:move-to-next-char",
  "text:select-to-next-char",
  "text:move-to-next-word-end",
  "text:select-to-next-word-end",
  "text:move-to-end-of-word",
  "text:select-to-end-of-word",
  "text:move-to-next-block-end",
  "text:select-to-next-block-end",
  "text:move-to-end-of-buffer",
  "text:select-to-end-of-buffer",
}) do
  local command_name = name
  commands[command_name] = function(dv, ...)
    return wrapped_forward_endpoint_command(dv, command_name, ...)
  end
end

commands["text:move-to-start-of-line"] = function(dv)
  return wrapped_move_to(
    dv, "text:move-to-start-of-line",
    move_to_wrapped_start_of_line, dv, move_to_start_of_line
  )
end
commands["text:select-to-start-of-line"] = function(dv)
  return wrapped_select_to(dv, "text:select-to-start-of-line", move_to_wrapped_start_of_line, dv)
end
commands["text:delete-to-start-of-line"] = function(dv)
  return wrapped_delete_to(dv, "text:delete-to-start-of-line", move_to_wrapped_start_of_line, dv)
end
commands["text:move-to-start-of-indentation"] = function(dv)
  return wrapped_move_to(
    dv, "text:move-to-start-of-indentation",
    move_to_wrapped_start_of_indentation, dv, move_to_start_of_indentation
  )
end
commands["text:select-to-start-of-indentation"] = function(dv)
  return wrapped_select_to(dv, "text:select-to-start-of-indentation", move_to_wrapped_start_of_indentation, dv)
end
commands["text:delete-to-start-of-indentation"] = function(dv)
  return wrapped_delete_to(dv, "text:delete-to-start-of-indentation", move_to_wrapped_start_of_indentation, dv)
end
commands["text:move-to-end-of-line"] = function(dv)
  return wrapped_move_to(dv, "text:move-to-end-of-line", move_to_wrapped_end_of_line, dv)
end
commands["text:select-to-end-of-line"] = function(dv)
  return wrapped_select_to(dv, "text:select-to-end-of-line", move_to_wrapped_end_of_line, dv)
end
commands["text:delete-to-end-of-line"] = function(dv)
  return wrapped_delete_to(dv, "text:delete-to-end-of-line", move_to_wrapped_end_of_line, dv)
end

commands["text:fold-at-caret"] = function(dv)
  local fold, err = dv:fold_at_caret()
  if not fold and err then core.log_quiet("Fold at caret skipped: %s", tostring(err)) end
end

commands["text:unfold-at-caret"] = function(dv)
  dv:unfold_at_caret("command")
end

commands["text:unfold-all"] = function(dv)
  dv:unfold_all("command")
end

command.add(function(...)
  local view = core.active_view
  local editor = core.current_editor()
  local panes = require "core.panes"
  local owner = panes.owner_for_view(view)
  if view and view ~= editor and owner ~= view
      and view.extends and view:extends(TextView) and not view:is(Editor) then
    return true, view, ...
  end
  if view and view:is(Editor) and not owner then
    return true, view, ...
  end
  if editor then return true, editor, ... end
  local pane = owner and panes.pane_for_view(owner)
  local owned_text_view = owner and owner ~= view and pane and pane.current_view == owner
    and view and view.extends and view:extends(TextView)
  local specialized_text_view = view and view.accepts_text_commands
    and view.extends and view:extends(TextView)
  return not not (owned_text_view or specialized_text_view), view, ...
end, commands)

command.add_toggle("line-wrapping:toggle", {
  get = function(view)
    view = view or core.active_view
    return view and view.buffer and view.extends and view:extends(TextView) and view:is_wrapping_enabled()
  end,
  set = function(enabled, view)
    view = view or core.active_view
    if view and view.buffer and view.extends and view:extends(TextView) then
      view:set_wrapping_enabled(enabled)
    end
  end,
})

keymap.add {
  ["f10"] = "line-wrapping:toggle",
}

keymap.add_direct {
  ["ctrl+-"] = "text:fold-at-caret",
  ["ctrl+shift+-"] = "text:fold-at-caret",
  ["ctrl+="] = "text:unfold-at-caret",
  ["ctrl+shift+="] = "text:unfold-at-caret",
  ["ctrl+plus"] = "text:unfold-at-caret",
  ["ctrl+shift+plus"] = "text:unfold-at-caret",
}
