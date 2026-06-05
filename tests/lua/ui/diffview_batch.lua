local test = require "core.test"
local diffview = require "plugins.diffview"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 1)
  while not predicate() do
    if system.get_time() >= deadline then
      test.fail(message or "timed out waiting for condition", 2)
    end
    coroutine.yield(0.01)
  end
end

local function text(doc)
  return table.concat(doc.lines)
end

test.describe("DiffView batch behavior", function()
  test.after_each(function(context)
    for _, view in ipairs(context.diffviews or {}) do
      view.doc_view_a.doc:on_close()
      view.doc_view_b.doc:on_close()
    end
  end)

  test.it("syncing an inserted hunk into the other side emits one document change", function(context)
    local view = track(context, "diffviews", diffview.string_to_string(
      "aa\ninserted\nbb",
      "aa\nbb",
      "left",
      "right",
      true
    ))
    wait_until(function() return view.updater_idx == nil end, 1, "expected diff computation to finish")

    local target = view.doc_view_b.doc
    local changes = 0
    function target:on_text_change()
      changes = changes + 1
    end

    view:sync(2, 1, true)

    test.equal(text(target), "aa\ninserted\nbb\n")
    test.equal(changes, 1)
  end)
end)
