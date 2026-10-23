local core = require "core"
local command = require "core.command"
local config = require "core.config"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local test = require "core.test"

local function make_view(text, filename)
  filename = filename or "markdown-list-navigation.md"
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename(filename, nil)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view:set_wrapping_enabled(false)
  return view, buffer
end

local function perform(view, name)
  local old_active = core.active_view
  core.active_view = view
  local ok, result = pcall(command.perform, name, view)
  core.active_view = old_active
  if not ok then error(result, 0) end
  return result
end

test.describe("Markdown list navigation", function()
  test.it("moves Home to task-list content before the physical line start", function()
    for _, name in ipairs({
      "core:move_to_start_of_indentation",
      "core:move_to_start_of_line",
    }) do
      local view, buffer = make_view("- [ ] this is a list item")
      buffer:set_selection(1, 20)

      test.equal(perform(view, name), true)

      local line, col = buffer:get_selection()
      test.same({ line, col }, { 1, 7 })
    end
  end)

  test.it("recognizes nested unordered, ordered, and task-list content starts", function()
    local cases = {
      { "  - nested item", 5 },
      { "12) ordered item", 5 },
      { "  * [x] completed item", 9 },
      { "12. [ ] ordered task", 9 },
    }
    for _, case in ipairs(cases) do
      local view, buffer = make_view(case[1])
      buffer:set_selection(1, #buffer.lines[1])

      test.equal(perform(view, "core:move_to_start_of_indentation"), true)

      local line, col = buffer:get_selection()
      test.same({ line, col }, { 1, case[2] })
    end
  end)

  test.it("moves through list content, marker indentation, and physical line start", function()
    local view, buffer = make_view("  - [ ] nested task")
    buffer:set_selection(1, #buffer.lines[1])

    test.equal(perform(view, "core:move_to_start_of_indentation"), true)
    local line, col = buffer:get_selection()
    test.same({ line, col }, { 1, 9 })

    test.equal(perform(view, "core:move_to_start_of_indentation"), true)
    line, col = buffer:get_selection()
    test.same({ line, col }, { 1, 3 })

    test.equal(perform(view, "core:move_to_start_of_indentation"), true)
    line, col = buffer:get_selection()
    test.same({ line, col }, { 1, 1 })
  end)

  test.it("selects to list content before selecting the prefix", function()
    for _, name in ipairs({
      "core:select_to_start_of_indentation",
      "core:select_to_start_of_line",
    }) do
      for _, case in ipairs({
        { "- item", 3 },
        { "  - nested item", 5 },
        { "12) ordered item", 5 },
        { "  * [x] completed item", 9 },
        { "12. [ ] ordered task", 9 },
      }) do
        local view, buffer = make_view(case[1])
        local anchor = #buffer.lines[1]
        buffer:set_selection(1, anchor)

        test.equal(perform(view, name), true)
        test.same({ buffer:get_selection() }, { 1, case[2], 1, anchor })
        test.equal(buffer:get_text(1, case[2], 1, anchor), case[1]:sub(case[2]))

        test.equal(perform(view, name), true)
        local prefix_col = name == "core:select_to_start_of_indentation"
          and (case[1]:find("%S")) or 1
        test.same({ buffer:get_selection() }, { 1, prefix_col, 1, anchor })
      end
    end
  end)

  test.it("extends each caret to its list content without changing its anchor", function()
    local view, buffer = make_view("- first item\n  - [ ] second task")
    buffer:set_selection(1, 9, 1, 6)
    buffer:add_selection(2, 16, 2, 12)

    test.equal(perform(view, "core:select_to_start_of_indentation"), true)

    test.same(buffer.selections, { 1, 3, 1, 6, 2, 9, 2, 12 })
  end)

  test.it("deletes to list content before deleting the prefix and supports undo", function()
    for _, name in ipairs({
      "core:delete_to_start_of_indentation",
      "core:delete_to_start_of_line",
    }) do
      local view, buffer = make_view("  - [ ] task text")
      buffer:set_selection(1, #buffer.lines[1])

      test.equal(perform(view, name), true)
      test.equal(buffer.lines[1], "  - [ ] \n")
      test.same({ buffer:get_selection() }, { 1, 9, 1, 9 })

      test.equal(perform(view, "core:undo"), true)
      test.equal(buffer.lines[1], "  - [ ] task text\n")

      test.equal(perform(view, name), true)
      test.equal(perform(view, name), true)
      test.equal(buffer.lines[1], name == "core:delete_to_start_of_indentation"
        and "  \n" or "\n")
    end
  end)

  test.it("keeps plain-text selection and deletion outside Markdown", function()
    local view, buffer = make_view("  - [ ] source text", "list-navigation.lua")
    buffer:set_selection(1, #buffer.lines[1])
    test.equal(perform(view, "core:select_to_start_of_indentation"), true)
    test.same({ buffer:get_selection() }, { 1, 3, 1, #buffer.lines[1] })

    buffer:set_selection(1, #buffer.lines[1])
    test.equal(perform(view, "core:delete_to_start_of_line"), true)
    test.equal(buffer.lines[1], "\n")
  end)

  test.it("keeps the caret position within a list item after unindent", function()
    local cases = {
      { source = "    - nested item", col = 7, expected_source = "- nested item\n", expected_col = 3 },
      { source = "    - nested item", col = 12, expected_source = "- nested item\n", expected_col = 8 },
      { source = "- root item", col = 8, expected_source = "- root item\n", expected_col = 8 },
    }
    for _, case in ipairs(cases) do
      local view, buffer = make_view(case.source)
      buffer:set_selection(1, case.col)

      test.equal(perform(view, "core:unindent"), true)

      test.equal(buffer.lines[1], case.expected_source)
      local line, col = buffer:get_selection()
      test.same({ line, col }, { 1, case.expected_col })
    end
  end)

  test.it("indents a list item from any caret position", function()
    local cases = {
      {
        source = "- parent\n- child",
        line = 2,
        col = 6,
        expected_source = "    - child\n",
        expected_col = 10,
      },
      {
        source = "- parent\n- [ ] task item",
        line = 2,
        col = 12,
        expected_source = "    - [ ] task item\n",
        expected_col = 16,
      },
      {
        source = "- root item",
        line = 1,
        col = 8,
        expected_source = "    - root item\n",
        expected_col = 12,
      },
      {
        source = "        - deeply indented",
        line = 1,
        col = 18,
        expected_source = "            - deeply indented\n",
        expected_col = 22,
      },
    }
    for _, case in ipairs(cases) do
      local view, buffer = make_view(case.source)
      buffer:set_selection(case.line, case.col)

      test.equal(perform(view, "core:indent"), true)

      test.equal(buffer.lines[case.line], case.expected_source)
      local line, col = buffer:get_selection()
      test.same({ line, col }, { case.line, case.expected_col })
    end
  end)

  test.it("does not treat list-looking source in another Language Mode as Markdown", function()
    local view, buffer = make_view("- [ ] source text", "list-navigation.lua")
    buffer:set_selection(1, #buffer.lines[1])

    test.equal(perform(view, "core:move_to_start_of_indentation"), true)

    local line, col = buffer:get_selection()
    test.same({ line, col }, { 1, 1 })
  end)

  test.it("keeps the wrapped-row start as the first Home stop", function()
    local view, buffer = make_view("- [ ] abcdefghijklmnopqrstuvwxyz")
    local cfg = config.plugins.linewrapping
    local old = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
    }
    local ok, err = pcall(function()
      cfg.mode = "letter"
      cfg.width_override = view:get_font():get_width("xxxxxxxx")
      cfg.indent = false
      cfg.wrapping_indent = 0
      cfg.require_tokenization = false
      view.wrapping_enabled = true
      linewrapping.update_textview_breaks(view)

      buffer:set_selection(1, 20)
      local _, _, _, wrapped_row_start = linewrapping.get_line_idx_col_count(view, 1, 20)
      test.ok(wrapped_row_start > 7, "the fixture caret should be on a continuation row")

      test.equal(perform(view, "core:move_to_start_of_indentation"), true)
      local line, col = buffer:get_selection()
      test.same({ line, col }, { 1, wrapped_row_start })

      test.equal(perform(view, "core:move_to_start_of_indentation"), true)
      line, col = buffer:get_selection()
      test.same({ line, col }, { 1, 7 })
    end)
    cfg.mode = old.mode
    cfg.width_override = old.width_override
    cfg.indent = old.indent
    cfg.wrapping_indent = old.wrapping_indent
    cfg.require_tokenization = old.require_tokenization
    view.wrapping_enabled = false
    if not ok then error(err, 0) end
  end)

  test.it("selects and deletes to the wrapped-row start before list content", function()
    local cfg = config.plugins.linewrapping
    local old = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
    }
    local ok, err = pcall(function()
      for _, name in ipairs({
        "core:select_to_start_of_indentation",
        "core:select_to_start_of_line",
        "core:delete_to_start_of_indentation",
        "core:delete_to_start_of_line",
      }) do
        local view, buffer = make_view("- [ ] abcdefghijklmnopqrstuvwxyz")
        cfg.mode = "letter"
        cfg.width_override = view:get_font():get_width("xxxxxxxx")
        cfg.indent = false
        cfg.wrapping_indent = 0
        cfg.require_tokenization = false
        view.wrapping_enabled = true
        linewrapping.update_textview_breaks(view)
        buffer:set_selection(1, 20)
        local _, _, _, row_start = linewrapping.get_line_idx_col_count(view, 1, 20)
        test.ok(row_start > 7, "the caret must start on a continuation row")

        test.equal(perform(view, name), true)
        local line, col = buffer:get_selection()
        test.same({ line, col }, { 1, row_start })

        test.equal(perform(view, name), true)
        line, col = buffer:get_selection()
        test.same({ line, col }, { 1, 7 })
        if name:find("select", 1, true) then
          test.same({ buffer:get_selection() }, { 1, 7, 1, 20 })
        else
          test.equal(buffer.lines[1], "- [ ] nopqrstuvwxyz\n")
        end
      end
    end)
    cfg.mode = old.mode
    cfg.width_override = old.width_override
    cfg.indent = old.indent
    cfg.wrapping_indent = old.wrapping_indent
    cfg.require_tokenization = old.require_tokenization
    if not ok then error(err, 0) end
  end)
end)
