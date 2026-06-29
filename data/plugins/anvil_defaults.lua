-- mod-version:3 priority:1
-- Anvil first-party defaults, promoted from the old ~/.config/anvil/init.lua.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
config.plugins.editor_wallpaper = false
local keymap = require "core.keymap"
local style = require "core.style"

local function plugin_defaults(name, defaults)
  if config.plugins[name] ~= false then
    config.plugins[name] = common.merge(defaults, config.plugins[name] or {})
  end
end

local core_plugins = {
  centered_editor = true,
  custom_nagview = true,
  custom_welcome = true,
  edit_location_history = true,
  filetree = true,
  global_prompt_bar_sanitize = true,
  intellij_actions = true,
  intellij_find = true,
  linewrapping = true,
  navigation_history = true,
  scale_debug_log = true,
  theme_editor = true,
  untitled_recovery = true,
  untitled_tabs = true,
}
core.first_party_core_plugins = core_plugins

local function assert_core_plugin_enabled(name)
  assert(
    config.plugins[name] ~= false,
    string.format('First-party core plugin "%s" cannot be disabled', name)
  )
end

local function require_core_plugin(name)
  assert_core_plugin_enabled(name)
  return require("plugins." .. name)
end

local function reload_core_plugin(name)
  assert_core_plugin_enabled(name)
  return core.reload_module("plugins." .. name)
end

plugin_defaults("autoreload", {
  always_show_nagview = false,
})
plugin_defaults("autorestart", {
  reload_type = "ask",
})
plugin_defaults("autosave_fast", {
  enabled = true,
  timeout = 3,
  hide_dirty_markers = true,
})
plugin_defaults("untitled_recovery", {
  delay = 0.25,
  large_delay = 1.0,
  large_doc_threshold = 1024 * 1024,
})
plugin_defaults("autocomplete", {
  min_len = 3,
  max_suggestions = 100,
  max_symbols = 10000,
  suggestions_scope = "global",
  desc_font_size = 15,
  hide_icons = false,
  icon_position = "left",
  hide_info = false,
})
plugin_defaults("column_guides", {
  enabled = true,
  columns = { 100, 150 },
})
plugin_defaults("centered_editor", {
  enabled = true,
  max_width = 1200,
  scale_width = true,
  min_margin = 0,
  main_tabs_only = true,
})
plugin_defaults("command_slots", {
  max_output_bytes = 10 * 1024 * 1024,
  max_output_history = 100,
  max_history = 100,
  prewarm = true,
  strip_ansi = true,
  powershell_candidates = { "pwsh.exe", "powershell.exe" },
})
plugin_defaults("diffview", {
  log_times = false,
  plain_text = false,
  plain_text_color = style.diffview_plain_text,
  fold_unchanged_by_default = true,
  fold_context_lines = 6,
  fold_min_lines = 16,
})
plugin_defaults("filetree", {
  size = 650 * SCALE,
  visible = false,
  show_hidden = false,
  delete_to_trash = PLATFORM == "Windows",
  folder_color = nil,
  folder_row_background = style.filetree_folder_row_background,
  show_line_hints = true,
})
plugin_defaults("findfile", {
  show_recent = true,
  enable_cache = false,
  cache_expiration = 60,
})
plugin_defaults("git", {
  git_path = "git",
  log_page_size = 500,
  max_output = 16 * 1024 * 1024,
})
plugin_defaults("gitdiff_highlight", {
  local_diff_debounce_ms = 200,
  max_file_size = 2 * 1024 * 1024,
  max_diff_cells = 2 * 1000 * 1000,
  max_diff_lines = 50000,
  overview = true,
  gutter = true,
})
plugin_defaults("ipc", {
  single_instance = true,
  dirs_instance = "new",
})
config.lsp = common.merge({
  -- Navigation waits longer than the old eager fallback so busy language servers
  -- such as clangd can finish Project-index-backed answers before Anvil falls
  -- back to local Tree-sitter results.
  navigation_timeout = 10,
}, config.lsp or {})

plugin_defaults("language_lua", {
  annotations = true,
})
plugin_defaults("lineguide", {
  enabled = false,
  width = 2,
  rulers = { config.line_limit },
  use_custom_color = false,
  custom_color = style.selection,
})
plugin_defaults("linewrapping", {
  mode = "letter",
  width_override = nil,
  guide = true,
  guide_color = nil,
  indent = true,
  wrapping_indent = 0,
  enable_by_default = false,
  require_tokenization = false,
})
plugin_defaults("navigation_history", {
  debug = false,
  max_entries = 150,
})
plugin_defaults("projectsearch", {
  threading = {
    workers = math.ceil(thread.get_cpu_count() / 2) + 1,
  },
  live_search = false,
  syntax_highlighting = true,
})
plugin_defaults("scale", {
  autodetect = true,
  default_scale = DEFAULT_SCALE,
  use_mousewheel = true,
})
plugin_defaults("search_ui", {
  replace_core_find = true,
  position = "bottom",
})
plugin_defaults("trimwhitespace", {
  enabled = false,
  trim_empty_end_lines = false,
})
-- IntelliJ-style navigation, custom actions/keybindings, and local workflow plugins.
require_core_plugin "navigation_history"
require_core_plugin "intellij_actions"
require_core_plugin "edit_location_history"
reload_core_plugin "global_prompt_bar_sanitize"
require_core_plugin "intellij_find"
require_core_plugin "untitled_recovery"
require_core_plugin "untitled_tabs"
reload_core_plugin "scale_debug_log"
-- require_core_plugin "editor_wallpaper"
require_core_plugin "centered_editor"
require_core_plugin "custom_welcome"
require_core_plugin "theme_editor"
if core.intellij_actions_disable_conflict_shortcuts then
  core.intellij_actions_disable_conflict_shortcuts()
