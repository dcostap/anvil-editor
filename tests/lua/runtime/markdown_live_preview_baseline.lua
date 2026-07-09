local common = require "core.common"
local core = require "core"
local links = require "core.markdown.links"
local Project = require "core.project"
local test = require "core.test"
local vault_index = require "core.markdown.vault_index"

local function join_path(...)
  return table.concat({ ... }, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

-- This characterization test intentionally describes the disconnected prototype
-- index. The link-index milestone replaces it with cold/scanning/ready behavior.
test.describe("Markdown Live Preview index baseline", function()
  test.it("does not scan an owning Project on first use", function()
    local root = join_path(
      USERDIR,
      "markdown-live-baseline-index-" .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    )
    local ok, err = common.mkdirp(root)
    test.ok(ok, err)
    local note_path = join_path(root, "Note.md")
    local source_path = join_path(root, "Source.md")
    write_file(note_path, "# Note\n")
    write_file(source_path, "[[Note]]\n")

    local old_projects = core.projects
    core.projects = { Project(root) }
    local passed, failure = pcall(function()
      local index = vault_index.index_for_path(source_path)
      local link = links.find_links("[[Note]]", 1)[1]
      test.equal(index:note_count(), 0)
      test.equal(vault_index.resolve(link, source_path).status, "missing")
    end)
    core.projects = old_projects
    common.rm(root, true)
    if not passed then error(failure, 0) end
  end)
end)
