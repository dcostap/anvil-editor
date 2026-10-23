local core = require "core"
local keymap = require "core.keymap"
local test = require "core.test"

-- Seam: focus events and native key metadata. The binding is local to this test.
test.describe("Held modifiers across focus changes", function()
  test.it("keeps modified commands available after each focus transfer", function()
    local count = 0
    local action = function() count = count + 1 end
    local binding = (PLATFORM == "Mac OS X" and "option" or "alt") .. "+f13"
    local saved = keymap.modkeys
    keymap.modkeys = {}
    keymap.add {[binding] = action}
    local ok, err = pcall(function()
      for _ = 1, 4 do
        core.on_event("focuslost")
        core.on_event("focusgained")
        -- Alt stays down in the OS. The destination receives no new Alt press.
        keymap.on_key_pressed("f13", {modifiers=256,alt=true,ctrl=false,shift=false,super=false,altgr=false})
      end
      test.equal(count, 4, "Focus transfer lost the held modifier")
      keymap.on_key_pressed("f13", {modifiers=0,alt=false,ctrl=false,shift=false,super=false,altgr=false})
      test.equal(count, 4, "A released modifier stayed active")
    end)
    keymap.unbind(binding, action)
    keymap.modkeys = saved
    if not ok then error(err, 0) end
  end)
end)
