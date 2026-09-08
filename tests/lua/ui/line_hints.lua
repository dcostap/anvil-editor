local common = require "core.common"
local core = require "core"
local test = require "core.test"
local style = require "core.style"
local metadata = require "plugins.file_metadata"

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function find_line(view, name)
  for i, line in ipairs(view.buffer.lines) do
    if line == name .. "\n" then return i end
  end
  error("Missing File Tree row: " .. name)
end

local function draw_texts(draw)
  local texts = {}
  local old_text, old_canvas = renderer.draw_text, renderer.draw_canvas
  renderer.draw_text = function(font, text, x)
    if text:find("%S") then texts[#texts + 1] = text end
    return x + font:get_width(text)
  end
  renderer.draw_canvas = function() end
  local ok, err = pcall(draw)
  renderer.draw_text, renderer.draw_canvas = old_text, old_canvas
  if not ok then error(err) end
  return texts
end

local function hint_texts(view, line)
  local hint = assert(view:get_line_hint(line))
  return draw_texts(function() hint.draw(0, 0, 3000) end)
end

local function contains(texts, expected)
  for _, text in ipairs(texts) do if text == expected then return true end end
  return false
end

test.describe("File Tree Line Hints", function()
  test.before_each(function(context)
    context.set_clip_rect = renderer.set_clip_rect
    renderer.set_clip_rect = function() end
    context.root = core.root_project().path .. PATHSEP .. "metadata-test-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.view = assert(require("plugins.filetree").new())
    context.view.current_dir = context.root
  end)

  test.after_each(function(context)
    renderer.set_clip_rect = context.set_clip_rect
    if context.root then test.ok(common.rm(context.root, true)) end
  end)

  test.it("shows direct child counts in File Tree and Fuzzy Searcher", function(context)
    local root, view = context.root, context.view
    test.ok(common.mkdirp(root .. PATHSEP .. "folder" .. PATHSEP .. "nested"))
    test.ok(common.mkdirp(root .. PATHSEP .. "empty"))
    write_file(root .. PATHSEP .. "folder" .. PATHSEP .. "one", "one")
    write_file(root .. PATHSEP .. "folder" .. PATHSEP .. "nested" .. PATHSEP .. "two", "two")
    view:refresh(false, false)
    local folder, empty = find_line(view, "folder/"), find_line(view, "empty/")
    local deadline = system.get_time() + 3
    repeat
      if contains(hint_texts(view, folder), "2") and contains(hint_texts(view, empty), "0") then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.ok(contains(hint_texts(view, folder), "2"), "expected direct children, not descendants")
    test.ok(contains(hint_texts(view, empty), "0"), "expected an empty folder count")
    local fuzzy = require("plugins.fuzzy_searcher")._test
    for name, count in pairs { folder = "2", empty = "0" } do
      local texts = draw_texts(function()
        fuzzy.draw_file_metadata(style.code_font, {
          kind = "folder", is_folder = true, abs_path = root .. PATHSEP .. name,
        }, 0, 0, 3000)
      end)
      test.ok(contains(texts, count), "expected the same folder count in Fuzzy Searcher")
    end
  end)

  test.it("uses the shared file metadata presentation", function(context)
    local path = context.root .. PATHSEP .. "file.bin"
    write_file(path, string.rep("x", 23 * 1024))
    context.view:refresh(false, false)
    local line = find_line(context.view, "file.bin")
    local info = system.get_file_info(path)
    local expected = draw_texts(function()
      metadata.draw(context.view:get_font(), metadata.parts {
        type = "file", size = info.size, modified = info.modified,
      }, 0, 0, 3000)
    end)
    test.same(hint_texts(context.view, line), expected)
  end)

  test.it("keeps custom hints inside the space after Buffer text", function(context)
    local view = context.view
    write_file(context.root .. PATHSEP .. "file.txt", "text")
    view:refresh(false, false)
    local line = find_line(view, "file.txt")
    view.position.x, view.position.y = 0, 0
    view.size.x, view.size.y = 1600, 600
    local bounds
    view.get_line_hint = function()
      return { draw = function(x, y, width) bounds = { x = x, width = width } end }
    end
    view:draw_line_hint(line, 0, 0)
    test.not_nil(bounds)
    test.ok(bounds.x >= view:get_line_hint_text_end_x(line, 0))
    test.ok(bounds.x + bounds.width <= view.size.x - style.padding.x)
  end)
end)
