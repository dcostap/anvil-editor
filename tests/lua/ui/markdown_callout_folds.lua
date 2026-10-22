local core = require "core"
local Buffer = require "core.buffer"
local Editor = require "core.editor"
local markdown = require "core.markdown"
local model = require "core.markdown.model"
local worker_pool = require "core.worker_pool"
local test = require "core.test"

local function ready(buffer)
  local instance = test.not_nil(model.peek(buffer))
  local deadline = system.get_time() + 10
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == "ready" then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.equal(instance.status, "ready", instance.reason)
end

local function make_view(text)
  local buffer = Buffer(nil, nil, true)
  buffer:set_filename("callout-folds.md", nil)
  buffer:insert(1, 1, text)
  buffer:set_selection(#buffer.lines, 1)
  local view = Editor(buffer)
  view.size.x, view.size.y = 600, 300
  view:set_wrapping_enabled(false)
  markdown.live_render.refresh_view(view)
  ready(buffer)
  return view, buffer
end

local function callout_folds(view)
  local folds = {}
  for _, fold in ipairs(view.fold_regions) do
    if fold.kind == "markdown-callout" then folds[#folds + 1] = fold end
  end
  return folds
end

test.describe("Markdown Callout fold publication", function()
  test.it("keeps folds without reconciling unrelated plain text edits", function()
    local view, buffer = make_view(
      "> [!note]- Folded\n> body\n\nplain\n\nend"
    )
    test.equal(#callout_folds(view), 1)
    test.ok(view:is_line_hidden_by_fold(2))
    -- Reconciliation has no visible effect here. Count its diagnostic instead.
    local reconciled = 0
    local log_quiet = core.log_quiet
    core.log_quiet = function(format, ...)
      if format:find("Markdown Callout folds reconciled", 1, true) then
        reconciled = reconciled + 1
      end
      return log_quiet(format, ...)
    end
    local ok, err = pcall(function()
      buffer:insert(4, 6, " text")
      ready(buffer)
    end)
    core.log_quiet = log_quiet
    if not ok then error(err, 0) end
    test.equal(#callout_folds(view), 1)
    test.ok(view:is_line_hidden_by_fold(2))
    test.equal(reconciled, 0, "plain text must not reconcile Callout folds")
  end)

  test.it("adds and removes folds when quote and Callout markers change", function()
    local view, buffer = make_view("plain\n\nend")
    test.equal(#callout_folds(view), 0)
    buffer:insert(1, 1, "> [!tip]- Title\n> body\n\n")
    ready(buffer)
    test.equal(#callout_folds(view), 1)
    test.ok(view:is_line_hidden_by_fold(2))

    buffer:remove(1, 3, 1, 11)
    ready(buffer)
    test.equal(#callout_folds(view), 0)
    buffer:insert(1, 3, "[!tip]- ")
    ready(buffer)
    test.equal(#callout_folds(view), 1)
    test.ok(view:is_line_hidden_by_fold(2))

    buffer:remove(1, 1, 4, 1)
    ready(buffer)
    test.equal(#callout_folds(view), 0)
    test.equal(buffer.lines[1], "plain\n")
  end)

  test.it("keeps a user-collapsed fold after edits above and inside its body", function()
    local view, buffer = make_view("plain\n\n> [!tip]+ Title\n> body\n\nend")
    local fold = test.not_nil(callout_folds(view)[1])
    test.ok(view:collapse_fold_region(fold, "test"))
    buffer:insert(1, 1, "above\n")
    ready(buffer)
    test.ok(view:is_line_hidden_by_fold(5))
    buffer:insert(5, 4, "new ")
    ready(buffer)
    test.equal(#callout_folds(view), 1)
    test.ok(view:is_line_hidden_by_fold(5))
  end)

  test.it("adds folds when a fence edit exposes Callout source", function()
    local view, buffer = make_view("```\n> [!tip]- Title\n> body\n```\n\nend")
    test.equal(#callout_folds(view), 0)
    buffer:remove(1, 1, 2, 1)
    ready(buffer)
    test.equal(#callout_folds(view), 1)
    test.ok(view:is_line_hidden_by_fold(2))
  end)
end)
