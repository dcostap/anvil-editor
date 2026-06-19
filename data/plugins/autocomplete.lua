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

---@class plugins.autocomplete.symbolinfo
---Text value of the symbol displayed on the autocomplete box.
---@field text string
---Additional information displayed on autocomplete box, eg: item type.
---@field info? string
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
      default = 100,
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
      label = "Suggestions Scope",
      description = "Which symbols to show on the suggestions list.",
      path = "suggestions_scope",
      type = "selection",
      default = "global",
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

-- Flag that indicates if the autocomplete box was manually triggered
-- with the autocomplete.complete() function to prevent the suggestions
-- from getting cluttered with arbitrary document symbols by using the
-- autocomplete.map_manually table.
local triggered_manually = false

local mt = { __tostring = function(t) return t.text end }

---Register a symbols table used for autocompletion.
---@param t plugins.autocomplete.symbols
---@param manually_triggered? boolean
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
    if doc.syntax and not autocomplete.map["language_"..doc.syntax.name] then
      local symbols = {
        name = "language_"..doc.syntax.name,
        files = doc.syntax.files,
        items = {}
      }
      for name, type in pairs(doc.syntax.symbols) do
        symbols.items[name] = type
      end
      autocomplete.add(symbols)
      return symbols.items
    end
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
        if not s[sym] and not syntax_symbols[sym] then
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

local function display_info(suggestion)
  local info = suggestion and suggestion.info
  if info == "normal" then return nil end
  return info
end

local function display_icon(suggestion)
  return suggestion and (suggestion.icon or display_info(suggestion))
end

local update_suggestions
local lsp_completion_items = nil
local lsp_completion_context = nil
local force_basic_suggestions = true

local function lsp_completion_module()
  local ok, completion = pcall(require, "core.lsp.completion")
  return ok and completion or nil
end

