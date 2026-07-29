local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local LineWrapping = require "core.linewrapping"
local test = require "core.test"

test.describe("Line wrapping during live window resize", function()
  test.before_each(function(context)
    local cfg = config.plugins.linewrapping
    context.old_config = {
      mode = cfg.mode,
      width_override = cfg.width_override,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
    }
    context.old_resizing_until = core.window_resizing_until
    context.old_live_resize_frame = core.in_live_resize_frame
    cfg.mode = "word"
    cfg.width_override = nil
    cfg.indent = false
    cfg.wrapping_indent = 0
    cfg.require_tokenization = false
  end)

  test.after_each(function(context)
    local cfg = config.plugins.linewrapping
    for key, value in pairs(context.old_config) do cfg[key] = value end
    if context.old_config.width_override == nil then cfg.width_override = nil end
    core.window_resizing_until = context.old_resizing_until
    core.in_live_resize_frame = context.old_live_resize_frame
    if context.doc then context.doc:on_close() end
  end)

  test.it("defers repeated width-only reflow until live resizing settles", function(context)
    local doc = Doc()
    context.doc = doc
    doc:insert(1, 1, string.rep("a word with wrapping spaces ", 80))
    local view = DocView(doc)
    view.wrapping_enabled = true
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 320, 240
    LineWrapping.update_docview_breaks(view)

    local initial_width = view.wrapped_settings.width
    local initial_rows = LineWrapping.get_total_wrapped_lines(view)
    core.window_resizing_until = system.get_time() + 10
    view.size.x = 640
    LineWrapping.update_docview_breaks(view)

    test.equal(initial_width, view.wrapped_settings.width)
    test.equal(initial_rows, LineWrapping.get_total_wrapped_lines(view))

    core.window_resizing_until = nil
    LineWrapping.update_docview_breaks(view)
    test.ok(view.wrapped_settings.width > initial_width)
    test.ok(LineWrapping.get_total_wrapped_lines(view) < initial_rows)
  end)
end)
