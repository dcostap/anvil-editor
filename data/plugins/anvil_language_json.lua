-- mod-version:3 priority:120
local syntax = require "core.syntax"

syntax.add {
  name = "JSON",
  files = { "%.json$", "%.jsonc$", "%.geojson$", "%.topojson$" },
  patterns = {
    { regex = [["(?:[^"\\]|\\.)*"()\s*:]], type = { "keyword", "normal" } },
    { regex = [["(?:[^"\\]|\\.)*"]], type = "string" },
    { regex = [[-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?]], type = "number" },
    { pattern = "[%{%}%[%],:]", type = "operator" },
  },
  symbols = {
    ["true"] = "literal",
    ["false"] = "literal",
    ["null"] = "literal",
  },
}
