local core = require "core"
local command = require "core.command"
local test = require "core.test"
local panes = require "core.panes"
local Editor = require "core.editor"
local style = require "core.style"
local wrapping = require "core.linewrapping"
local autosave = require "plugins.autosave_fast"
require "plugins.intellij_find"

local function report(name, samples)
  table.sort(samples)
  local sum = 0
  for _, n in ipairs(samples) do sum = sum + n end
  print(string.format("PROBE %s median=%.3f avg=%.3f p95=%.3f max=%.3f", name,
    samples[math.ceil(#samples / 2)], sum / #samples,
    samples[math.ceil(#samples * .95)], samples[#samples]))
end

local function selection(view)
  return view:with_selection_state(function() return view.buffer:get_selection() end)
end

local function marker_count(view)
  local count = 0
  local old = renderer.draw_rect
  local rounded = renderer.draw_rounded_rect
  renderer.draw_rounded_rect = function() end
  renderer.draw_rect = function(_, _, _, _, color)
    if color == style.search_overview or color == style.search_overview_secondary then count = count + 1 end
  end
  local ok, err = pcall(view.draw_scrollbar, view)
  renderer.draw_rect = old
  renderer.draw_rounded_rect = rounded
  if not ok then error(err) end
  return count
end

local function coverage_complete(state)
  return not state.pending and state.overview and state.overview.complete and not state.overview_pending
end

test.it("measures complete Local Find latency and ordinary redraw", function()
  -- Let startup finish before choosing the measured Pane. A delayed startup
  -- error can otherwise replace it with the Log View on the first yield.
  for _ = 1, 3 do coroutine.yield(0) end
  local autosave_enabled = autosave.enabled
  autosave.enabled = false
  local path = USERDIR .. PATHSEP .. "find-large.c"
  local f = assert(io.open(path, "wb"))
  local line = "int input = input + 1; /* input */\n"
  for _ = 1, 450000 do f:write(line) end
  f:close()
  print(string.format("PROBE fixture lines=450000 bytes=%d", #line * 450000))
  local buffer = core.open_buffer(path)
  local native_ok, native = pcall(require, "line_search")
  if native_ok then
    local t = system.get_time()
    local index = native.scan(buffer.lines, "i", nil, false)
    print(string.format("PROBE native_scan_ms=%.3f matches=%d", (system.get_time() - t) * 1000, #index))
  end
  local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 1100, 800
  local window = renwindow.create("Local Find probe", 1100, 800)
  local previous_window = core.window
  local root = os.getenv("FIND_PROBE_ROOT") and core.root_panel or view
  if root ~= view then
    -- The test loop also lays out the Root Panel between coroutine resumes.
    -- Keep both update paths on the same private renderer window.
    core.window = window
    root.position.x, root.position.y = 0, 0
    root.size.x, root.size.y = 1100, 800
  end
  local function frame(samples)
    if root ~= view then
      assert(root.size.x == 1100 and root.size.y == 800,
        string.format("Root Panel viewport changed: %.1fx%.1f", root.size.x, root.size.y))
      assert(root:pane_views()[1] == view,
        string.format("Root Panel shows %s instead of the probe Editor", tostring(root:pane_views()[1])))
    end
    local start = system.get_time()
    local previous_snapshot, previous_render = core.ui_snapshot_active, core.render_frame_active
    core.ui_snapshot_id = (core.ui_snapshot_id or 0) + 1
    core.ui_snapshot_active = true
    root:update()
    core.ui_snapshot_active = false
    core.render_frame_id = (core.render_frame_id or 0) + 1
    core.render_frame_active = true
    renderer.begin_frame(window)
    root:draw()
    renderer.end_frame()
    core.ui_snapshot_active, core.render_frame_active = previous_snapshot, previous_render
    if samples then samples[#samples + 1] = (system.get_time() - start) * 1000 end
  end
  for _, wrapped in ipairs { false, true } do
    view:set_wrapping_enabled(wrapped)
    wrapping.complete_async_reconstruction(view)
    local name = wrapped and "wrapped" or "unwrapped"
    command.perform("editor:find_close")
    core.set_active_view(view)
    view:with_selection_state(function() buffer:set_selection(200000, 30) end)
    view:scroll_to_line(200000, true, true)
    command.perform("editor:find")
    local input, query_frames = core.active_view, 0
    local state = input.local_find_state
    input:set_text("")
    local started = system.get_time()
    core.root_panel:on_text_input("i")
    local dispatch = (system.get_time() - started) * 1000
    local reveal
    repeat
      frame()
      query_frames = query_frames + 1
      if not reveal and selection(view) ~= 200000 then reveal = (system.get_time() - started) * 1000 end
      if not coverage_complete(state) then coroutine.yield() end
      assert(system.get_time() - started < 180, "query exceeded three minutes")
    until coverage_complete(state)
    test.equal(#state.matches, 1800000)
    print(string.format("PROBE %s dispatch_ms=%.3f result_ms=%.3f reveal_ms=%.3f frames=%d markers=%d", name,
      dispatch, (system.get_time() - started) * 1000, reveal or -1, query_frames, marker_count(view)))
    local edits, missing = {}, 0
    for _ = 1, 5 do
      started = system.get_time()
      buffer:insert(100, 1, "x")
      edits[#edits + 1] = (system.get_time() - started) * 1000
      for _ = 1, 10 do
        frame()
        if marker_count(view) == 0 then missing = missing + 1 end
        coroutine.yield()
      end
    end
    print(string.format("PROBE %s edit_frames_without_markers=%d/50", name, missing))
    report(name .. "_edit_ms", edits)
    for _ = 1, 10000 do
      frame()
      if coverage_complete(state) then break end
      coroutine.yield()
    end
    for _, find in ipairs { true, false } do
      if not find then command.perform("editor:find_close"); core.set_active_view(view) end
      view.scroll.x, view.scroll.y = view.scroll.to.x, view.scroll.to.y
      local deadline = system.get_time() + 120
      repeat
        frame()
        view:update()
        local ts = buffer.treesitter
        if ts then require("core.treesitter").poll_buffer(buffer) end
        local parse_pending = ts and (ts.status == "queued" or ts.status == "parsing"
          or ts.pending_parse_thread or ts.latest_parse_pending)
        if not view:is_horizontal_extent_scan_pending() and not parse_pending then break end
        coroutine.yield()
        assert(system.get_time() < deadline, string.format("steady redraw pending: extent=%s ts=%s debounce=%s latest=%s rev=%s scheduled=%s",
          tostring(view:is_horizontal_extent_scan_pending()), tostring(ts and ts.status),
          tostring(ts and ts.pending_parse_thread), tostring(ts and ts.latest_parse_pending),
          tostring(buffer.text_revision), tostring(ts and ts.scheduled_revision)))
      until false
      local samples = {}
      for _ = 1, 5 do frame() end
      if root ~= view then
        local draw, painted = view.draw, false
        view.draw = function(self, ...)
          painted = true
          return draw(self, ...)
        end
        frame()
        view.draw = draw
        assert(painted and view.size.x > 500 and view.size.y > 400,
          string.format("Root Panel did not draw the visible Editor: painted=%s size=%.1fx%.1f panes=%d owner=%s visible=%s",
            tostring(painted), view.size.x, view.size.y, #root:pane_views(),
            tostring(panes.pane_for_view(view)), tostring(panes.visible_group())))
        print(string.format("PROBE %s find=%s visible_editor=%.1fx%.1f",
          name, tostring(find), view.size.x, view.size.y))
      end
      for _ = 1, 40 do frame(samples); coroutine.yield() end
      report(name .. (find and "_find_frame_ms" or "_frame_ms"), samples)
      if os.getenv("FIND_PROBE_PROFILE") then
        local totals, originals = {}, {}
        for _, method in ipairs { "update", "draw", "get_scrollable_size", "get_h_scrollable_size",
          "get_visual_row_metric_cache", "get_visual_row", "draw_line_body", "prepare_line_body_draw_cache" } do
          local fn = view[method]
          originals[method] = fn
          view[method] = function(self, ...)
            local t = system.get_time()
            local results = table.pack(fn(self, ...))
            totals[method] = (totals[method] or 0) + (system.get_time() - t) * 1000
            return table.unpack(results, 1, results.n)
          end
        end
        if root ~= view then
          for _, entry in ipairs {
            { core.root_panel, "update_layout" }, { core.status_bar, "update" },
            { core.status_bar, "update_active_items" },
          } do
            local object, method = entry[1], entry[2]
            local fn = object[method]
            entry.fn = fn
            object[method] = function(self, ...)
              local t = system.get_time()
              local results = table.pack(fn(self, ...))
              totals[tostring(object) .. "." .. method] = (totals[tostring(object) .. "." .. method] or 0)
                + (system.get_time() - t) * 1000
              return table.unpack(results, 1, results.n)
            end
            originals[entry] = fn
          end
        end
        for _ = 1, 10 do frame() end
        for method, fn in pairs(originals) do
          local key = method
          if type(method) == "table" then
            method[1][method[2]] = fn
            key = tostring(method[1]) .. "." .. method[2]
          else view[method] = fn end
          print(string.format("PROBE scope %s %s %s avg_ms=%.3f", name, tostring(find), key, (totals[key] or 0) / 10))
        end
      end
    end
  end
  buffer:clean()
  panes.reset_for_tests()
  core.window = previous_window
  os.remove(path)
  autosave.enabled = autosave_enabled
end)
