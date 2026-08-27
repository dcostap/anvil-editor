local core = require "core"
local config = require "core.config"
local test = require "core.test"
local Editor = require "core.editor"
local panes = require "core.panes"
local autocomplete = require "plugins.autocomplete"
local sticky_scroll = require "plugins.sticky_scroll"

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_binary_view(context, text, place)
  local buffer = core.open_buffer()
  context.buffers[#context.buffers + 1] = buffer
  if text and text ~= "" then buffer:text_input(text) end
  buffer.binary = true
  buffer.clean_lines = {}
  local view
  if place then
    view = panes.place(function() return Editor(buffer) end, {
      placement = "new", focus = true,
    })
  else
    view = Editor(buffer)
  end
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 220, 180
  return view, buffer
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 2)
  while not predicate() and system.get_time() < deadline do
    coroutine.yield(0.05)
  end
  return predicate()
end

test.describe("binary Buffer performance guards", function()
  test.before_each(function(context)
    context.buffers = {}
    context.autocomplete_scope = config.plugins.autocomplete.suggestions_scope
    panes.reset_for_tests()
  end)

  test.after_each(function(context)
    autocomplete.close()
    config.plugins.autocomplete.suggestions_scope = context.autocomplete_scope
    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end
  end)

  test.it("does not enable default wrapping for a binary Buffer", function(context)
    test.equal(config.plugins.linewrapping.enable_by_default, true)
    local view = open_binary_view(context, "binary data")

    test.equal(view:is_wrapping_enabled(), false)

    view:set_wrapping_enabled(true)
    test.equal(view:is_wrapping_enabled(), true)
  end)

  test.it("does not create a Sticky Scroll model for a binary Buffer", function(context)
    local view = open_binary_view(context, "parent\n  child")

    view:update()

    test.equal(sticky_scroll.should_run(view), false)
    test.is_nil(rawget(sticky_scroll.managed_textviews, view))
  end)

  test.it("stops unwrapped binary drawing before a distant UTF-8 suffix", function(context)
    local suffix = "DISTANT-SUFFIX"
    local view = open_binary_view(context, string.rep("é", 900) .. suffix)
    view:set_wrapping_enabled(false)

    local old_draw_text = renderer.draw_text
    local old_draw_text_known_bounds = renderer.draw_text_known_bounds
    local submitted = {}
    renderer.draw_text = function(font, text, x, _, _, opts)
      submitted[#submitted + 1] = text
      return x + font:get_width(text, opts)
    end
    renderer.draw_text_known_bounds = function(_, text)
      submitted[#submitted + 1] = text
    end
    view.__test_force_known_bounds = true
    local x, y = view:get_line_screen_position(1)
    local ok, err = pcall(view.draw_line_text, view, 1, x, y)
    renderer.draw_text = old_draw_text
    renderer.draw_text_known_bounds = old_draw_text_known_bounds
    test.ok(ok, err)

    test.is_nil(table.concat(submitted):find(suffix, 1, true))
  end)

  test.it("does not offer Buffer words from a binary Buffer", function(context)
    config.plugins.autocomplete.suggestions_scope = "local"
    local view, buffer = open_binary_view(
      context, "binarycompletiontarget\nbinary", true
    )
    buffer.binary = false
    buffer:set_selection(2, 7)

    test.ok(wait_until(function()
      autocomplete.close()
      autocomplete.trigger()
      local item = autocomplete.get_selected_suggestion()
      return item and item.text == "binarycompletiontarget"
    end), "the autocomplete scanner did not publish the text Buffer word")

    autocomplete.close()
    buffer.binary = true
    buffer:insert(1, 1, "x")
    coroutine.yield(1.2)
    autocomplete.trigger()

    test.equal(autocomplete.is_open(), false)
    test.equal(core.active_view, view)
  end)
end)
