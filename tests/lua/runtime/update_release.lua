local test = require "core.test"
local json = require "core.json"

local function release(tag)
  return {
    tag_name = tag, draft = false, prerelease = false,
    assets = {{ name = "anvil.exe", state = "uploaded", size = 12345,
      browser_download_url = "https://github.com/dcostap/anvil-editor/releases/download/" .. tag .. "/anvil.exe",
      digest = "sha256:" .. string.rep("a", 64) }},
  }
end

test.describe("Release updates", function()
  test.it("offers only a newer stable version, using numeric version order", function()
    local releases = require "plugins.updater.release"
    local result = assert(releases.parse(json.encode(release("v1.10.0")), "1.9.9"))
    test.equal(result.version, "1.10.0")
    test.equal(result.sha256, string.rep("a", 64))
    test.equal(result.size, 12345)
    test.equal(assert(releases.parse(json.encode(release("v1.10.0")), "1.9.9-jit")).version, "1.10.0")
    test.equal(releases.parse(json.encode(release("v1.10.0")), "1.10.0"), false)
    test.equal(releases.parse(json.encode(release("v1.9.9")), "1.10.0"), false)
    test.equal(releases.parse(json.encode(release("v2.0.0-beta.1")), "1.0.0"), nil)
    local draft = release("v2.0.0")
    draft.draft = true
    test.equal(releases.parse(json.encode(draft), "1.0.0"), nil)
    draft.draft, draft.prerelease = false, true
    test.equal(releases.parse(json.encode(draft), "1.0.0"), nil)
  end)

  test.it("requires the complete executable and its GitHub digest from this repository", function()
    local releases = require "plugins.updater.release"
    for _, change in ipairs({
      function(r) r.assets = {} end,
      function(r) r.assets[1].digest = nil end,
      function(r) r.assets[1].digest = "sha256:abcd" end,
      function(r) r.assets[1].browser_download_url = "https://example.com/anvil.exe" end,
      function(r) r.assets[1].size = 0 end,
      function(r) r.assets[1].state = "new" end,
    }) do
      local r = release("v2.0.0")
      change(r)
      local value, message = releases.parse(json.encode(r), "1.0.0")
      test.equal(value, nil)
      test.ok(type(message) == "string" and #message > 0)
    end
    test.equal(releases.parse("not JSON", "1.0.0"), nil)
    test.equal(releases.parse("null", "1.0.0"), nil)
    test.equal(releases.parse(json.encode(release("v2.0.0")), "development"), nil)
  end)
end)
