-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local MarkdownView = require "core.markdownview"
local RootPanel = require "core.rootpanel"
local project_paths = require "core.project_paths"
local symbol_icons = require "core.symbol_icons"
local tree_sitter_registry = require "core.treesitter.registry"

---@class plugins.autocomplete.symbolinfo
---Text value of the symbol displayed on the autocomplete box.
---@field text string
---Additional information displayed on autocomplete box, eg: item type.
---@field info? string
---Rich row preview containing the displayed declaration or contextual symbol.
---@field preview_text? string
---Inclusive byte span of `text` within `preview_text`.
---@field preview_name_span? integer[]
---Whether `info` is shown beside a rich preview.
---@field preview_show_info? boolean
---Containing symbol used to build a contextual preview.
---@field preview_context? string
---Signature or value suffix used to build a contextual preview.
---@field preview_detail? string
---Context prefix inserted before the completed symbol unless it is already present.
---@field completion_prefix? string
---Name of a registered icon.
---@field icon? string
---Description shown when the symbol is hovered on the autocomplete box.
---@field desc? string
---An optional callback called once when the symbol is hovered.
---@field onhover? fun(idx:integer,item:plugins.autocomplete.symbolinfo)
---An optional callback called when the symbol is selected.
---@field onselect? fun(idx:integer,item:plugins.autocomplete.symbolinfo):boolean
---Optional data that can be used for onhover and onselect callbacks.
---@field data? any

---@class plugins.autocomplete.symbols
---Name of the symbols table.
---@field name string
---Lua patterns which match the files where the symbols are valid.
---@field files string | table<integer,string>
---List of symbols that belong to this symbols table.
---@field items table<string,plugins.autocomplete.symbolinfo|string|false|nil>

---@class plugins.autocomplete.map
---Lua patterns which match the files where the symbols are valid.
---@field files string | table<integer,string>
---List of symbols that belong to this symbols table.
---@field items table<string,plugins.autocomplete.symbolinfo>

---@class plugins.autocomplete.icon
---@field char string
---@field font renderer.font
---@field color string | renderer.color

---@alias plugins.autocomplete.onclose fun(doc:core.doc,item:plugins.autocomplete.symbolinfo)

---@class plugins.autocomplete.cachedata
---@field last_change_id number
---@field symbols table<string,boolean>

---Symbols cache of all open documents
---@type table<core.doc,plugins.autocomplete.cachedata>
local cache = setmetatable({}, { __mode = "k" })

---Configuration options for `autocomplete` plugin.
---@class config.plugins.autocomplete
---Amount of characters that need to be written for autocomplete
---@field min_len integer
---The max amount of scrollable items
---@field max_suggestions integer
---Maximum amount of symbols to cache per document
---@field max_symbols integer
---Maximum length of document symbols to cache and render in autocomplete.
---@field max_symbol_length integer
---Which symbols to show on the suggestions list: global, local, related, none
---@field suggestions_scope "global" | "local" | "related" | "none"
---Font size of the description box
---@field desc_font_size number
---Do not show the icons associated to the suggestions
---@field hide_icons boolean
---Position where icons will be displayed on the suggestions list
---@field icon_position "left" | "right"
---Do not show the additional information related to a suggestion
---@field hide_info boolean
config.plugins.autocomplete.config_spec = {
    name = "Autocomplete",
    {
      label = "Minimum Length",
      description = "Amount of characters that need to be written for autocomplete to popup.",
      path = "min_len",
      type = "number",
      default = 3,
      min = 1,
      max = 5
    },
    {
      label = "Maximum Suggestions",
      description = "The maximum amount of scrollable items.",
      path = "max_suggestions",
      type = "number",
      default = 20,
      min = 10,
      max = 10000
    },
    {
      label = "Maximum Symbols",
      description = "Maximum amount of symbols to cache per document.",
      path = "max_symbols",
      type = "number",
      default = 4000,
      min = 1000,
      max = 10000
    },
    {
      label = "Maximum Symbol Length",
      description = "Maximum length of document symbols to cache and render in autocomplete.",
      path = "max_symbol_length",
      type = "number",
      default = 40,
      min = 8,
      max = 256
    },
    {
      label = "Suggestions Scope",
      description = "Which symbols to show on the suggestions list.",
      path = "suggestions_scope",
      type = "selection",
      default = "related",
      values = {
        {"All Documents", "global"},
        {"Current Document", "local"},
        {"Related Documents", "related"},
        {"Known Symbols", "none"}
      },
      on_apply = function(value)
        if value == "global" then
          for _, doc in ipairs(core.docs) do
            if cache[doc] then cache[doc] = nil end
          end
        end
      end
    },
    {
      label = "Description Font Size",
      description = "Font size of the description box.",
      path = "desc_font_size",
      type = "number",
      default = 15,
      min = 8
    },
    {
      label = "Hide Icons",
      description = "Do not show icons on the suggestions list.",
      path = "hide_icons",
      type = "toggle",
      default = false
    },
    {
      label = "Icons Position",
      description = "Position to display icons on the suggestions list.",
      path = "icon_position",
      type = "selection",
      default = "left",
      values = {
        {"Left", "left"},
        {"Right", "Right"}
      }
    },
    {
      label = "Hide Items Info",
      description = "Do not show the additional info related to each suggestion.",
      path = "hide_info",
      type = "toggle",
      default = false
    }
  }

---@class plugins.autocomplete
local autocomplete = {}

---@type table<string,plugins.autocomplete.map>
autocomplete.map = {}
---@type table<string,plugins.autocomplete.map>
autocomplete.map_manually = {}
---@type nil | plugins.autocomplete.onclose
autocomplete.on_close = nil
---@type table<string,plugins.autocomplete.icon>
autocomplete.icons = {}
---@type table<string,fun(view:core.docview,opts:table):plugins.autocomplete.symbols?,table? >
autocomplete.providers = {}
local provider_maps = {}

-- Flag that indicates if the autocomplete box was manually triggered
-- with the autocomplete.complete() function to prevent the suggestions
-- from getting cluttered with arbitrary document symbols by using the
-- autocomplete.map_manually table.
local triggered_manually = false

local mt = { __tostring = function(t) return t.text end }

---Register a symbols table used for autocompletion.
---@param t plugins.autocomplete.symbols
---@param manually_triggered? boolean
function autocomplete.add_provider(id, fn)
  assert(type(id) == "string" and id ~= "", "autocomplete provider id is required")
  assert(type(fn) == "function", "autocomplete provider must be a function")
  autocomplete.providers[id] = fn
end

function autocomplete.remove_provider(id)
  if not autocomplete.providers[id] then return false end
  autocomplete.providers[id] = nil
  return true
end

function autocomplete.add(t, manually_triggered)
  local items = {}
  for text, info in pairs(t.items) do
    if type(info) == "table" then
      table.insert(
        items,
        setmetatable(
          {
            text = text,
            info = info.info,
            icon = info.icon,
            desc = info.desc,
            onhover = info.onhover,
            onselect = info.onselect,
            data = info.data
          },
          mt
        )
      )
    else
      info = (type(info) == "string") and info
      table.insert(items, setmetatable({ text = text, info = info }, mt))
    end
  end

  if not manually_triggered then
    autocomplete.map[t.name] =  { files = t.files or ".*", items = items }
  else
    autocomplete.map_manually[t.name] =  { files = t.files or ".*", items = items }
  end
end

---Same as translate.start_of_word but uses `symbol_non_word_chars` instead.
---@param doc core.doc
---@param line integer
---@param col integer
---@return integer line
---@return integer col
local ROW_PREVIEW_MAX_CHARS = 90

local function max_symbol_length()
  return math.max(1, tonumber(config.plugins.autocomplete.max_symbol_length) or 256)
end

local function suggestion_text(item)
  if type(item) == "table" then
    return tostring(item.insert_text or item.label or item.text or "")
  end
  return tostring(item or "")
end

local function suggestion_within_length(item)
  return #suggestion_text(item) <= max_symbol_length()
end

local function display_text(text, max_len)
  text = tostring(text or "")
  max_len = max_len or max_symbol_length()
  if #text <= max_len then return text end
  if max_len <= 1 then return "…" end
  return text:sub(1, max_len - 1) .. "…"
end

local function translate_start_of_word(doc, line, col)
  while true do
    local line2, col2 = doc:position_offset(line, col, -1)
    local char = doc:get_char(line2, col2)
    if doc:get_non_word_chars(true):find(char, nil, true)
    or line == line2 and col == col2 then
      break
    end
    line, col = line2, col2
  end
  return line, col
end

---Retrieve the current document partial symbol.
---@return string partial
---@return integer line1
---@return integer col1
---@return integer line2
---@return integer col2
function autocomplete.get_partial_symbol()
  local doc = core.active_view.doc
  local line2, col2 = doc:get_selection()
  local line1, col1 = doc:position_offset(line2, col2, translate_start_of_word)
  return doc:get_text(line1, col1, line2, col2), line1, col1, line2, col2
end

