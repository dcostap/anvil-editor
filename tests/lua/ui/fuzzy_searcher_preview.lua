local core = require "core"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function temp_file_path(name)
  local base = system.absolute_path(".")
  return base .. PATHSEP .. name
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text)
  fp:close()
end

local function remove_file(path)
  pcall(os.remove, path)
end

local function visible_text_right(view)
  local _, _, scroll_w = view.v_scrollbar:get_track_rect()
  return view.scroll.x + math.max(0, view.size.x - scroll_w)
end

local function range_x(view, line, col1, col2)
  local gw = view:get_gutter_width()
  local x1 = view:get_col_x_offset(line, col1) + gw
  local x2 = view:get_col_x_offset(line, col2) + gw
  return math.min(x1, x2), math.max(x1, x2)
end

test.describe("Fuzzy Searcher preview", function()
  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    for _, path in ipairs(context.files or {}) do
      remove_file(path)
    end
  end)

  test.it("horizontally reveals off-screen content matches in the DocView preview", function(context)
    local prefix = string.rep("x", 120)
    local query = "NEEDLE"
    local path = temp_file_path("fuzzy-preview-long-line-test.txt")
    context.files = { path }
    write_file(path, prefix .. query .. "\n")

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    picker:layout()
    local col1 = #prefix + 1
    local col2 = col1 + #query
    picker.results = {
      {
        kind = "grep",
        file = path,
        line = 1,
        grep_query = query,
        exact = true,
        content_spans = { { col1, col2 - 1 } },
        text = prefix .. query,
      }
    }
    picker.selected = 1

    local preview = picker:update_preview_view()

    test.ok(preview and preview.doc, "expected a DocView preview")
    local x1, x2 = range_x(preview, 1, col1, col2)
    test.ok(preview.scroll.x > 0, "expected preview to scroll horizontally to the content match")
    test.ok(x1 >= preview.scroll.x, "expected preview match start to be visible")
    test.ok(x2 <= visible_text_right(preview) + 1, "expected preview match end to be visible")
  end)
end)
