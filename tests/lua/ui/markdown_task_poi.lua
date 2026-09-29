local Buffer = require "core.buffer"
local Editor = require "core.editor"
local core = require "core"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local function wait_for_markdown(view)
  markdown.live_render.refresh_view(view)
  local model = markdown_model.peek(view.buffer)
  local deadline = system.get_time() + 5
  while model.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if model.status ~= "ready" then coroutine.yield(0.01) end
  end
  test.equal(model.status, "ready", model.reason)
end

test.describe("Markdown task Points of Interest", function()
  test.it("navigates unchecked tasks but skips checked tasks and code examples", function()
    local buffer = Buffer(nil, nil, true)
    buffer:set_filename("tasks.md", nil)
    buffer:insert(1, 1, table.concat({
      "- [ ] first", "- [X] done", "```md", "- [ ] example", "```",
      "  - [ ] nested [link](https://example.com)", "- [ ] last",
    }, "\n"))
    buffer:clear_undo_redo()
    local view = Editor(buffer)
    local previous = core.active_view
    local ok, err = pcall(function()
      core.set_active_view(view)
      wait_for_markdown(view)
      local points = require("core.poi").points_for_view(view)
      local tasks = {}
      for _, point in ipairs(points) do
        if point.kind == "markdown-task" then tasks[#tasks + 1] = point end
      end
      test.equal(#tasks, 3)
      test.same({
        { tasks[1].line, tasks[1].col },
        { tasks[2].line, tasks[2].col },
        { tasks[3].line, tasks[3].col },
      }, { { 1, 3 }, { 6, 5 }, { 7, 3 } })

      local poi = require "core.poi"
      buffer:set_selection(1, 1)
      test.equal(poi.navigate(view, 1).kind, "markdown-task")
      test.same({ buffer:get_selection() }, { 1, 3, 1, 3 })
      test.equal(poi.navigate(view, 1).kind, "markdown-task")
      test.same({ buffer:get_selection() }, { 6, 5, 6, 5 })
      test.equal(poi.navigate(view, 1).kind, "markdown-link")
      test.equal(poi.navigate(view, 1).kind, "markdown-task")
      test.same({ buffer:get_selection() }, { 7, 3, 7, 3 })
      test.equal(poi.navigate(view, -1).kind, "markdown-link")
      test.equal(poi.navigate(view, -1).kind, "markdown-task")
      test.same({ buffer:get_selection() }, { 6, 5, 6, 5 })

      buffer:set_selection(1, 3, 1, 6)
      buffer:text_input("[x]")
      wait_for_markdown(view)
      for _, point in ipairs(poi.points_for_view(view)) do
        test.ok(not (point.kind == "markdown-task" and point.line == 1))
      end
    end)
    view:on_close()
    buffer:on_close()
    if previous then core.set_active_view(previous) end
    if not ok then error(err, 0) end
  end)
end)
