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

  test.it("matches file names without requiring their diacritics", function(context)
    local path = make_file(context, "fuzzy-éclair.lua")

    local rows = fuzzy_searcher._test.file_search_rows("fuzzy-eclair", { path }, nil, 10)

    test.equal(rows[1].file, path)
  end)

  test.it("classifies diacritic-insensitive path matches like plain paths", function()
    local classify = fuzzy_searcher._test.grep_path_match_class
    local plain = classify("fuzzy-eclair", "folder/fuzzy-eclair.lua")
    local accented = classify("fuzzy-eclair", "folder/fuzzy-éclair.lua")

    test.equal(accented, plain)
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

end)
