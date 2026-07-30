local core = require "core"
local perf = require "core.perf"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function read_all(path)
  local file = assert(io.open(path, "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

local function remove_recording_files(summary_path)
  if not summary_path then return end
  local base = summary_path:gsub("_summary%.txt$", "")
  for _, suffix in ipairs {
    "_frames.csv",
    "_lua_samples.csv",
    "_api_calls.csv",
    "_details.csv",
    "_draw_scopes.csv",
    "_summary.txt",
  } do
    os.remove(base .. suffix)
  end
end

test.describe("Fuzzy Searcher performance diagnostics", function()
  test.after_each(function(context)
    if perf.is_recording() then
      context.summary_path = perf.stop_recording()
    end
    if context.original_draw_rect then renderer.draw_rect = context.original_draw_rect end
    if context.original_draw_text then renderer.draw_text = context.original_draw_text end
    if context.original_set_clip_rect then renderer.set_clip_rect = context.original_set_clip_rect end
    if context.original_draw_image then renderer.draw_image = context.original_draw_image end
    if context.original_draw_canvas then renderer.draw_canvas = context.original_draw_canvas end
    remove_recording_files(context.summary_path)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
  end)

  test.it("attributes picker drawing to stable phase and result-kind scopes", function(context)
    local picker = fuzzy_searcher.open_static_results("Symbols", {
      {
        kind = "symbol",
        label = "render_result",
        name = "render_result",
        symbol_kind = "function",
        file = "C:/project/render.lua",
        line = 17,
        declaration = "function render_result()",
        declaration_name_span = { 10, 22 },
        match_spans = { { 1, 6 } },
        file_spans = {},
      },
    }, { status = "1 symbol" })
    picker.selected = 1
    picker.is_full_width_mode = function() return false end
    picker.is_deep_code_mode = function() return true end
    picker.updated = true

    context.original_draw_rect = renderer.draw_rect
    context.original_draw_text = renderer.draw_text
    context.original_set_clip_rect = renderer.set_clip_rect
    context.original_draw_image = renderer.draw_image
    context.original_draw_canvas = renderer.draw_canvas
    renderer.draw_rect = function() end
    renderer.draw_text = function(font, text, x)
      return x + font:get_width(text)
    end
    renderer.set_clip_rect = function() end
    renderer.draw_image = function() end
    renderer.draw_canvas = function() end

    perf.start_recording()
    perf.begin_draw_frame()
    test.ok(picker:draw())
    perf.finish_draw_frame()
    perf.on_frame {
      time = system.get_time(),
      did_redraw = true,
      draw_emit_ms = 1,
      frame_ms = 1,
      total_ms = 1,
      target_fps = 60,
    }
    context.summary_path = perf.stop_recording()

    local base = context.summary_path:gsub("_summary%.txt$", "")
    local scopes = read_all(base .. "_draw_scopes.csv")
    test.ok(scopes:find("fuzzy_searcher/widget_chrome", 1, true))
    test.ok(scopes:find("fuzzy_searcher/list_setup", 1, true))
    test.ok(scopes:find("fuzzy_searcher/result_scan", 1, true))
    test.ok(scopes:find("fuzzy_searcher/result_rows/kind:symbol", 1, true))
    test.ok(scopes:find("fuzzy_searcher/preview", 1, true))
    test.ok(scopes:find("fuzzy_searcher/preview/preview_update", 1, true))
  end)
end)
