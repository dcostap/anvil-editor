local core = require "core"
local command = require "core.command"
local poi = require "core.poi"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local test = require "core.test"
local symbol_index = require "core.treesitter.symbol_index"
local treesitter = require "core.treesitter"

require "core.commands.language"
require "plugins.fuzzy_searcher"

test.describe("Symbol activation", function()
  local function open_cpp(context, text, line, col)
    context.view:on_close()
    context.buffer:on_close()
    context.buffer = Buffer()
    context.buffer:insert(1, 1, text)
    local path = "symbol-activation-" .. tostring(math.floor(system.get_time() * 1000000)) .. ".cpp"
    context.buffer:set_filename(path, path)
    context.view = Editor(context.buffer)
    core.set_active_view(context.view)
    local deadline = system.get_time() + 3
    while system.get_time() < deadline do
      treesitter.poll_buffer(context.buffer)
      if context.buffer.treesitter and context.buffer.treesitter.status == "ready" then break end
      coroutine.yield(0.01)
    end
    test.equal(context.buffer.treesitter.status, "ready")
    context.buffer:set_selection(line, col)
  end

  test.before_each(function(context)
    context.active = core.active_view
    context.buffer = Buffer()
    context.buffer:insert(1, 1, "object.render()")
    context.buffer:set_selection(1, 10)
    context.view = Editor(context.buffer)
    core.set_active_view(context.view)
    context.workspace_symbols_async = symbol_index.workspace_symbols_async
  end)

  test.after_each(function(context)
    poi.remove_activation_provider("test-symbol-priority")
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    symbol_index.workspace_symbols_async = context.workspace_symbols_async
    context.view:on_close()
    context.buffer:on_close()
    if context.active then core.set_active_view(context.active) end
  end)

  test.it("preserves higher-priority Points of Interest for both actions", function()
    local activations = 0
    poi.add_activation_provider("test-symbol-priority", {
      priority = 1000,
      point_at_caret = function()
        return {
          line = 1, col = 10, line2 = 1, col2 = 11, text_bounds = true,
          activate = function() activations = activations + 1; return true end,
        }
      end,
    })
    test.ok(command.perform("core:activate_point_of_interest"))
    test.ok(command.perform("core:activate_point_of_interest_alternate"))
    test.equal(activations, 2)
    test.is_nil(core.fuzzy_searcher_active_view)
  end)

  for _, action in ipairs {
    "core:activate_point_of_interest",
    "core:activate_point_of_interest_alternate",
  } do
    test.it("opens a case-sensitive Project Symbol Search for " .. action, function(context)
      test.ok(command.perform(action))
      local picker = test.not_nil(core.fuzzy_searcher_active_view)
      test.equal(picker.input:get_text(), "$render")
      test.equal(picker.case_sensitive, true)
      test.equal(picker.source_view, context.view)
      test.equal(picker.static_mode, false)
      test.same({ context.buffer:get_selection() }, { 1, 10, 1, 10 })
    end)
  end

  test.it("keeps a single Project symbol in the picker without jumping", function(context)
    local received
    symbol_index.workspace_symbols_async = function(query, opts)
      received = { query = query, opts = opts }
      return {
        done = true, status = "fresh", reason = nil, cancel = function() end,
        results = { {
          name = "render", kind = "function", path = "C:/project/code.lua",
          start_line = 30, start_col = 1,
        } },
      }, nil, "pending", { roots = {} }
    end
    test.ok(command.perform("core:activate_point_of_interest"))
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:refresh(picker.input:get_text())
    local deadline = system.get_time() + 3
    while not received and system.get_time() < deadline do coroutine.yield(0.03) end
    test.not_nil(received)
    test.equal(received.query, "render")
    test.equal(received.opts.case_sensitive, true)
    test.is_nil(received.opts.include_ignored)
    while #(picker.results or {}) == 0 and system.get_time() < deadline do coroutine.yield(0.03) end
    test.equal(#picker.results, 1)
    test.equal(core.fuzzy_searcher_active_view, picker)
    test.same({ context.buffer:get_selection() }, { 1, 10, 1, 10 })
  end)

  test.it("goes to a C++ definition in the same Buffer without opening Project Symbol Search", function(context)
    open_cpp(context, [[// RGE_Base_Game is declared in a header.
int RGE_Base_Game::start() {
  return this->setup_palette();
}
int RGE_Base_Game::setup_palette() { return 1; }
]], 3, 19)

    test.is_nil(poi.point_at_caret(context.view, { activatable = true }))
    test.ok(command.perform("core:activate_point_of_interest"))
    test.is_nil(core.fuzzy_searcher_active_view)
    test.equal(context.buffer:get_text(context.buffer:get_selection(true)), "setup_palette")
    test.equal(select(1, context.buffer:get_selection()), 5)
  end)

  test.it("opens Project Symbol Search when same-name C++ definitions are ambiguous", function(context)
    open_cpp(context, [[class First { public: int run(); };
class Second { public: int run(); };
int First::run() { return 1; }
int Second::run() { return 2; }
int call(First& value) { return value.run(); }
]], 5, 39)

    test.ok(command.perform("core:activate_point_of_interest"))
    test.equal(test.not_nil(core.fuzzy_searcher_active_view).input:get_text(), "$run")
    test.equal(select(1, context.buffer:get_selection()), 5)
  end)
end)
