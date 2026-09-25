local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local linewrapping = require "core.linewrapping"
local style = require "core.style"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local test_id = 0
local function rendered_fragments(source)
  test_id = test_id + 1
  local buffer = Buffer("inline-font-size.md", "inline-font-size-" .. test_id .. ".md", true)
  buffer:insert(1, 1, source .. "\nplain")
  buffer:clear_undo_redo()
  local view = Editor(buffer)
  view.size.x, view.size.y = 960, 400
  view:set_wrapping_enabled(false)
  buffer:set_selection(2, 1)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({max_ms = 5, max_messages = 64}) end
    if instance.status ~= "ready" then coroutine.yield(0.01) end
  end
  test.equal("ready", instance.status, instance.reason)
  linewrapping.complete_async_reconstruction(view)
  local by_text = {}
  for _, fragment in ipairs(view:iter_line_render_fragments(view:get_line_render(1))) do
    if fragment.text and fragment.text ~= "" and not fragment.hidden then
      by_text[fragment.text] = fragment
    end
  end
  model.close(buffer, "test")
  return by_text, view
end

test.describe("Markdown Live Preview inline font sizes", function()
  test.it("keeps bold and italic at body size while code keeps code size", function()
    local fragments, view = rendered_fragments(
      "plain **bold** and *italic* plus ***both*** and `code`"
    )
    local body = test.not_nil(fragments["plain "]).font:get_size()
    for _, text in ipairs({"bold", "italic", "both"}) do
      test.equal(body, test.not_nil(fragments[text]).font:get_size())
    end
    test.equal(view:get_font():get_size(), test.not_nil(fragments.code).font:get_size())
  end)

  test.it("keeps formatted headings at the heading size", function()
    local fragments = rendered_fragments("# Heading **bold** and *italic*")
    local heading_size = test.not_nil(fragments["Heading "]).font:get_size()
    test.ok(heading_size > style.markdown_body_font:get_size())
    test.equal(heading_size, test.not_nil(fragments.bold).font:get_size())
    test.equal(heading_size, test.not_nil(fragments.italic).font:get_size())
  end)
end)
