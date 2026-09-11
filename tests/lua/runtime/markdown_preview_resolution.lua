local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_files = require "core.project_files"
local links = require "core.markdown.links"
local vault_index = require "core.markdown.vault_index"
local test = require "core.test"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

test.describe("Markdown preview resolution", function()
  test.before_each(function(c)
    c.projects = core.projects
    c.root = USERDIR .. PATHSEP .. "preview-resolution-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(c.root .. PATHSEP .. "Notes"))
    c.source = c.root .. PATHSEP .. "Source.md"
    c.target = c.root .. PATHSEP .. "Notes" .. PATHSEP .. "Target.md"
    write_file(c.source, "[[Target#Section]]\n")
    write_file(c.target, "# Target\n\n## Section\n\nPreview body\n")
    core.projects = { Project(c.root) }
    test.not_nil(project_files.list(c.root))
    c.index = vault_index.get_index(c.root)
  end)

  test.after_each(function(c)
    if c.buffer then core.buffer_registry:remove(c.buffer, true) end
    core.projects = c.projects
    common.rm(c.root, true)
  end)

  test.it("resolves a filename and heading without building the full note index", function(c)
    test.equal(c.index:can_resolve(), false)
    local result = c.index:resolve_preview(links.from_target("wiki", "Target#Section"), c.source)
    test.equal(result.status, "resolved")
    test.equal(result.path, common.normalize_path(c.target))
    test.equal(result.line, 3)
    test.equal(c.index:can_resolve(), false)
  end)

  test.it("does not choose between duplicate filenames while the note index is cold", function(c)
    test.ok(common.mkdirp(c.root .. PATHSEP .. "Other"))
    write_file(c.root .. PATHSEP .. "Other" .. PATHSEP .. "Target.md", "# Other target\n")
    test.not_nil(project_files.list(c.root, { refresh = true }))
    local result = c.index:resolve_preview(links.from_target("wiki", "Target"), c.source)
    test.equal(result.status, "ambiguous")
    test.equal(#result.candidates, 2)
  end)

  test.it("uses unsaved heading positions for a cold preview", function(c)
    c.buffer = core.open_buffer(c.target)
    c.buffer:insert(1, 1, "Intro\n\n")
    local result = c.index:resolve_preview(links.from_target("wiki", "Target#Section"), c.source)
    test.equal(result.status, "resolved")
    test.equal(result.line, 5)
    test.equal(c.index:can_resolve(), false)
  end)
end)
