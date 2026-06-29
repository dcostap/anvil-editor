-- mod-version:3 priority:99
local core = require "core"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local RootPanel = require "core.rootpanel"
local perf = require "core.perf"

local hud = {
  visible = false,
  last_saved_path = nil,
}

local function fmt_ms(v)
  return string.format("%.2fms", tonumber(v) or 0)
end

local function fmt_num(v)
  return string.format("%.0f", tonumber(v) or 0)
end

local function draw_hud()
  if core.perf_capture_active then return end
  if not hud.visible and not perf.is_recording() then return end

  local s = core.performance_snapshot or {}
  local font = style.code_font
  local pad = math.floor(10 * SCALE)
  local line_h = math.floor(font:get_height() * 1.25)
  local recording = perf.is_recording()
  local lines = {}

  if recording then
    lines[#lines + 1] = "Recording... F11 to stop"
  else
    lines[#lines + 1] = "Performance  F10 hide"
  end
  lines[#lines + 1] = string.format("FPS %.1f / %.1f", tonumber(s.fps) or 0, tonumber(s.target_fps) or 0)
  lines[#lines + 1] = string.format("Frame %s  Present %s", fmt_ms(s.frame_ms), fmt_ms(s.present_ms))
  lines[#lines + 1] = string.format("Draw %s  Update %s", fmt_ms(s.draw_emit_ms), fmt_ms(s.update_ms))
  lines[#lines + 1] = string.format("D3D draws %s  uploads %s", fmt_num(s.draw_calls), fmt_num(s.texture_uploads))
  lines[#lines + 1] = string.format("DocView %s  prep %s", fmt_ms(s.docview_draw_ms), fmt_ms(s.docview_prepare_ms))
  if (tonumber(s.lsp_render_tokens_calls) or 0) > 0 then
    lines[#lines + 1] = string.format(
      "LSP tokens %s  offsets %s  scan %s",
      fmt_ms(s.lsp_render_tokens_ms),
      fmt_ms(s.lsp_render_tokens_line_offsets_ms),
      fmt_ms(s.lsp_render_tokens_scan_ms)
    )
  end
  lines[#lines + 1] = string.format("Selections %.0f  sel-iters %.0f", tonumber(s.selection_count) or 0, tonumber(s.doc_get_selections_iters) or 0)
  if not recording then
    lines[#lines + 1] = "F11 record detailed metrics"
  end
  if hud.last_saved_path and not recording then
    lines[#lines + 1] = "Saved path copied to clipboard"
  end

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, font:get_width(line))
  end
  local w = width + pad * 2
  local h = #lines * line_h + pad * 2
  local x = math.floor(core.root_panel.size.x - w - 14 * SCALE)
  local y = math.floor(14 * SCALE)

  renderer.draw_rect(x, y, w, h, recording and style.performance_hud_recording_background or style.performance_hud_background)
  local ty = y + pad
  for i, line in ipairs(lines) do
    renderer.draw_text(font, line, x + pad, ty, i == 1 and style.performance_hud_text or style.performance_hud_dim)
    ty = ty + line_h
  end
end

local old_root_draw = RootPanel.draw
function RootPanel:draw()
  old_root_draw(self)
  draw_hud()
end

command.add(nil, {
  ["performance-hud:toggle"] = function()
    hud.visible = not hud.visible
    core.redraw = true
  end,
  ["performance-hud:toggle-recording"] = function()
    local started, path = perf.toggle_recording()
    if started then
      hud.visible = true
      hud.last_saved_path = nil
      core.log("Performance recording started: %s", path)
    else
      hud.last_saved_path = path
      core.log("Performance recording saved and copied to clipboard: %s", path)
    end
    core.redraw = true
  end,
})

keymap.add {
  ["f10"] = "performance-hud:toggle",
  ["f11"] = "performance-hud:toggle-recording",
}

return hud
