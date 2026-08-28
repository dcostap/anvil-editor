-- mod-version:3 priority:120
local json = require "core.json"
local syntax = require "core.syntax"

local MAX_DETECTION_BYTES = 1024 * 1024

local function detect_json(text)
  if #text > MAX_DETECTION_BYTES then return nil end
  local content = text:match("^%s*(.-)%s*$") or ""
  local first = content:sub(1, 1)
  if first ~= "{" and first ~= "[" then return nil end
  if content == "{}" or content == "[]" then return nil end
  local _, err = json.decode(content)
  return err == nil and 1 or nil
end

syntax.add {
  name = "JSON",
  files = { "%.json$", "%.geojson$", "%.topojson$" },
  detect_content = detect_json,
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
