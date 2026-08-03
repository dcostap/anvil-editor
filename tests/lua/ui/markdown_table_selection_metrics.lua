-- Regression: selection-only line-render invalidations must not rebuild the
-- whole visual metric cache.
--
-- Clicking/selecting in a wrapped Markdown live-preview document used to
-- freeze the editor for seconds. The selection listener invalidated the line
-- render for the touched rows; `update_breaks` unconditionally bumped the
-- wrap layout generation even when the recomputed breaks were identical, so
-- the next visual metric lookup saw a stale signature and performed a
-- full-document metric rebuild. For a table-heavy document whose per-row
-- metrics re-scan table source, that rebuild cost ~2.2s per mouse release
-- (recorded: 17.5s for 8 clicks in a 577-line report).
--
-- This test drives the exact mechanism deterministically with a fixed
-- line-render provider (no semantic model, no font drift): a selection-style
-- invalidation must leave the wrap generation and the metric cache intact,
-- while a real text edit must still refresh them.
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local linewrapping = require "core.linewrapping"
local test = require "core.test"

local PROVIDER_ID = "test-fixed-render"

-- A deterministic stand-in for the Markdown Live Preview render provider.
-- `selection_preserves_metrics` mirrors table rows whose heights do not
-- depend on the selection.
local provider = {
  render_line = function(_, _view, line)
    local text = "0123456789abcdefghijklmnopqrstuvwxyz " .. line
    return {
      source_text = text,
      fragments = {
        { source_col1 = 1, source_col2 = #text + 1, text = text },
      },
      selection_preserves_metrics = true,
    }
  end,
}

-- Minimal visual metric provider so DocView builds its metric cache; the
-- default row height is used for every row.
local metric_provider = {
  generation = function() return "fixed" end,
}

local function make_view(text, filename)
  local doc = Doc(filename or "plain.md", filename or "plain.md", true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  local view = DocView(doc)
  view.position.x, view.position.y = 0, 0
  view.size.x, view.size.y = 200, 600
  view:set_wrapping_enabled(true)
  view:update_wrap_cache()
  view:add_line_render_provider(PROVIDER_ID, provider)
  view:add_visual_metric_provider(PROVIDER_ID, metric_provider)
  return view, doc
end

test.describe("Wrapped selection preserves visual metrics", function()
  test.before_each(function(context)
    context.mode = config.plugins.linewrapping.mode
    context.tokens = config.plugins.linewrapping.require_tokenization
    config.plugins.linewrapping.mode = "word"
    config.plugins.linewrapping.require_tokenization = false
  end)

  test.after_each(function(context)
    config.plugins.linewrapping.mode = context.mode
    config.plugins.linewrapping.require_tokenization = context.tokens
  end)

  test.test("selection-only invalidation keeps the wrap generation and metric cache", function()
    local view, doc = make_view(
      table.concat({
        "alpha beta gamma delta epsilon zeta eta theta",
        "iota kappa lambda mu nu xi omicron pi rho",
        "sigma tau upsilon phi chi psi omega alpha beta",
        "gamma delta epsilon zeta eta theta iota kappa",
        "lambda mu nu xi omicron pi rho sigma tau",
      }, "\n"),
      "wrapped.md"
    )
    view:get_visual_row_metric_cache()
    local cache_before = view.__visual_metric_cache
    local gen_before = view.__wrap_layout_generation
    test.ok(cache_before ~= nil, "metric cache exists after warmup")

    -- This is what a click does: the Markdown Live Preview selection
    -- listener invalidates the line render for the touched rows. The wrapped
    -- layout itself does not change.
    view:invalidate_line_render(PROVIDER_ID, 2, 2)
    test.equal(view.__wrap_layout_generation, gen_before,
      "selection-only invalidation must not bump the wrap layout generation")
    test.equal(view:get_visual_row_metric_cache(), cache_before,
      "selection-only invalidation must not rebuild the visual metric cache")
  end)

  test.test("a real text edit still refreshes the visual metric cache", function()
    local view, doc = make_view(
      "alpha beta gamma delta epsilon zeta eta theta\n"
      .. "iota kappa lambda mu nu xi omicron pi rho\n",
      "edit.md"
    )
    view:get_visual_row_metric_cache()
    doc:insert(2, 4, "a much longer stretch of text that changes wrapping")
    local cache = view:get_visual_row_metric_cache()
    test.equal(cache.text_revision, doc.text_revision,
      "after a text edit the metric cache must be in sync with the document")
    test.equal(cache.wrap_layout_generation, view.__wrap_layout_generation,
      "after a text edit the metric cache must match the wrap layout generation")
  end)
end)
