-- mod-version:3
-- Local clone of Pragtical's built-in in-file find commands.
-- Kept separate so we can evolve it toward IntelliJ-like search behavior without
-- patching Pragtical's core files.

local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local search = require "core.doc.search"
local style = require "core.style"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local MessageBox = require "widget.messagebox"

local last_view, last_fn, last_text, last_sel
local find_active = false
local case_sensitive = config.find_case_sensitive or false
local find_regex = config.find_regex or false
local found_expression
local find_label = "Find"
local find_info_text = ""
local find_info_error = false
local replace_active = false
local replace_text = ""
local replace_focus = "find"
local find_state_by_doc = setmetatable({}, { __mode = "k" })

if not DocView.__intellij_find_search_text then
  DocView.__intellij_find_search_text = true
  local draw_line_text = DocView.draw_line_text
  function DocView:draw_line_text(line, x, y)
    local search_selections = {}
    for _, line1, col1, line2, col2 in self.doc:get_selections(true) do
      if line == line1 and line <= line2 and self.doc:is_search_selection(line1, col1, line2, col2) then
        table.insert(search_selections, { start = col1, stop = col2 })
      end
    end
    if #search_selections == 0 then
      return draw_line_text(self, line, x, y)
    end

    local default_font = self:get_font()
    local tx, ty = x, y + self:get_line_text_y_offset()
    local tokens = self.doc.highlighter:get_line(line).tokens
    local last_token = nil
    if #tokens > 0 and string.sub(tokens[#tokens], -1) == "\n" then
      last_token = #tokens - 1
    end
    local _, indent_size = self.doc:get_indent_info()
    local col = 1
    local start_tx = tx

    local function is_selected(c)
      for _, sel in ipairs(search_selections) do
        if c >= sel.start and c < sel.stop then return true end
      end
      return false
    end

    for tidx, type, text in self.doc.highlighter:each_token(line) do
      local font = style.syntax_fonts[type] or default_font
      if font ~= default_font then font:set_tab_size(indent_size) end
      if tidx == last_token then text = text:sub(1, -2) end
      local i, len = 1, #text
      while i <= len do
        local chunk_start = i
        local selected = is_selected(col)
        while i <= len and is_selected(col) == selected do
          i = i + 1
          col = col + 1
        end
        local chunk = text:sub(chunk_start, i - 1)
        -- Keep syntax/default foreground unchanged for focused search matches;
        -- the match is indicated by the background + outline only.
        local color = style.syntax[type] or style.syntax["normal"]
        tx = renderer.draw_text(font, chunk, tx, ty, color, { tab_offset = tx - start_tx })
        if tx > self.position.x + self.size.x then break end
      end
      if tx > self.position.x + self.size.x then break end
    end

    return self:get_line_height()
  end
end

