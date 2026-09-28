local Buffer = require "core.buffer"
local core = require "core"
local TextView = require "core.textview"
local wrapping = require "core.linewrapping"
local test = require "core.test"

test.describe("Wrapped presentation publication", function()
  test.after_each(function(context)
    if context.view then context.view:release_owned_features("test") end
  end)

  test.it("finishes a sliced presentation while one line keeps changing", function(context)
    local buffer = Buffer()
    buffer:insert(1, 1, string.rep("words words words words\n", 12))
    local view = TextView(buffer)
    context.view = view
    view.size.x, view.size.y = 200, 400
    local small = view:get_font()
    local large = small:copy(small:get_size() * 2)
    local font, changing_font = small, small
    view:add_line_render_provider("changing-line", {
      line_generation = function(_, _, line)
        return line == 1 and changing_font or font
      end,
      render_line = function(_, _, line)
        return { fragments = {
          { source_col1 = 1, source_col2 = #buffer.lines[line],
            text = buffer.lines[line]:gsub("\n$", ""),
            font = line == 1 and changing_font or font },
        } }
      end,
    })
    view:set_wrapping_enabled(true)
    wrapping.complete_async_reconstruction(view)
    local before = view:get_visual_row_count_for_line(2)
    local add_thread, get_time = core.add_thread, system.get_time
    local jobs, clock, completed = {}, get_time(), false
    -- Control the scheduler and slice clock, not layout state. Each turn can
    -- prepare one line. Local presentation changes continue between turns.
    core.add_thread = function(fn) jobs[#jobs + 1] = coroutine.create(fn) end
    system.get_time = function() clock = clock + 1; return clock end
    local ok, err = pcall(function()
      font = large
      view:invalidate_line_render("changing-line", nil, nil, {
        defer_wrapped_reconstruction = true,
        on_wrapped_reconstructed = function(success) completed = success end,
      })
      for turn = 1, #buffer.lines * 3 do
        changing_font = turn % 2 == 0 and small or large
        view:invalidate_line_render("changing-line", 1, 1)
        local scheduled = jobs
        jobs = {}
        for _, job in ipairs(scheduled) do
          local resumed, failure = coroutine.resume(job)
          if not resumed then error(failure, 0) end
          if coroutine.status(job) ~= "dead" then jobs[#jobs + 1] = job end
        end
        if completed then break end
      end
    end)
    core.add_thread, system.get_time = add_thread, get_time
    if not ok then error(err, 0) end
    test.ok(completed, "local changes prevented the pending presentation from completing")
    test.ok(view:get_visual_row_count_for_line(2) > before)
    test.equal(view:get_visual_row_count_for_line(1),
      changing_font == large and view:get_visual_row_count_for_line(2) or before,
      "the repaired line must publish its latest wrap geometry")
    test.equal(view:get_line_render(2).fragments[1].font, large)
    test.equal(view:get_line_render(1).fragments[1].font, changing_font)
  end)

  test.it("adopts rendered text and wrapped rows together during a sliced rebuild", function(context)
    local buffer = Buffer()
    buffer:insert(1, 1, string.rep(string.rep("words ", 30) .. "\n", 40))
    local view = TextView(buffer)
    context.view = view
    view.size.x, view.size.y = 500, 400
    local small = view:get_font()
    local large = small:copy(small:get_size() * 2)
    local font = small
    local provider = {
      generation = function() return font end,
      render_line = function(_, owner, line)
        local line_font = line == 1 and font
          or owner:get_line_render(1).fragments[1].font
        return {
          source_text = owner.buffer.lines[line]:gsub("\n$", ""),
          text_row_height = line_font:get_height(),
          fragments = { { source_col1 = 1, source_col2 = #owner.buffer.lines[line],
            text = owner.buffer.lines[line]:gsub("\n$", ""), font = line_font } },
        }
      end,
      line_metrics = function(_, owner, line, count)
        return { row_count = count, height = owner:get_line_render(line).text_row_height }
      end,
    }
    view:add_line_render_provider("publication-test", provider)
    view:add_visual_metric_provider("publication-test", provider)
    view:set_wrapping_enabled(true)
    wrapping.complete_async_reconstruction(view)
    local function geometry()
      return {
        font = view:get_line_render(1).fragments[1].font:get_size(),
        rows = view:get_visual_row_count_for_line(1),
        height = view:get_visual_row_height(1),
      }
    end
    local before = geometry()
    font = large
    -- Control the clock boundary, not the wrapping implementation. Each slice
    -- exhausts its budget before it can finish the whole Buffer.
    local function start_rebuild()
      local get_time, tick = system.get_time, 0
      local origin = get_time()
      system.get_time = function() tick = tick + 1; return origin + tick end
      local ok, err = pcall(function()
        view:invalidate_line_render("publication-test", nil, nil, {
          defer_wrapped_reconstruction = true,
        })
      end)
      system.get_time = get_time
      if not ok then error(err, 0) end
      view:invalidate_visual_metrics("publication-test")
    end
    start_rebuild()
    local during = geometry()
    -- Replace unfinished work. Only the latest complete presentation may win.
    font = small:copy(small:get_size() * 3)
    start_rebuild()
    local restarted = geometry()
    wrapping.complete_async_reconstruction(view)
    local after = geometry()
    test.ok(after.rows > before.rows, "the larger text must require more wrapped rows")
    test.ok(after.height > before.height, "the larger text must require taller rows")
    test.same(during, before, "new text presentation reached the old wrapped layout")
    test.same(restarted, before, "restarting exposed an unfinished presentation")
    test.equal(after.font, font:get_size())
    test.equal(view:get_visual_row_count_for_line(2), after.rows,
      "a dependent line used an older presentation during layout preparation")

    font = small
    start_rebuild()
    buffer:insert(2, 1, "inserted line\n")
    wrapping.complete_async_reconstruction(view)
    test.same(geometry(), before,
      "a source edit discarded the unfinished presentation update for unchanged lines")
  end)
end)
