local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"

test.describe("LSP diagnostics command registration", function()
  test.test("diagnostics commands are available after default command startup load", function()
    local previous_active_view = core.active_view
    local doc = Doc()
    local view = DocView(doc)
    core.active_view = view

    local ok, valid = pcall(command.get_all_valid)
    core.active_view = previous_active_view
    pcall(function() doc:on_close() end)
    test.ok(ok, valid)

    local present = {}
    for _, name in ipairs(valid) do present[name] = true end
    test.ok(present["lsp:next-diagnostic"])
    test.ok(present["lsp:previous-diagnostic"])
    test.ok(present["lsp:show-document-diagnostics"])
    test.ok(present["lsp:complete-current-document"])
  end)
end)