end
if core.fuzzy_searcher_install_picker_keymaps then
  core.fuzzy_searcher_install_picker_keymaps()
end
if core.fuzzy_searcher_install_global_keymaps then
  core.fuzzy_searcher_install_global_keymaps()
end
-- Matching UI/code fonts with separate objects so UI and code scaling can diverge.
local font_path = DATADIR .. "/fonts/CaskaydiaCoveNerdFontMono-Regular.ttf"
local font_size = 15 * SCALE
local max_default_font_group = 10 -- native renderer FONT_FALLBACK_MAX

local default_font_fallbacks = {
  -- Keep color emoji early so broad Unicode fonts do not steal emoji glyphs.
  { "C:/Windows/Fonts/seguiemj.ttf" },
  -- Broad glyph coverage for the Unicode stress-test/general Windows installs.
  { "C:/Windows/Fonts/ARIALUNI.TTF" },
  -- Extra CJK/supplemental and common script coverage when Arial Unicode is absent/incomplete.
  { "C:/Windows/Fonts/YuGothR.ttc", "C:/Windows/Fonts/msgothic.ttc" },
  { "C:/Windows/Fonts/malgun.ttf" },
  { "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simsun.ttc" },
  { "C:/Windows/Fonts/seguisym.ttf" },
  { "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/NotoSans-Regular.ttf" },
  { "C:/Windows/Fonts/Nirmala.ttc" },
  { "C:/Windows/Fonts/LeelawUI.ttf" },
  -- These fill remaining slots on machines without some of the broader fonts above.
  { "C:/Windows/Fonts/NotoNaskhArabic-Regular.ttf", "C:/Windows/Fonts/NotoSansArabic-Regular.ttf" },
  { "C:/Windows/Fonts/NotoSansHebrew-Regular.ttf" },
  { "C:/Windows/Fonts/msjh.ttc", "C:/Windows/Fonts/mingliub.ttc" },
}

local function load_optional_font(paths, fonts)
  if #fonts >= max_default_font_group then return end
  for _, path in ipairs(paths) do
    if system.get_file_info(path) then
      local ok, font_or_error = pcall(renderer.font.load, path, font_size)
      if ok and font_or_error then
        table.insert(fonts, font_or_error)
        core.log_quiet("Default font fallback loaded: %s", path)
        return
      end
      core.log_quiet("Default font fallback failed: %s (%s)", path, tostring(font_or_error))
    end
  end
end

local function load_text_font()
  local fonts = {
    renderer.font.load(font_path, font_size, { ligatures = true }),
  }
  for _, paths in ipairs(default_font_fallbacks) do
    load_optional_font(paths, fonts)
  end
  return renderer.font.group(fonts)
end
style.font = load_text_font()
style.code_font = load_text_font()
-- First-party editable file tree.
require_core_plugin "custom_nagview"
require_core_plugin "filetree"
-- Use hard tabs for indentation, displayed at 4 columns.
config.indent_size = 4
config.tab_type = "hard"
-- Match IntelliJ/VSCode-style occurrence selection.
config.select_add_next_no_case = true
-- Integrated app-owned titlebar. On Windows this uses native non-client
-- integration for shadow/resize/snap behavior while Lua draws the top bar.
if PLATFORM == "Windows" then
  config.borderless = true
  config.integrated_titlebar_tabs = false
end
-- Cleaner tabs: grow to fit titles between compact min/max widths.
style.tab_min_width = 110 * SCALE
style.tab_max_width = 250 * SCALE
style.tab_width = style.tab_min_width
-- Keep the official autosave plugin disabled if it ever gets installed later.
config.plugins.autosave = false
-- Re-apply local shortcuts after plugins that append their own bindings.
if core.intellij_find_install_shortcut_override then
  core.intellij_find_install_shortcut_override()
end
if core.fuzzy_searcher_install_global_keymaps then
  core.fuzzy_searcher_install_global_keymaps()
end
keymap.add_direct({
  ["ctrl+shift+d"] = "doc:go-to-line",
  ["ctrl+shift+D"] = "doc:go-to-line",
})
require_core_plugin "linewrapping"
-- Wrap long lines at word boundaries and visually indent continuations.
config.plugins.linewrapping.mode = "word"
config.plugins.linewrapping.indent = true
config.plugins.linewrapping.wrapping_indent = 6
-- Keep the current-line background visible even while text is selected.
config.highlight_current_line = true
-- Keep 28 lines of vertical context around the caret when moving/typing.
config.scroll_context_lines = 28
-- Scrolling: enable smooth/interpolated vertical movement.
config.transitions = true
config.disabled_transitions.scroll = false
config.scroll_animation_type = "constant"
config.animation_rate = 4
-- Mouse wheel step; default is 70 * SCALE.
config.mouse_wheel_scroll = 120 * SCALE
-- Keep scrollbars visible in a small/contracted form instead of expanding/fading.
config.force_scrollbar_status = "contracted"
