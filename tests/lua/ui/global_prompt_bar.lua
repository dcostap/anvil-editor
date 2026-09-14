local core = require "core"
local test = require "core.test"

test.describe("Global Prompt Bar pointer interception", function()
  test.it("routes pointer movement when no View owns focus", function()
    local active = core.active_view
    core.active_view = nil
    local ok, err = pcall(core.root_panel.on_mouse_moved, core.root_panel, 0, 0, 0, 0)
    core.active_view = active
    test.ok(ok, err)
  end)

end)

test.describe("Global Prompt Bar focus restoration", function()
  test.it("closes safely when no previous View exists", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_view = core.active_view
    local previous_last_view = core.last_active_view
    if core.active_view then core.clear_active_view(core.active_view) end
    core.last_active_view = nil
    bar:enter("No Source View", { show_suggestions = false })

    local ok, err = pcall(bar.exit, bar, false)
    if not ok then
      core.last_active_view = previous_view
      pcall(bar.exit, bar, true)
    end
    if previous_view then core.set_active_view(previous_view) end
    core.last_active_view = previous_last_view

    test.ok(ok, err)
    test.not_equal(core.active_view, bar)
  end)
end)

test.describe("Global Prompt Bar typeahead", function()
  test.it("completes a suggestion without matching letter case", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_view = core.active_view
    local ok, err = pcall(function()
      bar:enter("Open File", {
        suggest = function()
          return { "Coding-Conventions.md" }
        end,
      })
      bar:on_text_input("coding")
      bar:update()

      test.equal(bar:get_text(), "Coding-Conventions.md")
      local line1, col1, line2, col2 = bar.buffer:get_selection()
      test.equal(line1, 1)
      test.equal(col1, #"coding" + 1)
      test.equal(line2, 1)
      test.equal(col2, #"Coding-Conventions.md" + 1)
    end)
    bar:exit(true)
    if previous_view then core.set_active_view(previous_view) end
    if not ok then error(err, 0) end
  end)
end)
