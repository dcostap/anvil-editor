local test = require "core.test"
local tab = require "core.tab"
local style = require "core.style"

-- Seam: Terminal Session Tab models and their renderer output.
test.describe("Terminal program icons", function()
  test.it("shows Pi's icon and keeps the status dot without guessing from the title", function()
    local old_canvas, old_dot, old_text = renderer.draw_canvas, renderer.draw_rounded_rect, renderer.draw_text
    local images, dots = {}, {}
    renderer.draw_canvas = function(image) images[#images + 1] = image end
    renderer.draw_rounded_rect = function(_, _, _, _, _, color) dots[#dots + 1] = color end
    renderer.draw_text = function() end
    local ok, err = pcall(function()
      local session = {id="pi-session",title="My task",state="running",busy=1,
        agent_app="pi",agent_state="blocked",agent_kind="permission",agent_message="Allow write?"}
      local item = tab.describe_session(session)
      tab.draw(item, 0, 0, 400, 28 * SCALE, {name_color=style.text})
      test.equal(#images, 1, "Pi's icon is missing")
      test.equal(dots[1], style.warn, "Pi's icon hid the waiting status")
      session.agent_app, session.title = "other", "pi"
      tab.draw(tab.describe_session(session), 0, 0, 400, 28 * SCALE, {name_color=style.text})
      test.equal(#images, 1, "A title selected Pi's icon for another program")
      session.state, session.agent_app = "exited", "pi"
      tab.draw(tab.describe_session(session), 0, 0, 400, 28 * SCALE, {name_color=style.text})
      test.equal(#images, 1, "An ended program kept Pi's icon")
    end)
    renderer.draw_canvas, renderer.draw_rounded_rect, renderer.draw_text = old_canvas, old_dot, old_text
    if not ok then error(err) end
  end)
end)

test.describe("Pi model badges", function()
  test.it("matches GPT, Claude and Fable names without case sensitivity", function()
    local icons = require "core.agent_icons"
    test.equal(icons.provider("gPt-5"), "openai")
    test.equal(icons.provider("Claude Sonnet"), "anthropic")
    test.equal(icons.provider("FABLE 5"), "anthropic")
    test.equal(icons.provider("Gemini Pro"), nil)
    test.equal(icons.provider(nil), nil)
  end)

  test.it("draws both logos without hiding the status dot or the name", function()
    local old_canvas, old_dot, old_text = renderer.draw_canvas, renderer.draw_rounded_rect, renderer.draw_text
    local images, dots = {}, {}
    renderer.draw_canvas = function(image) images[#images + 1] = image end
    renderer.draw_rounded_rect = function(_, _, _, _, _, color) dots[#dots + 1] = color end
    renderer.draw_text = function() end
    local ok, err = pcall(function()
      local session = {id="pi",title="Task",state="running",busy=1,agent_app="pi",agent_state="working"}
      local plain = tab.width(tab.describe_session(session), 28 * SCALE)
      for _, model in ipairs {"GPT Test", "Claude Test", "Fable Test"} do
        session.agent_model = model
        local item = tab.describe_session(session)
        images, dots = {}, {}
        tab.draw(item, 0, 0, 400, 28 * SCALE, {name_color=style.text})
        test.equal(#images, 2, model .. " has no provider badge")
        test.equal(dots[1], style.accent)
        test.ok(tab.width(item, 28 * SCALE) > plain, "The name has no space for the badge")
      end
      for _, model in ipairs {"Other Model", ""} do
        session.agent_model = model
        images = {}
        tab.draw(tab.describe_session(session), 0, 0, 400, 28 * SCALE, {name_color=style.text})
        test.equal(#images, 1, "An unknown model kept the previous badge")
      end
    end)
    renderer.draw_canvas, renderer.draw_rounded_rect, renderer.draw_text = old_canvas, old_dot, old_text
    if not ok then error(err) end
  end)
end)
