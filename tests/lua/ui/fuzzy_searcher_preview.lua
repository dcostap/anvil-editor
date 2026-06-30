local core = require "core"
local config = require "core.config"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local DocView = require "core.docview"
local sidepanel = require "core.sidepanel"

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

local function close_file_views_and_docs(path)
  for _, view in ipairs(core.root_panel.root_node:get_children()) do
    local view_path = view.path or (view.doc and view.doc.abs_filename)
    if view_path == path then
      local node = core.root_panel.root_node:get_node_for_view(view)
      if node then
        if view:extends(DocView) and view.doc:is_dirty() then view.doc:clean() end
        node:remove_view(core.root_panel.root_node, view)
      end
    end
  end
  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if doc.abs_filename == path then
      if doc:is_dirty() then doc:clean() end
      table.remove(core.docs, i)
      doc:on_close()
    end
  end
end

local function selection_state(view)
  return view:get_selection_state().selections
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
  test.before_each(function(context)
    context.linewrapping_enable_by_default = config.plugins.linewrapping.enable_by_default
  end)

  test.after_each(function(context)
    config.plugins.linewrapping.enable_by_default = context.linewrapping_enable_by_default
    if core.fuzzy_searcher_active_view then
      core.fuzzy_searcher_active_view:close()
    end
    for _, path in ipairs(context.files or {}) do
      close_file_views_and_docs(path)
      remove_file(path)
    end
  end)

  test.it("selects a single contiguous content match when accepting a grep result", function(context)
    local path = temp_file_path("fuzzy-confirm-select-match-test.txt")
    context.files = { path }
    write_file(path, "alpha NEEDLE omega\n")

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    picker.results = {
      {
        kind = "grep",
        file = path,
        line = 1,
        col = 7,
        grep_query = "NEEDLE",
        exact = true,
        content_selection_span = { 7, 12 },
        content_match_start = 7,
        text = "alpha NEEDLE omega",
      }
    }
    picker.selected = 1

    picker:confirm(false)

    local view = core.active_view
    test.ok(view and view.doc and view.doc.abs_filename == path, "expected accepted grep result to open its file")
    test.same(selection_state(view), { 1, 7, 1, 13 })
  end)

  test.it("focuses the Side Editor when accepting a file for the Side Panel", function(context)
    local path = temp_file_path("fuzzy-confirm-side-focus-test.txt")
    context.files = { path }
    write_file(path, "side target\n")

    fuzzy_searcher.open("")
    local picker = core.fuzzy_searcher_active_view
    picker.results = {
      {
        kind = "file",
        file = path,
        text = path,
      }
    }
    picker.selected = 1

    picker:confirm(true)

    local view = core.active_view
    test.ok(view and view.doc and view.doc.abs_filename == path, "expected side-accepted file to become active")
    test.ok(sidepanel.is_side_editor(view), "expected accepted file to be focused as a Side Editor")
  end)

  test.it("moves to the leftmost fuzzy chunk without selecting separated chunks", function(context)
    local path = temp_file_path("fuzzy-confirm-separated-chunks-test.txt")
    context.files = { path }
    write_file(path, "alpha beta\n")

    fuzzy_searcher.open("#")
    local picker = core.fuzzy_searcher_active_view
    picker.results = {
      {
        kind = "grep",
        file = path,
        line = 1,
        col = 7,
        grep_query = "ab",
        exact = false,
        content_spans = { { 1, 1 }, { 7, 7 } },
        content_match_start = 1,
        text = "alpha beta",
      }
    }
    picker.selected = 1

    picker:confirm(false)

    local view = core.active_view
    test.ok(view and view.doc and view.doc.abs_filename == path, "expected accepted grep result to open its file")
    test.same(selection_state(view), { 1, 1, 1, 1 })
  end)

  test.it("horizontally reveals off-screen content matches in the DocView preview", function(context)
    config.plugins.linewrapping.enable_by_default = false

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
