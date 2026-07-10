local core = require "core"
local vault_index = require "core.markdown.vault_index"

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
  local text = (view.doc.lines[line] or ""):gsub("\n$", "")
  local col1 = open_wikilink_start(text, col)
  if not col1 then return nil end
  local partial = text:sub(col1 + 2, col - 1)
  if partial:find("|", 1, true) then return nil end

  local mode, query
  if partial:sub(1, 2) == "##" then
    mode, query = "global_heading", partial:sub(3)
  elseif partial:sub(1, 1) == "#" then
    mode, query = "current_heading", partial:sub(2)
  elseif partial:sub(1, 2) == "^^" then
    mode, query = "global_block", partial:sub(3)
  elseif partial:sub(1, 1) == "^" then
    mode, query = "current_block", partial:sub(2)
  else
    mode, query = "note", partial
  end
  local col2 = text:sub(col, col + 1) == "]]" and col + 2 or col
  return {
    line = line,
    col1 = col1,
    col2 = col2,
    mode = mode,
    query = query,
  }
end

function completion.apply(view, target)
  local context = completion.context(view)
  if not context then return false end
  view:set_selection_state({
    selections = { context.line, context.col1, context.line, context.col2 },
    last_selection = 1,
  })
  view:with_selection_state(function()
    view.doc:text_input("[[" .. target .. "]]", false)
  end)
  core.log_quiet("Markdown link completion inserted %s", target)
  return true
end

function completion.symbols(view)
  local context = completion.context(view)
  if not context then return nil, "caret is not in an incomplete Wikilink" end
  local path = view.doc.abs_filename or view.doc.filename
  local index = path and vault_index.index_for_path(path)
  if not index then return nil, "index unavailable" end
  if index.status ~= "ready" then
    index:ensure("link-completion")
    return nil, "index pending"
  end
  local candidates = index:completion_candidates(context.mode, context.query, path, 200)
  if #candidates == 0 then return nil, "no candidates" end

  local items = {}
  for i, candidate in ipairs(candidates) do
    local label = candidate.text
    if items[label] then label = label .. " — " .. tostring(candidate.rel_path or i) end
    items[label] = {
      info = candidate.kind,
      data = candidate,
      onselect = function(_, item)
        return completion.apply(view, item.data.target)
      end,
    }
  end
  return {
    name = "markdown-live-link-completion",
    files = ".*",
    items = items,
  }
end

local provider_registered = false

function completion.ensure_provider()
  if provider_registered then return true end
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  if not ok or not autocomplete.add_provider then return false end
  autocomplete.add_provider("markdown-live-links", function(view)
    if not (view and view.__markdown_live_attached) then return nil end
    local symbols = completion.symbols(view)
    if symbols then return symbols, { force_open = true } end
  end)
  provider_registered = true
  return true
end

function completion.open(view)
  local symbols, err = completion.symbols(view)
  if not symbols then return false, err end
  local ok, autocomplete = pcall(require, "plugins.autocomplete")
  if not ok then return false, "autocomplete unavailable" end
  autocomplete.complete(symbols)
  return true
end

return completion
