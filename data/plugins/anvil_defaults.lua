-- mod-version:3 priority:1
-- Anvil first-party defaults, promoted from the old ~/.config/anvil/init.lua.
local core = require "core"
local config = require "core.config"
config.plugins.editor_wallpaper = false
local keymap = require "core.keymap"
local style = require "core.style"
-- IntelliJ-style custom actions/keybindings and local workflow plugins.
require "plugins.intellij_actions"
require "plugins.edit_location_history"
core.reload_module("plugins.global_prompt_bar_sanitize")
require "plugins.intellij_find"
require "plugins.untitled_tabs"
core.reload_module("plugins.scale_debug_log")
-- require "plugins.editor_wallpaper"
require "plugins.centered_editor"
require "plugins.custom_welcome"
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
local emoji_font_path = "C:/Windows/Fonts/seguiemj.ttf"
local function load_text_font()
  local main_font = renderer.font.load(font_path, 15 * SCALE, { ligatures = true })
  local emoji_font = renderer.font.load(emoji_font_path, 15 * SCALE)
  return renderer.font.group({ main_font, emoji_font })
end
style.font = load_text_font()
style.code_font = load_text_font()
-- First-party editable file tree.
require "plugins.custom_nagview"
require "plugins.filetree"
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
-- Wrap long lines at word boundaries and visually indent continuations.
config.plugins.linewrapping = config.plugins.linewrapping or {}
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