if not DocView.__intellij_find_search_outline then
  DocView.__intellij_find_search_outline = true
  local draw_line_body = DocView.draw_line_body
  local match_pad_x = math.max(1, SCALE)
  local match_pad_y = 0

  local function each_search_selection_rect(dv, line, x, y, fn)
    local line_height = dv:get_line_height()
    for _, line1, col1, line2, col2 in dv.doc:get_selections(true) do
      if line >= line1 and line <= line2 then
        local text = dv.doc.lines[line]
        if line1 ~= line then col1 = 1 end
        if line2 ~= line then col2 = #text + 1 end
        if dv.doc:is_search_selection(line1, col1, line, col2) then
          local x1 = x + dv:get_col_x_offset(line, col1)
          local x2 = x + dv:get_col_x_offset(line, col2)
          if x1 ~= x2 then
            fn(x1 - match_pad_x, x2 + match_pad_x, y - match_pad_y, line_height + match_pad_y * 2)
          end
        end
      end
    end
  end

  local function draw_outline(x1, x2, y, h, color)
    local thickness = math.max(1, SCALE)
    renderer.draw_rect(x1, y, x2 - x1, thickness, color)
    renderer.draw_rect(x1, y + h - thickness, x2 - x1, thickness, color)
    renderer.draw_rect(x1, y, thickness, h, color)
    renderer.draw_rect(x2 - thickness, y, thickness, h, color)
  end

  function DocView:draw_line_body(line, x, y)
    local state = find_state_by_doc[self.doc]
    local search_draw_active = state and state.active
    local outline = search_draw_active and style.search_selection_outline
    local secondary_outline = search_draw_active and (style.search_selection_secondary_outline or outline)
    if search_draw_active and secondary_outline then
      local line_height = self:get_line_height()
      for i, match in ipairs(state.matches or {}) do
        if i ~= state.current and match.line == line then
          local x1 = x + self:get_col_x_offset(line, match.col1) - match_pad_x
          local x2 = x + self:get_col_x_offset(line, match.col2) + match_pad_x
          renderer.draw_rect(x1, y - match_pad_y, x2 - x1, line_height + match_pad_y * 2, style.selectionhighlight or style.search_selection)
          draw_outline(x1, x2, y - match_pad_y, line_height + match_pad_y * 2, secondary_outline)
        end
      end
    end

    local bg = search_draw_active and style.search_selection
    if bg then
      each_search_selection_rect(self, line, x, y, function(x1, x2, ry, rh)
        renderer.draw_rect(x1, ry, x2 - x1, rh, bg)
      end)
    end

    local lh = draw_line_body(self, line, x, y)
    if outline then
      each_search_selection_rect(self, line, x, y, function(x1, x2, ry, rh)
        draw_outline(x1, x2, ry, rh, outline)
      end)
    end
    return lh
  end
end