--
-- Thread that scans open document symbols and cache them
--
local global_symbols = {}

core.add_thread(function()
  ---@param doc core.doc
  ---@return table<string,string>
  local function load_syntax_symbols(doc)
    return {}
  end

  ---@param doc core.doc
  ---@return table<string,boolean>
  local function get_symbols(doc)
    local s = {}
    local syntax_symbols = load_syntax_symbols(doc)
    local max_symbols = config.plugins.autocomplete.max_symbols
    if doc.disable_symbols then return syntax_symbols end
    local i = 1
    local symbols_count = 0
    local scanned_symbols = 0
    local symbol_pattern = doc:get_symbol_pattern()
    local slice_start = system.get_time()
    local slice_budget = 0.001
    while i <= #doc.lines do
      for sym in doc.lines[i]:gmatch(symbol_pattern) do
        scanned_symbols = scanned_symbols + 1
        if scanned_symbols % 200 == 0 and system.get_time() - slice_start >= slice_budget then
          coroutine.yield()
          slice_start = system.get_time()
        end
        if #sym <= max_symbol_length() and not s[sym] and not syntax_symbols[sym] then
          symbols_count = symbols_count + 1
          if symbols_count > max_symbols then
            s = nil
            doc.disable_symbols = true
            local filename_message
            if doc.filename then
              filename_message = doc.filename
            else
              filename_message = "unnamed"
            end
            core.warn(
              "Too many symbols in '%s': stopping auto-complete for this document "
                .. "according to config.plugins.autocomplete.max_symbols.",
              filename_message
            )
            collectgarbage('collect')
            return {}
          end
          s[sym] = true
        end
      end
      i = i + 1
      if i % 25 == 0 and system.get_time() - slice_start >= slice_budget then
        coroutine.yield()
        slice_start = system.get_time()
      end
    end
    return s
  end

  ---@param doc core.doc
  ---@return boolean
  local function cache_is_valid(doc)
    local c = cache[doc]
    return c and c.last_change_id == doc:get_change_id()
  end

  while true do
    local symbols = {}

    -- lift all symbols from all docs
    for _, doc in ipairs(core.docs) do
      -- update the cache if the doc has changed since the last iteration
      if not cache_is_valid(doc) then
        cache[doc] = {
          last_change_id = doc:get_change_id(),
          symbols = get_symbols(doc)
        }
      end
      -- update symbol set with doc's symbol set
      if config.plugins.autocomplete.suggestions_scope == "global" then
        for sym in pairs(cache[doc].symbols) do
          symbols[sym] = true
        end
      end
      coroutine.yield()
    end

    -- update global symbols list
    if config.plugins.autocomplete.suggestions_scope == "global" then
      global_symbols = symbols
    end

    -- wait for next scan
    local valid = true
    while valid do
      coroutine.yield(1)
      for _, doc in ipairs(core.docs) do
        if not cache_is_valid(doc) then
          valid = false
          break
        end
      end
    end

  end
end)


local partial = ""
local suggestions_offset = 1
local suggestions_idx = 1
local suggestions = {}
local last_line, last_col
local last_doc
local pending_deletion_doc

local function display_info(suggestion)
  local info = suggestion and suggestion.info
  if info == "normal" then return nil end
  return info
end

local function display_icon(suggestion)
  if suggestion and suggestion.no_icon then return nil end
  return suggestion and suggestion.icon
end

local function display_icon_width(suggestion, row_height)
  local icon = display_icon(suggestion)
  if not icon then return 0 end
  if symbol_icons.resolve_kind(icon) then
    return symbol_icons.size_for_row(row_height)
  end
  local registered = autocomplete.icons[icon]
  return registered and registered.font:get_width(registered.char) or 0
end

local function draw_display_icon(suggestion, x, y, width, row_height)
  local icon = display_icon(suggestion)
  if not icon then return false end
  local icon_width = display_icon_width(suggestion, row_height)
  if icon_width <= 0 then return false end
  local draw_x = x + math.max(0, math.floor((width - icon_width) / 2))
  if symbol_icons.resolve_kind(icon) then
    return symbol_icons.draw(icon, draw_x, y, row_height, icon_width)
  end

  local registered = autocomplete.icons[icon]
  if not registered then return false end
  local color = type(registered.color) == "string" and style.syntax[registered.color] or registered.color
  common.draw_text(registered.font, color or style.dim, registered.char, "center", x, y, width, row_height)
  return true
end

local function row_text_parts(suggestion, hide_info, max_chars)
  local label = tostring(suggestion and suggestion.text or "")
  local info = not hide_info and display_info(suggestion) or nil
  info = info and tostring(info) or nil
  if max_chars then
    if info and info ~= "" then
      local sep_len = 1
      local info_len = max_chars - #label - sep_len
      if info_len > 0 then
        info = display_text(info, info_len)
      else
        label = display_text(label, max_chars)
        info = nil
      end
    else
      label = display_text(label, max_chars)
    end
  end
  return label, info
end

local function row_text_width(font, info_font, suggestion, hide_info, max_chars)
  if suggestion and suggestion.preview_text then
    local width = style.get_small_font(font):get_width(display_text(suggestion.preview_text, max_chars))
    local info = suggestion.preview_show_info and not hide_info and display_info(suggestion) or nil
    if info and info ~= "" then width = width + style.padding.x + info_font:get_width(info) end
    return width
  end

  local label, info = row_text_parts(suggestion, hide_info, max_chars)
  local width = font:get_width(label)
  if info and info ~= "" then
    width = width + style.padding.x + info_font:get_width(info)
  end
  return width
end

local update_suggestions
local lsp_completion_items = nil
local lsp_completion_context = nil
local force_basic_suggestions = true
local native_fuzzy_ok, native_fuzzy = nil, nil

local function lsp_completion_module()
  local ok, completion = pcall(require, "core.lsp.completion")
  return ok and completion or nil
end

local function tree_sitter_locals_module()
  local ok, locals = pcall(require, "core.treesitter.locals")
  return ok and locals or nil
end

local function tree_sitter_symbol_index_module()
  local ok, symbols = pcall(require, "core.treesitter.symbol_index")
  return ok and symbols or nil
end

local function project_completion_language_ids(doc)
  local path = doc and (doc.abs_filename or doc.filename)
  if not path or path == "" then return nil end
  local resolved = project_paths.resolve(path)
  if not resolved or not resolved.flags or resolved.flags.autocomplete == false then return nil end
  local ts = doc.treesitter
  local language_id = ts and ts.language_id
  if not language_id then return nil end
  local language = ts.language or tree_sitter_registry.get(path, "")
  local configured = language and language.autocomplete_languages
  if configured and #configured > 0 then
    local ids = {}
    for i, id in ipairs(configured) do ids[i] = id end
    return ids
  end
  return { language_id }
end