local function tree_sitter_locals_module()
  local ok, locals = pcall(require, "core.treesitter.locals")
  return ok and locals or nil
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
  if type(item) ~= "table" then return tostring(item or "") end
  return tostring(item.insert_text or item.label or item.text or ""):gsub("^%s+", "")
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

  local assigned_sym = {}

  local lsp_available = has_lsp_completion(doc)

  -- get all relevant suggestions for given filename
  local items = {}
  if not lsp_available and force_basic_suggestions then
    for _, v in pairs(autocomplete.map) do
      if common.match_pattern(filename, v.files) then
        for _, item in pairs(v.items) do
          table.insert(items, item)
          assigned_sym[item.text] = true
        end
      end
    end
  end

  local manual_items = {}
  if triggered_manually then
    for _, v in pairs(autocomplete.map_manually) do
      if common.match_pattern(filename, v.files) then
        for _, item in pairs(v.items) do
          table.insert(manual_items, item)
        end
      end
    end
  end
  if lsp_available then
    local allow_private = partial:sub(1, 1) == "_"
    for _, item in ipairs(lsp_completion_items or {}) do
      local label = tostring(item.insert_text or item.label or item.text or ""):gsub("^%s+", "")
      if allow_private or label:sub(1, 1) ~= "_" then
        table.insert(manual_items, item)
      end
    end
  end

  -- Append the global, local or related text symbols if applicable
  local scope = config.plugins.autocomplete.suggestions_scope

  if not lsp_available and force_basic_suggestions then
    local text_symbols = nil

    if scope == "global" then
      text_symbols = global_symbols
    elseif scope == "local" and cache[doc] and cache[doc].symbols then
      text_symbols = cache[doc].symbols
    elseif scope == "related" then
      for _, d in ipairs(core.docs) do
        if doc.syntax == d.syntax then
          if cache[d] and cache[d].symbols then
            for name in pairs(cache[d].symbols) do
              if not assigned_sym[name] then
                table.insert(items, setmetatable(
                  {text = name, info = "normal"}, mt
                ))
              end
            end
          end
        end
      end
    end

    if text_symbols then
      for name in pairs(text_symbols) do
        if not assigned_sym[name] then
          table.insert(items, setmetatable({text = name, info = "normal"}, mt))
          assigned_sym[name] = true
        end
      end
    end

    local locals = tree_sitter_locals_module()
    local symbols = locals and locals.get_document_symbols and locals.get_document_symbols(doc) or nil
    for _, symbol in ipairs(symbols or {}) do
      local name = symbol.name
      if name and name ~= "" and not assigned_sym[name] then
        table.insert(items, setmetatable({text = name, info = symbol.kind or "symbol", icon = symbol.kind}, mt))
        assigned_sym[name] = true
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

  -- fuzzy match, remove duplicates and store
  if max_items > 0 then
    items = sort_display_matches(annotate_matches(common.fuzzy_match(items, partial, false), partial), partial)
    local j = 1
    for i = 1, max_items do
      suggestions[si+i] = items[j]
      j = j + 1
      while items[j] and items[i].text == items[j].text do
        items[i].info = items[i].info or items[j].info
        j = j + 1
      end
    end
  end

  suggestions_idx = 1
  suggestions_offset = 1
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

  local line, col = av.doc:get_selection()
  local x, y = av:get_line_screen_position(line, col - #partial)
  y = y + av:get_line_height() + style.padding.y
  local font = av:get_font()
  local th = font:get_height()
  local has_icons = false
  local hide_info = config.plugins.autocomplete.hide_info
  local hide_icons = config.plugins.autocomplete.hide_icons

  local max_width = 0
  local width_exceeds = false
  local win_width = system.get_window_size(core.window) - style.padding.x  * 2
  for i, s in ipairs(suggestions) do
    local w = font:get_width(s.text)
    local info = display_info(s)
    if info and not hide_info then
      w = w + style.font:get_width(info) + style.padding.x
    end
    local icon = display_icon(s)
    if not hide_icons and icon and autocomplete.icons[icon] then
      w = w + autocomplete.icons[icon].font:get_width(
        autocomplete.icons[icon].char
      ) + (style.padding.x / 2)
      has_icons = true
    end
    max_width = math.max(max_width, w)
    if max_width > win_width then
      width_exceeds = true
      if i > 1 then break end
    end
  end

  local lh = th + style.padding.y
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

  if max_width < 150 then
    max_width = 150
  end

  if not width_exceeds then
    -- if portion not visiable to right, reposition to DocView right margin
    if max_width + style.padding.x * 2 >= av.size.x then
      x = win_width / 2 - max_width / 2
    elseif (x - av.position.x) + max_width > av.size.x then
      x = (av.size.x + av.position.x) - max_width - (style.padding.x * 2)
    end
  else
    max_width = win_width - style.padding.x * 2
    x = style.padding.x * 2
  end

  return
    x - style.padding.x,
    rect_y,
    max_width + style.padding.x * 2,
    max_items * lh + style.padding.y,
    has_icons,
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

local function draw_matched_text(font, base_color, match_color, item, x, y, w, h)
  local text = tostring(item and item.text or "")
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
end

local function draw_description_box(text, sx, sy, sw, sh)
  local ww, wh = system.get_window_size(core.window)
  local gap = style.padding.x / 4
  local max_width = math.max(260 * SCALE, ww * 0.35)
  local x = sx + sw + gap
  local y = sy
  local width

  if sw > (ww - style.padding.x * 2) * 0.5 then
    x = sx
    y = sy + sh + gap
    width = math.min(sw, ww - x - style.padding.x * 2)
  elseif sx < ww - sx - sw then
    width = math.min(max_width, ww - x - style.padding.x * 2)
  else
    width = math.min(max_width, sx - gap - style.padding.x * 2)
    x = sx - gap - width
  end

  width = math.max(width, 160 * SCALE)

  local view = get_description_view(text)
  local _, content_height = view:get_rendered_size(width)
  local max_height = math.max(120 * SCALE, wh * 0.55)
  local available_height = wh - y - style.padding.y
  local height = math.min(content_height, max_height, math.max(available_height, 1))

  view:draw_at(x, y, width, height, style.background3, true)
  desc_rect = { x = x, y = y, w = width, h = height }
end

local function draw_suggestions_box(av)
  if #suggestions <= 0 then
    return
  end

  -- draw background rect
  local rx, ry, rw, rh, has_icons, visible_count = get_suggestions_rect(av)
  renderer.draw_rect(rx, ry, rw, rh, style.background3)
  desc_rect = nil

  -- draw text
  local font = av:get_font()
  local lh = font:get_height() + style.padding.y
  local y = ry + style.padding.y / 2
  local show_count = math.min(#suggestions, visible_count)
  local start_index = suggestions_offset
  local hide_info = config.plugins.autocomplete.hide_info
  local dots_width = font:get_width("...")

  for i=start_index, start_index+show_count-1, 1 do
    if not suggestions[i] then
      break
    end
    local s = suggestions[i]
    local selected = suggestions_idx == i
    if selected then
      renderer.draw_rect(rx, y, rw, lh, style.background2)
    end

    local icon_l_padding, icon_r_padding = 0, 0

    if has_icons then
      local icon = display_icon(s)
      if icon and autocomplete.icons[icon] then
        local ifont = autocomplete.icons[icon].font
        local itext = autocomplete.icons[icon].char
        local icolor = style.dim
        if config.plugins.autocomplete.icon_position == "left" then
          common.draw_text(
            ifont, icolor, itext, "left", rx + style.padding.x, y, rw, lh
          )
          icon_l_padding = ifont:get_width(itext) + (style.padding.x / 2)
        else
          common.draw_text(
            ifont, icolor, itext, "right", rx, y, rw - style.padding.x, lh
          )
          icon_r_padding = ifont:get_width(itext) + (style.padding.x / 2)
        end
      end
    end

    local color = selected and style.text or style.dim

    local iw = 0
    local info = display_info(s)
    if info and not hide_info then
      local ix2, _, ix1, _ = common.draw_text(
        style.font, color, info, "right",
        rx, y, rw - icon_r_padding - style.padding.x, lh
      )
      iw = ix2 - ix1 + style.padding.x
    end
    color = style.text
    local icon_padding = icon_l_padding > 0 and icon_l_padding or icon_r_padding
    local text_width = rw - icon_padding - style.padding.x - iw
    local text_padding = rx + icon_l_padding + style.padding.x
    core.push_clip_rect(text_padding, y, text_width, lh)
    draw_matched_text(font, color, style.accent, s, text_padding, y, text_width, lh)
    local text_draw_width = font:get_width(s.text)
    if text_draw_width > text_width then
      renderer.draw_rect(
        text_padding + text_width - dots_width, y,
        dots_width, lh,
        style.background3
      )
      common.draw_text(
        font, color, "...", "right",
        text_padding, y, text_width, lh
      )
    end
    core.pop_clip_rect()
    y = y + lh
    if selected then
      if s.onhover then
        s.onhover(suggestions_idx, s)
        s.onhover = nil
      end
      if s.desc and #s.desc > 0 then
        draw_description_box(s.desc, rx, ry, rw, rh)
      end
    end
  end

end

local function show_autocomplete(opts)
  opts = opts or {}
  local av = get_active_view()
  if av then
    -- update partial symbol and suggestions
    partial = autocomplete.get_partial_symbol()

    local doc = av.doc
    local completion = lsp_completion_module()
    local lsp_available = completion and completion.has_available_client and completion.has_available_client(doc)
    local trigger_character = nil
    if lsp_available and opts.text and completion.is_trigger_character and completion.is_trigger_character(doc, opts.text) then
      trigger_character = opts.text:sub(-1)
    end
    local should_open = triggered_manually
      or #partial >= config.plugins.autocomplete.min_len
      or trigger_character ~= nil

    if should_open then
      if lsp_available then
        request_lsp_completion(av, { manual = triggered_manually, trigger_character = trigger_character })
      end
      update_suggestions()

      if not triggered_manually then
        last_line, last_col = av.doc:get_selection()
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
local on_text_remove = Doc.remove
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

Doc.remove = function(self, line1, col1, line2, col2)
  on_text_remove(self, line1, col1, line2, col2)

  if triggered_manually and line1 == line2 then
    if last_col >= col1 then
      reset_suggestions()
    else
      show_autocomplete()
    end
  end
end

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
    -- reset suggestions if caret was moved
    local line, col = av.doc:get_selection()

    if not triggered_manually then
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
      force_basic_suggestions = at_word_completion_position()
    end
    last_line, last_col = av.doc:get_selection()
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
          text = item.text,
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

  ["autocomplete:cancel"] = function()
    reset_suggestions()
  end,
})

--
-- Keymaps
--
keymap.add {
  ["alt+space"] = "autocomplete:trigger",
  ["tab"]       = "autocomplete:complete",
  ["up"]        = "autocomplete:previous",
  ["down"]      = "autocomplete:next",
  ["escape"]    = "autocomplete:cancel",
}


return autocomplete
