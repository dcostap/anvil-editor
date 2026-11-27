local style = require "core.style"
local common = require "core.common"

-- Anvil Black: pure black surfaces, near-white text, and vivid syntax for high contrast.
-- Separation comes from dividers and rims, because shadows do not show on black.

local function c(hex)
  return { common.color("#" .. hex) }
end

local C = {
  -- editor/UI colors
  text_fg = "e6e6e6",
  text_bg = "000000",
  caret_row = "121212",
  gutter_bg = "000000",
  ignored = "8c8c8c",
  scrollbar_thumb = "2e2e2e",
  scrollbar_thumb_hover = "4a4a4a",
  scrollbar_thumb_active = "6a6a6a",
  tearline = "2a2a2a",
  whitespace = "3a3a3a",

  -- attributes
  ctrl_clickable = "5aa9ff",
  ctrl_clickable_effect = "7dbbff",
  block_comment = "7d8590",
  class_name = "f2cc60",
  constant = "79c0ff",
  doc_comment = "8b98a5",
  doc_comment_tag = "56d4c4",
  doc_comment_tag_effect = "3a9e92",
  doc_comment_tag_value = "a9b4bf",
  doc_markup = "7ee787",
  function_call = "a5d6ff",
  function_declaration = "6fd3ff",
  identifier = "e6e6e6",
  instance_field = "f0a8d8",
  interface_name = "e8d47a",
  interface_effect = "8a7a3a",
  invalid_string_escape = "ffa657",
  invalid_string_escape_effect = "ff5f5f",
  keyword = "ff8f6b",
  metadata = "ffcc66",
  number = "ffa657",
  semicolon = "a0a0a0",
  static_field = "f0a8d8",
  static_method = "8ee0ff",
  string = "7ee787",
  deleted_fg = "ffb3b3",
  deleted_bg = "3a0d12",
  folded_fg = "c0c0c0",
  folded_bg = "1a1a1a",
  folded_effect = "3d5a7a",
  followed_hyperlink = "a78bfa",
  identifier_under_caret_bg = "1c2f3d",
  identifier_under_caret_stripe = "5aa9ff",
  info_effect = "7a8a9a",
  java_keyword = "b4a0ff",
  kotlin_annotation = "ffcc66",
  kotlin_constructor = "f2cc60",
  kotlin_dynamic_function_call = "a5d6ff",
  kotlin_dynamic_property_call = "f0a8d8",
  kotlin_extension_function_call = "a5d6ff",
  kotlin_instance_property = "f0a8d8",
  kotlin_mutable_variable_effect = "6a6a6a",
  kotlin_parameter = "d8dee9",
  kotlin_type_parameter = "56d4c4",
  kotlin_wrapped_into_ref = "c8c8c8",
  not_used = "7a7a7a",
  not_used_effect = "4a4a4a",
  warning_effect = "8a7a3a",
  warning_stripe = "ffc640",
  write_identifier_under_caret_bg = "3a1f3d",
  write_identifier_under_caret_stripe = "e07ad8",
}

-- Keep named colors as shared values. A rule can refer to one without
-- changing another rule that happens to have the same RGB value.
style.theme_palette = {}
local function p(name)
  local value = style.theme_palette[name]
  if not value then
    value = c(C[name])
    style.theme_palette[name] = value
  end
  return value
end
for name in pairs(C) do p(name) end

