local Doc = require "core.doc"
local DocView = require "core.docview"
local test = require "core.test"
local tokenizer = require "core.tokenizer"
local treesitter = require "core.treesitter"

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

local function c_doc(text)
  local doc = Doc()
  set_text(doc, text or "int main(void) { return 0; }")
  doc:set_filename("ui_tree_sitter.c", "ui_tree_sitter.c")
  return doc
end

local function wait_ready(doc, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_doc(doc)
    if doc.treesitter and doc.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function with_fake_draw_text(fn)
  local old_draw_text = renderer.draw_text
  local calls = {}
  renderer.draw_text = function(font, text, x, y, color, opts)
    calls[#calls + 1] = { text = text, x = x, y = y, color = color, opts = opts }
    return x + #tostring(text)
  end
  local ok, err = pcall(fn, calls)
  renderer.draw_text = old_draw_text
  if not ok then error(err) end
  return calls
end

test.describe("Tree-sitter DocView highlighting", function()
  test.it("DocView draw uses Tree-sitter render tokens when ready", function()
    local doc = c_doc("int main(void) { return VALUE; }")
    test.ok(wait_ready(doc))
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    local render_line = doc.highlighter:get_render_line(1)
    test.equal(render_line.source, "treesitter")
    local calls = with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    local drawn = {}
    for _, call in ipairs(calls) do drawn[#drawn + 1] = call.text end
    test.equal(table.concat(drawn), doc.lines[1]:sub(1, -2))
    doc:on_close()
  end)

  test.it("DocView draw falls back before Tree-sitter is ready", function()
    local doc = c_doc("int main(void) { return VALUE; }")
    local render_line = doc.highlighter:get_render_line(1)
    test.equal(render_line.source, "tokenizer")
    local view = DocView(doc)
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1000, 1000
    with_fake_draw_text(function()
      view:draw_line_text(1, 0, 0)
    end)
    doc:on_close()
  end)

  test.it("DocView measurement uses render token iterator", function()
    local doc = Doc()
    set_text(doc, "abc")
    local view = DocView(doc)
    local render_calls = 0
    local legacy_calls = 0
    doc.highlighter.each_render_token = function(_, line, scol)
      render_calls = render_calls + 1
      return tokenizer.each_token({ "normal", "abc\n" }, scol)
    end
    doc.highlighter.each_token = function(_, line, scol)
      legacy_calls = legacy_calls + 1
      return tokenizer.each_token({ "normal", "abc\n" }, scol)
    end
    view:get_col_x_offset(1, 3)
    view:get_x_offset_col(1, 1)
    test.ok(render_calls >= 2)
    test.equal(legacy_calls, 0)
    doc:on_close()
  end)
end)
