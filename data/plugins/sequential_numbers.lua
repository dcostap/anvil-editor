-- mod-version:3
-- Insert sequential numbers at each cursor/selection using GlobalPromptBar prompts.

local core = require "core"
local command = require "core.command"
local DocView = require "core.docview"

local function is_docview(v)
  return v and v.extends and v:extends(DocView) and v.doc
end

local function parse_number(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  return tonumber(text)
end

local function number_text(n)
  if n == math.floor(n) then return string.format("%.0f", n) end
  return tostring(n)
end

local function insert_numbers(dv, initial, stride)
  if dv.can_edit and not dv:can_edit("insert sequential numbers", { warn = true }) then return end
  local doc = dv.doc
  local selections, final_by_idx = {}, {}
  for idx, line1, col1, line2, col2 in doc:get_selections(true) do
    selections[#selections + 1] = {
      idx = idx,
      line1 = line1,
      col1 = col1,
      line2 = line2,
      col2 = col2,
      text = number_text(initial + (#selections * stride)),
    }
    final_by_idx[idx] = "end"
  end

  if #selections == 0 then return end
  doc:apply_edits(selections, {
    type = "replace",
    selections = doc:selections_after_edits(selections, final_by_idx),
    last_selection = doc.last_selection,
    merge_cursors = false,
  })
end

local function prompt_stride(dv, initial)
  core.global_prompt_bar:enter("Sequential Numbers Stride", {
    text = "1",
    select_text = true,
    show_suggestions = false,
    validate = function(text)
      return parse_number(text) ~= nil
    end,
    submit = function(text)
      if not is_docview(dv) then return end
      if dv.can_edit and not dv:can_edit("insert sequential numbers", { warn = true }) then return end
      local stride = parse_number(text)
      if not stride then return end
      dv:with_selection_state(function()
        insert_numbers(dv, initial, stride)
      end)
    end,
  })
end

command.add(function()
  if not is_docview(core.active_view) then return false end
  return true, core.active_view
end, {
  ["doc:insert-sequential-numbers-on-cursors"] = function(dv)
    if dv.can_edit and not dv:can_edit("insert sequential numbers", { warn = true }) then return end
    core.global_prompt_bar:enter("Sequential Numbers Initial", {
      text = "0",
      select_text = true,
      show_suggestions = false,
      validate = function(text)
        return parse_number(text) ~= nil
      end,
      submit = function(text)
        if not is_docview(dv) then return end
        if dv.can_edit and not dv:can_edit("insert sequential numbers", { warn = true }) then return end
        local initial = parse_number(text)
        if not initial then return end
        prompt_stride(dv, initial)
      end,
    })
  end,
})
