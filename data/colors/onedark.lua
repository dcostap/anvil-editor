local style = require "core.style"
local common = require "core.common"

-- Port of "OneDark custom" from OneDark_custom.icls.
-- IntelliJ has many more semantic token slots than Anvil; all colors from
-- the scheme are preserved below and mapped to the closest Anvil style keys.

local function c(hex)
  return { common.color("#" .. hex) }
end

local C = {
  -- editor/UI colors
  text_fg = "bfccdb",
  text_bg = "1c1e26",
  caret_row = "2D2D33",
  gutter_bg = "313338",
  ignored = "938B8C",
  scrollbar_thumb = "3C3F41",
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
  function_declaration = "aae381",
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
style.background = c("16181e")
style.background2 = c("26282b")
style.tab_background = c("202126")
style.titlebar = style.tab_background
style.background3 = c(C.text_bg)
style.text = c(C.text_fg)
style.caret = c(C.ctrl_clickable)
style.accent = c(C.ctrl_clickable)
style.dim = c(C.ignored)
style.divider = c(C.tearline)
style.selection = c("214283")
style.line_number = c("606366")
style.line_number2 = c("b2b6bc")
style.line_highlight = c(C.caret_row)
style.scrollbar = c(C.scrollbar_thumb)
style.scrollbar2 = c(C.tearline)
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
style.fuzzy_searcher_match_background = c("ba9752")
style.selectionhighlight = c("274324")
style.indent_guide = { common.color "rgba(255, 255, 255, 0.09)" }
style.indent_guide_active = { common.color "rgba(255, 255, 255, 0.24)" }
style.whitespace = { common.color "rgba(255, 255, 255, 0.13)" }
style.whitespace_trailing = { common.color "rgba(255, 255, 255, 0.16)" }

-- Anvil's common syntax slots.
style.syntax["normal"] = c(C.text_fg)
style.syntax["symbol"] = c(C.identifier)
style.syntax["comment"] = c(C.block_comment)
-- Anvil's Kotlin lexer emits `private`, `fun`, etc. as generic
-- `keyword`; use the IntelliJ Java/Kotlin-looking blue keyword color rather
-- than DEFAULT_KEYWORD's orange.
style.syntax["keyword"] = c(C.java_keyword)
style.syntax["keyword2"] = c("d09bd0")
style.syntax["number"] = c(C.number)
style.syntax["literal"] = c(C.java_keyword)
style.syntax["string"] = c(C.string)
style.syntax["operator"] = c(C.semicolon)
style.syntax["function"] = c(C.function_declaration)

-- Extra semantic-ish slots for languages/plugins that emit more specific types.
style.syntax["class"] = c(C.class_name)
style.syntax["class_name"] = c(C.class_name)
style.syntax["type"] = c(C.interface_name)
style.syntax["interface"] = c(C.interface_name)
style.syntax["constant"] = c(C.constant)
style.syntax["field"] = c(C.instance_field)
style.syntax["property"] = c(C.instance_field)
style.syntax["variable"] = c(C.identifier)
style.syntax["parameter"] = c(C.kotlin_parameter)
style.syntax["annotation"] = c(C.kotlin_annotation)
style.syntax["metadata"] = c(C.metadata)
style.syntax["doccomment"] = c(C.doc_comment)
style.syntax["doc_comment"] = c(C.doc_comment)
style.syntax["tag"] = c(C.doc_comment_tag)
style.syntax["markup"] = c(C.doc_markup)
style.syntax["escape"] = c(C.invalid_string_escape)
style.syntax["error"] = c(C.invalid_string_escape_effect)
style.syntax["warning"] = c(C.warning_stripe)

style.log["INFO"] = { icon = "i", color = style.text }
style.log["WARN"] = { icon = "!", color = style.warn }
style.log["ERROR"] = { icon = "!", color = style.error }

return style
