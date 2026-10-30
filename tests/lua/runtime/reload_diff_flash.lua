local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"
local flash = require "plugins.reload_diff_flash"

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:insert(1, 1, text)
  buffer:clear_undo_redo()
  return TextView(buffer), buffer
end

local function flash_provider(view, buffer, old_lines, line, opts)
  local model, err = flash.flash(buffer, old_lines, buffer.lines, opts)
  test.not_nil(model, tostring(err))
  for _, entry in ipairs(view:decoration_provider_entries()) do
    local provider = entry.provider
    if provider.inline_ranges and provider:inline_ranges(view, line) then return entry end
    if provider.line_background and provider:line_background(view, line) then return entry end
  end
  test.fail("reload flash did not add a TextView decoration provider")
end

local function close_view(view, buffer, entry)
  if entry then view:remove_decoration_provider(entry.id) end
  buffer:on_close()
end

test.describe("reload diff flash", function()
  test.test("exposes inline marks for changed text through the TextView", function()
    local view, buffer = make_view("alpha\ntoo\nomega")
    local entry = flash_provider(view, buffer, { "alpha\n", "two\n", "omega\n" }, 2)
    local ranges = test.not_nil(entry.provider:inline_ranges(view, 2))
    test.same({ ranges[1].col1, ranges[1].col2 }, { 2, 3 })
    close_view(view, buffer, entry)
  end)

  test.test("exposes line and inline marks for inserted text through the TextView", function()
    local view, buffer = make_view("alpha\nbravo\nomega")
    local entry = flash_provider(view, buffer, { "alpha\n", "omega\n" }, 2)
    test.not_nil(entry.provider:line_background(view, 2))
    local ranges = test.not_nil(entry.provider:inline_ranges(view, 2))
    test.same({ ranges[1].col1, ranges[1].col2 }, { 1, 6 })
    close_view(view, buffer, entry)
  end)

  test.test("anchors a deleted line in the reloaded TextView", function()
    local view, buffer = make_view("alpha\nomega")
    local entry = flash_provider(view, buffer, { "alpha\n", "bravo\n", "omega\n" }, 2)
    test.not_nil(entry.provider:line_background(view, 2))
    close_view(view, buffer, entry)
  end)

  test.test("shows line marks when a large diff cannot use inline ranges", function()
    local view, buffer = make_view("three\nfour")
    local entry = flash_provider(view, buffer, { "one\n", "two\n" }, 1, { max_diff_cells = 1 })
    test.not_nil(entry.provider:line_background(view, 1))
    test.not_nil(entry.provider:line_background(view, 2))
    close_view(view, buffer, entry)
  end)
end)
