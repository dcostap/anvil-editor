local style = require "core.style"
local common = require "core.common"

-- Anvil Dark3: charcoal surfaces, warm cream text, and amber/rose syntax.
-- Theme Editor source edits for Dark3 live in colors/edits/dark3.lua.

local function c(hex)
  return { common.color("#" .. hex) }
end

local C = {
  -- editor/UI colors
  text_fg = "c8c4b6",
  text_bg = "1e2021",
  caret_row = "292b2a",
  gutter_bg = "252725",
  ignored = "999b91",
  scrollbar_thumb = "514d44",
  scrollbar_thumb_hover = "716351",
  scrollbar_thumb_active = "a28764",
  tearline = "48463e",
  whitespace = "5c5b52",

  -- attributes
  ctrl_clickable = "d2a36b",
  ctrl_clickable_effect = "e4b984",
  block_comment = "c58550",
  class_name = "dab966",
  constant = "d9b767",
  doc_comment = "bf9469",
  doc_comment_tag = "d3a56c",
  doc_comment_tag_effect = "ac8054",
  doc_comment_tag_value = "c8b69b",
  doc_markup = "b8b95f",
  function_call = "a2b0a9",
  function_declaration = "d1c9b7",
  identifier = "c8c4b6",
  instance_field = "b5b7ae",
  interface_name = "d2ba79",
  interface_effect = "8e7854",
  invalid_string_escape = "e1a068",
  invalid_string_escape_effect = "d56860",
  keyword = "df904b",
  metadata = "c7aa73",
  number = "de8b44",
  semicolon = "b9b5a8",
  static_field = "c1b9ad",
  static_method = "b7c0ab",
  string = "aeb65f",
  deleted_fg = "e1aaa2",
  deleted_bg = "3d2928",
  folded_fg = "b1afa3",
  folded_bg = "33332d",
  folded_effect = "706346",
  followed_hyperlink = "d0b17e",
  identifier_under_caret_bg = "494039",
  identifier_under_caret_stripe = "ca985f",
  info_effect = "a59375",
  java_keyword = "c99baa",
  kotlin_annotation = "cfaa8b",
  kotlin_constructor = "daba6f",
  kotlin_dynamic_function_call = "adb7aa",
  kotlin_dynamic_property_call = "b5b7ae",
  kotlin_extension_function_call = "a6b3a8",
  kotlin_instance_property = "b5b7ae",
  kotlin_mutable_variable_effect = "77786e",
  kotlin_parameter = "c8c4b6",
  kotlin_type_parameter = "d4b767",
  kotlin_wrapped_into_ref = "b0afa5",
  not_used = "817e75",
  not_used_effect = "514f49",
  warning_effect = "ba8550",
  warning_stripe = "f7a932",
  write_identifier_under_caret_bg = "48353d",
  write_identifier_under_caret_stripe = "bc8997",
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
style.background2 = c("292a28")
style.tab_background = style.background
style.titlebar = c("292926")
style.background3 = c("242625")
style.autocomplete_border = { common.color "rgba(210, 163, 107, 0.35)" }
style.autocomplete_selection = c("45382d")
style.text = p("text_fg")
style.caret = c("ebd9b1")
style.caret_trail = { common.color "rgba(210, 163, 107, 0.30)" }
style.navigation_history_feedback = { common.color "rgba(210, 163, 107, 0.12)" }
style.accent = p("ctrl_clickable")
style.dim = p("ignored")
style.divider = p("tearline")
style.selection = c("554533")
style.row_selection = { common.color "rgba(210, 163, 107, 0.19)" }
style.row_selection_inactive = { common.color "rgba(210, 163, 107, 0.11)" }
style.line_number = c("827e71")
style.line_number2 = c("d0c4a9")
style.line_highlight = p("caret_row")
style.update_wallpaper_line_highlight()
style.scrollbar = p("scrollbar_thumb")
style.scrollbar_hover = p("scrollbar_thumb_hover")
style.scrollbar_active = p("scrollbar_thumb_active")
style.scrollbar_track = p("gutter_bg")
style.nagbar = p("deleted_bg")
style.nagbar_text = p("deleted_fg")
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.40)" }
style.drag_overlay = { common.color "rgba(210, 163, 107, 0.10)" }
style.drag_overlay_tab = p("ctrl_clickable")
style.interactive_hover_background = { common.color "rgba(210, 163, 107, 0.18)" }
style.interactive_hover_overlay = { common.color "rgba(210, 163, 107, 0.11)" }
style.interactive_hover_border = c("e0be86")
style.good = p("string")
style.warn = p("warning_stripe")
style.error = c("d5766e")
style.modified = p("ctrl_clickable")

