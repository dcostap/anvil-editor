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
