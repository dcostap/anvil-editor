local style = require "core.style"
local common = require "core.common"

-- Anvil Dark theme.
-- Exposed to users as "dark" while remaining the internal default style schema.
-- Promoted from the personal OneDark defaults; this file is the complete
-- first-party style schema. Other themes may override any of these keys, but
-- first-party plugins should be able to rely on these values existing.

local function c(hex)
  return { common.color("#" .. hex) }
end

local C = {
  -- editor/UI colors
  text_fg = "bcc9d9",
  text_bg = "1c1e26",
  caret_row = "2D2D33",
  gutter_bg = "313338",
  ignored = "938B8C",
  scrollbar_thumb = "3C3F41",
  scrollbar_thumb_hover = "5a5f63",
  scrollbar_thumb_active = "74797d",
  tearline = "4E5153",
  whitespace = "46494B",

  -- attributes
  ctrl_clickable = "59a0fa",
  ctrl_clickable_effect = "589df6",
  block_comment = "858585",
  class_name = "7dba83",
  constant = "ac88bf",
  doc_comment = "339c9c",
  doc_comment_tag = "218dcb",
  doc_comment_tag_effect = "3b8bb4",
  doc_comment_tag_value = "8a9fa8",
  doc_markup = "52c77e",
  function_call = "e7d0c3",
  function_declaration = "e9b379",
  identifier = "bccbd9",
  instance_field = "d7a7f1",
  interface_name = "75c37b",
  interface_effect = "47755e",
  invalid_string_escape = "769765",
  invalid_string_escape_effect = "ff0000",
  keyword = "e0905c",
  metadata = "bbb529",
  number = "e7a270",
  semicolon = "5697d9",
  static_field = "d3a5ec",
  static_method = "ffcd8a",
  string = "59a577",
  deleted_fg = "c0c0c0",
  deleted_bg = "450505",
  folded_fg = "9a9a9c",
  folded_bg = "2c3539",
  folded_effect = "416383",
  followed_hyperlink = "297de2",
  identifier_under_caret_bg = "274324",
  identifier_under_caret_stripe = "36b13",
  info_effect = "72775f",
  java_keyword = "68b0e6",
  kotlin_annotation = "c08c8f",
  kotlin_constructor = "aae381",
  kotlin_dynamic_function_call = "ead6b3",
  kotlin_dynamic_property_call = "decaaa",
  kotlin_extension_function_call = "e9d5bd",
  kotlin_instance_property = "d29ed2",
  kotlin_mutable_variable_effect = "626669",
  kotlin_parameter = "a9b7c6",
  kotlin_type_parameter = "4fa799",
  kotlin_wrapped_into_ref = "b0c0cf",
  not_used = "94959c",
  not_used_effect = "56595c",
  warning_effect = "717b7b",
  warning_stripe = "be9117",
  write_identifier_under_caret_bg = "503653",
  write_identifier_under_caret_stripe = "b56277",
}

-- Core UI
style.background = c(C.text_bg)
style.background2 = c("26282b")
style.tab_background = c("202126")
style.titlebar = style.tab_background
style.background3 = c(C.text_bg)
style.autocomplete_border = { common.color "rgba(255, 255, 255, 0.25)" }
style.autocomplete_selection = c("30343a")
style.text = c(C.text_fg)
style.caret = c("ffffff")
style.accent = c(C.ctrl_clickable)
style.dim = c(C.ignored)
style.divider = c(C.tearline)
style.selection = c("214283")
style.line_number = c("606366")
style.line_number2 = c("b2b6bc")
style.line_highlight = c(C.caret_row)
style.scrollbar = c(C.scrollbar_thumb)
style.scrollbar_hover = c(C.scrollbar_thumb_hover)
style.scrollbar_active = c(C.scrollbar_thumb_active)
style.scrollbar_track = c(C.gutter_bg)
style.nagbar = c(C.deleted_bg)
style.nagbar_text = c(C.deleted_fg)
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.45)" }
style.drag_overlay = { common.color "rgba(255, 255, 255, 0.08)" }
style.drag_overlay_tab = c(C.ctrl_clickable)
style.good = c(C.string)
style.warn = c(C.warning_stripe)
style.error = c("c56a6a")
style.modified = c(C.ctrl_clickable)
style.markdown_live_heading_marker = style.dim
style.markdown_live_link = c(C.ctrl_clickable)
style.markdown_live_external_link = c(C.ctrl_clickable)
style.markdown_live_missing_link = style.warn
style.markdown_live_ambiguous_link = c(C.warning_stripe)
style.markdown_live_pending_link = style.dim
style.markdown_live_unresolved_link = style.warn
style.markdown_live_inline_code_bg = style.background2
style.markdown_live_code_background = style.background2
style.markdown_live_code_header = style.dim
style.markdown_live_highlight_bg = c(C.warning_stripe)
style.markdown_live_quote_bar = style.accent
style.markdown_live_callout_background = style.background2
style.markdown_live_callout_icon = style.accent
style.markdown_live_frontmatter_background = style.background2
style.markdown_live_frontmatter_delimiter = style.dim
style.markdown_live_frontmatter_key = style.accent
style.markdown_live_list_marker = style.accent
style.markdown_live_task_checked = style.dim
style.markdown_live_task_unchecked = style.accent
style.markdown_live_rule = style.dim
style.markdown_live_tag = style.accent
style.markdown_live_reference_definition = style.dim
style.markdown_live_math_background = style.background2
style.markdown_live_math = style.syntax.literal
style.markdown_live_footnote = style.accent
style.markdown_live_image_background = style.background2
style.markdown_live_image_loading = style.dim
style.markdown_live_image_blocked = c(C.warning_stripe)
style.markdown_live_image_error = style.error
style.markdown_live_attachment_bg = style.background2
style.markdown_live_embed_background = style.background2
style.markdown_live_embed_text = style.text
style.markdown_live_table_background = style.background2
style.markdown_live_table_header = style.accent
style.markdown_live_table_cell = style.text
style.markdown_live_table_separator = style.dim
style.markdown_live_hidden_syntax = style.dim

