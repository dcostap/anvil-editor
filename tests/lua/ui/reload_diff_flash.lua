local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local flash = require "plugins.reload_diff_flash"

local function make_view(text)
  local doc = Doc(nil, nil, true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 400, 200
  return view, doc
end

test.describe("reload diff flash UI", function()
  test.it("installs a temporary decoration provider on DocViews for the reloaded doc", function()
    local view, doc = make_view("one\ntwo")
    local old_lines = { "one\n" }
    local model = flash.flash(doc, old_lines, doc.lines, { duration = 0.05 })
    test.not_nil(model)

    local entry = view.decoration_providers and view.decoration_providers[flash._provider_id_for_test]
    test.not_nil(entry)
    local inline = entry.provider:inline_ranges(view, 2)
    test.not_nil(inline)
    test.equal(inline[1].col1, 1)
    test.equal(inline[1].col2, 4)

    view:remove_decoration_provider(flash._provider_id_for_test)
  end)
end)
