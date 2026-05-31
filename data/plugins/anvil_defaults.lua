-- mod-version:3 priority:1
-- Anvil first-party defaults, promoted from the old ~/.config/anvil/init.lua.
local core = require "core"
local config = require "core.config"
local style = require "core.style"
-- Theme.
core.reload_module("colors.onedark")
-- IntelliJ-style custom actions/keybindings and local workflow plugins.
require "plugins.intellij_actions"
require "plugins.edit_location_history"
core.reload_module("plugins.global_prompt_bar_sanitize")
require "plugins.intellij_find"
require "plugins.untitled_tabs"
core.reload_module("plugins.scale_debug_log")
require "plugins.editor_wallpaper"
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
-- Code font with programming ligatures and emoji fallback.
local code_font = renderer.font.load(
  "C:/Windows/Fonts/CascadiaCode.ttf",
  15 * SCALE,
  { ligatures = true }
)
local emoji_font = renderer.font.load(
  "C:/Windows/Fonts/seguiemj.ttf",
  15 * SCALE
)
style.code_font = renderer.font.group({ code_font, emoji_font })
-- First-party editable file tree.
require "plugins.custom_nagview"
require "plugins.filetree"
-- Use 4 spaces for soft tabs/indentation.
config.indent_size = 4
config.tab_type = "soft"
-- Match IntelliJ/VSCode-style occurrence selection.
config.select_add_next_no_case = true
-- Integrated app-owned titlebar. On Windows this uses native non-client
-- integration for shadow/resize/snap behavior while Lua draws the top bar.
if PLATFORM == "Windows" then
  config.borderless = true
  config.integrated_titlebar_tabs = false
end
-- Cleaner tabs: hide cramped close buttons and reduce default tab width.
config.tab_close_button = false
style.tab_width = 120 * SCALE
-- Keep the official autosave plugin disabled if it ever gets installed later.
config.plugins.autosave = false
-- Re-apply local shortcuts after plugins that append their own bindings.
if core.intellij_find_install_shortcut_override then
  core.intellij_find_install_shortcut_override()
end
if core.fuzzy_searcher_install_global_keymaps then
  core.fuzzy_searcher_install_global_keymaps()
end
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
-- Don't allow scrolling far beyond the end of a file.
config.scroll_past_end = false
-- Keep scrollbars visible in a small/contracted form instead of expanding/fading.
config.force_scrollbar_status = "contracted"