if not CommandView.__intellij_find_widget then
  CommandView.__intellij_find_widget = true
  local commandview_draw = CommandView.draw
  local commandview_get_line_screen_position = CommandView.get_line_screen_position

  local function find_widget_layout(view)
    local font = view:get_font()
    local pad = style.padding.x
    local sep = math.max(1, style.divider_size or SCALE)
    local find_label = "Find:"
    local replace_label = "Replace by:"
    local left_w = font:get_width(find_label) + pad * 2
    local info_w = find_info_text ~= "" and (font:get_width(find_info_text) + pad * 2) or (80 * SCALE)
    local input_max_w = 420 * SCALE
    local input_min_w = 120 * SCALE
    local replace_label_w = replace_active and (font:get_width(replace_label) + pad * 2) or 0
    local replace_w = replace_active and math.max(input_min_w, 220 * SCALE) or 0
    local available = view.size.x - left_w - info_w - replace_label_w - replace_w - sep * (replace_active and 3 or 2) - pad * (replace_active and 3 or 2)
    local input_w = math.max(input_min_w, math.min(input_max_w, available))
    local input_x = view.position.x + left_w + sep + pad
    local right_sep_x = input_x + input_w + pad
    local info_x = right_sep_x + sep + pad
    local replace_label_x = info_x + info_w + pad
    local replace_sep_x = replace_label_x + replace_label_w
    local replace_x = replace_sep_x + sep + pad
    local replace_right_sep_x = replace_x + replace_w + pad
    local lh = view:get_line_height()
    local line_y = view.position.y + (view.size.y - lh) / 2
    return {
      font = font,
      label = find_label,
      replace_label = replace_label,
      left_w = left_w,
      sep = sep,
      input_x = input_x,
      input_w = input_w,
      right_sep_x = right_sep_x,
      info_x = info_x,
      info_w = info_w,
      replace_label_x = replace_label_x,
      replace_label_w = replace_label_w,
      replace_sep_x = replace_sep_x,
      replace_x = replace_x,
      replace_w = replace_w,
      replace_right_sep_x = replace_right_sep_x,
      line_y = line_y,
      line_h = lh,
      pad = pad,
    }
  end

  function CommandView:get_line_screen_position(line, col)
    if find_active and self == core.command_view then
      local layout = find_widget_layout(self)
      local input_x = (replace_active and replace_focus == "replace") and layout.replace_x or layout.input_x
      if col then
        return input_x + self:get_col_x_offset(1, col), layout.line_y
      end
      return input_x, layout.line_y
    end
    return commandview_get_line_screen_position(self, line, col)
  end

  function CommandView:draw()
    if not (find_active and self == core.command_view) then
      return commandview_draw(self)
    end

    self:draw_background(style.background)
    local layout = find_widget_layout(self)
    local y = layout.line_y + self:get_line_text_y_offset()
    renderer.draw_text(layout.font, layout.label, self.position.x + layout.pad, y, style.dim or style.text)
    renderer.draw_rect(self.position.x + layout.left_w, self.position.y, layout.sep, self.size.y, style.divider)
    renderer.draw_rect(layout.right_sep_x, self.position.y, layout.sep, self.size.y, style.divider)

    if replace_active and replace_focus == "replace" then
      renderer.draw_text(layout.font, last_text or "", layout.input_x, y, style.text)
    else
      core.push_clip_rect(layout.input_x, self.position.y, layout.input_w, self.size.y)
      self:draw_line_body(1, layout.input_x, layout.line_y)
      self:draw_overlay()
      core.pop_clip_rect()
    end

    if find_info_text ~= "" then
      renderer.draw_text(layout.font, find_info_text, layout.info_x, y, find_info_error and (style.error or style.text) or (style.dim or style.text))
    end

    if replace_active then
      renderer.draw_text(layout.font, layout.replace_label, layout.replace_label_x, y, style.dim or style.text)
      renderer.draw_rect(layout.replace_sep_x, self.position.y, layout.sep, self.size.y, style.divider)
      renderer.draw_rect(layout.replace_right_sep_x, self.position.y, layout.sep, self.size.y, style.divider)
      if replace_focus == "replace" then
        core.push_clip_rect(layout.replace_x, self.position.y, layout.replace_w, self.size.y)
        self:draw_line_body(1, layout.replace_x, layout.line_y)
        self:draw_overlay()
        core.pop_clip_rect()
      else
        renderer.draw_text(layout.font, replace_text or "", layout.replace_x, y, style.text)
      end
    end
  end
end

local function is_searchable_docview(view)
  return view and view:extends(DocView) and not view:is(CommandView) and view.doc
end

local function doc()
  return is_searchable_docview(core.active_view) and core.active_view.doc or (last_view and last_view.doc)
end

local function get_find_tooltip()
  local rf = keymap.get_binding("find-replace:repeat-find")
  local ti = keymap.get_binding("find-replace:toggle-sensitivity")
  local tr = keymap.get_binding("find-replace:toggle-regex")
  return (find_regex and "[Regex] " or "") ..
    (case_sensitive and "[Sensitive] " or "") ..
    (rf and ("Press " .. rf .. " to select the next match.") or "") ..
    (ti and (" " .. ti .. " toggles case sensitivity.") or "") ..
    (tr and (" " .. tr .. " toggles regex find.") or "")
end

