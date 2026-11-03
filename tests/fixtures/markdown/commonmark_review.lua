-- These cases remain active in tests/lua/markdown_spec/inline.lua.
-- The normal suite excludes only these reviewed IDs, never an entire rule.
-- Do not store today's rendered output as an expected result here.
return {
  [17] = "Live Preview keeps typed code-span padding; CommonMark trims one space at each end.",
  [329] = "Live Preview keeps typed code-span padding; CommonMark trims one space at each end.",
  [330] = "Defect: a longer backtick run inside code closes a shorter delimiter.",
  [331] = "Defect: a longer backtick run inside code closes a shorter delimiter.",
  [340] = "Defect: a longer backtick run inside code closes a shorter delimiter.",
  [343] = "Defect: an HTML-like code fragment consumes text after its closing backtick.",
  [353] = "Defect: non-breaking spaces must not make an emphasis opener or closer.",
  [380] = "Defect: double asterisks beside a word and quotation mark become emphasis.",
  [385] = "Defect: double underscores beside a word and quotation mark become emphasis.",
  [391] = "Defect: a space before a bold closer produces italic text.",
  [392] = "Defect: punctuation beside a delimiter run produces unwanted emphasis.",
  [397] = "Defect: a space before an underscore bold closer produces italic text.",
  [398] = "Defect: punctuation beside an underscore run produces unwanted emphasis.",
  [411] = "Defect: adjacent nested delimiter runs differ from the reference.",
  [412] = "Defect: an internal double-asterisk run consumes literal text.",
  [415] = "Defect: adjacent nested delimiter runs differ from the reference.",
  [429] = "Defect: adjacent nested delimiter runs differ from the reference.",
}