local function member_completion_receiver(doc)
  if not doc or not core.active_view or core.active_view.doc ~= doc then return nil end
  local _, line1, col1 = autocomplete.get_partial_symbol()
  local language = doc.treesitter and doc.treesitter.language
  local separators = language and language.member_completion_separators or { "." }
  local separator_line, separator_col, separator_length
  for _, separator in ipairs(separators) do
    separator = tostring(separator or "")
    if separator ~= "" and (not separator_length or #separator > separator_length) then
      local start_line, start_col = doc:position_offset(line1, col1, -#separator)
      if start_line == line1 and doc:get_text(start_line, start_col, line1, col1) == separator then
        separator_line, separator_col, separator_length = start_line, start_col, #separator
      end
    end
  end
  if not separator_line then return nil end
  local receiver_line, receiver_col = doc:position_offset(separator_line, separator_col, translate_start_of_word)
  if receiver_line ~= separator_line or receiver_col == separator_col then return nil end
  local receiver = doc:get_text(receiver_line, receiver_col, separator_line, separator_col)
  return receiver ~= "" and receiver or nil
end

local function valid_preview_span(name, text, span)
  if type(span) ~= "table" or not span[1] or not span[2] then return false end
  text = tostring(text or "")
  local first, last = tonumber(span[1]), tonumber(span[2])
  return first and last and first >= 1 and last >= first and last <= #text
     and text:sub(first, last) == tostring(name or "")
end

local function project_symbol_preview(symbol)
  local name = tostring(symbol and symbol.name or "")
  local parent = symbol and symbol.parent_name and tostring(symbol.parent_name) or ""
  local signature = symbol and symbol.signature and tostring(symbol.signature) or ""
  if parent ~= "" then
    local prefix = parent .. "."
    local detail = ""
    if signature ~= "" then
      if symbol.kind == "enum_member" then
        detail = " = " .. signature
      elseif signature:match("^[%(%[]") then
        detail = signature
      else
        detail = " " .. signature
      end
    end
    return prefix .. name .. detail, { #prefix + 1, #prefix + #name }, true, parent, detail
  end
  if valid_preview_span(name, symbol and symbol.declaration, symbol and symbol.declaration_name_span) then
    return symbol.declaration, symbol.declaration_name_span, false
  end
  return nil, nil, false
end

local function human_symbol_kind(kind)
  kind = tostring(kind or "project symbol")
  return kind:gsub("_", " ")
end

local function native_fuzzy_module()
  if native_fuzzy_ok == nil then native_fuzzy_ok, native_fuzzy = pcall(require, "fuzzy") end
  return native_fuzzy_ok and native_fuzzy or nil
end

local function has_lsp_completion(doc)
  local completion = lsp_completion_module()
  return completion and completion.has_available_client and completion.has_available_client(doc) or false
end

local function at_word_completion_position()
  return partial:match("%a") ~= nil
end

local function reset_lsp_completion_items()
  lsp_completion_items = nil
  lsp_completion_context = nil
end

local function completion_context_key(doc, line, col)
  return table.concat({ tostring(doc), tostring(doc.get_change_id and doc:get_change_id() or 0), tostring(line), tostring(col) }, ":")
end

local function set_lsp_completion_items(doc, line, col, items)
  if not lsp_completion_context or lsp_completion_context.key ~= completion_context_key(doc, line, col) then return end
  lsp_completion_items = items or {}
  update_suggestions()
  core.redraw = true
end

local function annotate_match(item, needle)
  if type(item) ~= "table" then return item end
  item.autocomplete_matches = nil
  needle = tostring(needle or "")
  if needle == "" then return item end
  local text = tostring(item.text or "")

  local fuzzy = native_fuzzy_module()
  local ok, match = false, nil
  if fuzzy and fuzzy.match then
    ok, match = pcall(function() return fuzzy.match(text, needle, { mode = "generic", spans = true }) end)
  end
  if ok and match and match.spans then
    local matches = {}
    for _, span in ipairs(match.spans or {}) do
      local first = math.max(1, tonumber(span[1]) or 1)
      local last = math.min(#text, tonumber(span[2]) or first)
      for i = first, last do matches[i] = true end
    end
    item.autocomplete_matches = matches
    return item
  end

  local lower_text = text:lower()
  local lower_needle = needle:lower()
  local matches = {}
  local search_from = 1
  for i = 1, #lower_needle do
    local ch = lower_needle:sub(i, i)
    local pos = lower_text:find(ch, search_from, true)
    if not pos then
      item.autocomplete_matches = nil
      return item
    end
    matches[pos] = true
    search_from = pos + 1
  end
  item.autocomplete_matches = matches
  return item
end

local function annotate_matches(items, needle)
  for _, item in ipairs(items or {}) do annotate_match(item, needle) end
  return items
end

local function completion_sort_text(item)
  return suggestion_text(item):gsub("^%s+", "")
end

local function match_stats(text, needle)
  text = tostring(text or ""):lower()
  needle = tostring(needle or ""):lower()
  if needle == "" then return nil end
  local exact = text:find(needle, 1, true)
  if exact then
    return { exact = true, first = exact, last = exact + #needle - 1, width = #needle }
  end
  local first, last
  local search_from = 1
  for i = 1, #needle do
    local pos = text:find(needle:sub(i, i), search_from, true)
    if not pos then return nil end
    first = first or pos
    last = pos
    search_from = pos + 1
  end
  return { exact = false, first = first, last = last, width = last - first + 1 }
end

local function sort_display_matches(items, needle)
  needle = tostring(needle or "")
  if needle == "" then return items end
  local original_index = {}
  for i, item in ipairs(items or {}) do original_index[item] = i end
  table.sort(items, function(a, b)
    local at = tostring(a and a.text or a)
    local bt = tostring(b and b.text or b)
    local am = match_stats(at, needle)
    local bm = match_stats(bt, needle)
    if am and bm then
      if am.exact ~= bm.exact then return am.exact end
      local ap, bp = tonumber(a and a.autocomplete_priority) or 0, tonumber(b and b.autocomplete_priority) or 0
      if ap ~= bp then return ap > bp end
      if am.width ~= bm.width then return am.width < bm.width end
      if am.first ~= bm.first then return am.first < bm.first end
      local al = completion_sort_text(a)
      local bl = completion_sort_text(b)
      if #al ~= #bl then return #al < #bl end
      if #at ~= #bt then return #at < #bt end
    elseif am or bm then
      return am ~= nil
    end
    return (original_index[a] or 0) < (original_index[b] or 0)
  end)
  return items
end

local function code_symbol_chunks(text)
  text = tostring(text or "")
  local chunks = {}
  local buf = {}
  local saw_separator = false
  local function flush()
    if #buf > 0 then
      chunks[#chunks + 1] = table.concat(buf)
      buf = {}
    end
  end

  for i = 1, #text do
    local ch = text:sub(i, i)
    local prev = i > 1 and text:sub(i - 1, i - 1) or ""
    local next_ch = i < #text and text:sub(i + 1, i + 1) or ""
    if ch == "_" or ch == "-" or ch == "." then
      saw_separator = true
      flush()
    else
      local camel_boundary = #buf > 0
        and ch:match("%u")
        and ((prev:match("%l") or prev:match("%d")) or (prev:match("%u") and next_ch:match("%l")))
      if camel_boundary then
        saw_separator = true
        flush()
      end
      buf[#buf + 1] = ch
    end
  end
  flush()

  local kept = {}
  for _, chunk in ipairs(chunks) do
    if chunk ~= "" then kept[#kept + 1] = chunk:lower() end
  end
  return kept, saw_separator
end

local function code_symbol_chunk_query(text)
  local chunks, saw_separator = code_symbol_chunks(text)
  if not saw_separator or #chunks < 2 then return nil end
  for _, chunk in ipairs(chunks) do
    if #chunk < 2 then return nil end
  end
  return table.concat(chunks, " "), chunks
end

local function score_code_chunk_match(query_chunk, candidate_chunk)
  query_chunk = tostring(query_chunk or "")
  candidate_chunk = tostring(candidate_chunk or "")
  if query_chunk == "" or candidate_chunk == "" then return nil end

  if query_chunk == candidate_chunk then return 1400 + #query_chunk * 60 end
  if candidate_chunk:sub(1, #query_chunk) == query_chunk then
    return 1150 + #query_chunk * 55 - math.max(0, #candidate_chunk - #query_chunk) * 8
  end

  local pos = #query_chunk >= 3 and candidate_chunk:find(query_chunk, 1, true) or nil
  if pos then
    return 850 + #query_chunk * 45 - (pos - 1) * 40 - math.max(0, #candidate_chunk - #query_chunk) * 4
  end

  if #query_chunk < 3 then return nil end
  local positions = {}
  local scan = 1
  for i = 1, #query_chunk do
    local p = candidate_chunk:find(query_chunk:sub(i, i), scan, true)
    if not p then return nil end
    positions[#positions + 1] = p
    scan = p + 1
  end

  local longest_run, current_run, max_gap = 1, 1, 0
  for i = 2, #positions do
    local gap = positions[i] - positions[i - 1] - 1
    max_gap = math.max(max_gap, gap)
    if gap == 0 then current_run = current_run + 1 else current_run = 1 end
    longest_run = math.max(longest_run, current_run)
  end
  local span = positions[#positions] - positions[1] + 1
  if longest_run < math.ceil(#query_chunk / 2) and (span > #query_chunk * 2 + 2 or max_gap > math.max(4, #query_chunk)) then
    return nil
  end
  return 450 + #query_chunk * 35 + longest_run * 60 - span * 10 - max_gap * 15
end

local function code_symbol_chunk_match_score(candidate, query_chunks)
  if not query_chunks or #query_chunks < 2 then return nil end
  local candidate_chunks = code_symbol_chunks(candidate)
  if #candidate_chunks == 0 then return nil end

  local used, indexes = {}, {}
  local total = 0
  for _, query_chunk in ipairs(query_chunks) do
    local best_idx, best_score
    for i, candidate_chunk in ipairs(candidate_chunks) do
      if not used[i] then
        local score = score_code_chunk_match(query_chunk, candidate_chunk)
        if score and (not best_score or score > best_score or (score == best_score and #candidate_chunk < #candidate_chunks[best_idx])) then
          best_idx, best_score = i, score
        end
      end
    end
    if not best_idx then return nil end
    used[best_idx] = true
    indexes[#indexes + 1] = best_idx
    total = total + best_score
  end

  local inversions = 0
  for i = 2, #indexes do
    if indexes[i] < indexes[i - 1] then inversions = inversions + 1 end
  end
  total = total - inversions * 180
  local average = total / #query_chunks
  if average < 700 then return nil end
  return total
end

local function fuzzy_match_with_scores(items, query)
  local fuzzy = native_fuzzy_module()
  if not fuzzy or not fuzzy.filter then
    local out = {}
    for _, item in ipairs(common.fuzzy_match(items, query, false) or {}) do out[#out + 1] = { item = item, score = 0 } end
    return out
  end

  local texts = {}
  for i, item in ipairs(items or {}) do texts[i] = suggestion_text(item) end
  local ok, matches = pcall(function()
    return fuzzy.filter(texts, query, { mode = "generic", limit = #texts, spans = false })
  end)
  if not ok or not matches then return {} end

  local out = {}
  for _, match in ipairs(matches) do
    local item = items[match.index]
    if item then out[#out + 1] = { item = item, score = match.score or 0 } end
  end
  return out
end

local desc_view
local desc_view_text
local desc_view_font
local desc_rect
local desc_font_size = config.plugins.autocomplete.desc_font_size
local previous_scale = SCALE
local desc_font = style.code_font:copy(desc_font_size * SCALE)


local function reset_suggestions(skip_close)
  suggestions_offset = 1
  suggestions_idx = 1
  suggestions = {}
  desc_rect = nil
  desc_view = nil
  desc_view_text = nil
  desc_view_font = nil

  triggered_manually = false
  force_basic_suggestions = true
  pending_deletion_doc = nil
  reset_lsp_completion_items()

  if not skip_close then
    local doc = core.active_view.doc
    if autocomplete.on_close then
      autocomplete.on_close(doc, suggestions[suggestions_idx])
      autocomplete.on_close = nil
    end
    autocomplete.map_manually = {}
  end
end

function update_suggestions()
  local doc = core.active_view.doc
  local filename = doc and doc.filename or ""

  suggestions = {}
  desc_rect = nil

  local assigned_sym = {}
  local contextual_member_count = 0

  local lsp_available = has_lsp_completion(doc)

  -- get all relevant suggestions for given filename
  local items = {}

  local function item_richness(item)
    if type(item) ~= "table" then return 0 end
    local score = 0
    if item.preview_text and item.preview_text ~= "" then score = score + 8 end
    if item.source_line and item.source_col then score = score + 4 end
    if item.autocomplete_priority then score = score + 1 end
    return score
  end

  local function add_candidate_item(item, replace_if_richer)
    if not suggestion_within_length(item) then return false end
    local key = suggestion_text(item)
    if key == "" then return false end
    local existing = assigned_sym[key]
    if existing then
      if replace_if_richer and item_richness(item) > item_richness(existing.item) then
        items[existing.index] = item
        assigned_sym[key] = { item = item, index = existing.index }
        return true
      end
      return false
    end
    items[#items + 1] = item
    assigned_sym[key] = { item = item, index = #items }
    return true
  end

  if not lsp_available and force_basic_suggestions then
    for _, v in pairs(autocomplete.map) do
      if common.match_pattern(filename, v.files) then
        for _, item in pairs(v.items) do
          add_candidate_item(item, false)
        end
      end
    end
  end

  local manual_items = {}
  if triggered_manually then
    for _, v in pairs(autocomplete.map_manually) do
      if common.match_pattern(filename, v.files) then
        for _, item in pairs(v.items) do
          if suggestion_within_length(item) then
            table.insert(manual_items, item)
          end
        end
      end
    end
  end
  if lsp_available then
    local allow_private = partial:sub(1, 1) == "_"
    for _, item in ipairs(lsp_completion_items or {}) do
      local label = suggestion_text(item):gsub("^%s+", "")
      if #label <= max_symbol_length() and (allow_private or label:sub(1, 1) ~= "_") then
        table.insert(manual_items, item)
      end
    end
  end

  -- Append the global, local or related text symbols if applicable
  local scope = config.plugins.autocomplete.suggestions_scope

  if not lsp_available and force_basic_suggestions then
    local function source_location_fields(symbol, source_doc)
      if type(symbol) ~= "table" then return nil end
      local name_start = symbol.name_range and symbol.name_range.start
      local name_end = symbol.name_range and symbol.name_range["end"]
      local path = symbol.path or symbol.abs_filename or (source_doc and (source_doc.abs_filename or source_doc.filename))
      local line = name_start and name_start.line or symbol.start_line
      local col = name_start and name_start.col or symbol.start_col
      if not line or not col then return nil end
      return {
        source_doc = source_doc,
        source_path = path,
        source_line = line,
        source_col = col,
        source_end_line = name_end and name_end.line or symbol.end_line or line,
        source_end_col = name_end and name_end.col or symbol.end_col or col,
      }
    end

    local function add_text_symbol(name, info, icon, priority, preview_text, preview_name_span, no_icon, source)
      if name and name ~= "" and #name <= max_symbol_length() then
        local item = {
          text = name,
          info = info or "normal",
          icon = icon,
          autocomplete_priority = priority,
          preview_text = preview_text,
          preview_name_span = preview_name_span,
          no_icon = no_icon,
        }
        for k, v in pairs(source or {}) do item[k] = v end
        add_candidate_item(setmetatable(item, mt), item_richness(item) > 0)
      end
    end

    local function add_cache_symbols(symbols)
      for name in pairs(symbols or {}) do add_text_symbol(name, "normal") end
    end

    local locals = tree_sitter_locals_module()
    local symbols, visible_symbols = nil, false
    if locals and locals.get_visible_document_symbols then
      local _, line1, col1, line2, col2 = autocomplete.get_partial_symbol()
      local reason
      symbols, reason = locals.get_visible_document_symbols(doc, line1, col1, line2, col2)
      visible_symbols = symbols ~= nil and reason == nil
    end
    if not visible_symbols and locals and locals.get_document_symbols then
      symbols = locals.get_document_symbols(doc)
    end

    for _, symbol in ipairs(symbols or {}) do
      add_text_symbol(
        symbol.name,
        symbol.kind or "symbol",
        symbol.kind,
        symbol.autocomplete_priority,
        symbol.completion_preview,
        symbol.completion_preview_name_span,
        false,
        source_location_fields(symbol, doc)
      )
    end

    local text_symbols = nil

    if scope == "global" then
      if visible_symbols then
        for _, d in ipairs(core.docs) do
          if d ~= doc and cache[d] and cache[d].symbols then add_cache_symbols(cache[d].symbols) end
        end
      else
        text_symbols = global_symbols
      end
    elseif scope == "local" and not visible_symbols and cache[doc] and cache[doc].symbols then
      text_symbols = cache[doc].symbols
    elseif scope == "related" then
      for _, d in ipairs(core.docs) do
        if doc.syntax == d.syntax and (d ~= doc or not visible_symbols) then
          if cache[d] and cache[d].symbols then add_cache_symbols(cache[d].symbols) end
        end
      end
    end

    add_cache_symbols(text_symbols)

    local symbol_index = tree_sitter_symbol_index_module()
    local project_language_ids = project_completion_language_ids(doc)
    if symbol_index and project_language_ids then
      local function project_item(symbol)
        local name = symbol.name
        if not name or name == "" or #name > max_symbol_length() then return nil end
        local preview_text, preview_name_span, preview_show_info, preview_context, preview_detail =
          project_symbol_preview(symbol)
        local language = tree_sitter_registry.get_by_id(symbol.language_id)
          or tree_sitter_registry.get(symbol.path or symbol.abs_filename or "", "")
        local enum_separator = language and language.enum_completion_separator
        local item = {
          text = name,
          info = preview_show_info and human_symbol_kind(symbol.kind) or (symbol.kind or "project symbol"),
          preview_text = preview_text,
          preview_name_span = preview_name_span,
          preview_show_info = preview_show_info,
          preview_context = preview_context,
          preview_detail = preview_detail,
          completion_prefix = symbol.kind == "enum_member" and preview_context and preview_context ~= ""
            and type(enum_separator) == "string" and enum_separator ~= ""
            and preview_context .. enum_separator or nil,
          icon = symbol.kind,
        }
        for k, v in pairs(source_location_fields(symbol) or {}) do item[k] = v end
        return setmetatable(item, mt)
      end

      local function query_project_symbols(query, query_opts)
        query_opts = query_opts or {}
        local project_symbols, _reason, project_status = symbol_index.workspace_symbols(query, {
          kind = "autocomplete",
          language_ids = project_language_ids,
          parent_names = query_opts.parent_names,
          limit = math.max(20, config.plugins.autocomplete.max_suggestions * 2),
          allow_stale = true,
        })
        if project_status ~= "fresh" and project_status ~= "stale" then return {} end
        return project_symbols or {}
      end

      local contextual_names = {}
      local receiver = member_completion_receiver(doc)
      if receiver then
        local contextual_symbols = {}
        if symbol_index.current_document_symbols then
          local current_symbols = symbol_index.current_document_symbols(doc, partial, {
            parent_names = { receiver },
            limit = math.max(20, config.plugins.autocomplete.max_suggestions * 2),
          })
          for _, symbol in ipairs(current_symbols or {}) do contextual_symbols[#contextual_symbols + 1] = symbol end
        end
        for _, symbol in ipairs(query_project_symbols(partial, { parent_names = { receiver } })) do
          contextual_symbols[#contextual_symbols + 1] = symbol
        end
        local active_path = common.normalize_path(doc.abs_filename or doc.filename or "")
        local active_dir = active_path ~= "" and common.dirname(active_path) or ""
        local function locality(symbol)
          local path = common.normalize_path(symbol.path or symbol.abs_filename or "")
          if path ~= "" and active_path ~= "" and common.path_equals(path, active_path) then return 2 end
          if path ~= "" and active_dir ~= "" and common.path_equals(common.dirname(path), active_dir) then return 1 end
          return 0
        end
        table.sort(contextual_symbols, function(a, b)
          local al, bl = locality(a), locality(b)
          if al ~= bl then return al > bl end
          if tostring(a.name) ~= tostring(b.name) then return tostring(a.name) < tostring(b.name) end
          return tostring(a.path or a.file or "") < tostring(b.path or b.file or "")
        end)
        for _, symbol in ipairs(contextual_symbols) do
          local name = tostring(symbol.name or "")
          if name ~= "" and not contextual_names[name] then
            local item = project_item(symbol)
            if item then
              item.autocomplete_priority = 10000 + locality(symbol)
              contextual_names[name] = true
              manual_items[#manual_items + 1] = item
              contextual_member_count = contextual_member_count + 1
            end
          end
        end
      end

      local function add_project_symbols(query)
        if not query or query == "" then return end
        for _, symbol in ipairs(query_project_symbols(query)) do
          if not contextual_names[tostring(symbol.name or "")] then
            local item = project_item(symbol)
            if item then add_candidate_item(item, item_richness(item) > 0) end
          end
        end
      end
      if partial ~= "" then
        add_project_symbols(partial)
        local chunk_query = code_symbol_chunk_query(partial)
        if chunk_query and chunk_query ~= partial then add_project_symbols(chunk_query) end
      end
    end
  end

  -- when triggered manually and first character is a punctuation, it causes
  -- none of the items to match if they don't also start with the punctuation,
  -- we remove the punctuations to ensure results with plugins like lsp
  if triggered_manually then partial = partial:gsub("^%p+", "") end

  local si = 0 -- suggestions index
  local max_items = config.plugins.autocomplete.max_suggestions

  -- we prioritize the manually added symbols
  if #manual_items > 0 then
    manual_items = sort_display_matches(annotate_matches(common.fuzzy_match(manual_items, partial, false), partial), partial)
    for i = 1, max_items do
      suggestions[i] = manual_items[i]
    end
    max_items = #suggestions >= max_items and 0 or max_items - #suggestions
    si = #suggestions
  end

  -- fuzzy match, remove duplicates and store. If the current partial looks like
  -- a code symbol with separators or camel-case chunks, append a lower-priority
  -- pass that searches those chunks independently; for example, `text_draw`
  -- also tries `text draw`, which can find `draw_text` after the direct matches.
  if max_items > 0 then
    local ordered, seen = {}, {}
    for _, item in ipairs(suggestions) do seen[suggestion_text(item)] = item end
    local function append_matches(matches, query)
      for _, item in ipairs(matches or {}) do
        local key = suggestion_text(item)
        if key ~= "" and not seen[key] then
          annotate_match(item, query)
          seen[key] = item
          ordered[#ordered + 1] = item
        elseif key ~= "" and seen[key] and type(seen[key]) == "table" and type(item) == "table" then
          seen[key].info = seen[key].info or item.info
        end
      end
    end

    append_matches(sort_display_matches(common.fuzzy_match(items, partial, false), partial), partial)

    local chunk_query, query_chunks = code_symbol_chunk_query(partial)
    if chunk_query and chunk_query ~= partial then
      local scored = {}
      for _, match in ipairs(fuzzy_match_with_scores(items, chunk_query)) do
        local chunk_score = code_symbol_chunk_match_score(suggestion_text(match.item), query_chunks)
        if chunk_score then
          scored[#scored + 1] = {
            item = match.item,
            score = (match.score or 0) + chunk_score - 900,
          }
        end
      end
      table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return completion_sort_text(a.item) < completion_sort_text(b.item)
      end)
      local chunk_matches = {}
      for _, match in ipairs(scored) do chunk_matches[#chunk_matches + 1] = match.item end
      append_matches(chunk_matches, chunk_query)
    end

    for i = 1, math.min(max_items, #ordered) do
      suggestions[si+i] = ordered[i]
    end
  end

  suggestions_idx = 1
  suggestions_offset = 1
  return contextual_member_count
end

local function get_active_view()
  if core.active_view:is(DocView) then
    return core.active_view
  end
end

local function request_lsp_completion(av, opts)
  opts = opts or {}
  local doc = av and av.doc
  local completion = doc and lsp_completion_module()
  if not completion or not completion.has_available_client or not completion.has_available_client(doc) then return false end
  local line, col = doc:get_selection()
  local key = completion_context_key(doc, line, col)
  if lsp_completion_context and lsp_completion_context.key == key and lsp_completion_context.pending then return true end
  lsp_completion_context = { key = key, pending = true }
  lsp_completion_items = nil
  local trigger_character = opts.trigger_character
  completion.request(doc, {
    show = false,
    manual = opts.manual,
    trigger_character = trigger_character,
    trigger_kind = trigger_character and 2 or 1,
    on_items = function(items)
      if lsp_completion_context and lsp_completion_context.key == key then
        lsp_completion_context.pending = false
      end
      set_lsp_completion_items(doc, line, col, items)
    end,
  })
  return true
end

local function get_suggestions_rect(av)
  if #suggestions == 0 then
    return 0, 0, 0, 0
  end

  local _, partial_line, partial_col = autocomplete.get_partial_symbol()
  local rect_x, y = av:get_line_screen_position(partial_line, partial_col)
  y = y + av:get_line_height() + style.padding.y
  local font = av:get_font()
  local th = font:get_height()
  local lh = th + style.padding.y
  local icon_column_width = 0
  local hide_info = config.plugins.autocomplete.hide_info
  local hide_icons = config.plugins.autocomplete.hide_icons

  local window_width = system.get_window_size(core.window)
  local available_width = math.max(1, window_width - rect_x - style.padding.x)
  local content_width = 0
  for _, s in ipairs(suggestions) do
    local w = row_text_width(font, style.font, s, hide_info, ROW_PREVIEW_MAX_CHARS)
    if not hide_icons then
      local icon_width = display_icon_width(s, lh)
      if icon_width > 0 then
        icon_column_width = math.max(icon_column_width, icon_width + style.padding.x / 2)
      end
    end
    content_width = math.max(content_width, w)
  end

  local view_top = av.position.y
  local view_bottom = av.position.y + av.size.y
  local _, window_height = system.get_window_size(core.window)
  view_bottom = math.min(view_bottom, window_height - style.padding.y)

  local below_rect_y = y - style.padding.y
  local above_bottom = y - av:get_line_height() - style.padding.y

  local function visible_count_for(available_height)
    return math.max(1, math.min(#suggestions, math.floor((available_height - style.padding.y) / lh)))
  end

  local below_count = visible_count_for(view_bottom - below_rect_y)
  local above_count = visible_count_for(above_bottom - view_top)
  local max_items = below_count
  local rect_y = below_rect_y
  if below_count < #suggestions and above_count > below_count then
    max_items = above_count
    rect_y = above_bottom - (max_items * lh + style.padding.y)
  end

  local rect_width = math.max(150, content_width + icon_column_width + style.padding.x * 2)
  rect_width = math.min(rect_width, available_width)

  return
    rect_x,
    rect_y,
    rect_width,
    max_items * lh + style.padding.y,
    icon_column_width,
    max_items
end

local function get_visible_suggestion_count(av)
  if #suggestions == 0 then return 0 end
  av = av or get_active_view()
  if not av then return #suggestions end
  local _, _, _, _, _, visible_count = get_suggestions_rect(av)
  return math.max(1, math.min(#suggestions, visible_count or #suggestions))
end

local function point_over_rect(x, y, rect)
  return rect
    and x >= rect.x and y >= rect.y
    and x <= rect.x + rect.w and y <= rect.y + rect.h
end

local function draw_box_border(x, y, w, h)
  local t = math.max(1, style.divider_size or 1)
  local color = style.autocomplete_border
  renderer.draw_rect(x, y, w, t, color)
  renderer.draw_rect(x, y + h - t, w, t, color)
  renderer.draw_rect(x, y, t, h, color)
  renderer.draw_rect(x + w - t, y, t, h, color)
end

local function get_description_view(text)
  local font_size = config.plugins.autocomplete.desc_font_size
  if previous_scale ~= SCALE or desc_font_size ~= font_size then
    desc_font = style.code_font:copy(font_size * SCALE)
    desc_font_size = font_size
    previous_scale = SCALE
  end

  if
    not desc_view
    or desc_view_text ~= text
    or desc_view_font ~= desc_font
  then
    desc_view = MarkdownView({
      text = text,
      title = "Completion Documentation",
      font = desc_font
    })
    desc_view_text = text
    desc_view_font = desc_font
  end
  return desc_view
end

local function draw_matched_text(font, base_color, match_color, item, x, y, w, h, text)
  text = text or display_text(item and item.text or "")
  local matches = item and item.autocomplete_matches
  local draw_x = x
  local run_text = ""
  local run_color = nil
  local function flush()
    if run_text == "" then return end
    common.draw_text(font, run_color or base_color, run_text, "left", draw_x, y, w, h)
    draw_x = draw_x + font:get_width(run_text)
    run_text = ""
  end
  for i = 1, #text do
    local color = matches and matches[i] and match_color or base_color
    if run_color ~= color then
      flush()
      run_color = color
    end
    run_text = run_text .. text:sub(i, i)
  end
  flush()
  return draw_x
end

local function draw_matched_text_direct(font, base_color, match_color, item, x, y, text)
  text = tostring(text or "")
  local matches = item and item.autocomplete_matches
  local cx = x
  local run_text = ""
  local run_color = nil
  local function flush()
    if run_text == "" then return end
    cx = renderer.draw_text(font, run_text, cx, y, run_color or base_color)
    run_text = ""
  end
  for i = 1, #text do
    local color = matches and matches[i] and match_color or base_color
    if run_color ~= color then
      flush()
      run_color = color
    end
    run_text = run_text .. text:sub(i, i)
  end
  flush()
  return cx
end

local function fit_prefix(font, text, width)
  if text == "" or width <= 0 then return "" end
  if font:get_width(text) <= width then return text end
  local lo, hi = 0, #text
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if font:get_width(text:sub(1, mid)) <= width then lo = mid else hi = mid - 1 end
  end
  return text:sub(1, lo)
end

local function fit_suffix(font, text, width)
  if text == "" or width <= 0 then return "" end
  if font:get_width(text) <= width then return text end
  local lo, hi = 1, #text + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if font:get_width(text:sub(mid)) <= width then hi = mid else lo = mid + 1 end
  end
  return text:sub(lo)
end

local function clipped_preview_around_name(font, text, span, width)
  text = tostring(text or "")
  if text == "" or width <= 0 then return "", nil end
  if font:get_width(text) <= width then return text, span end
  span = span or { 1, math.min(#text, #(tostring(text):match("%S+") or text)) }
  local name_start = common.clamp(tonumber(span[1]) or 1, 1, #text)
  local name_end = common.clamp(tonumber(span[2]) or name_start, name_start, #text)
  local before = text:sub(1, name_start - 1)
  local name = text:sub(name_start, name_end)
  local after = text:sub(name_end + 1)
  local ellipsis = "..."
  local ellipsis_w = font:get_width(ellipsis)
  local name_w = font:get_width(name)
  if name_w >= width then
    local clipped_name = fit_prefix(font, name, math.max(0, width - ellipsis_w)) .. ellipsis
    return clipped_name, { 1, math.max(1, #clipped_name - #ellipsis) }
  end

  local remaining = width - name_w
  local before_budget = remaining / 2
  local after_budget = remaining - before_budget
  if before ~= "" then before_budget = math.max(0, before_budget - ellipsis_w) end
  if after ~= "" then after_budget = math.max(0, after_budget - ellipsis_w) end

  local clipped_before = fit_suffix(font, before, before_budget)
  local clipped_after = fit_prefix(font, after, after_budget)
  local before_used = font:get_width(clipped_before)
  local after_used = font:get_width(clipped_after)
  local spare = math.max(0, width - name_w - before_used - after_used
    - (clipped_before ~= before and ellipsis_w or 0)
    - (clipped_after ~= after and ellipsis_w or 0))
  if spare > 0 then
    if #clipped_before == #before and #clipped_after < #after then
      clipped_after = fit_prefix(font, after, after_budget + spare)
    elseif #clipped_after == #after and #clipped_before < #before then
      clipped_before = fit_suffix(font, before, before_budget + spare)
    end
  end

  local leading = clipped_before ~= before and ellipsis or ""
  local trailing = clipped_after ~= after and ellipsis or ""
  local clipped = leading .. clipped_before .. name .. clipped_after .. trailing
  while #clipped > 0 and font:get_width(clipped) > width and clipped_after ~= "" do
    clipped_after = clipped_after:sub(1, -2)
    trailing = clipped_after ~= after and ellipsis or ""
    clipped = leading .. clipped_before .. name .. clipped_after .. trailing
  end
  while #clipped > 0 and font:get_width(clipped) > width and clipped_before ~= "" do
    clipped_before = clipped_before:sub(2)
    leading = clipped_before ~= before and ellipsis or ""
    clipped = leading .. clipped_before .. name .. clipped_after .. trailing
  end
  local clipped_name_start = #leading + #clipped_before + 1
  return clipped, { clipped_name_start, clipped_name_start + #name - 1 }
end

local function draw_preview_text(font, item, x, y, w, h)
  local text, span = clipped_preview_around_name(font, item.preview_text, item.preview_name_span, w)
  if text == "" then return x end
  span = span or { 1, 0 }
  local before = text:sub(1, span[1] - 1)
  local name = text:sub(span[1], span[2])
  local after = text:sub(span[2] + 1)
  local cx = x
  if before ~= "" then cx = renderer.draw_text(font, before, cx, y, style.dim) end
  if name ~= "" then cx = draw_matched_text_direct(font, style.text, style.accent, item, cx, y, name) end
  if after ~= "" then cx = renderer.draw_text(font, after, cx, y, style.dim) end
  return cx
end

local function preferred_description_width(text, max_width)
  max_width = math.max(1, max_width or 1)
  local min_width = math.min(max_width, 160 * SCALE)
  local width = math.min(max_width, 360 * SCALE)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local line_width = desc_font:get_width(line)
    if line_width > 0 then
      width = math.max(width, math.min(max_width, line_width + style.padding.x * 4))
    end
  end
  return math.max(min_width, math.min(width, max_width))
end

local function draw_description_box(text, sx, sy, sw, sh)
  local ww, wh = system.get_window_size(core.window)
  local gap = style.padding.x / 4
  local max_width = math.max(360 * SCALE, ww * 0.65)
  local view = get_description_view(text)
  local x = sx + sw + gap
  local y = sy
  local width
  local available_width

  if sw > (ww - style.padding.x * 2) * 0.5 then
    x = sx
    y = sy + sh + gap
    available_width = ww - x - style.padding.x * 2
  elseif sx < ww - sx - sw then
    available_width = ww - x - style.padding.x * 2
  else
    available_width = sx - gap - style.padding.x * 2
  end

  width = preferred_description_width(text, math.min(max_width, available_width))
  if not (sw > (ww - style.padding.x * 2) * 0.5) and sx >= ww - sx - sw then
    x = sx - gap - width
  end

  local _, content_height = view:get_rendered_size(width)
  local max_height = math.max(120 * SCALE, wh * 0.55)
  local available_height = wh - y - style.padding.y
  local height = math.min(content_height, max_height, math.max(available_height, 1))

  view:draw_at(x, y, width, height, style.background3, true)
  draw_box_border(x, y, width, height)
  desc_rect = { x = x, y = y, w = width, h = height }
end

local function draw_suggestion_row(font, suggestion, rx, y, rw, lh, icon_column_width, selected, max_chars)
  local row_bg = selected and style.autocomplete_selection or style.background3
  if selected then renderer.draw_rect(rx, y, rw, lh, row_bg) end

  local icon_l_padding, icon_r_padding = 0, 0
  if icon_column_width > 0 then
    if config.plugins.autocomplete.icon_position == "left" then
      draw_display_icon(suggestion, rx + style.padding.x, y, icon_column_width - style.padding.x / 2, lh)
      icon_l_padding = icon_column_width
    else
      local icon_x = rx + rw - style.padding.x - icon_column_width + style.padding.x / 2
      draw_display_icon(suggestion, icon_x, y, icon_column_width - style.padding.x / 2, lh)
      icon_r_padding = icon_column_width
    end
  end

  local hide_info = config.plugins.autocomplete.hide_info
  local label, info = row_text_parts(suggestion, hide_info, max_chars)
  local text_width = rw - icon_l_padding - icon_r_padding - style.padding.x * 2
  local text_padding = rx + icon_l_padding + style.padding.x
  local dots_width = font:get_width("...")
  local content_width = row_text_width(font, style.font, suggestion, hide_info, max_chars)

  if text_width <= 0 then return end
  core.push_clip_rect(text_padding, y, text_width, lh)
  if suggestion.preview_text then
    local preview_font = style.get_small_font(font)
    local preview_y = y + math.max(0, math.floor((lh - preview_font:get_height()) / 2))
    local preview_info = suggestion.preview_show_info and not hide_info and display_info(suggestion) or nil
    local info_width = preview_info and preview_info ~= "" and style.font:get_width(preview_info) or 0
    local info_gap = info_width > 0 and style.padding.x or 0
    local preview_width = math.max(0, text_width - info_width - info_gap)
    local preview_end = draw_preview_text(preview_font, suggestion, text_padding, preview_y, preview_width, lh)
    if info_width > 0 then
      common.draw_text(
        style.font, style.dim, preview_info, "left",
        preview_end + info_gap, y,
        math.max(0, text_width - (preview_end - text_padding) - info_gap), lh
      )
    end
  else
    local label_end = draw_matched_text(font, style.text, style.accent, suggestion, text_padding, y, text_width, lh, label)
    if info and info ~= "" then
      common.draw_text(
        style.font, style.dim, info, "left",
        label_end + style.padding.x, y,
        math.max(0, text_width - (label_end - text_padding) - style.padding.x), lh
      )
    end
    if content_width > text_width then
      renderer.draw_rect(
        text_padding + math.max(0, text_width - dots_width), y,
        math.min(dots_width, text_width), lh,
        row_bg
      )
      common.draw_text(
        font, style.text, "...", "right",
        text_padding, y, text_width, lh
      )
    end
  end
  core.pop_clip_rect()
end

local function draw_suggestions_box(av)
  if #suggestions <= 0 then
    return
  end

  local rx, ry, rw, rh, icon_column_width, visible_count = get_suggestions_rect(av)
  renderer.draw_rect(rx, ry, rw, rh, style.background3)
  desc_rect = nil

  local font = av:get_font()
  local lh = font:get_height() + style.padding.y
  local y = ry + style.padding.y / 2
  local show_count = math.min(#suggestions, visible_count)
  local start_index = suggestions_offset
  local selected_item, selected_y, selected_desc

  for i=start_index, start_index+show_count-1, 1 do
    local s = suggestions[i]
    if not s then break end
    local selected = suggestions_idx == i
    draw_suggestion_row(font, s, rx, y, rw, lh, icon_column_width, selected, ROW_PREVIEW_MAX_CHARS)
    if selected then
      selected_item = s
      selected_y = y
      selected_desc = s.desc
      if s.onhover then
        s.onhover(suggestions_idx, s)
        s.onhover = nil
      end
    end
    y = y + lh
  end

  if selected_item then
    local hide_info = config.plugins.autocomplete.hide_info
    local full_width = row_text_width(font, style.font, selected_item, hide_info)
    full_width = full_width + icon_column_width
    local ww = system.get_window_size(core.window)
    local overlay_width = math.max(rw, full_width + style.padding.x * 2)
    overlay_width = math.min(overlay_width, math.max(rw, ww - rx - style.padding.x))
    draw_suggestion_row(font, selected_item, rx, selected_y, overlay_width, lh, icon_column_width, true)
    if selected_desc and #selected_desc > 0 then
      draw_description_box(selected_desc, rx, ry, rw, rh)
    end
  end

  draw_box_border(rx, ry, rw, rh)
end

local function refresh_providers(view, opts)
  for name in pairs(provider_maps) do autocomplete.map[name] = nil end
  provider_maps = {}
  local force_open = false
  for id, provider in pairs(autocomplete.providers) do
    local ok, symbols, provider_opts = pcall(provider, view, opts)
    if not ok then
      quiet_log("Autocomplete provider %s failed: %s", id, tostring(symbols))
    elseif symbols then
      autocomplete.add(symbols, false)
      provider_maps[symbols.name] = true
      force_open = force_open or (provider_opts and provider_opts.force_open) or false
    end
  end
  return force_open
end

local function show_autocomplete(opts)
  opts = opts or {}
  local av = get_active_view()
  if av then
    local provider_force_open = refresh_providers(av, opts)
    -- update partial symbol and suggestions
    partial = autocomplete.get_partial_symbol()

    local doc = av.doc
    local completion = lsp_completion_module()
    local lsp_available = completion and completion.has_available_client and completion.has_available_client(doc)
    local trigger_character = nil
    if lsp_available and opts.text and completion.is_trigger_character and completion.is_trigger_character(doc, opts.text) then
      trigger_character = opts.text:sub(-1)
    end
    local member_receiver = member_completion_receiver(doc)
    local should_open_normally = triggered_manually
      or provider_force_open
      or #partial >= config.plugins.autocomplete.min_len
      or (opts.keep_open and #partial > 0)
      or trigger_character ~= nil
    local should_open = should_open_normally or member_receiver ~= nil

    if should_open then
      if lsp_available then
        request_lsp_completion(av, { manual = triggered_manually, trigger_character = trigger_character })
      end
      local contextual_member_count = update_suggestions()
      if member_receiver and not should_open_normally and contextual_member_count == 0 then
        reset_suggestions()
      end

      if not triggered_manually then
        last_line, last_col = av.doc:get_selection()
        last_doc = av.doc
      else
        local line, col = av.doc:get_selection()
        local char = av.doc:get_char(line, col-1, line, col-1)

        if char:match("%s") or (char:match("%p") and col ~= last_col and not lsp_available) then
          reset_suggestions()
        end
      end
    else
      reset_suggestions()
    end

    -- scroll if rect is out of bounds of view
    local _, y, _, h = get_suggestions_rect(av)
    local limit = av.position.y + av.size.y
    if y + h > limit then
      av.scroll.to.y = av.scroll.y + y + h - limit
    end
  end
end

--
-- Patch event logic into RootPanel and Doc
--
local on_text_input = RootPanel.on_text_input
local on_doc_close = Doc.on_close
local on_mouse_pressed = RootPanel.on_mouse_pressed
local on_mouse_released = RootPanel.on_mouse_released
local on_mouse_moved = RootPanel.on_mouse_moved
local on_mouse_wheel = RootPanel.on_mouse_wheel
local update = RootPanel.update
local draw = RootPanel.draw

RootPanel.on_text_input = function(self, text, ...)
  on_text_input(self, text, ...)
  show_autocomplete({ text = text })
end

RootPanel.on_mouse_pressed = function(self, button, x, y, clicks)
  if desc_view and point_over_rect(x, y, desc_rect) then
    if desc_view:on_mouse_pressed(button, x, y, clicks) then
      return true
    end
  end
  return on_mouse_pressed(self, button, x, y, clicks)
end

RootPanel.on_mouse_released = function(self, button, x, y)
  if desc_view then
    desc_view:on_mouse_released(button, x, y)
  end
  return on_mouse_released(self, button, x, y)
end

RootPanel.on_mouse_moved = function(self, x, y, dx, dy)
  if desc_view and (point_over_rect(x, y, desc_rect) or desc_view:scrollbar_dragging()) then
    local handled = desc_view:on_mouse_moved(x, y, dx, dy)
    if handled then
      core.request_cursor(desc_view.cursor)
      core.redraw = true
      return true
    end
    local result = on_mouse_moved(self, x, y, dx, dy)
    core.request_cursor(desc_view.cursor)
    core.redraw = true
    return result
  elseif desc_view then
    desc_view:on_mouse_left()
  end
  return on_mouse_moved(self, x, y, dx, dy)
end

RootPanel.on_mouse_wheel = function(self, y, x)
  if desc_view and point_over_rect(core.root_panel.mouse.x, core.root_panel.mouse.y, desc_rect) then
    if keymap.modkeys["shift"] then
      x = y
      y = 0
    end
    if y and y ~= 0 then
      desc_view.scroll.to.y = desc_view.scroll.to.y + y * -config.mouse_wheel_scroll
    end
    if x and x ~= 0 then
      desc_view.scroll.to.x = desc_view.scroll.to.x + x * -config.mouse_wheel_scroll
    end
    core.redraw = true
    return true
  end
  return on_mouse_wheel(self, y, x)
end

Doc.register_text_transaction_handler("autocomplete", function(doc, transaction)
  if doc ~= last_doc or #suggestions == 0 then return end

  local deleted = transaction and transaction.edits and #transaction.edits > 0
  for _, edit in ipairs(transaction and transaction.edits or {}) do
    if edit.text ~= "" or edit.old_text == "" then
      deleted = false
      break
    end
  end
  pending_deletion_doc = deleted and doc or nil
end)

Doc.on_close = function(self)
  on_doc_close(self)
  if cache[self] then cache[self] = nil end
end

RootPanel.update = function(...)
  update(...)

  if desc_view then
    desc_view:update()
  end

  local av = get_active_view()
  if av then
    local line, col = av.doc:get_selection()
    local deleted = pending_deletion_doc == av.doc and #suggestions > 0
    pending_deletion_doc = nil

    if deleted and line == last_line and col <= last_col then
      show_autocomplete({ keep_open = true })
    elseif not triggered_manually then
      if line ~= last_line or col ~= last_col then
        reset_suggestions()
      end
    else
      if line ~= last_line or col < last_col then
        reset_suggestions()
      end
    end
  end
end

RootPanel.draw = function(...)
  draw(...)

  local av = get_active_view()
  if av then
    -- draw suggestions box after everything else
    core.root_panel:defer_draw(draw_suggestions_box, av)
  end
end

--
-- Public functions
--

---Manually invoke the completion list using already registered symbols.
---@param on_close? plugins.autocomplete.onclose
---@param opts? table
function autocomplete.open(on_close, opts)
  opts = opts or {}
  triggered_manually = true

  if on_close then
    if autocomplete.on_close then
      local current_on_close = autocomplete.on_close
      autocomplete.on_close = function (doc, item)
        current_on_close(doc, item)
        on_close(doc, item)
      end
    else
      autocomplete.on_close = on_close
    end
  end

  local av = get_active_view()
  if av then
    partial = autocomplete.get_partial_symbol()
    if opts.force_basic ~= nil then
      force_basic_suggestions = opts.force_basic == true
    else
      force_basic_suggestions = at_word_completion_position() or member_completion_receiver(av.doc) ~= nil
    end
    last_line, last_col = av.doc:get_selection()
    last_doc = av.doc
    request_lsp_completion(av, { manual = true })
    update_suggestions()
  end
end

function autocomplete.trigger()
  autocomplete.open()
end

---Manually close the completions list.
function autocomplete.close()
  reset_suggestions()
end

---Check if the completion lists is visible.
---@return boolean
function autocomplete.is_open()
  return #suggestions > 0
end

---Return the currently selected completion item, if any.
---@return plugins.autocomplete.symbolinfo?
function autocomplete.get_selected_suggestion()
  return suggestions[suggestions_idx]
end

---Manually invoke the completion list using the provided symbols.
---@param completions plugins.autocomplete.symbols
---@param on_close? plugins.autocomplete.onclose
function autocomplete.complete(completions, on_close)
  reset_suggestions(true)

  autocomplete.add(completions, true)

  autocomplete.open(on_close, { force_basic = false })
end

---Check if autocomplete can be triggered by checking if current
---partial symbol meets the required minimum autocompletion len.
---@return boolean
function autocomplete.can_complete()
  if #partial >= config.plugins.autocomplete.min_len then
    return true
  end
  return false
end

---Register a font icon that can be assigned to completion items.
---@param name string
---@param character string
---@param font? renderer.font
---@param color? string | renderer.color A style.syntax[] name or specific color
function autocomplete.add_icon(name, character, font, color)
  local color_type = type(color)
  assert(
    not color or color_type == "table"
      or (color_type == "string" and style.syntax[color]),
    "invalid icon color given"
  )
  autocomplete.icons[name] = {
    char = character,
    font = font or style.code_font,
    color = color or "keyword"
  }
end

--
-- Register built-in syntax symbol types icon
--
for name, _ in pairs(style.syntax) do
  autocomplete.add_icon(name, "M", style.icon_font, name)
end

--
-- Commands
--
local function quiet_log(...)
  if core.log_quiet then core.log_quiet(...) end
end

local function source_range(item)
  if not item or not item.source_line or not item.source_col then return nil end
  local line1 = item.source_line
  local col1 = item.source_col
  return line1, col1, item.source_end_line or line1, item.source_end_col or col1
end

local function select_source_range(view, line1, col1, line2, col2)
  if not view or not view.doc then return false end
  local function select_range()
    if view.expand_folds_covering_range then
      view:expand_folds_covering_range(line1, col1, line2, col2, "autocomplete-source")
    end
    view.doc:set_selection(line1, col1, line2, col2)
    return true
  end
  if view.with_selection_state then return view:with_selection_state(select_range) end
  return select_range()
end

local function open_completion_source_view(item, target_side, line1, col1, line2, col2, restore_focus)
  local path = item.source_path
  if target_side then
    local ok, sidepanel = pcall(require, "core.sidepanel")
    if not ok or not sidepanel then return nil end
    local opts = { line = line1, col = col1, line2 = line2, col2 = col2, focus = true, restore_focus = restore_focus }
    if path and path ~= "" then return sidepanel.open_path_in_side(path, opts) end
    if item.source_doc then return sidepanel.open_doc_in_side(item.source_doc, opts) end
    return nil
  end

  local ok, sidepanel = pcall(require, "core.sidepanel")
  local active_docview = get_active_view()
  if ok and sidepanel then
    local opts = {
      line = line1,
      col = col1,
      line2 = line2,
      col2 = col2,
      source_view = active_docview,
      replace_dirty_singleton = true,
    }
    if path and path ~= "" then return sidepanel.open_path_in_main(path, opts) end
    if item.source_doc and (not active_docview or active_docview.doc ~= item.source_doc) then
      return sidepanel.open_doc_in_main(item.source_doc, opts)
    end
  elseif path and path ~= "" then
    return core.open_file(path)
  elseif item.source_doc and (not active_docview or active_docview.doc ~= item.source_doc) then
    return core.root_panel:open_doc(item.source_doc)
  end
  return active_docview
end

local function reveal_completion_source(target_side)
  local item = suggestions[suggestions_idx]
  local line1, col1, line2, col2 = source_range(item)
  if not line1 then
    quiet_log("Autocomplete source navigation ignored item without source location")
    return true
  end

  local restore_focus = get_active_view()
  reset_suggestions()
  local view = open_completion_source_view(item, target_side, line1, col1, line2, col2, restore_focus)
  if not view or not view.doc then
    quiet_log("Autocomplete source navigation could not open source for %s", tostring(item.text or item))
    return true
  end

  if not target_side then select_source_range(view, line1, col1, line2, col2) end
  return true
end

local function docview_predicate()
  local active_docview = get_active_view()
  return active_docview ~= nil, active_docview
end

local function predicate()
  local active_docview = get_active_view()
  return active_docview and #suggestions > 0, active_docview
end

command.add(docview_predicate, {
  ["autocomplete:trigger"] = function()
    autocomplete.trigger()
  end,
})

command.add(predicate, {
  ["autocomplete:complete"] = function(dv)
    if dv.can_edit and not dv:can_edit("autocomplete", { warn = true }) then return end
    local doc = dv.doc
    local item = suggestions[suggestions_idx]
    local inserted = false
    if item.onselect then
      inserted = item.onselect(suggestions_idx, item)
    end
    if not inserted then
      local current_partial = autocomplete.get_partial_symbol()
      local sz = #current_partial

      local edits = {}
      local final_by_idx = {}
      for idx, line1, col1, line2, col2 in doc:get_selections(true) do
        local n = col1 - 1
        local line = doc.lines[line1]
        local replace_line1, replace_col1 = line1, col1
        for i = 1, sz + 1 do
          local j = sz - i
          local subline = line:sub(n - j, n)
          local subpartial = current_partial:sub(i, -1)
          if subpartial == subline then
            replace_col1 = n - j
            break
          end
        end
        edits[#edits + 1] = {
          line1 = replace_line1,
          col1 = replace_col1,
          line2 = line2,
          col2 = col2,
          text = item.completion_prefix
            and line:sub(replace_col1 - #item.completion_prefix, replace_col1 - 1) ~= item.completion_prefix
            and item.completion_prefix .. item.text
            or item.text,
          idx = idx,
        }
        final_by_idx[idx] = "end"
      end

      if #edits > 0 then
        doc:apply_edits(edits, {
          type = "insert",
          selections = doc:selections_after_edits(edits, final_by_idx),
          last_selection = doc.last_selection,
          merge_cursors = false,
        })
      end
    end
    reset_suggestions()
  end,

  ["autocomplete:previous"] = function(dv)
    suggestions_idx = (suggestions_idx - 2) % #suggestions + 1

    local ah = get_visible_suggestion_count(dv)
    if suggestions_offset > suggestions_idx then
      suggestions_offset = suggestions_idx
    elseif suggestions_offset + ah < suggestions_idx + 1 then
      suggestions_offset = suggestions_idx - ah + 1
    end
  end,

  ["autocomplete:next"] = function(dv)
    suggestions_idx = (suggestions_idx % #suggestions) + 1

    local ah = get_visible_suggestion_count(dv)
    if suggestions_offset + ah < suggestions_idx + 1 then
      suggestions_offset = suggestions_idx - ah + 1
    elseif suggestions_offset > suggestions_idx then
      suggestions_offset = suggestions_idx
    end
  end,

  ["autocomplete:cycle"] = function()
    local newidx = suggestions_idx + 1
    suggestions_idx = newidx > #suggestions and 1 or newidx
  end,

  ["autocomplete:go-to-declaration"] = function()
    return reveal_completion_source(false)
  end,

  ["autocomplete:go-to-declaration-side"] = function()
    return reveal_completion_source(true)
  end,

  ["autocomplete:cancel"] = function()
    reset_suggestions()
  end,
})

--
-- Keymaps
--
pcall(require, "core.commands.language")
keymap.add {
  ["alt+space"]    = "autocomplete:trigger",
  ["tab"]          = "autocomplete:complete",
  ["alt+r"]        = { "autocomplete:go-to-declaration", "language:go-to-declaration" },
  ["alt+shift+r"]  = { "autocomplete:go-to-declaration-side", "language:show-references" },
  ["up"]           = "autocomplete:previous",
  ["down"]         = "autocomplete:next",
  ["escape"]       = "autocomplete:cancel",
}

keymap.add_direct {
  ["ctrl+space"] = "autocomplete:trigger",
}

autocomplete._test = {
  code_symbol_chunk_query = code_symbol_chunk_query,
  code_symbol_chunk_match_score = code_symbol_chunk_match_score,
}

return autocomplete
