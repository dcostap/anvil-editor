local command = require "core.command"
local panes = require "core.panes"
local Capture = require("core.text_capture").View
local View = require "core.view"
local test = require "core.test"

test.describe("Reopen closed Pane", function()
  test.before_each(function() panes.reset_for_tests() end)
  test.after_each(function() panes.reset_for_tests() end)

  test.it("restores non-file Views and their backward and forward history", function()
    local first = Capture { title = "First", text = "first capture" }
    local pane = panes.create { factory = function() return first end }
    panes.present(Capture { title = "Second", text = "second capture" }, { pane = pane })
    panes.back(pane)
    test.ok(panes.close(pane, { force = true }))
    test.equal(panes.count(), 0)
    test.ok(command.perform("core:reopen_last_closed_pane"))
    local restored = test.not_nil(panes.active())
    test.equal(restored.current_view:get_name(), "First")
    test.equal(panes.forward(restored):get_name(), "Second")
    test.equal(panes.back(restored):get_name(), "First")
    test.contains(table.concat(restored.current_view.buffer.lines), "first capture")
    test.ok(panes.validate())
  end)

  test.it("restores closed Panes in reverse order without replacing open Panes", function()
    for _, title in ipairs { "First", "Second" } do
      local pane = panes.create { factory = function() return Capture { title = title } end }
      panes.close(pane, { force = true })
    end
    local existing = panes.create { factory = function() return Capture { title = "Existing" } end }
    test.ok(panes.reopen_last_closed())
    test.equal(panes.active().current_view:get_name(), "Second")
    test.ok(panes.reopen_last_closed())
    test.equal(panes.active().current_view:get_name(), "First")
    test.equal(existing.current_view:get_name(), "Existing")
    test.equal(panes.count(), 3)
  end)

  test.it("reports an unsupported View instead of reopening an older Pane", function()
    local older = panes.create { factory = function() return Capture { title = "Older" } end }
    panes.close(older, { force = true })
    local pane = panes.create { factory = function() return View() end }
    panes.close(pane, { force = true })
    local restored, reason = panes.reopen_last_closed()
    test.not_ok(restored)
    test.ok(type(reason) == "string" and #reason > 0)
    test.equal(panes.count(), 0)
  end)

  test.it("restores a Git Log with its related capture in one constrained Pane", function()
    local core = require "core"
    local manager = require "plugins.git_view"
    local _, log = manager.open_log(core.root_project(), {
      focus = false, git_view_opts = { defer_refresh = true },
    })
    local pane = panes.create { factory = function() return log end }
    panes.present(Capture { title = "Log capture", text = "saved output",
      pane_constraint = panes.constraint(pane) }, { pane = pane })
    test.ok(panes.close(pane, { force = true }))
    local restored, err = panes.reopen_last_closed()
    test.ok(restored, err)
    test.equal(restored.current_view:get_name(), "Log capture")
    local reopened_log = panes.back(restored)
    test.equal(reopened_log:model_tab().kind, "log")
    test.equal(panes.constraint(restored), reopened_log)
    test.equal(panes.forward(restored):get_name(), "Log capture")
    test.equal(panes.count(), 1)
    test.ok(panes.validate())
    panes.close(restored, { force = true })
  end)

  test.it("does not record a canceled close", function()
    local original = Capture { title = "Keep" }
    function original:can_close() end
    local pane = panes.create { factory = function() return original end }
    test.not_ok(panes.close(pane))
    test.not_ok(panes.reopen_last_closed())
    test.equal(pane.current_view, original)
  end)
end)
