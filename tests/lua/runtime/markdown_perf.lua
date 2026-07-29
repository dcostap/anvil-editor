local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local linewrapping = require "core.linewrapping"
local perf = require "core.perf"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function wait_ready(instance, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return true end
    coroutine.yield(0.005)
  until system.get_time() >= deadline
  return instance.status == "ready"
end

local function read_all(path)
  local file = assert(io.open(path, "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

local function remove_recording_files(frames_path, summary_path)
  local base = summary_path:gsub("_summary%.txt$", "")
  os.remove(frames_path)
  os.remove(summary_path)
  os.remove(base .. "_lua_samples.csv")
  os.remove(base .. "_api_calls.csv")
  os.remove(base .. "_details.csv")
end

test.describe("Markdown performance diagnostics", function()
  test.it("reports model and Live Preview publication phase drilldown", function()
    local old_enabled = config.markdown_live_editor
    config.markdown_live_editor = true
    local doc = Doc("perf-drilldown.md", "perf-drilldown.md", true)
    local lines = { "# Heading" }
    for index = 1, 120 do
      lines[#lines + 1] = string.format(
        "Paragraph %d with **strong text**, [[Note %d|alias]], and enough prose to wrap.",
        index, index
      )
    end
    doc:insert(1, 1, table.concat(lines, "\n") .. "\n")
    doc:clear_undo_redo()
    local view = DocView(doc)
    view.size.x, view.size.y = 900, 700
    view:set_wrapping_enabled(true)

    local frames_path = perf.start_recording()
    markdown.live_render.refresh_view(view)
    local instance = test.not_nil(markdown_model.peek(doc))
    local ready = wait_ready(instance)
    linewrapping.complete_async_reconstruction(view)
    local summary_path = perf.stop_recording()
    local summary = read_all(summary_path)

    test.ok(ready, instance.reason)
    test.ok(summary:find("Slow Markdown model publication callbacks", 1, true))
    test.ok(summary:find("Slow Markdown Live Preview publication listeners", 1, true))
    test.ok(summary:find("perf-drilldown.md", 1, true))
    test.ok(summary:find("slowest_listener_id", 1, true))
    test.ok(summary:find("fence_reconcile_ms", 1, true))
    test.ok(summary:find("wrapped,active,visible,view_width", 1, true))
    test.ok(summary:find("linewrap async reconstruct commits", 1, true))

    remove_recording_files(frames_path, summary_path)
    markdown.live_render.release(view, "test")
    markdown_model.close(doc, "test")
    config.markdown_live_editor = old_enabled
  end)
end)
