-- These cases remain active in tests/lua/markdown_spec/inline.lua.
-- The normal suite excludes only these reviewed IDs, never an entire rule.
-- Do not store today's rendered output as an expected result here.
return {
  [17] = "Live Preview keeps typed code-span padding; CommonMark trims one space at each end.",
  [329] = "Live Preview keeps typed code-span padding; CommonMark trims one space at each end.",
  [330] = "Live Preview keeps typed code-span padding.",
  [331] = "Live Preview keeps typed code-span padding.",
  [340] = "Live Preview keeps typed code-span padding.",
}
