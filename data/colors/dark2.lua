local style = require "core.style"
local common = require "core.common"

-- Anvil Dark2: near-black surfaces, cool text, and muted jade accents.
-- Theme Editor source edits for Dark2 live in colors/edits/dark2.lua.

local function c(hex)
  return { common.color("#" .. hex) }
end

local C = {
  -- editor/UI colors
  text_fg = "c1c7d1",
  text_bg = "0c0e14",
  caret_row = "181d25",
  gutter_bg = "11151d",
  ignored = "7e8b98",
  scrollbar_thumb = "334740",
  scrollbar_thumb_hover = "4b6b5b",
  scrollbar_thumb_active = "729c80",
  tearline = "31473f",
  whitespace = "45525b",

  -- attributes
  ctrl_clickable = "87b9a1",
  ctrl_clickable_effect = "a1cbb3",
  block_comment = "798790",
  class_name = "9fc4b1",
  constant = "b1b0cb",
  doc_comment = "84a59e",
  doc_comment_tag = "89b9b5",
  doc_comment_tag_effect = "6c9697",
  doc_comment_tag_value = "a7b9bc",
  doc_markup = "90be9c",
  function_call = "c4cbd2",
  function_declaration = "afcbbc",
  identifier = "c1c7d1",
  instance_field = "adaec6",
  interface_name = "9dc8b4",
  interface_effect = "587b6a",
  invalid_string_escape = "d3aa7c",
  invalid_string_escape_effect = "d17d83",
  keyword = "89baa7",
  metadata = "babd9a",
  number = "b5b9d3",
  semicolon = "91a7b4",
  static_field = "b5afc9",
  static_method = "c9ceba",
  string = "8fbd9c",
  deleted_fg = "deb1b2",
  deleted_bg = "36252b",
  folded_fg = "a3afb8",
  folded_bg = "202c2c",
  folded_effect = "527166",
  followed_hyperlink = "a6bbb9",
  identifier_under_caret_bg = "244037",
  identifier_under_caret_stripe = "719f81",
  info_effect = "729b8d",
  java_keyword = "91b6c1",
  kotlin_annotation = "b6afbd",
  kotlin_constructor = "a8c4ab",
  kotlin_dynamic_function_call = "c2cbbf",
  kotlin_dynamic_property_call = "b3bdc5",
  kotlin_extension_function_call = "b6cabd",
  kotlin_instance_property = "adaec6",
  kotlin_mutable_variable_effect = "72818b",
  kotlin_parameter = "bac3cc",
  kotlin_type_parameter = "85b7b2",
  kotlin_wrapped_into_ref = "a2b2bd",
  not_used = "6d7a82",
  not_used_effect = "3c4a50",
  warning_effect = "a88d64",
  warning_stripe = "f2b731",
  write_identifier_under_caret_bg = "38313f",
  write_identifier_under_caret_stripe = "a48ba9",
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
style.background2 = c("161923")
style.tab_background = style.background
style.titlebar = c("171c24")
style.background3 = c("10151c")
style.autocomplete_border = { common.color "rgba(119, 172, 142, 0.35)" }
style.autocomplete_selection = c("263b34")
style.text = p("text_fg")
style.caret = c("c5dfcf")
style.caret_trail = { common.color "rgba(135, 185, 161, 0.32)" }
style.navigation_history_feedback = { common.color "rgba(135, 185, 161, 0.12)" }
style.accent = p("ctrl_clickable")
style.dim = p("ignored")
style.divider = p("tearline")
style.selection = c("2a493e")
style.row_selection = { common.color "rgba(135, 185, 161, 0.18)" }
style.row_selection_inactive = { common.color "rgba(135, 185, 161, 0.10)" }
style.line_number = c("657681")
style.line_number2 = c("b3c2c3")
style.line_highlight = p("caret_row")
style.update_wallpaper_line_highlight()
style.scrollbar = p("scrollbar_thumb")
style.scrollbar_hover = p("scrollbar_thumb_hover")
style.scrollbar_active = p("scrollbar_thumb_active")
style.scrollbar_track = p("gutter_bg")
style.nagbar = p("deleted_bg")
style.nagbar_text = p("deleted_fg")
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.40)" }
style.drag_overlay = { common.color "rgba(135, 185, 161, 0.09)" }
style.drag_overlay_tab = p("ctrl_clickable")
style.interactive_hover_background = { common.color "rgba(135, 185, 161, 0.18)" }
style.interactive_hover_overlay = { common.color "rgba(135, 185, 161, 0.11)" }
style.interactive_hover_border = c("a4d0b5")
style.good = p("string")
style.warn = p("warning_stripe")
style.error = c("d1838a")
style.modified = p("ctrl_clickable")

