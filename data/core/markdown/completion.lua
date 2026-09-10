local core = require "core"
local vault_index = require "core.markdown.vault_index"
local file_completion = require "core.markdown.file_completion"

local completion = {}

local function primary_caret(view)
  local state = view and view.get_selection_state and view:get_selection_state()
  local selections = state and state.selections
  if not selections or #selections ~= 4 then return nil end
  local line1, col1, line2, col2 = selections[1], selections[2], selections[3], selections[4]
  if line1 ~= line2 or col1 ~= col2 then return nil end
  return line1, col1
end

local function open_wikilink_start(text, col)
  local start, cursor = nil, 1
  local before = text:sub(1, col - 1)
  while cursor <= #before do
    local open = before:find("[[", cursor, true)
    local close = before:find("]]", cursor, true)
    if open and (not close or open < close) then
      start = open
      cursor = open + 2
    elseif close then
      start = nil
      cursor = close + 2
    else
      break
    end
  end
  return start
end

function completion.context(view)
  local line, col = primary_caret(view)
  if not line then return nil end
  local text = (view.buffer.lines[line] or ""):gsub("\n$", "")
  local col1 = open_wikilink_start(text, col)
  if not col1 then return file_completion.context(text, line, col) end
  local partial = text:sub(col1 + 2, col - 1)
  if partial:find("|", 1, true) then return nil end

  local mode, query, note_target
  if partial:sub(1, 2) == "##" then
    mode, query = "global_heading", partial:sub(3)
  elseif partial:sub(1, 1) == "#" then
    mode, query = "current_heading", partial:sub(2)
  elseif partial:sub(1, 2) == "^^" then
    mode, query = "global_block", partial:sub(3)
  elseif partial:sub(1, 1) == "^" then
    mode, query = "current_block", partial:sub(2)
  elseif partial:find("#", 1, true) then
    note_target, query = partial:match("^(.-)#(.*)$")
    mode = "current_heading"
    if query:sub(1, 1) == "^" then
      mode, query = "current_block", query:sub(2)
    end
  else
    mode, query = "note", partial
  end
  local close = text:find("]]", col, true)
  local target_end = close or #text + 1
  local alias_start = text:find("|", col, true)
  local alias = alias_start and alias_start < target_end and text:sub(alias_start, target_end - 1) or nil
  return {
    line = line,
    col1 = col1,
    col2 = close and close + 2 or #text + 1,
    mode = mode,
    query = query,
    query_col = col - #query,
    note_target = note_target,
    alias = alias,
  }
end

function completion.apply(view, target, is_directory)
  local context = completion.context(view)
  if not context then return false end
  if context.alias then target = target:match("^[^|]*") .. context.alias end
  local text, target_end
  if context.mode == "file" then
    text, target_end = file_completion.replacement(context, target)
  else
    text = "[[" .. target .. "]]"
  end
  local result = view:with_selection_state(function()
    local buffer = view.buffer
    local edits = {{
      line1 = context.line, col1 = context.col1,
      line2 = context.line, col2 = context.col2,
      text = text, idx = 1,
    }}
    local selections = buffer:selections_after_edits(edits, { "end" })
    if is_directory then
      selections = { context.line, context.col1 + target_end, context.line, context.col1 + target_end }
    end
    return buffer:apply_edits(edits, {
      type = "replace", merge_undo = false, allow_selection_only = true,
      selections = selections,
      last_selection = 1,
    })
  end)
  if result.applied then core.log_quiet("Markdown link completion inserted %s", target) end
  return result.applied
end

function completion.get_completions(view)
  if not require("core.markdown.live_render").is_markdown_buffer(view.buffer) then return nil end
  local context = completion.context(view)
  if not context then return nil end
  context.items = {}
  local path = view.buffer.abs_filename or view.buffer.filename
  if not path then return context end
  local candidates
  if context.mode == "file" then
    candidates = file_completion.candidates(context, path)
  else
    local index = vault_index.index_for_path(path)
    if not index:can_resolve() then
      index:ensure("link-completion")
      return context
    end
    local target_path = path
    if context.note_target then
      local resolution = index:resolve(context.note_target, path)
      if resolution.status ~= "resolved" or resolution.kind ~= "note" then return context end
      target_path = resolution.path
    end
    candidates = index:completion_candidates(context.mode, context.query, target_path, 200)
  end

  for _, candidate in ipairs(candidates) do
    if context.note_target then
      candidate.target = context.note_target
        .. (context.mode == "current_block" and "#" or "") .. candidate.target
    end
    context.items[#context.items + 1] = {
      text = candidate.text,
      info = candidate.line and candidate.rel_path .. ":" .. candidate.line or candidate.kind,
      icon = candidate.kind,
      data = candidate,
      source_path = candidate.path,
      source_line = candidate.line or 1,
      source_col = 1,
      onselect = function(_, item)
        return completion.apply(view, item.data.target, item.data.directory)
      end,
    }
  end
  return context
end

local provider_registered = false

function completion.ensure_provider()
  if provider_registered then return true end
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  if not ok or not autocomplete.add_provider then return false end
  autocomplete.add_provider("markdown-live-links", completion.get_completions)
  provider_registered = true
  return true
end

function completion.open(view)
  if not completion.context(view) then return false, "caret is not in a link target" end
  if not completion.ensure_provider() then return false, "autocomplete unavailable" end
  require("plugins.autocomplete").trigger()
  return true
end

return completion