-- Diff/search/selection-like colors
style.diff_delete = c(C.deleted_bg)
style.diff_insert = c(C.identifier_under_caret_bg)
style.diff_modify = c(C.warning_stripe)
style.diff_delete_background = c(C.deleted_bg)
style.diff_insert_background = c(C.identifier_under_caret_bg)
style.diff_modify_background = c(C.write_identifier_under_caret_bg)
style.diff_delete_inline = c(C.deleted_bg)
style.diff_insert_inline = c(C.identifier_under_caret_bg)
style.search_selection = c("214283")
style.search_selection_text = nil
style.search_selection_outline = c("c8c8c8")
style.search_selection_secondary_outline = c("777777")
style.fuzzy_searcher_match = c("000000")
style.fuzzy_searcher_match_background = { 186, 151, 82, 230 }
style.selectionhighlight = c("274324")
style.reload_diff_flash_line = { common.color "rgba(255, 220, 90, 0.22)" }
style.reload_diff_flash_inline = { common.color "rgba(255, 220, 90, 0.48)" }
style.reload_diff_flash_insert_inline = { common.color "rgba(105, 210, 130, 0.48)" }
style.reload_diff_flash_delete_anchor = { common.color "rgba(255, 120, 120, 0.28)" }
style.indent_guide = { common.color "rgba(255, 255, 255, 0.09)" }
style.indent_guide_active = { common.color "rgba(255, 255, 255, 0.24)" }
style.whitespace = { common.color "rgba(255, 255, 255, 0.13)" }
style.whitespace_trailing = { common.color "rgba(255, 255, 255, 0.16)" }
style.transparent = { common.color "#00000000" }

-- First-party plugin colors
style.bracketmatch_color = c(C.function_declaration)
style.bracketmatch_char_color = c(C.java_keyword)
style.bracketmatch_block_char_color = style.background
style.bracketmatch_block_color = style.line_number2
style.bracketmatch_frame_color = c("9da1a7")
style.guide = style.selection
style.line_wrapping_guide = style.whitespace
style.performance_hud_background = { common.color "rgba(0, 0, 0, 0.70)" }
style.performance_hud_recording_background = { common.color "rgba(140, 0, 0, 0.75)" }
style.performance_hud_text = c("ffffff")
style.performance_hud_dim = c("c8c8c8")
style.editor_wallpaper_line_highlight = { 64, 64, 64, 128 }
style.editor_wallpaper_tab_hover = { 255, 255, 255, 10 }
style.docview_content_left_edge = style.whitespace
style.line_hint = style.dim
style.fold_widget_background = c(C.folded_bg)
style.fold_widget_text = c(C.folded_fg)
style.fold_widget_effect = c(C.folded_effect)
style.fold_widget_border = c(C.ctrl_clickable_effect)
style.diagnostic_error_underline = style.error
style.diagnostic_warning_underline = style.warn
style.titlebar_close_hover = { 196, 43, 28, 255 }
style.titlebar_close_pressed = { 153, 31, 32, 255 }
style.titlebar_control_hover = { 255, 255, 255, 18 }
style.titlebar_control_pressed = { 255, 255, 255, 32 }
style.titlebar_close_text = { 255, 255, 255, 255 }
style.titlebar_tab_hover = { 255, 255, 255, 12 }
style.image_grid_bright = c("AAAAAA")
style.image_grid_dark = c("555555")
style.fuzzy_searcher_preview_background = { 0, 0, 0, 210 }
style.fuzzy_searcher_overlay_background = { 0, 0, 0, 110 }
style.fuzzy_searcher_result_row_padding = 2 * SCALE
style.filetree_operation_create = { 130, 220, 140, 255 }
style.filetree_operation_copy = { 105, 210, 230, 255 }
style.filetree_operation_move = { 130, 175, 255, 255 }
style.filetree_operation_rename = { 205, 170, 255, 255 }
style.filetree_operation_delete = { 255, 120, 120, 255 }
style.filetree_folder_row_background = { common.color "rgba(220, 220, 220, 0.05)" }
style.project_path_external = c("68b0e6")
style.project_path_external_dim = c("6f8aa3")
style.project_path_vendored = c("bbb529")
style.project_path_vendored_dim = c("8f8a48")
style.project_path_excluded = c("c56a6a")
style.project_path_missing = style.warn
style.project_path_separator = style.dim
style.diffview_plain_text = c("ffffff")

