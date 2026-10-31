local test = require "core.test"
local command = require "core.command"
local json = require "core.json"
local worker_pool = require "core.worker_pool"
local dialogs = require "core.ui.dialog"

if PLATFORM ~= "Windows" then return end

local updater
local old_named, old_embedded, old_hosted, old_version
local jobs
local response = json.encode({ tag_name = "v99.0.0", draft = false, prerelease = false, assets = {{
  name = "anvil.exe", state = "uploaded", size = 12345, digest = "sha256:" .. string.rep("a", 64),
  browser_download_url = "https://github.com/dcostap/anvil-editor/releases/download/v99.0.0/anvil.exe",
}} })

test.describe("Release update Dialog", function()
  test.before_each(function()
    old_named, old_embedded, old_hosted = worker_pool.named, rawget(_G, "EMBEDDED_DATADIR"), system.is_hosted_surface
    old_version, VERSION = VERSION, "1.0.0-jit"
    jobs = {}
    worker_pool.named = function(name, options)
      if name ~= "updater" then return old_named(name, options) end
      return { submit = function(_, job) jobs[#jobs + 1] = job; return {} end }
    end
    rawset(_G, "EMBEDDED_DATADIR", DATADIR)
    system.is_hosted_surface = function() return true end
    updater = require "plugins.updater"
  end)
  test.after_each(function()
    if dialogs.current() then dialogs.current():close() end
    worker_pool.named, system.is_hosted_surface = old_named, old_hosted
    VERSION = old_version
    rawset(_G, "EMBEDDED_DATADIR", old_embedded)
    test.ok(test.remove_tree(USERDIR .. PATHSEP .. "updates"))
    test.ok(test.remove_tree(USERDIR .. PATHSEP .. "storage" .. PATHSEP .. "updater"))
  end)

  test.it("shows check failures, then offers a verified release without starting an update", function()
    test.ok(command.perform("updater:check"))
    local dialog = dialogs.current()
    test.ok(dialog)
    test.ok(not dialog.update_button.enabled)
    jobs[#jobs].on_result({ payload = { code = 22, stderr = "HTTP 403" } })
    dialog:on_update()
    test.ok(dialog.message:find("HTTP 403", 1, true))
    test.ok(not dialog.update_button.enabled)
    dialog.check_button:activate()
    test.equal(updater.state, "checking", updater.message)
    jobs[#jobs].on_result({ payload = { code = 0, stdout = response } })
    dialog:on_update()
    test.ok(dialog.update_button.enabled, dialog.message)
    test.ok(dialog.message:find("99.0.0", 1, true))
    dialog:close()
    test.equal(updater.state, "available")
  end)

  test.it("does not replace an external-data development build", function()
    rawset(_G, "EMBEDDED_DATADIR", nil)
    test.ok(command.perform("updater:check"))
    local dialog = dialogs.current()
    dialog:on_update()
    test.ok(not dialog.update_button.enabled)
    test.ok(dialog.message:find("development", 1, true))
    test.equal(updater.install(), false)
    test.equal(#jobs, 0)
  end)

  test.it("starts only the accepted update and shows an independent helper launch failure", function()
    test.ok(command.perform("updater:check"))
    jobs[#jobs].on_result({ payload = { code = 0, stdout = response } })
    local dialog = dialogs.current()
    dialog:on_update()
    test.ok(dialog.update_button:activate(), dialog.message)
    dialog:on_update()
    test.ok(not dialog.update_button.enabled)
    local launch = jobs[#jobs]
    local arguments = launch.payload.command
    local file = assert(io.open(arguments[#arguments], "rb"))
    local request = json.decode(file:read("*a"))
    file:close()
    test.equal(request.version, "99.0.0")
    test.equal(request.sha256, string.rep("a", 64))
    test.equal(request.executable, EXEFILE:gsub("/", "\\"))
    launch.on_result({ payload = { code = 1, stderr = "Windows Explorer is unavailable." } })
    dialog:on_update()
    test.ok(dialog.message:find("Explorer is unavailable", 1, true))
    test.ok(dialog.check_button.enabled)
    test.ok(not dialog.update_button.enabled)
  end)
end)
