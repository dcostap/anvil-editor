-- Run with anvil:lua-ui --test-args ui/markdown_layout_oracle.lua through Meson.
-- A retained view must lay out every line the same way as a fresh view of
-- the same text once parsing and wrapping finish. Each seed builds a random
-- document, applies random edits, view resizes and scrolls, then compares the
-- complete layout with a fresh view.
--
-- Set ANVIL_LAYOUT_ORACLE_SEEDS=first-last to sweep a wider range of seeds.
local core = require "core"
local config = require "core.config"
local test = require "core.test"
local oracle = dofile("tests/fixtures/markdown/layout_oracle.lua")

require "core.commands.text"

-- Each sequence diverged from a fresh view before retained layout checked
-- its render plans: stale table rows, heading heights after several-caret
-- deletions, and list, quote and paragraph wraps after undo.
local REGRESSION_SEEDS = { 5, 12, 16, 27, 36, 54, 59, 72, 78, 100, 104 }

local function seeds()
  local first, last = (os.getenv("ANVIL_LAYOUT_ORACLE_SEEDS") or ""):match("^(%d+)%-(%d+)$")
  if not first then return REGRESSION_SEEDS end
  local result = {}
  for seed = tonumber(first), tonumber(last) do result[#result + 1] = seed end
  return result
end

test.describe("Markdown layout oracle", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.live = config.markdown_live_editor
    context.transitions = config.transitions
    context.merge = config.undo_merge_timeout
    context.pane_views_only = config.plugins.centered_editor.pane_views_only
    context.snapshot_active = core.ui_snapshot_active
    context.snapshot_id = core.ui_snapshot_id
    context.clip = core.clip_rect_stack
    config.markdown_live_editor = true
    config.transitions = false
    config.undo_merge_timeout = 0
    config.plugins.centered_editor.pane_views_only = false
    core.clip_rect_stack = { { 0, 0, 1200, 800 } }
  end)

  test.after_each(function(context)
    oracle.close_views(context)
    core.active_view = context.active
    config.markdown_live_editor = context.live
    config.transitions = context.transitions
    config.undo_merge_timeout = context.merge
    config.plugins.centered_editor.pane_views_only = context.pane_views_only
    core.ui_snapshot_active = context.snapshot_active
    core.ui_snapshot_id = context.snapshot_id
    core.clip_rect_stack = context.clip
  end)

  for _, seed in ipairs(seeds()) do
    test.it("matches a fresh view after edit sequence " .. seed, function(context)
      local difference = oracle.run_sequence(context, seed)
      test.ok(difference == nil, difference)
    end)
  end
end)
