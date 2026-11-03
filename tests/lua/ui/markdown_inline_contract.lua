local test = require "core.test"
local harness = dofile("tests/fixtures/markdown/inline_harness.lua")

local presentation = {
  {
    "nested bold and italic compose",
    "**outer *inner* end**",
    {
      { text = "outer ", style = "strong" },
      { text = "inner", style = "strong_emphasis" },
      { text = " end", style = "strong" },
    },
  },
  {
    "a highlight keeps nested formatting",
    "==mark **bold** and *italic*==",
    {
      { text = "mark ", style = "normal", highlight = true },
      { text = "bold", style = "strong", highlight = true },
      { text = " and ", style = "normal", highlight = true },
      { text = "italic", style = "emphasis", highlight = true },
    },
  },
  {
    "strikethrough keeps nested bold",
    "~~**gone**~~",
    { { text = "gone", style = "strong", strike = true } },
  },
  {
    "comments hide their nested syntax",
    "%%**hidden** [[Note]]%%shown",
    { { text = "shown", style = "normal" } },
  },
  {
    "a Wikilink shows its alias",
    "[[Note|Alias]]",
    { { text = "Alias", style = "normal" } },
  },
  {
    "code shows extension syntax literally",
    "`==plain== [[Note]] %%text%% **bold**`",
    { { text = "==plain== [[Note]] %%text%% **bold**", style = "code" } },
  },
  {
    "code keeps typed padding in Live Preview",
    "` padded `",
    { { text = " padded ", style = "code" } },
  },
  {
    "escaped emphasis markers stay visible",
    "\\*not italic\\*",
    { { text = "*not italic*", style = "normal" } },
  },
  {
    "an unresolved reference stays visible",
    "[missing]",
    { { text = "[missing]", style = "normal" } },
  },
}

-- These check incremental consistency, not CommonMark compliance. The separate
-- standards audit supplies independent expected text and formatting.
local edits = {
  { "a space before closing bold", "**test**", 7, " ", "**test **" },
  { "a space before closing italic", "*test*", 6, " ", "*test *" },
  { "a deleted bold closer", "**test**", 7, 9, "**test" },
  { "a deleted code closer", "`**code**`", 10, 11, "`**code**" },
  { "a deleted link closer", "[label](target.md)", 18, 19, "[label](target.md" },
  { "a deleted Wikilink closer", "[[Note|Alias]]", 13, 15, "[[Note|Alias" },
  { "an escaped highlight opener", "==**mark**==", 1, "\\", "\\==**mark**==" },
  { "an incomplete bold opener", "word", 1, "**", "**word" },
  { "a comment closer", "%%**hidden**", 13, "%%", "%%**hidden**%%" },
  { "a UTF-8 edit before formatting", "é **bold**", 4, "中", "é 中**bold**" },
}

test.describe("Markdown inline presentation contracts", function()
  test.after_each(harness.close)

  for _, case in ipairs(presentation) do
    test.it(case[1], function()
      local view = harness.view(case[2])
      test.same(harness.runs(view, 1), case[3])
    end)
  end

  test.it("a reference resolves through its definition", function()
    local view = harness.view("[label][id]\n\n[id]: target.md")
    -- Reference definitions prepare on the UI scheduler after the parse.
    -- Wait for the public presentation, not a private cache or a fixed delay.
    local deadline = system.get_time() + 30
    local runs
    repeat
      runs = harness.runs(view, 1)
      if #runs == 1 and runs[1].text == "label" then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.same(runs, { { text = "label", style = "normal" } })
  end)

  for _, case in ipairs(edits) do
    test.it("edit, undo and redo agree with fresh text after " .. case[1], function()
      local before, col, change, after = case[2], case[3], case[4], case[5]
      local view, buffer = harness.view(before)
      local original = harness.snapshot(view, before)
      if type(change) == "string" then
        buffer:insert(1, col, change)
      else
        buffer:remove(1, col, 1, change)
      end
      test.equal(buffer.lines[1], after .. "\n", "edit fixture must produce its stated text")
      local edited = harness.snapshot(view, after)
      local fresh = harness.view(after)
      test.same(edited, harness.snapshot(fresh, after), "edited presentation differs from a fresh parse")
      buffer:undo()
      test.equal(buffer.lines[1], before .. "\n")
      test.same(harness.snapshot(view, before), original, "undo did not restore the presentation")
      buffer:redo()
      test.equal(buffer.lines[1], after .. "\n")
      test.same(harness.snapshot(view, after), edited, "redo did not restore the presentation")
    end)
  end
end)
