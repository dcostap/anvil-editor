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
end)
