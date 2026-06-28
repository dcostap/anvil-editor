local style = require "core.style"
local common = require "core.common"

-- Anvil Light theme.
-- Based on JetBrains' bundled Experimental UI "Light" editor scheme
-- (`expUI_lightScheme.xml`) layered over the default IntelliJ light scheme and
-- paired with the first-party Anvil style schema from colors.default.

local function c(hex)
  return { common.color("#" .. hex) }
end

local C = {
  -- editor/UI colors from IntelliJ Light / ExpUI Light
  text_fg = "080808",
  text_bg = "ffffff",
  caret_row = "f5f8fe",
  gutter_bg = "ffffff",
  ignored = "5a5d6b",
  scrollbar_thumb = "c9ccd6",
  tearline = "d4d4d4",
  whitespace = "adadad",

  -- attributes from IntelliJ Light / ExpUI Light
  ctrl_clickable = "006dcc",
  ctrl_clickable_effect = "006dcc",
  block_comment = "8c8c8c",
  class_name = "174be6",
  constant = "871094",
  doc_comment = "8c8c8c",
  doc_comment_tag = "8c8c8c",
  doc_comment_tag_effect = "999999",
  doc_comment_tag_value = "3d3d3d",
  doc_markup = "008000",
  function_call = "080808",
  function_declaration = "00627a",
  identifier = "080808",
  instance_field = "871094",
  interface_name = "174be6",
  interface_effect = "3777e6",
  invalid_string_escape = "067d17",
  invalid_string_escape_effect = "ff0000",
  keyword = "0033b3",
  metadata = "9e880d",
  number = "1750eb",
  semicolon = "080808",
  static_field = "871094",
  static_method = "00627a",
  string = "067d17",
  deleted_fg = "6c707e",
  deleted_bg = "f0f0f0",
  folded_fg = "414d41",
  folded_bg = "e9f5e6",
  folded_effect = "add9c7",
  followed_hyperlink = "8552c6",
  identifier_under_caret_bg = "edebfc",
  identifier_under_caret_stripe = "d0a1ff",
  info_effect = "818594",
  java_keyword = "0033b3",
  kotlin_annotation = "9e880d",
  kotlin_constructor = "00627a",
  kotlin_dynamic_function_call = "00627a",
  kotlin_dynamic_property_call = "871094",
  kotlin_extension_function_call = "00627a",
  kotlin_instance_property = "871094",
  kotlin_mutable_variable_effect = "000000",
  kotlin_parameter = "080808",
  kotlin_type_parameter = "007e8a",
  kotlin_wrapped_into_ref = "494b57",
  not_used = "a8adbd",
  not_used_effect = "c9ccd6",
  warning_effect = "f2bf57",
  warning_stripe = "f2bf57",
  write_identifier_under_caret_bg = "fce8f4",
  write_identifier_under_caret_stripe = "f0a8d2",
}

-- Core UI
style.background = c(C.text_bg)
style.background2 = c("f7f8fa")
style.tab_background = c("ebecf0")
style.titlebar = style.tab_background
style.background3 = c("ffffff")
style.text = c(C.text_fg)
style.caret = c("000000")
style.accent = c("3574f0")
style.dim = c(C.ignored)
style.divider = c(C.tearline)
style.selection = c("a6d2ff")
style.line_number = c("aeb3c2")
style.line_number2 = c("767a8a")
style.line_highlight = c(C.caret_row)
style.scrollbar = c(C.scrollbar_thumb)
style.scrollbar_track = c(C.gutter_bg)
style.nagbar = c("ffe8e8")
style.nagbar_text = c("ad2b38")
style.nagbar_dim = { common.color "rgba(0, 0, 0, 0.20)" }
style.drag_overlay = { common.color "rgba(53, 116, 240, 0.12)" }
style.drag_overlay_tab = c("3574f0")
style.good = c("067d17")
style.warn = c(C.warning_stripe)
style.error = c("db3b4b")
style.modified = c("0033b3")

