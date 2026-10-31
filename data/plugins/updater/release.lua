-- The GitHub release boundary. No network or editor state belongs here.
local json = require "core.json"
local M = {
  endpoint = "https://api.github.com/repos/dcostap/anvil-editor/releases/latest",
  page = "https://github.com/dcostap/anvil-editor/releases",
}

local function version(text)
  if type(text) ~= "string" then return end
  local a, b, c = text:match("^v?(%d+)%.(%d+)%.(%d+)$")
  if not a then return end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

-- Returns a newer release, false when current, or nil and an error for an unusable response.
function M.parse(body, current)
  -- Meson adds this display suffix to the shipped LuaJIT build, not to its release tag.
  local running = version(type(current) == "string" and current:gsub("%-jit$", "") or current)
  local ok, release = pcall(json.decode, body)
  if not running then return nil, "This build has no release version." end
  if not ok or type(release) ~= "table" or release.draft ~= false or release.prerelease ~= false then
    return nil, "GitHub did not return a stable release."
  end
  local latest = version(release.tag_name)
  if not latest then return nil, "The release version is not valid." end
  local newer = false
  for i = 1, 3 do
    if latest[i] ~= running[i] then newer = latest[i] > running[i]; break end
  end
  if not newer then return false end
  local expected_url = M.page .. "/download/" .. release.tag_name .. "/anvil.exe"
  for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
    if type(asset) == "table" and asset.name == "anvil.exe" then
      local hash = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$")
      if asset.state ~= "uploaded" or asset.browser_download_url ~= expected_url
        or not hash or #hash ~= 64 or type(asset.size) ~= "number" or asset.size <= 0
        or asset.size > 512 * 1024 * 1024 or asset.size ~= math.floor(asset.size) then
        return nil, "The release executable or its SHA-256 digest is not ready."
      end
      return { version = table.concat(latest, "."), url = expected_url, sha256 = hash:lower(), size = asset.size,
        page = M.page .. "/tag/" .. release.tag_name }
    end
  end
  return nil, "The release has no anvil.exe."
end

return M
