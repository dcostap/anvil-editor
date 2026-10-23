local core = require "core"
local command = require "core.command"
local style = require "core.style"
local test = require "core.test"

-- Seam: prompt navigation commands and the completed input text.
test.describe("Global Prompt Bar navigation", function()
  local function with_prompt(options, fn)
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_view = core.active_view
    options.suggest = function() return { "one", "two", "three" } end
    local ok, err = pcall(function()
      bar:enter("Choices", options)
      fn(bar)
    end)
    bar:exit(true)
    if previous_view then core.set_active_view(previous_view) end
    if not ok then error(err, 0) end
  end

  test.it("moves through visible suggestions in top-to-bottom order", function()
    with_prompt({}, function(bar)
      test.ok(command.perform("core:select_next_prompt_item"))
      test.equal(bar:get_text(), "two")
      test.ok(command.perform("core:select_previous_prompt_item"))
      test.equal(bar:get_text(), "one")
      test.ok(command.perform("core:select_previous_prompt_item"))
      test.equal(bar:get_text(), "three")
      test.ok(command.perform("core:select_next_prompt_item"))
      test.equal(bar:get_text(), "one")
    end)
  end)

  test.it("recalls older hidden history and returns to the typed text", function()
    with_prompt({ show_suggestions = false, text = "draft" }, function(bar)
      test.ok(command.perform("core:select_previous_prompt_item"))
      test.equal(bar:get_text(), "one")
      test.ok(command.perform("core:select_previous_prompt_item"))
      test.equal(bar:get_text(), "two")
      test.ok(command.perform("core:select_next_prompt_item"))
      test.equal(bar:get_text(), "one")
      test.ok(command.perform("core:select_next_prompt_item"))
      test.equal(bar:get_text(), "draft")
    end)
  end)
end)

test.describe("Global Prompt Bar attention overlay", function()
  test.it("can keep the editor clear while previewing choices", function()
    local bar = core.global_prompt_bar
    local root = core.root_panel
    bar:exit(true)
    local old_overlay = root.app_overlay
    root.app_overlay = nil
    bar:enter("Font Category", {overlay = false, suggest = function() return {"Prose"} end})
    test.equal(nil, root.app_overlay)
    bar:update()
    test.equal(nil, root.app_overlay)
    bar:exit(false)
    root:update_app_overlay(system.get_time() + 1)
    test.equal(nil, root.app_overlay)
    bar:enter("Ordinary Prompt", {suggest = function() return {"one"} end})
    test.equal(root.app_overlay.owner, bar)
    bar:exit(true)
    root.app_overlay = old_overlay
  end)
end)

test.describe("Global Prompt Bar pointer interception", function()
  test.it("routes pointer movement when no View owns focus", function()
    local active = core.active_view
    core.active_view = nil
    local ok, err = pcall(core.root_panel.on_mouse_moved, core.root_panel, 0, 0, 0, 0)
    core.active_view = active
    test.ok(ok, err)
  end)

end)

test.describe("Global Prompt Bar outside clicks", function()
  test.it("closes on a click on the overlay beside the editor UI", function()
    -- A hosted Window extends the overlay over its Sidebar, left of the Root Panel.
    local bar, root = core.global_prompt_bar, core.root_panel
    bar:exit(true)
    local previous_active = core.active_view
    bar:enter("Outside Click", { suggest = function() return { "one" } end })
    test.equal(core.active_view, bar)
    root:on_mouse_pressed("left", root.position.x - 5, root.position.y + 20, 1)
    root:on_mouse_released("left", root.position.x - 5, root.position.y + 20)
    bar:update()
    test.ok(core.active_view ~= bar, "the prompt kept focus after a click on the overlay")
    bar:exit(true)
    if previous_active and core.active_view ~= previous_active then core.set_active_view(previous_active) end
  end)
end)

test.describe("Global Prompt Bar suggestion geometry", function()
  test.it("lets the suggestion list reach the input", function()
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_active = core.active_view
    local previous_x, previous_y = bar.position.x, bar.position.y
    local previous_width, previous_input_height = bar.size.x, bar.size.y
    local previous_height = bar.suggestions_height

    bar:enter("Suggestions", { suggest = function() return { "one" } end })
    bar.position.x, bar.position.y = 0, 100
    bar.size.x, bar.size.y = 300, 20
    bar.suggestions_height = 20
    bar.mouse_position.x = 10
    bar.mouse_position.y = bar.position.y + bar.size.y + 0.5

    test.ok(bar:is_mouse_on_suggestions())

    bar:exit(true)
    bar.position.x, bar.position.y = previous_x, previous_y
    bar.size.x, bar.size.y = previous_width, previous_input_height
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

-- Seam: core:paste and typing into the Global Prompt Bar, then its caret's screen position.
test.describe("Global Prompt Bar long and multiline text", function()
  local function with_prompt(fn)
    local bar = core.global_prompt_bar
    bar:exit(true)
    local previous_view = core.active_view
    local clipboard = system.get_clipboard()
    local ok, err = pcall(function()
      bar:enter("Command", { show_suggestions = false })
      fn(bar)
    end)
    bar:exit(true)
    system.set_clipboard(clipboard or "")
    if previous_view then core.set_active_view(previous_view) end
    if not ok then error(err, 0) end
  end

  test.it("pastes several lines as one line with a space between them", function()
    with_prompt(function(bar)
      system.set_clipboard("SELECT a,\n       b\r\nFROM t\n")
      test.ok(command.perform("core:paste"))
      test.equal(bar:get_text(), "SELECT a, b FROM t")
    end)
  end)

  test.it("keeps the caret inside the bar at the end of long text", function()
    with_prompt(function(bar)
      bar:on_text_input(string.rep("word ", 400))
      for _ = 1, 3 do bar:update(); coroutine.yield() end
      local x = bar:get_line_screen_position(1, #bar:get_text() + 1)
      test.ok(x > bar.position.x + bar:get_gutter_width() and x < bar.position.x + bar.size.x,
        string.format("caret x %.1f is outside the bar from %.1f to %.1f", x,
          bar.position.x + bar:get_gutter_width(), bar.position.x + bar.size.x))
    end)
  end)
end)
