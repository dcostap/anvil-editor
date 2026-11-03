local test = require "core.test"
local harness = dofile("tests/fixtures/markdown/inline_harness.lua")

test.describe("Markdown link label formatting", function()
  test.after_each(harness.close)

  test.it("formats Markdown inside an inline link label", function()
    local view = harness.view("[**bold**](target.md)")
    test.same(harness.runs(view, 1), { { text = "bold", style = "strong" } })
  end)

  test.it("composes mixed formatting without styling the whole label", function()
    local view = harness.view("[plain **bold** *italic* `code`](target.md)")
    test.same(harness.runs(view, 1), {
      { text = "plain ", style = "normal" },
      { text = "bold", style = "strong" },
      { text = " ", style = "normal" },
      { text = "italic", style = "emphasis" },
      { text = " ", style = "normal" },
      { text = "code", style = "code" },
    })
  end)

  test.it("keeps formatting that surrounds the link", function()
    local view = harness.view("**[plain *italic*](target.md)**")
    test.same(harness.runs(view, 1), {
      { text = "plain ", style = "strong" },
      { text = "italic", style = "strong_emphasis" },
    })
  end)

  test.it("keeps escaped label markers literal", function()
    local view = harness.view("[a \\*literal\\*](target.md)")
    test.same(harness.runs(view, 1), { { text = "a *literal*", style = "normal" } })
  end)

  test.it("formats a resolved reference link label", function()
    local view = harness.view("[**bold**][ref]\n\n[ref]: target.md")
    local deadline = system.get_time() + 30
    local runs
    repeat
      runs = harness.runs(view, 1)
      if #runs == 1 and runs[1].text == "bold" then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.same(runs, { { text = "bold", style = "strong" } })
  end)

  test.it("keeps link targets and UTF-8 source positions through a reveal", function()
    local source = "See [é **bold** end](target.md) now"
    local view, buffer = harness.view(source)
    local bold_col = test.not_nil(source:find("bold", 1, true))
    local linked, bold = 0, false
    for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(1))) do
      if not fragment.hidden and fragment.link then
        linked = linked + 1
        test.equal(fragment.link.raw_target, "target.md")
        test.equal(fragment.cursor, "hand")
        if fragment.text == "bold" then
          bold = true
          test.equal(fragment.source_col1, bold_col)
          test.equal(fragment.source_col2, bold_col + #"bold")
        end
      end
    end
    test.ok(linked > 1, "formatted label must keep its separate linked runs")
    test.ok(bold)
    view:set_selection_state({ selections = { 1, bold_col, 1, bold_col }, last_selection = 1 })
    harness.refresh(view)
    local text = {}
    for _, run in ipairs(harness.runs(view, 1)) do text[#text + 1] = run.text end
    test.equal(table.concat(text), "See é **bold** end now")
    local label_col = test.not_nil(source:find("é", 1, true))
    view:set_selection_state({ selections = { 1, label_col, 1, label_col }, last_selection = 1 })
    harness.refresh(view)
    text = {}
    for _, run in ipairs(harness.runs(view, 1)) do text[#text + 1] = run.text end
    test.equal(table.concat(text), source)
    view:set_selection_state({ selections = { 3, 1, 3, 1 }, last_selection = 1 })
    harness.refresh(view)
    text = {}
    for _, run in ipairs(harness.runs(view, 1)) do text[#text + 1] = run.text end
    test.equal(table.concat(text), "See é bold end now")
    test.equal(buffer.lines[1], source .. "\n")
  end)
end)