-- Git changed-line colors
style.git_change_addition = c("587c0c")
style.git_change_modification = c("0c7d9d")
style.git_change_deletion = c("94151b")
style.gitdiff_width = 2 * SCALE
style.gitdiff_overview_min_height = math.max(2, 2 * SCALE)

-- File tree Git status and line-count colors
style.filetree_git_status_ignored = c("5f6368")
style.filetree_git_status_untracked = c("c98282")
style.filetree_git_status_added = style.git_change_addition
style.filetree_git_status_modified = c("3b82f6")
style.filetree_git_status_deleted = c("c98282")
style.filetree_git_line_additions = style.git_change_addition
style.filetree_git_line_deletions = style.git_change_deletion
style.filetree_folder = style.dim

-- Anvil's common syntax slots.
style.syntax["normal"] = c(C.text_fg)
style.syntax["symbol"] = c(C.identifier)
style.syntax["comment"] = c(C.block_comment)
style.syntax["keyword"] = c(C.java_keyword)
style.syntax["keyword2"] = c(C.java_keyword)
style.syntax["number"] = c(C.number)
style.syntax["literal"] = c(C.java_keyword)
style.syntax["string"] = c(C.string)
style.syntax["operator"] = c(C.semicolon)
style.syntax["function"] = c(C.function_declaration)

-- Broad semantic roots. Detailed Tree-sitter/LSP child keys (for example
-- `type.class`, `variable.property.readonly`, or `function.method`) are resolved
-- through the syntax hierarchy unless a theme overrides them.
style.syntax["type"] = c(C.class_name)
style.syntax["variable"] = c(C.identifier)
style.syntax["constant"] = c(C.constant)
style.syntax["annotation"] = c(C.kotlin_annotation)
style.syntax["markup"] = c(C.doc_markup)
style.syntax["punctuation"] = c(C.semicolon)
style.syntax["error"] = c(C.invalid_string_escape_effect)
style.syntax["warning"] = c(C.warning_stripe)

-- OneDark custom-specific semantic refinements.
style.syntax["keyword.return"] = c(C.java_keyword)
style.syntax["keyword.function"] = c(C.java_keyword)
style.syntax["keyword.operator"] = c(C.java_keyword)
style.syntax["keyword.modifier"] = c(C.java_keyword)
style.syntax["function.declaration"] = c(C.function_declaration)
style.syntax["function.definition"] = c(C.function_declaration)
style.syntax["function.call"] = c(C.function_call)
style.syntax["function.method"] = c(C.function_declaration)
style.syntax["function.method.declaration"] = c(C.function_declaration)
style.syntax["function.method.definition"] = c(C.function_declaration)
style.syntax["function.method.call"] = c(C.function_call)
style.syntax["function.constructor"] = c(C.kotlin_constructor)
style.syntax["function.method.static"] = c(C.static_method)
style.syntax["function.macro"] = c(C.static_method)
style.syntax["type.class"] = c(C.class_name)
style.syntax["type.struct"] = c(C.class_name)
style.syntax["type.enum"] = c(C.class_name)
style.syntax["type.interface"] = c(C.interface_name)
style.syntax["type.parameter"] = c(C.kotlin_type_parameter)
style.syntax["type.builtin"] = c(C.java_keyword)
style.syntax["type.namespace"] = c(C.identifier)
style.syntax["variable.property"] = c(C.kotlin_instance_property)
style.syntax["variable.field"] = c(C.kotlin_instance_property)
style.syntax["variable.property.static"] = c(C.static_field)
style.syntax["variable.parameter"] = c(C.kotlin_parameter)
style.syntax["variable.readonly"] = c(C.constant)
style.syntax["constant.builtin"] = c(C.constant)
style.syntax["constant.enum_member"] = c(C.constant)
style.syntax["annotation.decorator"] = c(C.kotlin_annotation)
style.syntax["metadata"] = c(C.metadata)
style.syntax["doc_comment"] = c(C.doc_comment)
style.syntax["doccomment"] = c(C.doc_comment)
style.syntax["tag"] = c(C.doc_comment_tag)
style.syntax["string.escape"] = c(C.invalid_string_escape)
style.syntax["punctuation.delimiter"] = c(C.semicolon)
style.syntax["punctuation.bracket"] = c(C.semicolon)

style.log["INFO"] = { icon = "i", color = style.text }
style.log["WARN"] = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
