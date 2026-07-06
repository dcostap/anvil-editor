-- mod-version:3
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

local M = {}

local PROVIDER_ID = "reload-diff-flash"

local function plugin_config()
  local cfg = config.plugins.reload_diff_flash
  if cfg == false then return false end
  return cfg or {}
end

local function option(opts, key, default)
  if opts and opts[key] ~= nil then return opts[key] end
  local cfg = plugin_config()
  if cfg and cfg[key] ~= nil then return cfg[key] end
  return default
end

local function clone_lines(lines)
  local copy = {}
  for i, line in ipairs(lines or {}) do copy[i] = line end
  if #copy == 0 then copy[1] = "\n" end
  return copy
end

local function slice_lines(lines, first, last_exclusive)
  local out = {}
  for i = first, last_exclusive - 1 do out[#out + 1] = lines[i] end
  return out
end

local function same_lines(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function trim_equal_edges(old_lines, new_lines)
  local old_count, new_count = #old_lines, #new_lines
  local min_count = math.min(old_count, new_count)
  local prefix = 0
  while prefix < min_count and old_lines[prefix + 1] == new_lines[prefix + 1] do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < min_count - prefix
    and old_lines[old_count - suffix] == new_lines[new_count - suffix]
  do
    suffix = suffix + 1
  end

  return {
    prefix = prefix,
    suffix = suffix,
    old_first = prefix + 1,
    old_last_exclusive = old_count - suffix + 1,
    new_first = prefix + 1,
    new_last_exclusive = new_count - suffix + 1,
  }
end

local function visible_col2(text)
  text = text or ""
  if text:sub(-1) == "\n" then return math.max(1, #text) end
  return #text + 1
end

local function ensure_line(model, line)
  line = common.clamp(math.floor(tonumber(line) or 1), 1, math.max(1, model.new_line_count or 1))
  local entry = model.lines[line]
  if not entry then
    entry = { inline = {} }
    model.lines[line] = entry
  end
  return entry, line
end

local function add_inline_range(model, line, col1, col2, tag)
  if col2 <= col1 then return end
  local entry = ensure_line(model, line)
  local last = entry.inline[#entry.inline]
  if last and last.tag == tag and col1 <= last.col2 then
    if col2 > last.col2 then last.col2 = col2 end
  else
    entry.inline[#entry.inline + 1] = { col1 = col1, col2 = col2, tag = tag }
  end
end

local function add_line_flash(model, line, tag)
  local entry = ensure_line(model, line)
  entry.line = true
  entry.tag = entry.tag or tag
end

local function add_insert_line(model, line, text)
  local entry = ensure_line(model, line)
  entry.line = true
  entry.tag = entry.tag or "insert"
  local col2 = visible_col2(text)
  if col2 > 1 then add_inline_range(model, line, 1, col2, "insert") end
end

local function add_delete_anchor(model, line)
  add_line_flash(model, line, "delete")
end

local function add_modify_line(model, line, old_text, new_text)
  local ok, parts = pcall(diff.inline_diff, old_text or "", new_text or "")
  if not ok or type(parts) ~= "table" then
    add_line_flash(model, line, "modify")
    return
  end

  local col = 1
  local line_col2 = visible_col2(new_text)
  for _, part in ipairs(parts) do
    local tag = part.tag
    local val = part.val or ""
    if tag == "equal" then
      col = col + #val
    elseif tag == "insert" then
      local col1 = col
      col = col + #val
      local col2 = math.min(col, line_col2)
      if col1 < col2 then add_inline_range(model, line, col1, col2, "modify") end
    elseif tag == "delete" then
      -- Deleted text has no span in the reloaded document.  If a modified line
      -- only deleted text, the line-level flash below gives the user an anchor.
    end
  end

  local entry = model.lines[line]
  if not entry or #entry.inline == 0 then add_line_flash(model, line, "modify") end
end

local function over_budget(old_count, new_count, opts)
  local max_lines = option(opts, "max_diff_lines", 50000)
  if old_count > max_lines or new_count > max_lines then return true, "too_many_lines" end
  local max_cells = option(opts, "max_diff_cells", 2 * 1000 * 1000)
  if old_count * new_count > max_cells then return true, "too_many_cells" end
  return false
end

local function add_coarse_changed_region(model, trim)
  local first = trim.new_first
  local last = trim.new_last_exclusive - 1
  if last >= first then
    for line = first, last do add_line_flash(model, line, "modify") end
  else
    add_delete_anchor(model, first)
  end
end

function M.build_model(old_lines, new_lines, opts)
  old_lines = clone_lines(old_lines)
  new_lines = clone_lines(new_lines)

  local model = {
    lines = {},
    new_line_count = math.max(1, #new_lines),
    meta = { clean = false, too_large = false },
  }

  if same_lines(old_lines, new_lines) then
    model.meta.clean = true
    return model
  end

  local trim = trim_equal_edges(old_lines, new_lines)
  model.meta.prefix = trim.prefix
  model.meta.suffix = trim.suffix

  local old_mid_count = trim.old_last_exclusive - trim.old_first
  local new_mid_count = trim.new_last_exclusive - trim.new_first
  model.meta.old_mid_count = old_mid_count
  model.meta.new_mid_count = new_mid_count

  if old_mid_count == 0 and new_mid_count == 0 then
    model.meta.clean = true
    return model
  end

  local too_large, reason = over_budget(old_mid_count, new_mid_count, opts)
  if too_large or not diff or not diff.diff_iter then
    model.meta.too_large = too_large or nil
    model.meta.reason = reason or "diff_unavailable"
    add_coarse_changed_region(model, trim)
    return model
  end

  local old_mid = slice_lines(old_lines, trim.old_first, trim.old_last_exclusive)
  local new_mid = slice_lines(new_lines, trim.new_first, trim.new_last_exclusive)
  local old_line = trim.old_first
  local new_line = trim.new_first

  local ok, err = pcall(function()
    for edit in diff.diff_iter(old_mid, new_mid) do
      if edit.tag == "equal" then
        if edit.a then old_line = old_line + 1 end
        if edit.b then new_line = new_line + 1 end
      elseif edit.tag == "modify" then
        add_modify_line(model, new_line, edit.a or "", edit.b or "")
        if edit.a then old_line = old_line + 1 end
        if edit.b then new_line = new_line + 1 end
      elseif edit.tag == "delete" then
        add_delete_anchor(model, new_line)
        if edit.a then old_line = old_line + 1 end
      elseif edit.tag == "insert" then
        add_insert_line(model, new_line, edit.b or "")
        if edit.b then new_line = new_line + 1 end
      end
    end
  end)

  if not ok then
    model.lines = {}
    model.meta.error = tostring(err)
    add_coarse_changed_region(model, trim)
  end

  return model
end

local function has_flashes(model)
  for _ in pairs(model.lines or {}) do return true end
  return false
end

local function color_with_alpha(color, alpha)
  color = color or { 255, 220, 90, 180 }
  return {
    color[1] or 255,
    color[2] or 255,
    color[3] or 255,
    math.max(0, math.min(255, math.floor((color[4] or 255) * alpha + 0.5))),
  }
end

local function model_alpha(model)
  local duration = math.max(0.01, model.duration or 1.0)
  local t = common.clamp((system.get_time() - model.start_time) / duration, 0, 1)
  local alpha = 1 - t
  return alpha * alpha
end

local function line_color_for(entry, alpha)
  if entry.tag == "delete" then
    return color_with_alpha(style.reload_diff_flash_delete_anchor or style.reload_diff_flash_line, alpha)
  end
  return color_with_alpha(style.reload_diff_flash_line, alpha)
end

local function inline_color_for(range, alpha)
  if range.tag == "insert" then
    return color_with_alpha(style.reload_diff_flash_insert_inline or style.reload_diff_flash_inline, alpha)
  end
  return color_with_alpha(style.reload_diff_flash_inline, alpha)
end

local function active_docviews_for_doc(doc)
  local out = {}
  local registry = DocView.registry and DocView.registry[doc]
  if registry then
    for view in pairs(registry) do
      if view.doc == doc then out[#out + 1] = view end
    end
  elseif core.get_views_referencing_doc then
    out = core.get_views_referencing_doc(doc)
  end
  return out
end

function M.flash(doc, old_lines, new_lines, opts)
  local cfg = plugin_config()
  if cfg == false or (cfg and cfg.enabled == false) then return nil, { disabled = true } end
  if not doc then return nil, { error = "missing_doc" } end

  old_lines = clone_lines(old_lines)
  new_lines = clone_lines(new_lines or doc.lines)
  local model = M.build_model(old_lines, new_lines, opts)
  if model.meta.clean or not has_flashes(model) then return nil, model.meta end

  model.doc = doc
  model.start_time = system.get_time()
  model.duration = option(opts, "duration", 1.0)

  local installed = {}
  for _, view in ipairs(active_docviews_for_doc(doc)) do
    if view.add_decoration_provider and view.remove_decoration_provider then
      local provider = {}
      function provider.line_background(_, provider_view, line)
        if provider_view.doc ~= doc then return nil end
        local entry = model.lines[line]
        if entry and entry.line then return line_color_for(entry, model_alpha(model)) end
      end
      function provider.inline_ranges(_, provider_view, line)
        if provider_view.doc ~= doc then return nil end
        local entry = model.lines[line]
        if not entry or not entry.inline or #entry.inline == 0 then return nil end
        local alpha = model_alpha(model)
        local ranges = {}
        for _, range in ipairs(entry.inline) do
          ranges[#ranges + 1] = {
            col1 = range.col1,
            col2 = range.col2,
            color = inline_color_for(range, alpha),
          }
        end
        return ranges
      end
      view:add_decoration_provider(PROVIDER_ID, provider, { priority = 45 })
      installed[#installed + 1] = { view = view, provider = provider }
    end
  end

  if #installed == 0 then return nil, { no_views = true } end

  core.add_thread(function()
    local stop_time = model.start_time + math.max(0.01, model.duration)
    while system.get_time() < stop_time do
      core.redraw = true
      coroutine.yield(0.016)
    end
    for _, item in ipairs(installed) do
      local view = item.view
      local entry = view.decoration_providers and view.decoration_providers[PROVIDER_ID]
      if entry and entry.provider == item.provider then
        view:remove_decoration_provider(PROVIDER_ID)
      end
    end
    core.redraw = true
  end)

  core.redraw = true
  core.log_quiet("Reload diff flash installed for %s: views=%d", doc:get_name(), #installed)
  return model, model.meta
end

M.clone_lines = clone_lines
M._build_model_for_test = M.build_model
M._provider_id_for_test = PROVIDER_ID

return M
