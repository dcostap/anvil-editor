local core = require "core"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local markdown = require "core.markdown"
local markdown_model = require "core.markdown.model"
local style = require "core.style"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function with_style_snapshot(fn)
  local snapshot = {}
  for key, value in pairs(style) do snapshot[key] = value end
  local nested = {}
  for _, key in ipairs({ "syntax", "syntax_fonts", "log" }) do
    local values = {}
    for child, value in pairs(style[key] or {}) do values[child] = value end
    nested[key] = values
  end

  local ok, err = xpcall(fn, debug.traceback)
  for key in pairs(style) do style[key] = nil end
  for key, value in pairs(snapshot) do style[key] = value end
  for key, values in pairs(nested) do
    local destination = style[key]
    for child in pairs(destination) do destination[child] = nil end
    for child, value in pairs(values) do destination[child] = value end
  end
  if not ok then error(err, 0) end
end

local function refresh_live_view(view)
  markdown.live_render.refresh_view(view)
  local instance = test.not_nil(markdown_model.peek(view.doc))
  local deadline = system.get_time() + 5
  while instance.status ~= "ready" and system.get_time() < deadline do
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status ~= "ready" then system.sleep(0.001) end
  end
  test.equal(instance.status, "ready", instance.reason)
  linewrapping.complete_async_reconstruction(view)
end

test.describe("Markdown Live Preview light theme", function()
  test.it("uses the active light palette for rendered block backgrounds", function()
    with_style_snapshot(function()
      core.reload_module("colors.default")
      local dark_background = style.markdown_live_code_background
      core.reload_module("colors.light")

      for _, key in ipairs({
        "markdown_live_inline_code_bg",
        "markdown_live_code_background",
        "markdown_live_callout_background",
        "markdown_live_frontmatter_background",
        "markdown_live_math_background",
        "markdown_live_image_background",
        "markdown_live_attachment_bg",
        "markdown_live_embed_background",
      }) do
        test.equal(style[key], style.background2, key .. " did not follow the light palette")
        test.ok(style[key] ~= dark_background, key .. " retained the dark palette")
      end
      test.equal(style.markdown_live_embed_text, style.text)
      test.equal(style.markdown_live_table_background, style.background)
      test.equal(style.markdown_live_table_header, style.text)
      test.equal(style.markdown_live_table_cell, style.text)
      test.equal(style.markdown_live_table_separator, style.divider)
    end)
  end)

  test.it("does not retain dark-only chrome and project-path colors", function()
    with_style_snapshot(function()
      core.reload_module("colors.default")
      local dark_titlebar_tab_active = style.titlebar_tab_active
      local dark_project_path_external = style.project_path_external
      local dark_project_path_vendored = style.project_path_vendored
      local dark_project_path_excluded = style.project_path_excluded

      core.reload_module("colors.light")

      test.ok(style.titlebar ~= style.background)
      test.equal(style.titlebar_tab_active, style.background)
      test.ok(style.titlebar_tab_active ~= dark_titlebar_tab_active)
      test.equal(style.project_path_external, style.accent)
      test.equal(style.project_path_external_dim, style.dim)
      test.equal(style.project_path_vendored, style.syntax.metadata)
      test.equal(style.project_path_vendored_dim, style.dim)
      test.equal(style.project_path_excluded, style.error)
      test.equal(style.project_path_missing, style.warn)
      test.equal(style.project_path_separator, style.dim)
      test.ok(style.project_path_external ~= dark_project_path_external)
      test.ok(style.project_path_vendored ~= dark_project_path_vendored)
      test.ok(style.project_path_excluded ~= dark_project_path_excluded)
    end)
  end)

  test.it("refreshes cached rendered text immediately after a theme change", function()
    with_style_snapshot(function()
      core.reload_module("colors.default")
      local doc = Doc(nil, nil, true)
      doc:insert(1, 1, "Heading")
      local view = DocView(doc)
      local calls = 0
      view:add_line_render_provider("theme-aware", {
        render_line = function(_, _, _, context)
          calls = calls + 1
          return { fragments = { { text = context.source_text, color = style.text } } }
        end,
      })

      local dark_color = view:get_line_render(1).fragments[1].color
      core.reload_module("colors.light")
      local light_color = view:get_line_render(1).fragments[1].color

      test.equal(calls, 2)
      test.equal(light_color, style.text)
      test.ok(light_color ~= dark_color)
    end)
  end)

  test.it("refreshes cached table text colors immediately after a theme change", function()
    local old_live_enabled = config.markdown_live_editor
    local view, doc
    config.markdown_live_editor = true
    local ok, err = pcall(function()
      core.reload_module("colors.default")
      doc = Doc("table-theme.md", "table-theme.md", true)
      doc:insert(1, 1, "| Name | Value |\n| --- | --- |\n| one | two |\n\nplain")
      doc:clear_undo_redo()
      doc:set_selection(5, 1)
      view = DocView(doc)
      view.position.x, view.position.y = 0, 0
      view.size.x, view.size.y = 500, 200
      view:set_wrapping_enabled(false)
      refresh_live_view(view)

      local function table_cell_color(line, column)
        for _, fragment in ipairs(view:iter_line_render_fragments(
          test.not_nil(view:get_line_render(line))
        )) do
          if fragment.table_cell and fragment.table_column == column then
            return fragment.color
          end
        end
      end

      local dark_header = test.not_nil(table_cell_color(1, 1))
      local dark_cell = test.not_nil(table_cell_color(3, 1))
      core.reload_module("colors.light")
      local light_header = test.not_nil(table_cell_color(1, 1))
      local light_cell = test.not_nil(table_cell_color(3, 1))
      test.equal(light_header, style.markdown_live_table_header)
      test.equal(light_cell, style.markdown_live_table_cell)
      test.ok(light_header ~= dark_header)
      test.ok(light_cell ~= dark_cell)
    end)
    config.markdown_live_editor = old_live_enabled
    core.reload_module("colors.default")
    if view then markdown.live_render.release(view, "test") end
    if doc then markdown_model.close(doc, "test") end
    if not ok then error(err, 0) end
  end)
end)
