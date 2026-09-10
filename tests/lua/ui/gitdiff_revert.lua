local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local command = require "core.command"
local test = require "core.test"
local gitdiff = require "plugins.gitdiff_highlight"
local ranges = require "plugins.gitdiff_highlight.ranges"

local function setup(context, base, current, line)
  context.active = core.active_view
  local buffer = Buffer()
  buffer:insert(1, 1, current)
  local view = Editor(buffer)
  context.view = view
  core.active_view = view
  view:with_selection_state(function() buffer:set_selection(line, 1) end)
  gitdiff._set_state_for_tests(buffer, {
    is_in_repo = true, base_lines = ranges.split_buffer_lines(base),
    ranges = {}, line_index = {},
  })
  return buffer, view
end

local function text(buffer)
  return buffer:get_text(1, 1, #buffer.lines, #buffer.lines[#buffer.lines])
end

test.describe("Revert Git Change", function()
  test.after_each(function(context)
    core.active_view = context.active
    if context.view then context.view.buffer:on_close() end
  end)

  test.it("reverts only the caret region and supports Undo and Redo", function(context)
    local buffer = setup(context, "old\nkeep\nlast", "new\nkeep\nother", 1)
    test.ok(command.perform("editor:revert_git_change"))
    test.equal(text(buffer), "old\nkeep\nother")
    test.ok(command.perform("core:undo"))
    test.equal(text(buffer), "new\nkeep\nother")
    test.ok(command.perform("core:redo"))
    test.equal(text(buffer), "old\nkeep\nother")
  end)

  for _, case in ipairs({
    { "removes added lines", "one\nlast", "one\nadded\nlast", 2 },
    { "restores deleted lines at their marker", "one\ndeleted\nlast", "one\nlast", 2 },
    { "removes additions at the end", "one", "one\nadded", 2 },
    { "restores deletions at the end", "one\ndeleted", "one", 1 },
    { "replaces the last line", "old", "new", 1 },
    { "clears a new file", "", "added", 1 },
    { "restores an empty file", "old", "", 1 },
  }) do
    test.it(case[1], function(context)
      local buffer = setup(context, case[2], case[3], case[4])
      test.ok(command.perform("editor:revert_git_change"))
      test.equal(text(buffer), case[2])
    end)
  end

  test.it("does not edit unchanged lines or read-only buffers", function(context)
    local buffer, view = setup(context, "old\nkeep", "new\nkeep", 2)
    command.perform("editor:revert_git_change")
    test.equal(text(buffer), "new\nkeep")
    view:with_selection_state(function() buffer:set_selection(1, 1) end)
    buffer.read_only = true
    command.perform("editor:revert_git_change")
    test.equal(text(buffer), "new\nkeep")
  end)

  test.it("uses current text when edits move a region before markers refresh", function(context)
    local buffer, view = setup(context, "first\nkeep\nold\nlast", "first\nkeep\nnew\nlast", 3)
    buffer:insert(1, 1, "added\n")
    view:with_selection_state(function() buffer:set_selection(4, 1) end)
    test.ok(command.perform("editor:revert_git_change"))
    test.equal(text(buffer), "added\nfirst\nkeep\nold\nlast")
  end)
end)
