local queries = {}

queries.block = [[
  (atx_heading) @block.heading
  (setext_heading) @block.heading
  (atx_h1_marker) @marker.heading.h1
  (atx_h2_marker) @marker.heading.h2
  (atx_h3_marker) @marker.heading.h3
  (atx_h4_marker) @marker.heading.h4
  (atx_h5_marker) @marker.heading.h5
  (atx_h6_marker) @marker.heading.h6
  (setext_h1_underline) @marker.heading.h1
  (setext_h2_underline) @marker.heading.h2
  (paragraph) @block.paragraph
  (block_quote) @block.quote
  (block_quote_marker) @marker.quote
  (list) @block.list
  (list_item) @block.list_item
  (list_marker_minus) @marker.list
  (list_marker_plus) @marker.list
  (list_marker_star) @marker.list
  (list_marker_dot) @marker.list
  (list_marker_parenthesis) @marker.list
  (task_list_marker_checked) @marker.task.checked
  (task_list_marker_unchecked) @marker.task.unchecked
  (fenced_code_block) @block.code.fenced
  (indented_code_block) @block.code.indented
  (fenced_code_block_delimiter) @marker.code_fence
  (info_string) @content.code_info
  (thematic_break) @block.thematic_break
  (minus_metadata) @block.frontmatter
  (plus_metadata) @block.frontmatter
  (pipe_table) @block.table
  (pipe_table_header) @block.table_header
  (pipe_table_row) @block.table_row
  (pipe_table_cell) @block.table_cell
  (link_reference_definition) @block.link_reference
  (link_reference_definition (link_label) @content.reference_label)
  (link_reference_definition (link_destination) @content.reference_destination)
  (link_reference_definition (link_title) @content.reference_title)
  (html_block) @block.html
]]

queries.inline = [[
  (emphasis) @span.emphasis
  (strong_emphasis) @span.strong
  (strikethrough) @span.strikethrough
  (emphasis_delimiter) @marker.emphasis
  (code_span) @span.code
  (code_span_delimiter) @marker.code
  (inline_link) @span.link
  (full_reference_link) @span.link_reference
  (collapsed_reference_link) @span.link_reference
  (shortcut_link) @span.link_reference
  (full_reference_link (link_label) @content.reference_label)
  (image) @span.image
  (link_destination) @content.link_destination
  (link_text) @content.link_text
  (image_description) @content.image_alt
  (backslash_escape) @span.escape
  (hard_line_break) @span.hard_break
  (html_tag) @span.html
  (latex_block) @span.math
  (latex_span_delimiter) @marker.math
]]

return queries
