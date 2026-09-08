local test = require "core.test"
local metadata = require "plugins.file_metadata"
local core = require "core"
local config = require "core.config"
local style = require "core.style"

local function capture(font, parts, columns)
  local saved = renderer.draw_text
  local result = {}
  renderer.draw_text = function(text_font, text, x, y, color)
    if text:find("%S") then result[#result + 1] = { text = text, x = x, y = y, color = color } end
    return x + text_font:get_width(text)
  end
  local ok, width = pcall(metadata.draw, font, parts, 0, 0, 800, columns)
  renderer.draw_text = saved
  if not ok then error(width, 0) end
  return result, width
end

test.describe("Shared file metadata", function()
  test.it("shows folder contents instead of a file size", function()
    local parts = metadata.parts({ type = "dir", size = 9999, count = 7 })
    local values = {}
    for _, part in ipairs(parts) do values[part.id] = part.text end
    test.equal(values.size, "7")
    test.is_nil(values.ignored)
  end)

  test.it("marks ignored entries without adding a label to ordinary files", function()
    local ignored = metadata.parts({ type = "file", git = { kind = "ignored" } })
    local ordinary = metadata.parts({ type = "file" })
    local found = false
    for _, part in ipairs(ignored) do
      if part.id == "ignored" then test.equal(part.text, "ignored"); found = true end
    end
    test.ok(found)
    for _, part in ipairs(ordinary) do test.ok(part.id ~= "ignored") end
  end)
end)

test.describe("File metadata reuse", function()
  test.before_each(function(context)
    context.visited = core.visited_files
    context.max_visited = config.max_visited_files
    config.max_visited_files = 100
    core.visited_files = {
      { path = EXEDIR .. PATHSEP .. "metadata-test.txt", last_edited = 100, last_viewed = 200 },
    }
  end)

  test.after_each(function(context)
    core.visited_files = context.visited
    config.max_visited_files = context.max_visited
  end)

  test.it("returns current timestamps after visits, edits, pruning, and history replacement", function()
    local path = core.visited_files[1].path
    local edited, viewed = metadata.recent_times(path)
    test.equal(edited, 100)
    test.equal(viewed, 200)
    core.set_recent_file_edited(path, 300)
    edited, viewed = metadata.recent_times(path)
    test.equal(edited, 300)
    test.equal(viewed, 200)
    core.set_visited(path, 400)
    edited, viewed = metadata.recent_times(path)
    test.equal(edited, 300)
    test.equal(viewed, 400)
    core.visited_files = { { path = path, last_edited = 500, last_viewed = 600 } }
    edited, viewed = metadata.recent_times(path)
    test.equal(edited, 500)
    test.equal(viewed, 600)
    config.max_visited_files = 0
    core.prune_visited_files()
    edited, viewed = metadata.recent_times(path)
    test.is_nil(edited)
    test.is_nil(viewed)
  end)

  test.it("matches equivalent paths and returns no timestamps for missing files", function()
    local path = core.visited_files[1].path
    local equivalent = EXEDIR .. PATHSEP .. "." .. PATHSEP .. "metadata-test.txt"
    if PATHSEP == "\\" then equivalent = equivalent:upper():gsub("\\", "/") end
    test.equal(metadata.recent_times(equivalent), 100)
    test.is_nil(metadata.recent_times(path .. ".missing"))
  end)

  test.it("keeps text aligned after metadata and font sizes change", function()
    local font = style.code_font:copy(style.code_font:get_size())
    local parts = {
      { id = "size", text = "1K", sample = "999M" },
      { id = "age", text = "2m", sample = "99yr" },
    }
    capture(font, parts)
    parts[1].text, parts[2].text = "123456M", "100yr"
    font:set_size(font:get_size() + 4)
    local columns = {}
    metadata.include_columns(columns, font, parts)
    local warm, warm_width = capture(font, parts, columns)
    local fresh_font = font:copy(font:get_size())
    local fresh_columns = {}
    metadata.include_columns(fresh_columns, fresh_font, parts)
    local fresh, fresh_width = capture(fresh_font, parts, fresh_columns)
    test.equal(#warm, 2)
    test.same(warm, fresh)
    test.equal(warm_width, fresh_width)
    test.ok(warm[2].x > warm[1].x)
    test.equal(warm[2].x + metadata.font(font):get_width(parts[2].text), 800)
  end)
end)
