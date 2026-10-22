local test = require "core.test"
local tab = require "core.tab"
local SidebarView = require "core.sidebar_view"

test.describe("Terminal labels", function()
  test.it("shows executable names and keeps command arguments", function()
    local cases = {
      {[[C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__package\pwsh.exe]], "PowerShell"},
      {[[.\gradlew.bat runAppiDesktop]], "gradlew runAppiDesktop"},
      {[[& "C:\Program Files\Tools\build.exe" --target "Desktop App"]], [[build --target "Desktop App"]]},
      {[["C:\Tools\runner.cmd" --file C:\work\input.txt]], [[runner --file C:\work\input.txt]]},
      {[[C:\Tools\pwsh.exe -NoProfile]], "PowerShell -NoProfile"},
      {"Production logs", "Production logs"},
      {"π - Fix terminal labels", "π - Fix terminal labels"},
      {"npm run build", "npm run build"},
    }
    for _, pair in ipairs(cases) do
      local item = tab.describe_session {id="one", title=pair[1], state="running"}
      test.equal(tab.display_name(item), pair[2])
      test.equal(item.name, pair[1], "display formatting changed the original title")
    end
    test.equal(tab.display_name {name="notes.bat"}, "notes.bat", "a file Tab changed its name")
  end)

  test.it("exposes the full terminal title on hover and clears it on leave", function()
    local title = [["C:\Program Files\Tools\build.exe" --target desktop]]
    local view = SidebarView(function() end)
    view:set_model {{id=1, row_id=1, path="C:/Work", state="ready", terminals={
      {id="one", title=title, state="running", activity=os.time()},
    }}}
    view:set_size(260, 600)
    for index, row in ipairs(view.rows) do
      if row.kind == "terminal" then view:on_mouse_moved(50, view:row_y(index) + row.h / 2) end
    end
    test.equal(view:get_tooltip(), title)
    coroutine.yield(1)
    local draw_text, draw_rect, draw_rounded, clip =
      renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect, renderer.set_clip_rect
    local drawn = {}
    renderer.draw_text = function(_, text) drawn[#drawn + 1] = text end
    renderer.draw_rect, renderer.draw_rounded_rect, renderer.set_clip_rect = function() end, function() end, function() end
    local ok, err = pcall(view.draw, view, 260, 600)
    renderer.draw_text, renderer.draw_rect, renderer.draw_rounded_rect, renderer.set_clip_rect =
      draw_text, draw_rect, draw_rounded, clip
    test.ok(ok, err)
    test.ok(table.concat(drawn):find(title, 1, true), "the hover tooltip lost part of the original title")
    view:on_mouse_left()
    test.equal(view:get_tooltip(), nil)
  end)
end)