-- Diff/search/selection-like colors
style.diff_delete = c("ffe5e5")
style.diff_insert = c("e3f7e7")
style.diff_modify = c("edf3ff")
style.diff_delete_background = c("ffe5e5")
style.diff_insert_background = c("e3f7e7")
style.diff_modify_background = c("edf3ff")
style.diff_delete_inline = c("ffcccc")
style.diff_insert_inline = c("c5e5cc")
style.search_selection = c("fcd47e")
style.search_selection_text = c("000000")
style.search_selection_outline = c("c47233")
style.search_selection_secondary_outline = c("aeb3c2")
style.fuzzy_searcher_match = c("000000")
style.fuzzy_searcher_match_background = c("fcd47e")
style.selectionhighlight = c(C.identifier_under_caret_bg)
style.indent_guide = c("ebecf0")
style.indent_guide_active = c("aeb3c2")
style.whitespace = { common.color "rgba(0, 0, 0, 0.18)" }
style.whitespace_trailing = { common.color "rgba(219, 59, 75, 0.55)" }
style.transparent = { common.color "#00000000" }

-- First-party plugin colors
style.bracketmatch_color = c("93d9d9")
style.bracketmatch_char_color = c(C.java_keyword)
style.bracketmatch_block_char_color = style.background
style.bracketmatch_block_color = c("6c707e")
style.bracketmatch_frame_color = c("6c707e")
style.guide = c("a6d2ff")
style.line_wrapping_guide = c("ebecf0")
style.performance_hud_background = { common.color "rgba(255, 255, 255, 0.92)" }
style.performance_hud_recording_background = { common.color "rgba(255, 235, 236, 0.95)" }
style.performance_hud_text = c("000000")
style.performance_hud_dim = c("5a5d6b")
style.editor_wallpaper_line_highlight = { 245, 248, 254, 180 }
style.editor_wallpaper_tab_hover = { 0, 0, 0, 10 }
style.docview_content_left_edge = c("ebecf0")
style.line_hint = style.dim
style.diagnostic_error_underline = style.error
style.diagnostic_warning_underline = style.warn
style.titlebar_close_hover = { 229, 87, 101, 255 }
style.titlebar_close_pressed = { 188, 48, 62, 255 }
style.titlebar_control_hover = { 0, 0, 0, 13 }
style.titlebar_control_pressed = { 0, 0, 0, 29 }
style.titlebar_close_text = { 0, 0, 0, 255 }
style.titlebar_tab_hover = { 0, 0, 0, 12 }
style.image_grid_bright = c("ffffff")
style.image_grid_dark = c("dfe1e5")
style.fuzzy_searcher_preview_background = { 255, 255, 255, 235 }
style.fuzzy_searcher_overlay_background = { 0, 0, 0, 70 }
style.filetree_operation_create = { 32, 138, 60, 255 }
style.filetree_operation_copy = { 3, 155, 161, 255 }
style.filetree_operation_move = { 53, 116, 240, 255 }
style.filetree_operation_rename = { 131, 77, 240, 255 }
style.filetree_operation_delete = { 219, 59, 75, 255 }
style.filetree_folder_row_background = { common.color "rgba(0, 0, 0, 0.035)" }
style.diffview_plain_text = c("080808")

-- Git/diff plugin colors
style.gitdiff_addition = c("067d17")
style.gitdiff_modification = c("0033b3")
style.gitdiff_deletion = style.error
style.gitdiff_width = 2 * SCALE
style.gitdiff_overview_min_height = math.max(2, 2 * SCALE)

-- File tree Git status colors
style.filetree_git_ignored = c("8c4f00")
style.filetree_git_untracked = c("b23247")
style.filetree_git_added = c("067d17")
style.filetree_git_modified = c("0033b3")
style.filetree_git_deleted = c("6c707e")
style.filetree_git_additions = style.gitdiff_addition
style.filetree_git_deletions = style.gitdiff_deletion
style.filetree_folder = c("6c707e")

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

-- IntelliJ Light semantic refinements.
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