local function find_all_matches(d, text)
  if not d or text == "" then return {} end

  local matches = {}
  local compiled
  if find_regex then
    local ok, result = pcall(regex.compile, text, case_sensitive and "" or "i")
    if not ok or not result then return matches end
    compiled = result
  elseif not case_sensitive then
    text = text:lower()
  end

  for line_nr, line_text in ipairs(d.lines) do
    local source = (not find_regex and not case_sensitive) and line_text:lower() or line_text
    local pos = 1
    while pos <= #source do
      local s, e
      if find_regex then
        s, e = regex.find_offsets(compiled, source, pos)
      else
        s, e = source:find(text, pos, true)
      end
      if not s then break end
      if e >= s and (e ~= #source or s ~= e) then
        matches[#matches+1] = {
          line = line_nr,
          col1 = s,
          col2 = e == #source and e or e + 1,
        }
      end
      pos = math.max(e + 1, s + 1)
    end
  end

  return matches
end

local function match_at_selection(matches)
  if not last_view then return 0 end
  local l1, c1, l2, c2 = last_view.doc:get_selection(true)
  for i, match in ipairs(matches) do
    if match.line == l1 and match.line == l2 and match.col1 == c1 and match.col2 == c2 then
      return i
    end
  end
  return 0
end

local function update_find_label(text, matches, current)
  if not find_active then return end
  matches = matches or {}
  if text and text ~= "" then
    if #matches == 0 then
      find_info_text = "0 results"
      find_info_error = true
    else
      find_info_text = string.format("%d / %d", current or 0, #matches)
      find_info_error = false
    end
  else
    find_info_text = ""
    find_info_error = false
  end
  core.command_view.label = ""
end

local function set_find_state(d, text, matches, current)
  if d then
    d.intellij_find_active = find_active
    find_state_by_doc[d] = { active = find_active, text = text, matches = matches or {}, current = current or 0 }
  end
end

local function clear_find_state(d)
  if d then
    d.intellij_find_active = nil
    find_state_by_doc[d] = nil
    d:clear_search_selections()
  end
end

local function compare_pos(line_a, col_a, line_b, col_b)
  if line_a ~= line_b then return line_a < line_b and -1 or 1 end
  if col_a ~= col_b then return col_a < col_b and -1 or 1 end
  return 0
end

local function choose_match(matches, text, reverse)
  if #matches == 0 then return 0 end

  if reverse == nil and text ~= "" then
    local l1, c1, l2, c2 = last_view.doc:get_selection(true)
    if c1 ~= c2 or l1 ~= l2 then
      local selected_text = last_view.doc:get_text(l1, c1, l2, c2)
      if selected_text == text then
        local idx = match_at_selection(matches)
        if idx > 0 then return idx end
      end
    end
  end

  local start_line, start_col = last_sel[1], last_sel[2]
  if reverse ~= nil then
    local l1, c1, l2, c2 = last_view.doc:get_selection(true)
    start_line, start_col = reverse and l1 or l2, reverse and c1 or c2
  end

  if reverse then
    for i = #matches, 1, -1 do
      local match = matches[i]
      if compare_pos(match.line, match.col1, start_line, start_col) < 0 then return i end
    end
    return #matches
  end

  for i, match in ipairs(matches) do
    local anchor_col = reverse == nil and match.col1 or match.col2
    if compare_pos(match.line, anchor_col, start_line, start_col) > 0 then return i end
  end
  return 1
end

local function update_preview(sel, search_fn, text, reverse)
  local d = last_view.doc
  d:clear_search_selections()

  local matches = find_all_matches(d, text or "")
  local current = text ~= "" and choose_match(matches, text, reverse) or 0
  if current > 0 then
    local match = matches[current]
    d:add_search_selection(match.line, match.col1, match.line, match.col2)
    d:set_selection(match.line, match.col2, match.line, match.col1)
    last_view:scroll_to_line(match.line, true)
    found_expression = true
  else
    d:set_selection(table.unpack(sel))
    found_expression = false
  end

  set_find_state(d, text, matches, current)
  update_find_label(text, matches, current)
end

local function current_find_text()
  return (replace_active and replace_focus == "replace") and (last_text or "") or core.command_view:get_text()
end

local function selection_match_index(d, match)
  for idx, l1, c1, l2, c2 in d:get_selections(true, true) do
    if l1 == match.line and l2 == match.line and c1 == match.col1 and c2 == match.col2 then
      return idx
    end
  end
end

local function add_find_match_to_selection(reverse)
  if not last_view or not last_fn then return end
  local d = last_view.doc
  if replace_active and replace_focus == "replace" then replace_text = core.command_view:get_text() end
  local text = current_find_text()
  last_text = text

  d:clear_search_selections()
  local matches = find_all_matches(d, text or "")
  local current = text ~= "" and choose_match(matches, text, reverse) or 0
  if current > 0 then
    local match = matches[current]
    d:add_search_selection(match.line, match.col1, match.line, match.col2)
    local existing_idx = selection_match_index(d, match)
    if existing_idx then
      -- When navigation wraps to an already-selected match, keep all existing
      -- selections/cursors.  set_selection() would replace the whole selection
      -- set, so just make the existing match the active cursor instead.
      d.last_selection = existing_idx
    else
      d:add_selection(match.line, match.col2, match.line, match.col1)
    end
    last_view:scroll_to_line(match.line, true)
    found_expression = true
  else
    found_expression = false
  end

  set_find_state(d, text, matches, current)
  update_find_label(text, matches, current)
end

local function replace_current_match()
  if not last_view then return end
  local d = last_view.doc
  local l1, c1, l2, c2 = d:get_selection(true)
  if l1 == l2 and c1 == c2 then return end
  d:text_input(replace_text or "", d.last_selection)
  last_sel = { d:get_selection() }
  if last_fn and last_text and last_text ~= "" then
    update_preview(last_sel, last_fn, last_text, false)
  end
end

local function perform_replace_all(matches, replacement)
  local d = last_view and last_view.doc
  if not d or #matches == 0 then return end
  for i = #matches, 1, -1 do
    local match = matches[i]
    d:remove(match.line, match.col1, match.line, match.col2)
    d:insert(match.line, match.col1, replacement or "")
  end
  d:clear_search_selections()
  last_sel = { d:get_selection() }
  found_expression = false
  set_find_state(d, last_text, {}, 0)
  update_find_label(last_text, {}, 0)
end

local function confirm_replace_all()
  if not last_view then return end
  if replace_active and replace_focus == "replace" then
    replace_text = core.command_view:get_text()
  else
    last_text = core.command_view:get_text()
  end

  local text = last_text or ""
  if text == "" then return end
  local matches = find_all_matches(last_view.doc, text)
  local count = #matches
  if count == 0 then
    update_find_label(text, matches, 0)
    return
  end

  local replacement = replace_text or ""
  local was_active_view = core.active_view
  MessageBox.warning(
    "Replace All",
    string.format("Will replace %d instance%s of %q with %q.", count, count == 1 and "" or "s", text, replacement),
    function(_, button_id)
      if button_id == 1 then
        perform_replace_all(matches, replacement)
      end
      if was_active_view then core.set_active_view(was_active_view) end
    end,
    MessageBox.BUTTONS_OK_CANCEL
  )
end

local function set_find_widget_focus(field)
  if not find_active or not replace_active then return end
  if replace_focus == field then return end
  if replace_focus == "find" then
    last_text = core.command_view:get_text()
    replace_focus = "replace"
    core.command_view:set_text(replace_text or "")
  else
    replace_text = core.command_view:get_text()
    replace_focus = "find"
    core.command_view:set_text(last_text or "")
  end
end

local function insert_unique(t, v)
  local n = #t
  for i = 1, n do
    if t[i] == v then
      table.remove(t, i)
      break
    end
  end
  table.insert(t, 1, v)
end

local function find(label, search_fn, as_replace)
  if find_active and core.active_view:is(CommandView) and last_view then
    if replace_active and replace_focus == "replace" then
      replace_text = core.command_view:get_text()
    else
      last_text = core.command_view:get_text()
    end
    if as_replace then
      replace_active = true
      replace_focus = "find"
      core.command_view:set_text(last_text or "")
    end
    return
  end

  find_label = label
  last_view, last_sel = core.active_view,
    { core.active_view.doc:get_selection() }
  local text = last_view.doc:get_text(table.unpack(last_sel))
  found_expression = false
  last_fn, last_text = search_fn, text
  replace_active = as_replace or false
  replace_text = ""
  replace_focus = "find"

  find_info_text = ""
  find_info_error = false
  find_active = true

  core.command_view:enter(label, {
    text = text,
    select_text = true,
    show_suggestions = false,
    submit = function(text)
      if replace_active and replace_focus == "replace" then
        replace_text = text
        replace_current_match()
        return
      end
      insert_unique(core.previous_find, text)
      find_active = false
      replace_active = false
      if found_expression then
        last_fn, last_text = search_fn, text
      else
        clear_find_state(last_view.doc)
        core.error("Couldn't find %q", text)
        last_view.doc:set_selection(table.unpack(last_sel))
        last_view:scroll_to_make_visible(table.unpack(last_sel))
      end
    end,
    suggest = function(text)
      if replace_active and replace_focus == "replace" then
        replace_text = text
      else
        update_preview(last_sel, search_fn, text)
        last_fn, last_text = search_fn, text
      end
      return core.previous_find
    end,
    cancel = function(explicit)
      find_active = false
      replace_active = false
      clear_find_state(last_view.doc)
      if explicit then
        last_view.doc:set_selection(table.unpack(last_sel))
        last_view:scroll_to_make_visible(table.unpack(last_sel))
      end
    end
  })
end

local find_search_fn = function(d, line, col, text, sensitive, regex_enabled, reverse)
  local opt = { wrap = true, no_case = not sensitive, regex = regex_enabled, reverse = reverse }
  return search.find(d, line, col, text, opt)
end

local function find_text_command()
  find("Find Text", find_search_fn, false)
end

local function replace_text_command()
  find("Find Text", find_search_fn, true)
end

local function valid_for_finding()
  -- Allow using repeat/previous while the command view is focused.
  if core.active_view:is(CommandView) and last_view then
    return true, last_view
  end
  return is_searchable_docview(core.active_view), core.active_view
end

command.add(function()
  return is_searchable_docview(core.active_view), core.active_view
end, {
  ["find-replace:find"] = find_text_command,
  ["find-replace:replace"] = replace_text_command,
  ["user:find"] = find_text_command,
})

command.add(valid_for_finding, {
  ["find-replace:repeat-find"] = function(dv)
    if not last_fn then
      core.error("No find to continue from")
    else
      last_view = dv
      last_sel = { dv.doc:get_selection() }
      update_preview(last_sel, last_fn, last_text, false)
      if not found_expression then core.error("Couldn't find %q", last_text) end
    end
  end,

  ["find-replace:previous-find"] = function(dv)
    if not last_fn then
      core.error("No find to continue from")
    else
      last_view = dv
      last_sel = { dv.doc:get_selection() }
      update_preview(last_sel, last_fn, last_text, true)
      if not found_expression then core.error("Couldn't find %q", last_text) end
    end
  end,
})

local function find_commandview_active()
  return core.active_view:is(CommandView) and find_active
end

command.add(find_commandview_active, {
  ["find-replace:replace"] = replace_text_command,

  ["user:find-field-next"] = function()
    if replace_active and replace_focus == "replace" then replace_text = core.command_view:get_text() end
    last_text = current_find_text()
    if last_fn and last_text ~= "" then
      update_preview(last_sel, last_fn, last_text, false)
    else
      update_find_label(last_text)
    end
  end,

  ["user:find-field-previous"] = function()
    if replace_active and replace_focus == "replace" then replace_text = core.command_view:get_text() end
    last_text = current_find_text()
    if last_fn and last_text ~= "" then
      update_preview(last_sel, last_fn, last_text, true)
    else
      update_find_label(last_text)
    end
  end,

  ["user:find-field-add-next"] = function()
    add_find_match_to_selection(false)
  end,

  ["user:find-field-add-previous"] = function()
    add_find_match_to_selection(true)
  end,

  ["user:find-toggle-replace-field"] = function()
    if replace_active then
      set_find_widget_focus(replace_focus == "find" and "replace" or "find")
    end
  end,

  ["user:find-submit-or-replace"] = function()
    if replace_active and replace_focus == "replace" then
      replace_text = core.command_view:get_text()
      replace_current_match()
    else
      core.command_view:submit()
    end
  end,

  ["user:find-replace-all-confirm"] = function()
    if replace_active then
      confirm_replace_all()
    end
  end,

  ["user:find-close"] = function()
    find_active = false
    replace_active = false
    -- Treat closing the find field as accepting the current previewed result:
    -- close the CommandView, return focus to the editor, and keep the current
    -- match selection instead of restoring the pre-search caret.
    clear_find_state(last_view and last_view.doc)
    core.command_view:exit(true)
  end,
})

-- search_ui also binds ctrl+f and was taking precedence. Replace the shortcut
-- outright so Ctrl+F opens this local CommandView-based find.
keymap.add_direct {
  ["ctrl+f"] = "find-replace:find",
  ["ctrl+r"] = "find-replace:replace",
}

keymap.add {
  ["up"] = { "user:find-field-previous", "command:select-previous", "doc:move-to-previous-line" },
  ["down"] = { "user:find-field-next", "command:select-next", "doc:move-to-next-line" },
  ["shift+up"] = { "user:find-field-add-previous", "doc:select-to-previous-line" },
  ["shift+down"] = { "user:find-field-add-next", "doc:select-to-next-line" },
  ["tab"] = { "user:find-toggle-replace-field", "command:complete", "doc:indent" },
  ["return"] = { "user:find-submit-or-replace", "command:submit", "doc:newline", "dialog:select" },
  ["keypad enter"] = { "user:find-submit-or-replace", "command:submit", "doc:newline", "dialog:select" },
  ["ctrl+return"] = { "user:find-replace-all-confirm" },
}

command.add("core.commandview", {
  ["find-replace:toggle-sensitivity"] = function()
    case_sensitive = not case_sensitive
    if last_sel then update_preview(last_sel, last_fn, last_text) end
  end,

  ["find-replace:toggle-regex"] = function()
    find_regex = not find_regex
    if last_sel then update_preview(last_sel, last_fn, last_text) end
  end,
})

local function prioritize_key(stroke, cmd)
  keymap.unbind(stroke, cmd)
  local list = keymap.map[stroke] or {}
  table.insert(list, 1, cmd)
  keymap.map[stroke] = list
  keymap.reverse_map[cmd] = keymap.reverse_map[cmd] or {}
  table.insert(keymap.reverse_map[cmd], stroke)
end

local function install_find_shortcut_override()
  if config.plugins.search_ui then
    config.plugins.search_ui.replace_core_find = false
  end
  command.add(function()
    return is_searchable_docview(core.active_view), core.active_view
  end, {
    ["find-replace:find"] = find_text_command,
    ["user:find"] = find_text_command,
  })
  command.add(function()
    if find_commandview_active() then return true end
    return is_searchable_docview(core.active_view), core.active_view
  end, {
    ["find-replace:replace"] = replace_text_command,
  })
  keymap.add_direct {
    ["ctrl+f"] = "find-replace:find",
    ["ctrl+r"] = "find-replace:replace",
  }
  prioritize_key("escape", "user:find-close")
  prioritize_key("tab", "user:find-toggle-replace-field")
  prioritize_key("return", "user:find-submit-or-replace")
  prioritize_key("keypad enter", "user:find-submit-or-replace")
  prioritize_key("ctrl+return", "user:find-replace-all-confirm")
end

-- Some bundled plugins, notably search_ui, register after the user module in
-- certain startup paths. Re-apply our local find override once after startup so
-- Ctrl+F cannot fall through to search_ui's TextBox, where Up/Down move the
-- caret instead of navigating matches.
core.intellij_find_install_shortcut_override = install_find_shortcut_override
install_find_shortcut_override()
core.add_thread(function()
  coroutine.yield(0.1)
  install_find_shortcut_override()
end)
