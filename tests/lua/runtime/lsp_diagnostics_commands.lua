local command = require "core.command"
local Buffer = require "core.buffer"
local TextView = require "core.textview"
local test = require "core.test"

test.describe("LSP diagnostics command registration", function()
  test.test("diagnostics commands are available after default command startup load", function()
    local previous_active_view = core.active_view
    local buffer = Buffer()
    buffer:insert(1, 1, "symbol")
    buffer:set_selection(1, 1)
    local view = TextView(buffer)
    core.active_view = view

    local ok, valid = pcall(command.get_all_valid)
    core.active_view = previous_active_view
    pcall(function() buffer:on_close() end)
    test.ok(ok, valid)

    local present = {}
    for _, name in ipairs(valid) do present[name] = true end
    test.ok(present["lsp:next-diagnostic"])
    test.ok(present["lsp:previous-diagnostic"])
    test.ok(present["lsp:show-buffer-diagnostics"])
    test.not_ok(present["lsp:complete-current-buffer"])
    test.ok(present["lsp:hover-current-position"])
    test.ok(present["lsp:signature-help-current-position"])
    test.ok(present["language:go-to-declaration"])
    test.ok(present["language:show-references"])
  end)
end)
