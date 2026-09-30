local test = require "core.test"

local function luminance(rgb)
  local function linear(value)
    value = value / 255
    return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linear(math.floor(rgb / 65536) % 256)
    + 0.7152 * linear(math.floor(rgb / 256) % 256)
    + 0.0722 * linear(rgb % 256)
end

local function contrast(a, b)
  a, b = luminance(a), luminance(b)
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05)
end

local function find_run(snapshot, text)
  for _, row in ipairs(snapshot.rows) do
    for _, run in ipairs(row.text_runs) do
      if run.text:find(text, 1, true) then return run, row end
    end
  end
  error("Missing terminal text: " .. text)
end

local function background_at(row, col, fallback)
  for _, span in ipairs(row.backgrounds) do
    if col >= span.col and col < span.col + span.columns then return span.color end
  end
  return fallback
end

local function visible_color(run, background)
  local alpha = run.alpha or (run.faint and 140 or 255)
  local function channel(shift)
    local fg = math.floor(run.fg / 2 ^ shift) % 256
    local bg = math.floor(background / 2 ^ shift) % 256
    return math.floor((fg * alpha + bg * (255 - alpha) + 127) / 255)
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

local function start_session(context, options)
  local native = require "terminal_native"
  options = options or {}
  options.cols, options.rows = 80, 12
  options.cell_width, options.cell_height = 8, 16
  options.foreground, options.background = 0x080808, 0xffffff
  options.minimum_contrast = options.minimum_contrast or 4.5
  options.cwd = system.getcwd()
  options.shell = [[powershell.exe -NoLogo -NoProfile -File tests/fixtures/terminal_contrast.ps1]]
  local session, err = native.new(options)
  test.ok(session, err)
  context.session = session
  local deadline = system.get_time() + 8
  repeat
    session:update()
    local snapshot = session:snapshot()
    for _, row in ipairs(snapshot.rows) do
      for _, run in ipairs(row.text_runs) do
        if run.text:find("ANVIL_CONTRAST_READY", 1, true) then return session, snapshot end
      end
    end
    coroutine.yield(0.005)
  until system.get_time() >= deadline
  error("Terminal contrast fixture did not finish")
end

test.describe("Terminal contrast correction", function()
  test.before_each(function()
    test.skip_if(PLATFORM ~= "Windows", "ConPTY is Windows-specific")
  end)
  test.after_each(function(context)
    if context.session then context.session:close() end
  end)

  test.it("makes explicit pale text readable on a light background", function(context)
    local _, snapshot = start_session(context)
    local run = find_run(snapshot, "LOW")
    test.ok(contrast(run.fg, 0xffffff) >= 4.5, "Pale text still has low contrast")
    local r = math.floor(run.fg / 65536) % 256
    local g = math.floor(run.fg / 256) % 256
    local b = run.fg % 256
    test.ok(g > r and g > b, "Corrected green text lost its color")
  end)

  test.it("keeps readable program colors and respects explicit backgrounds", function(context)
    local _, snapshot = start_session(context)
    test.equal(find_run(snapshot, "READABLE").fg, 0x005000)
    local run, row = find_run(snapshot, "DARK")
    test.equal(run.fg, 0xa6e3a1)
    test.equal(background_at(row, run.col, snapshot.background), 0x000000)
  end)

  test.it("checks dim text after opacity blending", function(context)
    local _, snapshot = start_session(context)
    local run, row = find_run(snapshot, "DIM")
    local background = background_at(row, run.col, snapshot.background)
    test.ok(contrast(visible_color(run, background), background) >= 4.5,
      "Dim text still has low contrast after blending")
  end)

  test.it("keeps readable dim text dim", function(context)
    local _, snapshot = start_session(context)
    local run = find_run(snapshot, "DIM_DARK")
    test.equal(run.fg, 0xffffff)
    test.ok(run.alpha < 255, "Readable dim text lost its opacity")
    test.ok(contrast(visible_color(run, 0), 0) >= 4.5)
  end)

  test.it("makes dark text readable on a dark background", function(context)
    local _, snapshot = start_session(context)
    local run = find_run(snapshot, "LOW_DARK")
    test.ok(contrast(run.fg, 0) >= 4.5, "Dark text still has low contrast")
    test.ok(run.fg % 256 > math.floor(run.fg / 65536) % 256,
      "Corrected blue text lost its hue")
  end)

  test.it("checks reversed text against the reversed background", function(context)
    local _, snapshot = start_session(context)
    local run, row = find_run(snapshot, "INVERSE")
    local background = background_at(row, run.col, snapshot.background)
    test.equal(background, 0xffffff)
    test.ok(contrast(run.fg, background) >= 4.5, "Reversed text still has low contrast")
  end)

  test.it("keeps graphics colors and does not reveal hidden text", function(context)
    local session, snapshot = start_session(context)
    test.equal(find_run(snapshot, "\226\150\136").fg, 0xa6e3a1)
    test.equal(find_run(snapshot, "\238\130\176").fg, 0xa6e3a1)
    for _, row in ipairs(snapshot.rows) do
      for _, run in ipairs(row.text_runs) do test.ok(not run.text:find("HIDDEN", 1, true)) end
    end
    local capture = session:text_capture()
    test.equal(capture.styles[6][1].alpha, 0)
  end)

  test.it("uses the selected cell background for text correction", function(context)
    local session = start_session(context, { selection_background = 0x000000, selection_alpha = 255 })
    test.ok(session:select(0, 0, 2, 0, false))
    local snapshot = session:snapshot()
    local run, row = find_run(snapshot, "LOW")
    local background = background_at(row, run.col, snapshot.background)
    test.equal(background, 0x000000)
    test.equal(run.fg, 0xa6e3a1)
    test.ok(contrast(run.fg, background) >= 4.5)
  end)

  test.it("captures the same corrected colors without changing program text", function(context)
    local session, snapshot = start_session(context)
    local capture = session:text_capture()
    test.ok(capture.text:find("LOW\nREADABLE\nDIM\nINVERSE", 1, true), capture.text)
    for index, text in ipairs({ "LOW", "READABLE", "DIM", "INVERSE" }) do
      local run = find_run(snapshot, text)
      test.equal(capture.styles[index][1].fg, run.fg)
      test.equal(capture.styles[index][1].alpha, run.alpha)
    end
  end)

  test.it("restores exact program colors when correction is turned off", function(context)
    local session, snapshot = start_session(context)
    test.ok(find_run(snapshot, "LOW").fg ~= 0xa6e3a1)
    test.ok(session:set_colors({ minimum_contrast = 1 }))
    snapshot = session:snapshot(snapshot)
    test.equal(find_run(snapshot, "LOW").fg, 0xa6e3a1)
    test.equal(find_run(snapshot, "DIM").fg, 0x005000)
    test.ok(session:set_colors({ minimum_contrast = 4.5 }))
    snapshot = session:snapshot(snapshot)
    test.ok(contrast(find_run(snapshot, "LOW").fg, 0xffffff) >= 4.5)
  end)

  test.it("updates correction when the terminal background changes", function(context)
    local session, snapshot = start_session(context)
    test.ok(session:set_colors({ background = 0x000000 }))
    snapshot = session:snapshot(snapshot)
    test.equal(find_run(snapshot, "LOW").fg, 0xa6e3a1)
    test.ok(session:set_colors({ background = 0xffffff }))
    snapshot = session:snapshot(snapshot)
    test.ok(contrast(find_run(snapshot, "LOW").fg, 0xffffff) >= 4.5)
  end)
end)
