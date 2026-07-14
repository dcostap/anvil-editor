local core = require "core"
local Doc = require "core.doc"
local DocView = require "core.docview"
local style = require "core.style"
local test = require "core.test"

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
        "markdown_live_table_background",
      }) do
        test.equal(style[key], style.background2, key .. " did not follow the light palette")
        test.ok(style[key] ~= dark_background, key .. " retained the dark palette")
      end
      test.equal(style.markdown_live_embed_text, style.text)
      test.equal(style.markdown_live_table_cell, style.text)
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
end)
