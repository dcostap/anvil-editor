local core = require "core"
local style = require "core.style"
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

test.describe("Global Prompt Bar suggestion geometry", function()
  test.it("lets the suggestion dropdown reach the prompt bar", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_active = core.active_view
    local previous_x, previous_y = bar.position.x, bar.position.y
    local previous_width = bar.size.x
    local previous_height = bar.suggestions_height

    bar:enter("Suggestions", { suggest = function() return { "one" } end })
    bar.position.x, bar.position.y = 0, 100
    bar.size.x = 300
    bar.suggestions_height = 20
    bar.mouse_position.x = 10
    bar.mouse_position.y = bar.position.y - math.max(1, style.divider_size or 1) / 2

    test.ok(bar:is_mouse_on_suggestions())

    bar:exit(true)
    bar.position.x, bar.position.y = previous_x, previous_y
    bar.size.x = previous_width
    bar.suggestions_height = previous_height
    if previous_active then core.set_active_view(previous_active) end
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