-- Integrated terminal colors. Applications can override these per session
-- through VT control sequences. Explicit RGB colors remain unchanged.
style.terminal_foreground = p("text_fg")
style.terminal_background = p("text_bg")
style.terminal_cursor = c("ebd9b1")
style.terminal_palette = {
  c("1e2021"), c("c5736b"), c("aeb65f"), c("d9b767"),
  -- Normal ANSI blue is also a common background. Keep it dark enough
  -- for the default terminal foreground. Bright blue remains index 12.
  c("384653"), c("c99baa"), c("a2b0a9"), c("c8c4b6"),
  c("817e75"), c("df8980"), c("c0c874"), c("e4cb83"),
  c("9eafbe"), c("dfb0bf"), c("b8c5b7"), c("e9e2cf"),
}
style.markdown_live_heading_marker = style.dim
style.markdown_live_link = p("ctrl_clickable")
style.markdown_live_link_error = style.error
style.markdown_live_inline_code_bg = style.background2
style.markdown_live_code_background = style.background2
style.markdown_live_code_header = style.dim
style.markdown_live_highlight_bg = c("584931")
style.markdown_live_quote_bar = style.accent
style.markdown_live_quote_background = { 210, 163, 107, 12 }
style.markdown_live_callout_palette = {
  note     = { accent = c("b5b9a4"), background = c("30312b") },
  abstract = { accent = c("a2b0a9"), background = c("29322e") },
  info     = { accent = c("b5b9a4"), background = c("30312b") },
  todo     = { accent = c("d2a36b"), background = c("352d26") },
  tip      = { accent = c("a2b0a9"), background = c("29322e") },
  success  = { accent = c("aeb65f"), background = c("303324") },
  question = { accent = c("d9b767"), background = c("373123") },
  warning  = { accent = c("dfa05c"), background = c("392c22") },
  failure  = { accent = c("d5766e"), background = c("392726") },
  danger   = { accent = c("d5766e"), background = c("3d2626") },
  bug      = { accent = c("c99baa"), background = c("342a30") },
  example  = { accent = c("c99baa"), background = c("312b32") },
  quote    = { accent = c("aaa79c"), background = c("2e2e2b") },
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
style.diff_insert = c("25382d")
style.diff_modify = c("27354b")
style.diff_delete_background = p("deleted_bg")
style.diff_insert_background = style.diff_insert
style.diff_modify_background = style.diff_modify
style.diff_modify_inline = c("365678")
style.diff_marker_delete = { common.color "rgba(228, 97, 104, 0.74)" }
style.diff_marker_insert = { common.color "rgba(67, 184, 110, 0.72)" }
style.diff_marker_modify = { common.color "rgba(75, 159, 226, 0.72)" }
style.diff_overview_delete = { common.color "rgba(228, 97, 104, 0.58)" }
style.diff_overview_insert = { common.color "rgba(67, 184, 110, 0.54)" }
style.diff_overview_modify = { common.color "rgba(75, 159, 226, 0.54)" }
style.search_selection = c("5c4932")
style.search_selection_text = nil
style.search_selection_outline = c("dfbb7e")
style.search_selection_secondary = c("433c30")
style.search_selection_secondary_outline = c("a58d65")
style.search_overview = c("d1a16b")
style.search_overview_secondary = c("ad895e")
style.fuzzy_searcher_match = c("f1e5cb")
style.fuzzy_searcher_modifier = style.accent
style.fuzzy_searcher_match_background = { 112, 79, 46, 230 }
style.fuzzy_searcher_recent_project_icon = p("constant")
style.selectionhighlight = p("identifier_under_caret_bg")
style.copy_feedback = { common.color "rgba(210, 163, 107, 0.17)" }
style.fuzzy_searcher_copy_feedback = style.copy_feedback
style.reload_diff_flash_line = { common.color "rgba(223, 160, 92, 0.20)" }
style.reload_diff_flash_inline = { common.color "rgba(223, 160, 92, 0.44)" }
style.reload_diff_flash_insert_inline = { common.color "rgba(174, 182, 95, 0.45)" }
style.reload_diff_flash_delete_anchor = { common.color "rgba(213, 118, 110, 0.27)" }
style.indent_guide = { common.color "rgba(185, 181, 168, 0.10)" }
style.indent_guide_active = { common.color "rgba(210, 163, 107, 0.32)" }
style.whitespace = { common.color "rgba(185, 181, 168, 0.20)" }
style.whitespace_trailing = { common.color "rgba(213, 118, 110, 0.40)" }
style.transparent = { common.color "#00000000" }

-- First-party plugin colors
style.bracketmatch_color = p("function_declaration")
style.bracketmatch_char_color = p("java_keyword")
style.bracketmatch_block_char_color = style.background
style.bracketmatch_block_color = style.line_number2
style.bracketmatch_frame_color = c("d2a36b")
style.line_wrapping_guide = { common.color "rgba(185, 181, 168, 0.18)" }
style.soft_wrap_indicator = style.whitespace
style.guide = style.line_wrapping_guide
style.sticky_scroll_shadow = { common.color "rgba(0, 0, 0, 0.10)" }
style.sticky_scroll_shadow_height = 10 * SCALE
style.poi_preview_shadow = { common.color "rgba(0, 0, 0, 0.07)" }
style.poi_preview_shadow_size = 4 * SCALE
style.performance_hud_background = { common.color "rgba(30, 32, 33, 0.90)" }
style.performance_hud_recording_background = { common.color "rgba(85, 38, 36, 0.90)" }
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
style.titlebar_close_hover = { 148, 70, 62, 255 }
style.titlebar_close_pressed = { 110, 49, 44, 255 }
style.titlebar_control_hover = { 210, 163, 107, 22 }
style.titlebar_control_pressed = { 210, 163, 107, 38 }
style.titlebar_close_text = p("text_fg")
style.titlebar_tab_active = style.background
style.titlebar_tab_hover = { 210, 163, 107, 17 }
style.titlebar_pane_number = style.dim
style.titlebar_group_indicator = { common.color "rgba(210, 163, 107, 0.62)" }
style.image_grid_bright = c("383832")
style.image_grid_dark = c("292a26")
style.image_overlay_background = { 0, 0, 0, 225 }
style.fuzzy_searcher_preview_background = { 0, 0, 0, 210 }
style.fuzzy_searcher_overlay_background = { 0, 0, 0, 89 }
style.fuzzy_searcher_result_selection_background = { common.color "rgba(210, 163, 107, 0.17)" }
style.fuzzy_searcher_result_hover_background = { common.color "rgba(210, 163, 107, 0.09)" }
style.global_prompt_bar_overlay_background = { 0, 0, 0, 72 }
style.fuzzy_searcher_result_row_padding = 2 * SCALE
style.filetree_operation_create = { 174, 182, 95, 255 }
style.filetree_operation_copy = { 162, 176, 169, 255 }
style.filetree_operation_move = { 210, 163, 107, 255 }
style.filetree_operation_rename = { 201, 155, 170, 255 }
style.filetree_operation_delete = { 213, 118, 110, 255 }
style.filetree_folder_row_background = { common.color "rgba(210, 163, 107, 0.05)" }
style.project_path_external = p("function_call")
style.project_path_external_dim = c("818f88")
style.project_path_vendored = p("metadata")
style.project_path_vendored_dim = c("887555")
style.project_path_missing = style.warn
style.project_path_separator = style.dim
style.diffview_plain_text = p("text_fg")

-- Git changed-line colors
style.git_change_addition = c("43b86e")
style.git_change_modification = c("4b9fe2")
style.git_change_deletion = c("e46168")
style.gitdiff_width = common.round(2 * SCALE)
style.git_graph_colors = {
  c("d2a36b"), c("aeb65f"), c("c99baa"), c("a2b0a9"), c("d5766e"), c("d9b767"),
}
style.git_ref_head = p("string")
style.git_ref_branch = style.accent
style.git_ref_remote = p("constant")
style.git_ref_tag = p("warning_stripe")

-- File tree Git status and line-count colors
style.filetree_git_status_ignored = p("not_used")
style.filetree_git_status_untracked = c("c3847e")
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

-- Match the reference's rose control words, amber types, and sage calls.
style.syntax["keyword.return"] = p("java_keyword")
style.syntax["keyword.function"] = p("java_keyword")
style.syntax["keyword.operator"] = p("java_keyword")
style.syntax["keyword.modifier"] = p("class_name")
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
