local core = require "core"
local config = require "core.config"
local test = require "core.test"
local autocomplete = require "plugins.autocomplete"
local Editor = require "core.editor"
local panes = require "core.panes"

local function open_editor(context, text)
  local buffer = core.open_buffer()
  context.buffer = buffer
  if text then buffer:text_input(text) end
  panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
end

test.describe("autocomplete symbol matching", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    context.scope = config.plugins.autocomplete.suggestions_scope
    config.plugins.autocomplete.suggestions_scope = "none"
  end)

  test.after_each(function(context)
    autocomplete.close()
    autocomplete.map["test-symbol-matching"] = nil
    config.plugins.autocomplete.suggestions_scope = context.scope
    panes.reset_for_tests()
    if context.buffer then
      context.buffer:clean()
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == context.buffer then table.remove(core.buffers, i) end
      end
      context.buffer:on_close()
    end
  end)

  for _, mode in ipairs({ "automatic", "manual" }) do
    test.it(mode .. " completion rejects scattered letters", function(context)
      open_editor(context, mode == "manual" and "manner" or nil)
      local source = {
        name = "test-symbol-matching", files = ".*",
        items = {
          AlmacenInteractiveCompletion = "",
          AlmacenLineCard = "",
          AlmacenPrinterIds = "",
          AlmacenScannerTest = "",
          AlmacenLineCardHeader = "",
          AnimatedSpinner = "",
          MANAGED_CLIENT_RESOURCE_ROOT = "",
        },
      }
      if mode == "manual" then
        autocomplete.complete(source)
      else
        autocomplete.add(source)
        core.root_panel:on_text_input("manner")
      end
      test.not_ok(autocomplete.is_open(), "unrelated symbols must not open the popup")
    end)

    for _, example in ipairs({
      { "alm", "AlmacenLineCard" },
      { "line", "AlmacenLineCard" },
      { "alc", "AlmacenLineCard" },
      { "allica", "AlmacenLineCard" },
      { "mlc", "MANAGED_LINE_CARD" },
      { "ghc", "GetHTTPClient" },
      { "abcd", "AbcBcd" },
    }) do
      local query, symbol = example[1], example[2]
      test.it(mode .. " completion accepts " .. query .. " for " .. symbol, function(context)
        open_editor(context, mode == "manual" and query or nil)
        local source = { name = "test-symbol-matching", files = ".*", items = { [symbol] = "" } }
        if mode == "manual" then
          autocomplete.complete(source)
        else
          autocomplete.add(source)
          core.root_panel:on_text_input(query)
        end
        test.ok(autocomplete.is_open(), "expected a prefix, substring, or word-prefix abbreviation")
        test.equal(autocomplete.get_selected_suggestion().text, symbol)
      end)
    end
  end

  test.it("keeps reordered word prefixes", function(context)
    open_editor(context, "text_dra")
    autocomplete.add({ name = "test-symbol-matching", files = ".*", items = { draw_text = "" } })
    autocomplete.trigger()
    test.ok(autocomplete.is_open())
    test.equal(autocomplete.get_selected_suggestion().text, "draw_text")
  end)

  test.it("rejects scattered letters inside query words", function(context)
    open_editor(context, "cntxt_dra")
    autocomplete.add({ name = "test-symbol-matching", files = ".*", items = { context_draw = "" } })
    autocomplete.trigger()
    test.not_ok(autocomplete.is_open(), "word matching must not restore scattered-letter matches")
  end)
end)
