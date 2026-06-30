local common = require "core.common"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local test = require "core.test"
local diagnostic_markers = require "core.lsp.diagnostic_markers"
local diagnostic_underlines = require "core.lsp.diagnostic_underlines"
local diagnostics = require "core.lsp.diagnostics"
local documents = require "core.lsp.documents"
local uri = require "core.lsp.uri"

local temp_root

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
  return path
end

local function set_text(doc, text)
  doc.lines = {}
  for line in (text .. "\n"):gmatch("(.-\n)") do
    doc.lines[#doc.lines + 1] = line
  end
  if #doc.lines == 0 then doc.lines[1] = "\n" end
  doc:clear_undo_redo()
  doc:clean()
  doc:set_selection(1, 1)
end

local function new_doc(path, text)
  local doc = Doc()
  set_text(doc, text or "")
  doc:set_filename(path, path)
  return doc
end

local function fake_client(id)
  return {
    server_id = id or "fake-diagnostic-underlines",
    position_encoding = "utf-16",
    notifications = {},
    on_notification = function(self, method, handler)
      self.notifications[method] = handler
    end,
    send_notification = function()
      return true
    end,
  }
end

local function lsp_range(sl, sc, el, ec)
  return {
    start = { line = sl, character = sc },
    ["end"] = { line = el, character = ec },
  }
end

local function publish(client, params)
  local handler = client.notifications["textDocument/publishDiagnostics"]
  test.not_nil(handler)
  handler(params)
end

local function with_fake_draw_poly(fn)
  local old_draw_poly = renderer.draw_poly
  local calls = {}
  renderer.draw_poly = function(points, color)
    calls[#calls + 1] = { points = points, color = color }
  end
  local ok, err = pcall(fn, calls)
  renderer.draw_poly = old_draw_poly
  if not ok then error(err, 0) end
  return calls
end

local function point_bounds(points)
  local min_x, min_y, max_x, max_y
  for _, point in ipairs(points or {}) do
    local x, y = point[1], point[2]
    min_x = min_x and math.min(min_x, x) or x
    min_y = min_y and math.min(min_y, y) or y
    max_x = max_x and math.max(max_x, x) or x
    max_y = max_y and math.max(max_y, y) or y
  end
  return min_x, min_y, max_x, max_y
end

test.describe("LSP Diagnostic Underlines", function()
  test.before_each(function(context)
    temp_root = USERDIR .. PATHSEP .. "lsp-diagnostic-underlines-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.temp_root = temp_root
    mkdir(temp_root)
  end)

  test.after_each(function(context)
    if context.original_error_underline then style.diagnostic_error_underline = context.original_error_underline end
    if context.original_warning_underline then style.diagnostic_warning_underline = context.original_warning_underline end
    if context.original_removal_grace then diagnostic_markers.set_removal_grace_seconds(context.original_removal_grace) end
    if context.test_font_key then style[context.test_font_key] = nil end
    if context.docs then
      for _, doc in ipairs(context.docs) do pcall(function() doc:on_close() end) end
    end
    if context.clients then
      for _, client in ipairs(context.clients) do diagnostics.clear_client(client) end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function track_doc(context, doc)
    context.docs = context.docs or {}
    context.docs[#context.docs + 1] = doc
    return doc
  end

  local function track_client(context, client)
    context.clients = context.clients or {}
    context.clients[#context.clients + 1] = client
    return client
  end

  local function setup(context, text)
    local path = join_path(temp_root, "main.cpp")
    local doc = track_doc(context, new_doc(path, text or "first\nsecond\nthird"))
    local client = track_client(context, fake_client())
    documents.attach(client, doc, { language_id = "cpp" })
    diagnostics.attach_client(client)
    return doc, client, uri.path_to_uri(path)
  end

  test.it("draws error and warning underlines for diagnostic ranges", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "error" },
        { range = lsp_range(1, 0, 1, 6), severity = 2, message = "warning" },
        { range = lsp_range(2, 0, 2, 5), severity = 3, message = "info" },
      },
    })

    local view = DocView(doc)
    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 10, 20)
      diagnostic_underlines.draw_line(view, 2, 10, 40)
      diagnostic_underlines.draw_line(view, 3, 10, 60)
    end)

    test.equal(#calls, 2)
    test.equal(calls[1].color, style.diagnostic_error_underline)
    test.equal(calls[2].color, style.diagnostic_warning_underline)
    for _, call in ipairs(calls) do
      local min_x, min_y, max_x, max_y = point_bounds(call.points)
      test.ok(max_x > min_x)
      test.ok(max_y > min_y)
      test.ok(#call.points > 4, "diagnostic underline should be a squiggle polygon")
    end
  end)

  test.it("keeps stale-tracked underlines visible when document sync makes diagnostics stale", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "stale error" },
      },
    })

    local view = DocView(doc)
    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 0, 0)
      doc:apply_edits({ { line1 = 1, col1 = 1, line2 = 1, col2 = 1, text = "new " } })
      diagnostic_underlines.draw_line(view, 1, 0, 0)
      documents.flush(client, doc)
      diagnostic_underlines.draw_line(view, 1, 0, 0)
    end)

    test.equal(#calls, 3)
  end)

  test.it("shifts stale-tracked underlines to the original diagnostic line when inserting newline at diagnostic start", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), severity = 1, message = "moves down" },
      },
    })

    doc:insert(2, 1, "\n")

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 2), 0)
    local shifted = diagnostic_underlines.ranges_for_line(doc, 3)
    test.equal(#shifted, 1)
    test.equal(shifted[1].col1, 1)
    test.equal(shifted[1].col2, 7)
  end)

  test.it("preserves underlines through broad replacements that keep diagnostic text", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), severity = 1, message = "preserved" },
      },
    })

    doc:apply_edits({
      { line1 = 1, col1 = 1, line2 = 3, col2 = #doc.lines[3], text = "zero\nfirst\nsecond\nthird\n" },
    })

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 2), 0)
    local shifted = diagnostic_underlines.ranges_for_line(doc, 3)
    test.equal(#shifted, 1)
    test.equal(shifted[1].col1, 1)
    test.equal(shifted[1].col2, 7)
  end)

  test.it("shifts stale-tracked underlines when inserting lines before diagnostics", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(1, 0, 1, 6), severity = 1, message = "moves down" },
      },
    })

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 2), 1)
    doc:insert(1, 1, "inserted\n")
    test.equal(#diagnostic_underlines.ranges_for_line(doc, 2), 0)
    local shifted = diagnostic_underlines.ranges_for_line(doc, 3)
    test.equal(#shifted, 1)
    test.equal(shifted[1].col1, 1)
    test.equal(shifted[1].col2, 7)
    documents.flush(client, doc)
    test.equal(#diagnostic_underlines.ranges_for_line(doc, 3), 1)
  end)

  test.it("does not create visual markers from same-version publishes while local edits are pending", function(context)
    local doc, client, document_uri = setup(context)
    doc:insert(1, 1, "dirty ")
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "stale publish" },
      },
    })

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 1), 0)
  end)

  test.it("authoritative empty publishes defer marker removal to avoid flicker", function(context)
    local doc, client, document_uri = setup(context)
    context.original_removal_grace = diagnostic_markers.set_removal_grace_seconds(60)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "kept briefly" },
      },
    })
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {},
    })

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 1), 1)
  end)

  test.it("expired deferred marker removals stop rendering", function(context)
    local doc, client, document_uri = setup(context)
    context.original_removal_grace = diagnostic_markers.set_removal_grace_seconds(0)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "removed" },
      },
    })
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {},
    })

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 1), 0)
  end)

  test.it("same-version empty publishes while dirty do not clear tracked underlines", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "kept" },
      },
    })
    doc:insert(1, 1, "dirty ")
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {},
    })

    test.equal(#diagnostic_underlines.ranges_for_line(doc, 1), 1)
  end)

  test.it("keeps zero-width diagnostics visible", function(context)
    local doc, client, document_uri = setup(context, "abc")
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 1, 0, 1), severity = 1, message = "zero" },
      },
    })

    local view = DocView(doc)
    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 0, 0)
    end)

    test.equal(#calls, 1)
    local min_x, _, max_x = point_bounds(calls[1].points)
    test.ok(max_x > min_x)
  end)

  test.it("resolves underline colors at draw time", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 2, message = "warning" },
      },
    })

    context.original_warning_underline = style.diagnostic_warning_underline
    local replacement = { 9, 8, 7, 255 }
    local view = DocView(doc)
    style.diagnostic_warning_underline = replacement

    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 0, 0)
    end)

    test.equal(calls[1].color, replacement)
  end)

  test.it("scales squiggle thickness and position with the code font", function(context)
    local doc, client, document_uri = setup(context)
    publish(client, {
      textDocument = { uri = document_uri, version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 5), severity = 1, message = "font scaled" },
      },
    })

    local view = DocView(doc)
    context.test_font_key = "__test_diagnostic_underline_font"
    local fake_font = {
      get_height = function() return 28 end,
      get_width = function(_, text) return #(text or "") * 10 end,
      set_tab_size = function() end,
    }
    style[context.test_font_key] = fake_font
    view.font = context.test_font_key

    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 5, 11)
    end)

    local _, min_y, _, max_y = point_bounds(calls[1].points)
    local text_bottom = 11 + view:get_line_text_y_offset() + fake_font:get_height()
    local expected_minimum_span = math.ceil(fake_font:get_height() / 14)
    test.ok(max_y <= math.ceil(text_bottom))
    test.ok(max_y - min_y > expected_minimum_span)
  end)

  test.it("splits wrapped underline ranges across visual rows", function(context)
    require "core.linewrapping"
    local doc = track_doc(context, new_doc(join_path(temp_root, "wrapped.cpp"), "abcdefghi"))
    local client = track_client(context, fake_client())
    documents.attach(client, doc, { language_id = "cpp" })
    diagnostics.attach_client(client)
    publish(client, {
      textDocument = { uri = uri.path_to_uri(doc.filename), version = 0 },
      diagnostics = {
        { range = lsp_range(0, 2, 0, 8), severity = 1, message = "wrapped" },
      },
    })

    local view = DocView(doc)
    view.wrapped_settings = {}
    view.wrapped_lines = { 1, 1, 1, 6 }
    view.wrapped_line_to_idx = { [1] = 1, [2] = 3 }
    view.wrapped_line_offsets = { 0 }

    local lh = view:get_line_height()
    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 0, 100)
    end)

    test.equal(#calls, 2)
    local _, min_y1, _, max_y1 = point_bounds(calls[1].points)
    local _, min_y2, _, max_y2 = point_bounds(calls[2].points)
    test.equal(min_y2 - min_y1, lh)
    test.equal(max_y2 - max_y1, lh)
  end)

  test.it("draws wrapped underlines once through DocView line body", function(context)
    local doc = track_doc(context, new_doc(join_path(temp_root, "wrapped-once.cpp"), "abcdefghi"))
    local client = track_client(context, fake_client())
    documents.attach(client, doc, { language_id = "cpp" })
    diagnostics.attach_client(client)
    diagnostic_underlines.install()
    publish(client, {
      textDocument = { uri = uri.path_to_uri(doc.filename), version = 0 },
      diagnostics = {
        { range = lsp_range(0, 2, 0, 8), severity = 1, message = "wrapped" },
      },
    })

    local view = DocView(doc)
    view.wrapped_settings = {}
    view.wrapped_lines = { 1, 1, 1, 6 }
    view.wrapped_line_to_idx = { [1] = 1, [2] = 3 }
    view.wrapped_line_offsets = { 0 }
    view.draw_line_text = function(self)
      return self:get_line_height() * 2
    end
    view.draw_line_hint = function() end

    local old_draw_rect = renderer.draw_rect
    renderer.draw_rect = function() end
    local calls = with_fake_draw_poly(function()
      view:draw_line_body(1, 0, 100)
    end)
    renderer.draw_rect = old_draw_rect

    test.equal(#calls, 2)
  end)

  test.it("culls wrapped underline ranges to visible visual rows", function(context)
    require "core.linewrapping"
    local doc = track_doc(context, new_doc(join_path(temp_root, "wrapped-culled.cpp"), "abcdefghi"))
    local client = track_client(context, fake_client())
    documents.attach(client, doc, { language_id = "cpp" })
    diagnostics.attach_client(client)
    publish(client, {
      textDocument = { uri = uri.path_to_uri(doc.filename), version = 0 },
      diagnostics = {
        { range = lsp_range(0, 0, 0, 9), severity = 1, message = "wrapped" },
      },
    })

    local view = DocView(doc)
    view.wrapped_settings = {}
    view.wrapped_lines = { 1, 1, 1, 4, 1, 7 }
    view.wrapped_line_to_idx = { [1] = 1, [2] = 4 }
    view.wrapped_line_offsets = { 0 }
    view.__wrapped_draw_first_idx = 2
    view.__wrapped_draw_last_idx = 2

    local lh = view:get_line_height()
    local calls = with_fake_draw_poly(function()
      diagnostic_underlines.draw_line(view, 1, 0, 100)
    end)

    test.equal(#calls, 1)
    local _, min_y = point_bounds(calls[1].points)
    test.ok(min_y >= 100 + lh, "expected only the visible wrapped row underline to be drawn")
  end)
end)
