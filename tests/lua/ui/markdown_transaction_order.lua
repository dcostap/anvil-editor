local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local test = require "core.test"

local function visible_text(view, line)
  local rendered = test.not_nil(view:get_line_render(line))
  local parts = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(rendered)) do
    if not fragment.hidden then parts[#parts + 1] = fragment.text or "" end
  end
  return table.concat(parts)
end

test.describe("Markdown edit scheduling", function()
  test.it("shows edited text while its Markdown parse is pending", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("transaction-order.md", nil)
    buffer:insert(1, 1, "plain text")
    local view = Editor(buffer)
    view.size.x, view.size.y = 600, 300
    view:set_wrapping_enabled(false)
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(model.peek(buffer))
    buffer:insert(1, 7, "new ")
    test.equal(instance.status, "pending")
    test.equal(visible_text(view, 1), "plain new text")
  end)
end)
