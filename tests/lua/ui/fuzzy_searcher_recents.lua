local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function temp_file_path(name)
  return system.absolute_path(".") .. PATHSEP .. name
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function remove_file(path)
  pcall(os.remove, path)
end

local function basename(path)
  return path:match("[^/\\]+$") or path
end

test.describe("Fuzzy Searcher recent files", function()
  test.before_each(function(context)
    context.original_visited_files = core.visited_files
    context.files = {}
  end)

  test.after_each(function(context)
    core.visited_files = context.original_visited_files
    for _, path in ipairs(context.files or {}) do remove_file(path) end
  end)

  local function make_file(context, name)
    local path = temp_file_path(name)
    write_file(path)
    context.files[#context.files+1] = path
    return path
  end

  test.it("matches path separators interchangeably in file search fallback rows", function(context)
    local path = make_file(context, "fuzzy-separator-main.lua")
    local slash_path = path:gsub("\\", "/")

    local rows = fuzzy_searcher._test.file_search_rows("\\fuzzy-separator-main", { slash_path }, nil, 10)

    test.equal(rows[1].file, slash_path)
  end)

  test.it("skips the current file only from recents and keeps matching recents above general matches", function(context)
    local current = make_file(context, "fuzzy-current-needle.lua")
    local recent_newer = make_file(context, "fuzzy-recent-newer-needle.lua")
    local recent_older = make_file(context, "fuzzy-recent-older-needle.lua")
    local general = make_file(context, "fuzzy-general-needle.lua")

    core.visited_files = {
      { path = current, last_viewed = 100, last_edited = 90 },
      { path = recent_newer, last_viewed = 80, last_edited = 70 },
      { path = recent_older, last_viewed = 60, last_edited = 50 },
    }

    local rows = fuzzy_searcher._test.file_search_rows("needle", {
      current,
      recent_older,
      general,
      recent_newer,
    }, current, 20)

    test.equal(basename(rows[1].file), basename(recent_newer))
    test.ok(rows[1].recent, "expected first row to be a recent file")
    test.equal(rows[1].last_viewed, 80)
    test.equal(rows[1].last_edited, 70)
    test.equal(basename(rows[2].file), basename(recent_older))
    test.ok(rows[2].recent, "expected second row to be a recent file")
    test.ok(rows[3] and rows[3].separator, "expected separator between recent and general sections")

    local seen = {}
    for _, row in ipairs(rows) do
      if row.file then
        local name = basename(row.file)
        if name == basename(current) then
          test.not_ok(row.recent, "current file should not be shown as a recent file")
        end
        test.not_ok(seen[name], "duplicate file result: " .. row.file)
        seen[name] = true
      end
    end
    test.ok(seen[basename(current)], "expected current file to remain in the general results")
    test.ok(seen[basename(general)], "expected general match below recents")
  end)

  test.it("formats recent file ages with compact minute, hour, day, and year units", function()
    local format_age = fuzzy_searcher._test.format_recent_file_age
    local now = 10 * 365 * 24 * 60 * 60

    test.equal(format_age(now - 3 * 60, now), "3 min")
    test.equal(format_age(now - 22 * 60, now), "22 min")
    test.equal(format_age(now - 60 * 60, now), "1 h")
    test.equal(format_age(now - 2 * 60 * 60, now), "2 h")
    test.equal(format_age(now - 24 * 60 * 60, now), "1 d")
    test.equal(format_age(now - 88 * 24 * 60 * 60, now), "88 d")
    test.equal(format_age(now - 365 * 24 * 60 * 60, now), "1 yr")
    test.equal(format_age(now - 2 * 365 * 24 * 60 * 60, now), "2 yr")
  end)

  test.it("provides scalable pencil and eye SVGs for Recent File metadata", function()
    local icons = require "core.recent_file_icons"
    for _, name in ipairs({ "pencil", "eye" }) do
      local icon, err = icons.get(name, 14)
      test.not_nil(icon, err)
      test.same({ icon:get_size() }, { 14, 14 })
    end
  end)

  test.it("uses a smaller font and tight right-aligned cells for Recent File ages", function()
    local function make_font(size)
      local font = {}
      function font:get_height() return size end
      function font:get_size() return size end
      function font:get_width(text) return #text * size end
      function font:copy(new_size) return make_font(new_size) end
      return font
    end

    local font = make_font(15)
    local age_x = {}
    local age_fonts = {}
    local old_draw_text = renderer.draw_text
    local old_draw_canvas = renderer.draw_canvas
    renderer.draw_text = function(draw_font, text, x)
      if text == "6 min" or text == "19 d" then
        age_x[text] = x
        age_fonts[text] = draw_font
      end
      return x + draw_font:get_width(text)
    end
    renderer.draw_canvas = function() end
    local now = os.time()
    local ok, err = pcall(function()
      fuzzy_searcher._test.draw_recent_file_metadata(font, { last_edited = now - 6 * 60 }, 0, 0, 100)
      fuzzy_searcher._test.draw_recent_file_metadata(font, { last_edited = now - 19 * 24 * 60 * 60 }, 0, 0, 100)
    end)
    renderer.draw_text = old_draw_text
    renderer.draw_canvas = old_draw_canvas
    if not ok then error(err, 0) end

    test.ok(age_fonts["6 min"]:get_size() < font:get_size())
    test.ok(age_fonts["19 d"]:get_size() < font:get_size())
    test.equal(
      age_x["6 min"] + age_fonts["6 min"]:get_width("6 min"),
      age_x["19 d"] + age_fonts["19 d"]:get_width("19 d")
    )
  end)
end)
