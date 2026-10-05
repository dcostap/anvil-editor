local Buffer = require "core.buffer"
local Editor = require "core.editor"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_view(context, source, wrapped)
  local filename = "plain-text-indent-" .. tostring(wrapped) .. ".md"
  local buffer = Buffer(filename, filename, true)
  buffer:insert(1, 1, source)
  local view = Editor(buffer)
  context.view = view
  view.size.x, view.size.y = 800, 600
  view:set_wrapping_enabled(wrapped)
  buffer:set_selection(#buffer.lines, 1)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then coroutine.yield(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
  return view, buffer
end

test.describe("Markdown plain text indentation", function()
  test.after_each(function(context)
    if context.view then context.view:release_owned_features("test") end
  end)

  for _, wrapped in ipairs({ false, true }) do
    test.it("keeps text after a list aligned when the caret enters it ("
      .. (wrapped and "wrapped" or "unwrapped") .. ")", function(context)
      local view, buffer = make_view(context, table.concat({
        " 4. CEN → 101 — Pending",
        "",
        " - Date: 2026-10-05",
        " - Task: delivery",
        " - Project: example",
        " - Part: 1",
        "",
        " ┌─────────┬─────────────────────────────────┬─────┐",
        " │ Article │ Description                     │ Qty │",
        " ├─────────┼─────────────────────────────────┼─────┤",
        " │ 221265  │ Brida G8                        │ 12  │",
        " └─────────┴─────────────────────────────────┴─────┘",
        "",
        "plain",
      }, "\n"), wrapped)
      local before = view:get_col_x_offset(8, 2)
      buffer:set_selection(8, 2)
      local active = view:get_col_x_offset(8, 2)
      test.ok(math.abs(before - active) < 0.01,
        string.format("caret entry moved text from %.3f to %.3f", before, active))
      test.equal(view:get_col_x_offset(8, 2), view:get_col_x_offset(9, 2),
        "equally indented plain text must use the same margin")
      buffer:set_selection(14, 1)
      test.equal(view:get_col_x_offset(8, 2), before,
        "caret exit must preserve the text margin")
    end)
  end
end)
