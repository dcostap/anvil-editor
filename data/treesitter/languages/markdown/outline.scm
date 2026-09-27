; Markdown headings are the only selected symbols.
; See data/treesitter/languages/README.md for the language review.
(atx_heading heading_content: (inline) @name) @outline.heading
(setext_heading heading_content: (paragraph) @name) @outline.heading