-- Integrated terminal colors. Applications can override these per session
-- through VT control sequences. Explicit RGB colors remain unchanged.
style.terminal_foreground = p("text_fg")
style.terminal_background = c("0a0d1a")
style.terminal_cursor = c("c5dfcf")
style.terminal_palette = {
  c("0a0d1a"), c("b7757c"), c("85b996"), c("c5ae85"),
  -- Normal ANSI blue is also a common background. Keep it dark enough
  -- for the default terminal foreground. Bright blue remains index 12.
  c("29425a"), c("a8a2bf"), c("85b5b6"), c("c1c7d1"),
  c("657681"), c("d39198"), c("a3d0ae"), c("ddc99d"),
  c("9dbfd1"), c("c5b4d2"), c("a5d1cc"), c("e6e9e9"),
}
style.markdown_live_heading_marker = style.dim
style.markdown_live_link = p("ctrl_clickable")
style.markdown_live_link_error = style.error
style.markdown_live_inline_code_bg = style.background2
style.markdown_live_code_background = style.background2
style.markdown_live_code_header = style.dim
style.markdown_live_highlight_bg = c("514631")
style.markdown_live_quote_bar = style.accent
style.markdown_live_quote_background = { 135, 185, 161, 12 }
style.markdown_live_callout_palette = {
  note     = { accent = c("91b6c1"), background = c("1b2931") },
  abstract = { accent = c("85b5b6"), background = c("182b2e") },
  info     = { accent = c("91b6c1"), background = c("1b2931") },
  todo     = { accent = c("87b9a1"), background = c("1b2d27") },
  tip      = { accent = c("85b5b6"), background = c("182b2e") },
  success  = { accent = c("8fbd9c"), background = c("1c2d25") },
  question = { accent = c("babd9a"), background = c("2b2b21") },
  warning  = { accent = c("c9aa78"), background = c("30291f") },
  failure  = { accent = c("d1838a"), background = c("332328") },
  danger   = { accent = c("d1838a"), background = c("362328") },
  bug      = { accent = c("b998ad"), background = c("2d2530") },
  example  = { accent = c("b1b0cb"), background = c("262633") },
  quote    = { accent = c("a3afb8"), background = c("242a2c") },
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
style.markdown_live_image_background = style.background2
style.markdown_live_image_loading = style.dim
style.markdown_live_image_blocked = p("warning_stripe")
style.markdown_live_image_error = style.error
style.markdown_live_attachment_bg = style.background2
style.markdown_live_embed_background = style.background2
style.markdown_live_embed_text = style.text
style.markdown_live_table_background = style.background
style.markdown_live_table_header = style.text
style.markdown_live_table_cell = style.text
style.markdown_live_table_separator = style.divider
style.markdown_live_hidden_syntax = style.dim

-- Diff/search/selection-like colors
style.diff_delete = p("deleted_bg")
style.diff_insert = c("1b332b")
style.diff_modify = c("1c2b38")
style.diff_delete_background = p("deleted_bg")
style.diff_insert_background = style.diff_insert
style.diff_modify_background = style.diff_modify
style.diff_delete_inline = c("673740")
style.diff_insert_inline = c("285941")
style.diff_modify_inline = c("314c5b")
style.diff_marker_delete = { common.color "rgba(228, 97, 104, 0.74)" }
style.diff_marker_insert = { common.color "rgba(67, 184, 110, 0.72)" }
style.diff_marker_modify = { common.color "rgba(75, 159, 226, 0.72)" }
style.diff_overview_delete = { common.color "rgba(228, 97, 104, 0.58)" }
style.diff_overview_insert = { common.color "rgba(67, 184, 110, 0.54)" }
style.diff_overview_modify = { common.color "rgba(75, 159, 226, 0.54)" }
style.search_selection = c("395747")
style.search_selection_text = nil
style.search_selection_outline = c("a0c5a9")
style.search_selection_secondary = c("273d37")
style.search_selection_secondary_outline = c("729582")
style.search_overview = c("84ae94")
style.search_overview_secondary = c("5f8b78")
style.fuzzy_searcher_match = c("eef2eb")
style.fuzzy_searcher_modifier = style.accent
style.fuzzy_searcher_match_background = { 62, 103, 79, 230 }
style.fuzzy_searcher_recent_project_icon = p("constant")
style.selectionhighlight = p("identifier_under_caret_bg")
style.copy_feedback = { common.color "rgba(135, 185, 161, 0.17)" }
style.fuzzy_searcher_copy_feedback = style.copy_feedback
style.reload_diff_flash_line = { common.color "rgba(201, 170, 120, 0.20)" }
style.reload_diff_flash_inline = { common.color "rgba(201, 170, 120, 0.44)" }
style.reload_diff_flash_insert_inline = { common.color "rgba(143, 189, 156, 0.45)" }
style.reload_diff_flash_delete_anchor = { common.color "rgba(209, 131, 138, 0.27)" }
style.indent_guide = { common.color "rgba(145, 167, 180, 0.10)" }
style.indent_guide_active = { common.color "rgba(135, 185, 161, 0.32)" }
style.whitespace = { common.color "rgba(145, 167, 180, 0.20)" }
style.whitespace_trailing = { common.color "rgba(209, 131, 138, 0.40)" }
style.transparent = { common.color "#00000000" }

-- First-party plugin colors
style.bracketmatch_color = p("function_declaration")
style.bracketmatch_char_color = p("java_keyword")
style.bracketmatch_block_char_color = style.background
style.bracketmatch_block_color = style.line_number2
style.bracketmatch_frame_color = c("89b9a5")
style.line_wrapping_guide = { common.color "rgba(145, 167, 180, 0.18)" }
style.soft_wrap_indicator = style.whitespace
style.guide = style.line_wrapping_guide
style.sticky_scroll_shadow = { common.color "rgba(0, 0, 0, 0.10)" }
style.sticky_scroll_shadow_height = 10 * SCALE
style.poi_preview_shadow = { common.color "rgba(0, 0, 0, 0.07)" }
style.poi_preview_shadow_size = 4 * SCALE
style.performance_hud_background = { common.color "rgba(12, 20, 25, 0.88)" }
style.performance_hud_recording_background = { common.color "rgba(79, 36, 43, 0.88)" }
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
style.titlebar_close_hover = { 148, 66, 77, 255 }
style.titlebar_close_pressed = { 111, 46, 56, 255 }
style.titlebar_control_hover = { 135, 185, 161, 22 }
style.titlebar_control_pressed = { 135, 185, 161, 38 }
style.titlebar_close_text = p("text_fg")
style.titlebar_tab_active = style.background
style.titlebar_tab_hover = { 135, 185, 161, 17 }
style.titlebar_pane_number = style.dim
style.titlebar_group_indicator = { common.color "rgba(135, 185, 161, 0.62)" }
style.image_grid_bright = c("29362f")
style.image_grid_dark = c("19241f")
style.image_overlay_background = { 0, 0, 0, 225 }
style.fuzzy_searcher_preview_background = { 0, 0, 0, 210 }
style.fuzzy_searcher_overlay_background = { 0, 0, 0, 89 }
style.fuzzy_searcher_result_selection_background = { common.color "rgba(135, 185, 161, 0.17)" }
style.fuzzy_searcher_result_hover_background = { common.color "rgba(135, 185, 161, 0.09)" }
style.global_prompt_bar_overlay_background = { 0, 0, 0, 72 }
style.fuzzy_searcher_result_row_padding = 2 * SCALE
style.filetree_operation_create = { 143, 189, 156, 255 }
style.filetree_operation_copy = { 133, 181, 182, 255 }
style.filetree_operation_move = { 145, 182, 193, 255 }
style.filetree_operation_rename = { 177, 176, 203, 255 }
style.filetree_operation_delete = { 209, 131, 138, 255 }
style.filetree_folder_row_background = { common.color "rgba(135, 185, 161, 0.05)" }
style.project_path_external = p("java_keyword")
style.project_path_external_dim = c("718f98")
style.project_path_vendored = p("metadata")
style.project_path_vendored_dim = c("858968")
style.project_path_missing = style.warn
style.project_path_separator = style.dim
style.diffview_plain_text = p("text_fg")

-- Git changed-line colors
style.git_change_addition = c("43b86e")
style.git_change_modification = c("4b9fe2")
style.git_change_deletion = c("e46168")
style.gitdiff_width = common.round(2 * SCALE)
style.git_graph_colors = {
  c("87b9a1"), c("91b6c1"), c("b1b0cb"), c("c9aa78"), c("c28e9a"), c("85b5b6"),
}
style.git_ref_head = p("string")
style.git_ref_branch = style.accent
style.git_ref_remote = p("constant")
style.git_ref_tag = p("warning_stripe")

-- File tree Git status and line-count colors
style.filetree_git_status_ignored = p("not_used")
style.filetree_git_status_untracked = c("c28e9a")
style.filetree_git_status_added = style.git_change_addition
style.filetree_git_status_modified = style.git_change_modification
style.filetree_git_status_deleted = style.git_change_deletion
style.filetree_git_status_unmerged = style.error
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
style.syntax["literal"] = p("java_keyword")
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

-- Keep detailed syntax roles within the same jade, slate, and soft lilac range.
style.syntax["keyword.return"] = p("java_keyword")
style.syntax["keyword.function"] = p("java_keyword")
style.syntax["keyword.operator"] = p("java_keyword")
style.syntax["keyword.modifier"] = p("java_keyword")
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
style.syntax["type.builtin"] = p("java_keyword")
style.syntax["type.namespace"] = p("identifier")
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
