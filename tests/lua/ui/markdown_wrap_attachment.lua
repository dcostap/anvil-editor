local Buffer = require "core.buffer"
local Editor = require "core.editor"
local config = require "core.config"
local markdown = require "core.markdown"
local wrapping = require "core.linewrapping"
local test = require "core.test"

test.it("attaches Markdown with the final reading lane geometry", function()
  local cfg = config.plugins.centered_editor
  local previous = cfg.pane_views_only
  cfg.pane_views_only = false
  local buffer = Buffer("attachment.md", nil, true)
  buffer:insert(1, 1, string.rep("words ", 100) .. "\n")
  local view = Editor(buffer)
  view.size.x, view.size.y = 1600, 700
  local ok, err = pcall(function()
    view:set_wrapping_enabled(true)
    markdown.live_render.attach(view)
    wrapping.complete_async_reconstruction(view)
    local attached_rows = view:get_visual_row_count_for_line(1)
    view:update_wrap_cache()
    wrapping.complete_async_reconstruction(view)
    test.equal(attached_rows, view:get_visual_row_count_for_line(1),
      "attachment published rows for an older lane")
  end)
  markdown.live_render.detach(view)
  view:on_close()
  cfg.pane_views_only = previous
  if not ok then error(err, 0) end
end)