-- Core UI
style.background = p("text_bg")
style.wallpaper_reference_background = style.background
style.background2 = c("0e0e0e")
style.tab_background = style.background
style.titlebar = c("000000")
style.background3 = c("000000")
style.card_selection = { common.color "rgba(90, 169, 255, 0.22)" }
style.text = p("text_fg")
style.caret = c("ffffff")
style.caret_trail = { common.color "rgba(90, 169, 255, 0.35)" }
style.navigation_history_feedback = { common.color "rgba(126, 231, 135, 0.12)" }
style.bookmark = p("ctrl_clickable")
style.accent = p("ctrl_clickable")
style.focus_feedback = { 90, 169, 255, 120 }
style.dim = p("ignored")
style.divider = p("tearline")
style.selection = c("1f3a4a")
style.row_selection = { common.color "rgba(90, 169, 255, 0.22)" }
style.row_selection_inactive = { common.color "rgba(90, 169, 255, 0.12)" }
style.row_hover = { 255, 255, 255, 16 }
style.line_number = c("4a4a4a")
style.line_number2 = c("e6e6e6")
style.line_highlight = p("caret_row")
style.update_wallpaper_line_highlight()
style.scrollbar = p("scrollbar_thumb")
style.scrollbar_hover = p("scrollbar_thumb_hover")
style.scrollbar_active = p("scrollbar_thumb_active")
style.scrollbar_track = p("gutter_bg")
style.card = c("141414")
style.card_text = c("a8a8a8")
style.dialog_dim = { common.color "rgba(0, 0, 0, 0.60)" }
style.card_border = { 255, 255, 255, 36 }
style.card_shadow = { 0, 0, 0, 160 }
style.card_field = { 0, 0, 0, 255 }
style.button = { 255, 255, 255, 20 }
style.button_hover = { 255, 255, 255, 18 }
style.button_pressed = { 0, 0, 0, 120 }
style.button_primary_text = c("000000")
-- Dialogs and their controls (core.ui). Text has four strengths, from strong to dim.
style.dialog_text = c("e6e6e6")
style.dialog_text_strong = c("ffffff")
style.dialog_text_muted = c("a0a0a0")
style.dialog_text_dim = c("707070")
style.dialog_placeholder = c("7a7a7a")
style.dialog_focus_ring = c("5aa9ff")
style.dialog_line = { 255, 255, 255, 30 }
style.dialog_danger = c("ff6b6b")
-- The colors of Badges and Status Dots, for each tone other than neutral.
style.dialog_tones = { success = c("7ee787"), warning = c("ffc640"), danger = c("ff6b6b"), info = c("5aa9ff") }
-- A surface has a fill and a 1 px rim, each a gradient from `top` to `bottom`, and a text color.
-- `shadow` falls `shadow_y` pixels below the surface and fades over `shadow_blur` pixels, at scale 1.
style.dialog_surfaces = {
  dialog = { fill = c("121212"), fill_bottom = c("0c0c0c"), rim = { 255, 255, 255, 40 }, rim_bottom = { 255, 255, 255, 16 },
    shadow = { 0, 0, 0, 200 }, shadow_y = 16, shadow_blur = 40 },
  group = { fill = c("181818"), fill_bottom = c("161616"), rim = { 255, 255, 255, 26 }, rim_bottom = { 255, 255, 255, 26 } },
  raised = { fill = c("222222"), rim = { 255, 255, 255, 60 }, rim_bottom = { 255, 255, 255, 12 }, text = c("e6e6e6"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  raised_hover = { fill = c("2c2c2c"), rim = { 255, 255, 255, 84 }, rim_bottom = { 255, 255, 255, 18 }, text = c("ffffff"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 3 },
  lit = { fill = c("f0f0f0"), rim = { 255, 255, 255, 255 }, rim_bottom = { 255, 255, 255, 0 }, text = c("000000"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  lit_hover = { fill = c("ffffff"), rim = { 255, 255, 255, 255 }, rim_bottom = { 255, 255, 255, 0 }, text = c("000000"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 3 },
  danger_hover = { fill = c("2a0f10"), rim = { 255, 107, 107, 120 }, rim_bottom = { 255, 107, 107, 30 }, text = c("ff6b6b"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 3 },
  danger_primary = { fill = c("e0443e"), rim = c("ffb0aa"), rim_bottom = { 224, 68, 62, 0 }, text = c("ffffff"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  danger_primary_hover = { fill = c("f05550"), rim = c("ffb0aa"), rim_bottom = { 224, 68, 62, 0 }, text = c("ffffff"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 3 },
  ghost_hover = { fill = { 255, 255, 255, 24 }, fill_bottom = { 255, 255, 255, 12 }, text = c("ffffff") },
  selected = { fill = { 255, 255, 255, 22 }, fill_bottom = { 255, 255, 255, 12 }, text = c("ffffff") },
  well = { fill = c("000000"), fill_bottom = c("050505"), rim = { 255, 255, 255, 40 }, rim_bottom = { 255, 255, 255, 64 },
    text = c("e6e6e6"), shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  well_hover = { fill = c("050505"), fill_bottom = c("0a0a0a"), rim = { 255, 255, 255, 60 }, rim_bottom = { 255, 255, 255, 90 },
    text = c("e6e6e6"), shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  switch_off = { fill = c("000000"), fill_bottom = c("0a0a0a"), rim = { 255, 255, 255, 40 }, rim_bottom = { 255, 255, 255, 64 },
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  switch_off_hover = { fill = c("050505"), fill_bottom = c("101010"), rim = { 255, 255, 255, 60 }, rim_bottom = { 255, 255, 255, 90 },
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  switch_on = { fill = c("5aa9ff"), rim = { 170, 210, 255, 255 }, rim_bottom = { 90, 169, 255, 0 }, text = c("000000"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 2 },
  switch_on_hover = { fill = c("7dbbff"), rim = { 190, 222, 255, 255 }, rim_bottom = { 90, 169, 255, 0 }, text = c("000000"),
    shadow = { 0, 0, 0, 120 }, shadow_y = 1, shadow_blur = 3 },
  thumb_on = { fill = c("000000") },
  thumb_off = { fill = c("e6e6e6"), shadow = { 0, 0, 0, 140 }, shadow_y = 1, shadow_blur = 2 },
  -- Menus, such as a Select's list, and tooltips.
  popover = { fill = c("161616"), fill_bottom = c("111111"), rim = { 255, 255, 255, 44 }, rim_bottom = { 255, 255, 255, 18 },
    shadow = { 0, 0, 0, 200 }, shadow_y = 8, shadow_blur = 24 },
  -- Key caps.
  kbd = { fill = c("262626"), fill_bottom = c("1c1c1c"), rim = { 255, 255, 255, 36 }, rim_bottom = { 255, 255, 255, 10 },
    shadow = { 0, 0, 0, 140 }, shadow_y = 1 },
}
style.drag_overlay = { common.color "rgba(90, 169, 255, 0.12)" }
style.drag_overlay_tab = p("ctrl_clickable")
style.drop_target_accent = p("ctrl_clickable")
style.drop_target_background = { common.color "rgba(90, 169, 255, 0.14)" }
style.interactive_hover_background = { common.color "rgba(90, 169, 255, 0.20)" }
style.interactive_hover_overlay = { common.color "rgba(90, 169, 255, 0.12)" }
style.interactive_hover_border = c("a5d6ff")
style.good = p("string")
style.warn = p("warning_stripe")
style.error = c("ff6b6b")
style.tab_file_missing = style.error
style.modified = p("ctrl_clickable")

-- Integrated terminal colors. Applications can override these per session
-- through VT control sequences. Explicit RGB colors remain unchanged.
style.terminal_foreground = p("text_fg")
style.terminal_background = p("text_bg")
style.terminal_cursor = c("ffffff")
style.terminal_palette = {
  c("000000"), c("f14c4c"), c("4ec94e"), c("e5c84a"),
  -- Normal ANSI blue is also a common background. Keep it dark enough
  -- for the default terminal foreground. Bright blue remains index 12.
  c("2457a6"), c("c678dd"), c("3cc8c8"), c("d4d4d4"),
  c("767676"), c("ff6e6e"), c("7ee787"), c("ffe066"),
  c("6cb6ff"), c("e09aff"), c("6ee7e7"), c("ffffff"),
}
style.markdown_live_heading_marker = style.dim
style.markdown_live_link = p("ctrl_clickable")
style.markdown_live_link_error = style.error
style.markdown_live_inline_code_bg = { common.color "rgba(255, 255, 255, 0.10)" }
style.markdown_live_code_background = style.background2
style.markdown_live_code_header = style.dim
style.markdown_live_highlight_bg = c("4a3c00")
style.markdown_live_quote_bar = style.accent
style.markdown_live_quote_background = { 90, 169, 255, 14 }
style.markdown_live_callout_palette = {
  note     = { accent = c("5aa9ff"), background = c("0b1a2b") },
  abstract = { accent = c("56d4c4"), background = c("0a2220") },
  info     = { accent = c("5aa9ff"), background = c("0b1a2b") },
  todo     = { accent = c("5aa9ff"), background = c("0b1a2b") },
  tip      = { accent = c("56d4c4"), background = c("0a2220") },
  success  = { accent = c("7ee787"), background = c("0d2410") },
  question = { accent = c("f2cc60"), background = c("261f08") },
  warning  = { accent = c("ffa657"), background = c("2a1806") },
  failure  = { accent = c("ff6b6b"), background = c("2a0c0c") },
  danger   = { accent = c("ff6b6b"), background = c("2a0c0c") },
  bug      = { accent = c("f0a8d8"), background = c("261222") },
  example  = { accent = c("b4a0ff"), background = c("18132b") },
  quote    = { accent = c("a0a0a0"), background = c("141414") },
}
style.markdown_live_list_marker = style.dim
style.markdown_live_task_checked = style.accent
style.markdown_live_task_unchecked = style.dim
style.markdown_live_task_completed_text = style.dim
style.markdown_live_task_background = style.background
style.markdown_live_task_checkmark = style.background
style.markdown_live_task_hover = { style.accent[1], style.accent[2], style.accent[3], 64 }
style.markdown_live_rule = style.dim
style.markdown_live_tag = style.accent
style.markdown_live_reference_definition = style.dim
style.markdown_live_math_background = style.background2
style.markdown_live_footnote = style.accent
style.markdown_footnote_anchor_bg = { common.color "rgba(86, 212, 196, 0.22)" }
style.markdown_live_image_background = style.background2
style.markdown_live_image_selection = { common.color "rgba(90, 169, 255, 0.30)" }
style.markdown_live_image_loading = style.dim
style.markdown_live_image_blocked = p("warning_stripe")
style.markdown_live_image_error = style.error
style.markdown_live_attachment_bg = style.background2
style.markdown_live_table_background = style.background
style.markdown_live_table_header = style.text
style.markdown_live_table_cell = style.text
style.markdown_live_table_separator = style.divider
style.markdown_live_table_header_background = { common.color "rgba(255, 255, 255, 0.07)" }
style.markdown_live_table_active_cell = { common.color "rgba(90, 169, 255, 0.12)" }
style.markdown_live_table_cell_selection = { common.color "rgba(90, 169, 255, 0.18)" }
style.markdown_live_table_cell_selection_outline = style.accent
style.markdown_live_hidden_syntax = style.dim
style.markdown_footnote_card_bg = c("0d1f24")
style.markdown_footnote_card_active_bg = c("143038")
style.markdown_footnote_placeholder = style.dim

-- Diff/search/selection-like colors
style.diff_delete = p("deleted_bg")
style.diff_insert = c("0d3318")
style.diff_modify = c("0f2a4a")
style.diff_delete_background = { common.color "rgba(90, 16, 24, 0.75)" }
style.diff_insert_background = { common.color "rgba(14, 70, 32, 0.70)" }
style.diff_modify_background = { common.color "rgba(16, 52, 96, 0.70)" }
style.diff_delete_inline = { common.color "rgba(200, 50, 60, 0.50)" }
style.diff_insert_inline = { common.color "rgba(60, 180, 90, 0.40)" }
style.diff_modify_inline = { common.color "rgba(60, 130, 220, 0.50)" }
style.diff_inline_marker_insert = { common.color "rgba(78, 201, 78, 0.75)" }
style.diff_marker_delete = { common.color "rgba(241, 76, 76, 0.85)" }
style.diff_marker_insert = { common.color "rgba(78, 201, 78, 0.85)" }
style.diff_marker_modify = { common.color "rgba(90, 169, 255, 0.85)" }
style.diff_header_delete = c("ff7b7b")
style.diff_header_insert = c("7ee787")
style.diff_header_modify = c("79c0ff")
style.diff_overview_delete = { common.color "rgba(241, 76, 76, 0.70)" }
style.diff_overview_insert = { common.color "rgba(78, 201, 78, 0.65)" }
style.diff_overview_modify = { common.color "rgba(90, 169, 255, 0.65)" }
style.search_selection = c("5c4a00")
style.search_selection_text = nil
style.search_selection_outline = c("ffd84a")
style.search_selection_secondary = c("2e2600")
style.search_overview = c("ffd84a")
style.search_overview_secondary = { 255, 216, 74, 90 }
style.fuzzy_searcher_modifier = style.accent
style.fuzzy_searcher_recent_project_icon = p("constant")
style.selectionhighlight = p("identifier_under_caret_bg")
style.copy_feedback = { common.color "rgba(90, 169, 255, 0.20)" }
style.fuzzy_searcher_copy_feedback = style.copy_feedback
style.reload_diff_flash_line = { common.color "rgba(255, 198, 64, 0.20)" }
style.reload_diff_flash_inline = { common.color "rgba(255, 198, 64, 0.44)" }
style.reload_diff_flash_insert_inline = { common.color "rgba(126, 231, 135, 0.40)" }
style.reload_diff_flash_delete_anchor = { common.color "rgba(255, 107, 107, 0.30)" }
style.indent_guide = { common.color "rgba(255, 255, 255, 0.09)" }
style.indent_guide_active = { common.color "rgba(90, 169, 255, 0.40)" }
style.whitespace = { common.color "rgba(255, 255, 255, 0.20)" }
style.whitespace_trailing = { common.color "rgba(255, 107, 107, 0.40)" }
style.transparent = { common.color "#00000000" }

-- First-party plugin colors
style.bracketmatch_color = p("function_declaration")
style.bracketmatch_char_color = p("class_name")
style.bracketmatch_block_char_color = style.background
style.bracketmatch_block_color = style.line_number2
style.bracketmatch_frame_color = c("5aa9ff")
style.line_wrapping_guide = { common.color "rgba(255, 255, 255, 0.14)" }
style.soft_wrap_indicator = style.whitespace
style.guide = style.line_wrapping_guide
style.sticky_scroll_shadow = { common.color "rgba(255, 255, 255, 0.06)" }
style.sticky_scroll_shadow_height = 2 * SCALE
style.poi_preview_shadow = { common.color "rgba(255, 255, 255, 0.05)" }
style.poi_preview_shadow_size = 2 * SCALE
style.performance_hud_background = { common.color "rgba(0, 0, 0, 0.90)" }
style.performance_hud_recording_background = { common.color "rgba(90, 16, 24, 0.90)" }
style.performance_hud_text = p("text_fg")
style.performance_hud_dim = p("ignored")
style.textview_content_left_edge = style.line_wrapping_guide
style.line_hint = style.dim
style.fold_widget_background = p("folded_bg")
style.fold_widget_text = p("folded_fg")
style.fold_widget_effect = p("folded_effect")
style.fold_widget_border = p("ctrl_clickable_effect")
style.diagnostic_error_underline = style.error
style.diagnostic_warning_underline = style.warn
style.titlebar_close_hover = { 196, 43, 28, 255 }
style.titlebar_close_pressed = { 150, 32, 22, 255 }
style.titlebar_control_hover = { 255, 255, 255, 24 }
style.titlebar_control_pressed = { 255, 255, 255, 40 }
style.titlebar_close_text = c("ffffff")
style.titlebar_tab_active = c("1a1a1a")
style.titlebar_tab_hover = { 255, 255, 255, 16 }
style.titlebar_pane_number = style.dim
style.titlebar_group_indicator = { common.color "rgba(90, 169, 255, 0.70)" }
style.sidebar_hover = { 255, 255, 255, 18 }
style.sidebar_selection = { 255, 255, 255, 36 }
style.sidebar_selection_behind = { 255, 255, 255, 16 }
style.sidebar_cursor = { 90, 169, 255, 64 }
style.sidebar_card = c("1a1a1a")
style.sidebar_shadow = { 0, 0, 0, 160 }
style.image_grid_bright = c("1e1e1e")
style.image_grid_dark = c("121212")
style.image_overlay_background = { 0, 0, 0, 160 }
style.fuzzy_searcher_preview_background = { 0, 0, 0, 230 }
style.fuzzy_searcher_overlay_background = { 0, 0, 0, 140 }
style.fuzzy_searcher_result_mark_background = { common.color "rgba(90, 169, 255, 0.22)" }
style.fuzzy_searcher_result_hover_background = { common.color "rgba(255, 255, 255, 0.07)" }
style.global_prompt_bar_overlay_background = { 0, 0, 0, 120 }
style.fuzzy_searcher_result_row_padding = 2 * SCALE
style.filetree_operation_create = { 126, 231, 135, 255 }
style.filetree_operation_copy = { 86, 212, 196, 255 }
style.filetree_operation_move = { 90, 169, 255, 255 }
style.filetree_operation_rename = { 180, 160, 255, 255 }
style.filetree_operation_delete = { 255, 107, 107, 255 }
style.filetree_folder_row_background = { common.color "rgba(255, 255, 255, 0.03)" }
style.project_path_external = p("function_call")
style.project_path_external_dim = c("6a8aa5")
style.project_path_vendored = p("metadata")
style.project_path_vendored_dim = c("8a7440")
style.project_path_missing = style.warn
style.project_path_separator = style.dim
style.diffview_plain_text = p("text_fg")

-- Git changed-line colors
style.git_change_addition = c("4ec94e")
style.git_change_modification = c("5aa9ff")
style.git_change_deletion = c("f14c4c")
style.diff_inline_marker_delete = { common.color "rgba(241, 76, 76, 0.75)" }
style.gitdiff_width = common.round(2 * SCALE)
style.git_graph_colors = {
  c("5aa9ff"), c("4ec94e"), c("b4a0ff"), c("f2cc60"), c("f14c4c"), c("56d4c4"),
}
style.git_ref_head = style.git_change_addition
style.git_ref_branch = style.git_change_modification
style.git_ref_remote = c("b4a0ff")
style.git_ref_tag = c("f2cc60")

-- File tree Git status and line-count colors
style.filetree_git_status_ignored = c("6a6a6a")
style.filetree_git_status_untracked = c("b0c4d8")
style.filetree_git_status_added = style.git_change_addition
style.filetree_git_status_modified = style.git_change_modification
style.filetree_git_status_deleted = style.git_change_deletion
style.filetree_git_status_unmerged = style.git_change_deletion
style.filetree_git_line_additions = style.git_change_addition
style.filetree_git_line_deletions = style.git_change_deletion
style.filetree_folder = style.dim

-- Anvil's common syntax slots.
style.syntax["normal"] = p("text_fg")
style.syntax["symbol"] = p("identifier")
style.syntax["comment"] = p("block_comment")
style.syntax["keyword"] = p("java_keyword")
style.syntax["keyword2"] = p("java_keyword")
style.syntax["number"] = p("number")
style.syntax["literal"] = p("constant")
style.syntax["string"] = p("string")
style.syntax["operator"] = p("semicolon")
style.syntax["function"] = p("function_declaration")

-- Broad semantic roots. Detailed Tree-sitter/LSP child keys (for example
-- `type.class`, `variable.property.readonly`, or `function.method`) are resolved
-- through the syntax hierarchy unless a theme overrides them.
style.syntax["type"] = p("class_name")
style.syntax["variable"] = p("identifier")
style.syntax["constant"] = p("constant")
style.syntax["annotation"] = p("kotlin_annotation")
style.syntax["markup"] = p("doc_markup")
style.syntax["punctuation"] = p("semicolon")
style.syntax["error"] = p("invalid_string_escape_effect")
style.syntax["warning"] = p("warning_stripe")
style.syntax["todo"] = style.syntax["warning"]

-- Lavender control words, yellow types, cyan functions, and green strings.
style.syntax["keyword.return"] = p("java_keyword")
style.syntax["keyword.function"] = p("java_keyword")
style.syntax["keyword.operator"] = p("java_keyword")
style.syntax["keyword.modifier"] = p("keyword")
style.syntax["function.declaration"] = p("function_declaration")
style.syntax["function.definition"] = p("function_declaration")
style.syntax["function.call"] = p("function_call")
style.syntax["function.method"] = p("function_declaration")
style.syntax["function.method.declaration"] = p("function_declaration")
style.syntax["function.method.definition"] = p("function_declaration")
style.syntax["function.method.call"] = p("function_call")
style.syntax["function.constructor"] = p("kotlin_constructor")
style.syntax["function.method.static"] = p("static_method")
style.syntax["function.macro"] = p("static_method")
style.syntax["type.class"] = p("class_name")
style.syntax["type.struct"] = p("class_name")
style.syntax["type.enum"] = p("class_name")
style.syntax["type.interface"] = p("interface_name")
style.syntax["type.parameter"] = p("kotlin_type_parameter")
style.syntax["type.builtin"] = p("class_name")
style.syntax["type.namespace"] = p("identifier")
style.syntax["variable.builtin"] = p("keyword")
style.syntax["variable.property"] = p("kotlin_instance_property")
style.syntax["variable.field"] = p("kotlin_instance_property")
style.syntax["variable.property.static"] = p("static_field")
style.syntax["variable.parameter"] = p("kotlin_parameter")
style.syntax["variable.readonly"] = p("constant")
style.syntax["constant.builtin"] = p("constant")
style.syntax["constant.enum_member"] = p("constant")
style.syntax["annotation.decorator"] = p("kotlin_annotation")
style.syntax["metadata"] = p("metadata")
style.syntax["doc_comment"] = p("doc_comment")
style.syntax["doccomment"] = p("doc_comment")
style.syntax["tag"] = p("doc_comment_tag")
style.syntax["string.escape"] = p("invalid_string_escape")
style.syntax["punctuation.delimiter"] = p("semicolon")
style.syntax["punctuation.bracket"] = p("semicolon")

-- Bind aliases after the syntax roles so a switch from another theme does
-- not leave the old theme's color table in Markdown Live Preview.
style.markdown_live_math = style.syntax.literal

style.log["INFO"] = { icon = "i", color = style.text }
style.log["WARN"] = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
