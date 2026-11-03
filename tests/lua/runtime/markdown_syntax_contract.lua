local Buffer = require "core.buffer"
local json = require "core.json"
local model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

-- These are Anvil's public semantic nodes, not a second Markdown parser.
-- Each span names the exact source that it must own. Structural blocks are
-- checked separately because paragraph wrappers are not presentation rules.
local cases = {
  { "an Anvil tag is not an ATX heading", "#not a heading **bold**", {}, { { "tag", "#not" }, { "strong", "**bold**" } } },
  { "seven hashes do not make a heading", "####### plain", {}, {} },
  { "an ATX heading keeps nested formatting", "## title **bold**", { "heading" }, { { "strong", "**bold**" } } },
  { "a setext underline makes a heading", "Title\n===", { "heading" }, {} },
  { "a setext underline takes precedence over a break", "Title\n---", { "heading" }, {} },
  { "a separated thematic break stays a break", "before\n\n***\n\nafter", { "thematic_break" }, {} },
  { "a quote keeps inline formatting", "> **bold**", { "quote" }, { { "strong", "**bold**" } } },
  { "list items keep their own inline formatting", "- one\n- **two**", { "list", "list_item", "list_item" }, { { "strong", "**two**" } } },
  { "an ordered list keeps inline code", "3. `code`\n4. text", { "list", "list_item", "list_item" }, { { "code", "`code`" } } },
  { "an escaped heading marker stays text", "\\# text **bold**", {}, { { "escape", "\\#" }, { "strong", "**bold**" } } },
  { "UTF-8 text does not shift a span", "é中 **bold**", {}, { { "strong", "**bold**" } } },
  { "a double backtick span owns an inner backtick", "``a`b``", {}, { { "code", "``a`b``" } } },
  { "an inline link owns its label and destination", "[label](target.md)", {}, { { "link", "[label](target.md)" } } },
  { "a link label keeps nested bold", "[**bold**](target.md)", {}, { { "link", "[**bold**](target.md)" }, { "strong", "**bold**" } } },
  { "balanced parentheses stay in a link destination", "[label](target_(x).md)", {}, { { "link", "[label](target_(x).md)" } } },
  { "an escaped bracket does not start a link", "\\[label](target.md)", {}, { { "escape", "\\[" } } },
  { "an image is not an ordinary link", "![alt](image.png)", {}, { { "image", "![alt](image.png)" } } },
  { "inline code suppresses standard and Anvil syntax", "`**raw** ==raw== [[Note]] %%raw%%`", {}, { { "code", "`**raw** ==raw== [[Note]] %%raw%%`" } } },
  { "a fenced block suppresses inline syntax", "```\n**raw** ==raw== [[Note]]\n```", { "code_fenced" }, {} },
  { "a tilde fence suppresses inline syntax", "~~~\n*raw* %%raw%%\n~~~", { "code_fenced" }, {} },
  { "an open fence protects the remaining text", "```\n**raw**", { "code_fenced" }, {} },
  { "an indented block suppresses inline syntax", "    **raw** ==raw== [[Note]]", { "code_indented" }, {} },
  { "raw HTML blocks suppress Markdown and extensions", "<div>\n**raw** ==raw== [[Note]]\n</div>", { "html" }, {} },
  { "YAML frontmatter suppresses inline syntax", "---\ntitle: **raw**\n---\nbody", { "frontmatter" }, {} },
  { "TOML frontmatter suppresses inline syntax", "+++\ntitle = \"**raw**\"\n+++\nbody", { "frontmatter" }, {} },
  { "an Anvil highlight can contain bold", "==**mark**==", {}, { { "highlight", "==**mark**==" }, { "strong", "**mark**" } } },
  { "an Anvil comment suppresses nested formatting", "%%**hidden** [[Note]]%% **shown**", {}, { { "comment", "%%**hidden** [[Note]]%%" }, { "strong", "**shown**" } } },
  { "an Anvil comment can cross a line", "%%**hidden**\nstill hidden%% **shown**", {}, { { "comment", "%%**hidden**\nstill hidden%%" }, { "strong", "**shown**" } } },
  { "an Anvil alias is a Wikilink rather than a reference link", "[[Note|Alias]]", {}, { { "wiki_link", "[[Note|Alias]]" } } },
  { "a table keeps bold and code inside cells", "| **head** | plain |\n| --- | --- |\n| body | `code` |", { "table" }, { { "strong", "**head**" }, { "code", "`code`" } } },
}

local structural = {}
for _, kind in ipairs({ "heading", "quote", "list", "list_item", "thematic_break",
  "code_fenced", "code_indented", "html", "frontmatter", "table" }) do
  structural[kind] = true
end
local block_detail = { paragraph = true, table_header = true, table_row = true, table_cell = true }
local buffer

local function sorted(values)
  table.sort(values)
  return values
end

local function nodes_for(source)
  buffer = Buffer("syntax-contract.md", "syntax-contract.md", true)
  buffer:insert(1, 1, source .. "\n")
  local instance = model.get(buffer)
  local deadline = system.get_time() + 30
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.01) end
  end
  test.equal(instance.status, "ready", instance.reason)
  return test.not_nil(instance:nodes_for_lines(1, #buffer.lines))
end

test.describe("Markdown syntax contracts", function()
  test.after_each(function()
    if buffer then model.close(buffer, "syntax-contract-test") buffer = nil end
  end)

  for _, case in ipairs(cases) do
    test.it(case[1], function()
      local source, wanted_blocks, wanted_spans = case[2], case[3], case[4]
      local blocks, spans, expected = {}, {}, {}
      for _, node in ipairs(nodes_for(source)) do
        if structural[node.type] then
          blocks[#blocks + 1] = node.type
        elseif not block_detail[node.type] then
          local range = node.source
          local text = buffer:get_text(range.line1, range.col1, range.line2, range.col2)
          spans[#spans + 1] = node.type .. ":" .. text .. ":" .. range.start_byte
        end
      end
      for _, span in ipairs(wanted_spans) do
        -- The literal span is independent of the parser. This lookup checks
        -- byte positions without copying the parser's delimiter rules.
        local start = test.not_nil(source:find(span[2], 1, true)) - 1
        expected[#expected + 1] = span[1] .. ":" .. span[2] .. ":" .. start
      end
      test.same(sorted(blocks), sorted(wanted_blocks), "structural blocks for " .. source)
      test.same(sorted(spans), sorted(expected), "exact inline spans for " .. source
        .. "\nexpected: " .. json.encode(expected) .. "\nactual: " .. json.encode(spans))
    end)
  end
end)
