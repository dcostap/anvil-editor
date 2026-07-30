local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local test = require "core.test"

local function median(values)
  table.sort(values)
  return values[math.floor((#values + 1) / 2)]
end

local function elapsed_ms(fn)
  local started = system.get_time()
  fn()
  return (system.get_time() - started) * 1000
end

local function make_source(line_count, line_factory)
  local lines = {}
  for line = 1, line_count do lines[line] = line_factory(line) end
  return table.concat(lines)
end

local function new_view(name, source, width_cells)
  local doc = Doc(name, name, true)
  doc:insert(1, 1, source)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.size.x, view.size.y = 1200, 800
  local font = view:get_font()
  local width = font:get_width(string.rep("x", width_cells))
  return doc, view, font, width
end

local function close(doc, view)
  view:set_wrapping_enabled(false)
  doc:on_close()
end

local function benchmark_reconstruction(name, source, width_cells, iterations)
  local doc, view, font, width = new_view(name, source, width_cells)
  linewrapping.reconstruct_breaks(view, font, width)
  local samples = {}
  for iteration = 1, iterations do
    collectgarbage("collect")
    samples[iteration] = elapsed_ms(function()
      linewrapping.reconstruct_breaks(view, font, width)
    end)
  end
  local result = {
    bytes = #source,
    lines = #doc.lines,
    rows = linewrapping.get_total_wrapped_lines(view),
    median_ms = median(samples),
  }
  close(doc, view)
  return result
end

local function benchmark_edit_position(line_count, target_line)
  local source = make_source(line_count, function(line)
    return string.format("value_%05d = representative_words_for_wrapping alpha beta gamma delta\n", line)
  end)
  local doc, view, _, width = new_view("linewrap-edit-benchmark.lua", source, 72)
  linewrapping.reconstruct_breaks(view, view:get_font(), width)
  doc:set_selection(target_line, 1, target_line, 1)
  local ms = elapsed_ms(function() doc:text_input(string.rep("x", 72)) end)
  local rows = linewrapping.get_total_wrapped_lines(view)
  close(doc, view)
  return ms, rows, #source
end

local function benchmark_multi_range_edit(source, line_count, edit_count, force_reconstruct)
  local samples = {}
  local rows
  for iteration = 1, 5 do
    local doc, view, _, width = new_view(
      "linewrap-multi-range-benchmark.lua", source, 72
    )
    linewrapping.reconstruct_breaks(view, view:get_font(), width)
    local edits = {}
    for index = 1, edit_count do
      local line = math.floor((index - 1) * (line_count - 1) / (edit_count - 1)) + 1
      edits[index] = {
        line1 = line, col1 = 10, line2 = line, col2 = 10, text = "X",
      }
    end

    local original_update = linewrapping.update_multiple_nonstructural_breaks
    if force_reconstruct then
      linewrapping.update_multiple_nonstructural_breaks = function() return false end
    end
    collectgarbage("collect")
    local ok, elapsed = pcall(elapsed_ms, function()
      doc:apply_edits(edits, { type = "linewrap-multi-range-benchmark" })
    end)
    linewrapping.update_multiple_nonstructural_breaks = original_update
    if not ok then
      close(doc, view)
      error(elapsed, 0)
    end
    samples[iteration] = elapsed
    rows = linewrapping.get_total_wrapped_lines(view)
    close(doc, view)
  end
  return median(samples), rows
end

test.describe("line wrapping benchmark", function()
  test.it("reports reconstruction and incremental edit costs", function()
    local cfg = config.plugins.linewrapping
    local saved = {
      mode = cfg.mode,
      indent = cfg.indent,
      wrapping_indent = cfg.wrapping_indent,
      require_tokenization = cfg.require_tokenization,
      enable_by_default = cfg.enable_by_default,
    }
    cfg.mode = "word"
    cfg.indent = true
    cfg.wrapping_indent = 6
    cfg.require_tokenization = false
    cfg.enable_by_default = false

    local source = make_source(20000, function(line)
      return string.format(
        "local value_%05d = compute(alpha, beta, gamma) -- representative source words\n",
        line
      )
    end)
    local ordinary = benchmark_reconstruction(
      "linewrap-ordinary-benchmark.lua", source, 80, 5
    )

    local long_ascii = benchmark_reconstruction(
      "linewrap-long-ascii-benchmark.txt",
      ("representative words for wrapping "):rep(32000), 80, 5
    )
    local long_utf8 = benchmark_reconstruction(
      "linewrap-long-utf8-benchmark.txt",
      ("naïve café λογος 漢字 representative words "):rep(12000), 80, 5
    )
    local utf8_lines = benchmark_reconstruction(
      "linewrap-utf8-lines-benchmark.txt",
      make_source(5000, function()
        return ("naïve café λογος 漢字 representative words "):rep(4) .. "\n"
      end),
      80,
      5
    )

    local early_edit_ms, early_rows, edit_bytes = benchmark_edit_position(20000, 1)
    local late_edit_ms, late_rows = benchmark_edit_position(20000, 20000)
    local multi_reconstruct_ms, multi_reconstruct_rows = benchmark_multi_range_edit(
      source, 20000, 100, true
    )
    local multi_incremental_ms, multi_incremental_rows = benchmark_multi_range_edit(
      source, 20000, 100, false
    )

    print(string.format(
      "Line wrap ordinary reconstruction: bytes=%d lines=%d rows=%d median_ms=%.3f",
      ordinary.bytes, ordinary.lines, ordinary.rows, ordinary.median_ms
    ))
    print(string.format(
      "Line wrap long ASCII reconstruction: bytes=%d lines=%d rows=%d median_ms=%.3f",
      long_ascii.bytes, long_ascii.lines, long_ascii.rows, long_ascii.median_ms
    ))
    print(string.format(
      "Line wrap long UTF-8 reconstruction: bytes=%d lines=%d rows=%d median_ms=%.3f",
      long_utf8.bytes, long_utf8.lines, long_utf8.rows, long_utf8.median_ms
    ))
    print(string.format(
      "Line wrap UTF-8 lines reconstruction: bytes=%d lines=%d rows=%d median_ms=%.3f",
      utf8_lines.bytes, utf8_lines.lines, utf8_lines.rows, utf8_lines.median_ms
    ))
    print(string.format(
      "Line wrap row-changing edit: bytes=%d lines=%d early_ms=%.3f late_ms=%.3f early_rows=%d late_rows=%d",
      edit_bytes, 20000, early_edit_ms, late_edit_ms, early_rows, late_rows
    ))
    print(string.format(
      "Line wrap 100-range edit: bytes=%d lines=%d reconstruct_ms=%.3f incremental_ms=%.3f rows=%d",
      #source, 20000, multi_reconstruct_ms, multi_incremental_ms,
      multi_incremental_rows
    ))
    io.stdout:flush()

    for key, value in pairs(saved) do cfg[key] = value end
    test.ok(ordinary.rows >= ordinary.lines)
    test.ok(long_ascii.rows > 1)
    test.ok(long_utf8.rows > 1)
    test.ok(utf8_lines.rows > utf8_lines.lines)
    test.equal(multi_incremental_rows, multi_reconstruct_rows)
  end)
end)
