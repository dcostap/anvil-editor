local common = require "core.common"
local core = require "core"
local Doc = require "core.doc"
local links = require "core.markdown.links"
local Project = require "core.project"
local test = require "core.test"
local vault_index = require "core.markdown.vault_index"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function temp_root(name)
  return join_path(USERDIR, name .. "-" .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
end

local function with_projects(projects, fn)
  local old_projects = core.projects
  core.projects = projects
  local ok, err = pcall(fn)
  core.projects = old_projects
  if not ok then error(err) end
end

local function wiki(text)
  return links.find_links(text, 1)[1]
end

local function normalized(path)
  return common.normalize_path(path)
end

test.describe("Markdown vault index", function()
  test.it("cooperatively builds a cold index and publishes readiness", function()
    local root = temp_root("markdown-vault-async")
    mkdirp(root)
    for i = 1, 70 do write_file(join_path(root, "Note" .. i .. ".md"), "# Note " .. i .. "\n") end
    local index = vault_index.get_index(root)
    local events = {}
    index:add_listener("test", function(_, reason) events[#events + 1] = reason end)
    test.equal(index:ensure("test"), false)
    test.equal(index.status, "indexing")
    local deadline = system.get_time() + 5
    while index.status ~= "ready" and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(index.status, "ready")
    test.equal(index:note_count(), 70)
    test.same(events, { "indexing", "ready" })
    index:remove_listener("test")
    common.rm(root, true)
  end)

  test.it("bounds oversized cold-start notes with shallow entries", function()
    local root = temp_root("markdown-vault-large")
    mkdirp(root)
    write_file(join_path(root, "Large.md"), "# Heading\n" .. string.rep("prose ", 90000))
    local index = vault_index.get_index(root)
    index:ensure("test-large")
    local deadline = system.get_time() + 5
    while index.status ~= "ready" and system.get_time() < deadline do coroutine.yield(0.01) end
    test.equal(index.status, "ready")
    test.equal(index:resolve(wiki("[[Large]]"), join_path(root, "Source.md")).status, "resolved")
    test.equal(index:resolve(wiki("[[Large#Heading]]"), join_path(root, "Source.md")).status, "missing")
    common.rm(root, true)
  end)

  test.it("reconciles a tracked rename during cooperative scanning", function()
    local root1 = temp_root("markdown-vault-race-one")
    local root2 = temp_root("markdown-vault-race-two")
    mkdirp(root1)
    mkdirp(root2)
    for i = 1, 70 do write_file(join_path(root1, "Fill" .. i .. ".md"), "# Fill\n") end
    local old_path = join_path(root1, "Old.md")
    local new_path = join_path(root2, "New.md")
    write_file(old_path, "# Old\n")
    with_projects({ Project(root1), Project(root2) }, function()
      local index = vault_index.get_index(root1)
      local doc = Doc(old_path, old_path, true)
      doc:insert(1, 1, "# Unsaved\n")
      index:track_doc(doc)
      index:ensure("rename-race")
      coroutine.yield(0)
      os.remove(old_path)
      doc:set_filename(new_path, new_path)
      local deadline = system.get_time() + 5
      while index.status ~= "ready" and system.get_time() < deadline do coroutine.yield(0.01) end
      test.equal(index.status, "ready")
      test.equal(index:resolve(wiki("[[Old]]"), join_path(root1, "Source.md")).status, "missing")
    end)
    common.rm(root1, true)
    common.rm(root2, true)
  end)

  test.it("resolves note, heading, and block wikilinks", function()
    local root = temp_root("markdown-vault-index")
    mkdirp(root)
    write_file(join_path(root, "Note.md"), "# Heading\n\nText ^block-id\n")
    write_file(join_path(root, "Source.md"), "source\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local result = index:resolve(wiki("[[Note]]"), join_path(root, "Source.md"))
      test.equal(result.status, "resolved")
      test.equal(result.kind, "note")
      test.equal(result.path, normalized(join_path(root, "Note.md")))

      result = index:resolve(wiki("[[Note#Heading]]"), join_path(root, "Source.md"))
      test.equal(result.status, "resolved")
      test.equal(result.line, 1)

      result = index:resolve(wiki("[[Note#^block-id]]"), join_path(root, "Source.md"))
      test.equal(result.status, "resolved")
      test.equal(result.line, 3)

      result = index:resolve(wiki("[[#Heading]]"), join_path(root, "Note.md"))
      test.equal(result.status, "resolved")
      test.equal(result.line, 1)
      result = index:resolve(wiki("[[^block-id]]"), join_path(root, "Note.md"))
      test.equal(result.status, "resolved")
      test.equal(result.line, 3)

      result = index:resolve(
        links.find_links("[download](Note.md?download#Heading)", 1)[1],
        join_path(root, "Source.md")
      )
      test.equal(result.status, "resolved")
      test.equal(result.line, 1)
    end)

    common.rm(root, true)
  end)

  test.it("resolves explicit project-relative and source-relative paths", function()
    local root = temp_root("markdown-vault-paths")
    mkdirp(join_path(root, "folder"))
    write_file(join_path(root, "folder", "Note.md"), "# Folder Note\n")
    write_file(join_path(root, "folder", "Other.markdown"), "# Other\n")
    write_file(join_path(root, "folder", "Source.md"), "source\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local project_relative = index:resolve(wiki("[[folder/Note]]"), join_path(root, "folder", "Source.md"))
      test.equal(project_relative.status, "resolved")
      test.equal(project_relative.path, normalized(join_path(root, "folder", "Note.md")))

      local source_relative = index:resolve(wiki("[[./Note]]"), join_path(root, "folder", "Source.md"))
      test.equal(source_relative.status, "resolved")
      test.equal(source_relative.path, normalized(join_path(root, "folder", "Note.md")))

      local alternate_extension = index:resolve(wiki("[[folder/Other]]"), join_path(root, "folder", "Source.md"))
      test.equal(alternate_extension.status, "resolved")
      test.equal(alternate_extension.path, normalized(join_path(root, "folder", "Other.markdown")))
    end)

    common.rm(root, true)
  end)

  test.it("resolves against the source note's owning Project", function()
    local root1 = temp_root("markdown-vault-project-one")
    local root2 = temp_root("markdown-vault-project-two")
    mkdirp(root1)
    mkdirp(root2)
    write_file(join_path(root1, "Note.md"), "# One\n")
    write_file(join_path(root2, "Note.md"), "# Two\n")
    write_file(join_path(root2, "Source.md"), "source\n")

    with_projects({ Project(root1), Project(root2) }, function()
      vault_index.get_index(root1):rebuild("test")
      vault_index.get_index(root2):rebuild("test")
      local result = vault_index.resolve(wiki("[[Note]]"), join_path(root2, "Source.md"))
      test.equal(result.status, "resolved")
      test.equal(result.path, normalized(join_path(root2, "Note.md")))
    end)

    common.rm(root1, true)
    common.rm(root2, true)
  end)

  test.it("reports ambiguous note names instead of choosing one", function()
    local root = temp_root("markdown-vault-ambiguous")
    mkdirp(join_path(root, "a"))
    mkdirp(join_path(root, "b"))
    write_file(join_path(root, "a", "Note.md"), "# A\n")
    write_file(join_path(root, "b", "Note.md"), "# B\n")
    write_file(join_path(root, "Source.md"), "source\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local result = index:resolve(wiki("[[Note]]"), join_path(root, "Source.md"))
      test.equal(result.status, "ambiguous")
      test.equal(#result.candidates, 2)
    end)

    common.rm(root, true)
  end)

  test.it("resolves attachments by explicit filename and rejects outside-vault absolutes", function()
    local root = temp_root("markdown-vault-attachments")
    local outside = temp_root("markdown-vault-outside")
    mkdirp(root)
    mkdirp(outside)
    write_file(join_path(root, "image.png"), "png")
    write_file(join_path(root, "Source.md"), "source\n")
    write_file(join_path(outside, "Other.md"), "# Other\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local missing = index:resolve(wiki("[[image]]"), join_path(root, "Source.md"))
      test.equal(missing.status, "missing")

      local attachment = index:resolve(wiki("[[image.png]]"), join_path(root, "Source.md"))
      test.equal(attachment.status, "resolved")
      test.equal(attachment.kind, "attachment")

      local external = index:resolve(wiki("[[" .. join_path(outside, "Other.md") .. "]]"), join_path(root, "Source.md"))
      test.equal(external.status, "external")
    end)

    common.rm(root, true)
    common.rm(outside, true)
  end)

  test.it("updates heading and block targets from tracked Document edits", function()
    local root = temp_root("markdown-vault-doc-update")
    mkdirp(root)
    local note_path = join_path(root, "Note.md")
    write_file(note_path, "# Old\n\nText ^old\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local doc = Doc(note_path, note_path, true)
      doc:insert(1, 1, "# New\n\nText ^new\n")
      index:track_doc(doc)

      local heading = index:resolve(wiki("[[Note#New]]"), note_path)
      test.equal(heading.status, "resolved")
      test.equal(heading.line, 1)
      local block = index:resolve(wiki("[[Note#^new]]"), note_path)
      test.equal(block.status, "resolved")
      test.equal(block.line, 3)

      doc:remove(1, 1, math.huge, math.huge)
      doc:insert(1, 1, "# New Heading\n\nText ^new\n")
      heading = index:resolve(wiki("[[Note#New Heading]]"), note_path)
      test.equal(heading.status, "resolved")
      local old = index:resolve(wiki("[[Note#New]]"), note_path)
      test.equal(old.status, "missing")
    end)

    common.rm(root, true)
  end)

  test.it("releases closed unsaved Document overlays", function()
    local root = temp_root("markdown-vault-doc-close")
    mkdirp(root)
    local ghost_path = join_path(root, "Ghost.md")
    local source_path = join_path(root, "Source.md")
    write_file(source_path, "source\n")
    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local doc = Doc(ghost_path, ghost_path, true)
      doc:insert(1, 1, "# Unsaved\n")
      index:track_doc(doc)
      test.equal(index:resolve(wiki("[[Ghost]]"), source_path).status, "resolved")
      doc:on_close()
      test.equal(index:resolve(wiki("[[Ghost]]"), source_path).status, "missing")
    end)
    common.rm(root, true)
  end)

  test.it("replaces stale aliases when re-indexing an existing file", function()
    local root = temp_root("markdown-vault-alias-update")
    mkdirp(root)
    local note_path = join_path(root, "Note.md")
    local source_path = join_path(root, "Source.md")
    write_file(source_path, "source\n")
    write_file(note_path, "---\naliases: [Old]\n---\n# Note\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      test.equal(index:resolve(wiki("[[Old]]"), source_path).status, "resolved")
      write_file(note_path, "---\naliases: [New]\n---\n# Note\n")
      test.equal(index:update_path(note_path), true)
      test.equal(index:resolve(wiki("[[Old]]"), source_path).status, "missing")
      test.equal(index:resolve(wiki("[[New]]"), source_path).status, "resolved")
    end)

    common.rm(root, true)
  end)

  test.it("returns external results for URL targets", function()
    local root = temp_root("markdown-vault-external-url")
    mkdirp(root)
    write_file(join_path(root, "Source.md"), "source\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local result = index:resolve(links.find_links("[Site](https://example.com/page.html)", 1)[1], join_path(root, "Source.md"))
      test.equal(result.status, "external")
      test.equal(result.path, "https://example.com/page.html")
    end)

    common.rm(root, true)
  end)

  test.it("updates tracked docs after filename changes", function()
    local root = temp_root("markdown-vault-rename")
    mkdirp(root)
    local old_path = join_path(root, "Old.md")
    local new_path = join_path(root, "New.md")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local doc = Doc(old_path, old_path, true)
      doc:insert(1, 1, "# Renamed\n")
      index:track_doc(doc)
      test.equal(index:resolve(wiki("[[Old]]"), old_path).status, "resolved")
      doc:set_filename(new_path, new_path)
      test.equal(index:resolve(wiki("[[Old]]"), new_path).status, "missing")
      test.equal(index:resolve(wiki("[[New]]"), new_path).status, "resolved")
    end)

    common.rm(root, true)
  end)

  test.it("retains an old disk note when an open Document is saved as a new path", function()
    local root = temp_root("markdown-vault-save-as")
    mkdirp(root)
    local old_path = join_path(root, "Old.md")
    local new_path = join_path(root, "New.md")
    write_file(old_path, "# Disk Original\n")
    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      local doc = Doc(old_path, old_path, true)
      doc:insert(1, 1, "# Open Overlay\n")
      index:track_doc(doc)
      doc:set_filename(new_path, new_path)
      test.equal(index:resolve(wiki("[[Old#Disk Original]]"), new_path).status, "resolved")
      test.equal(index:resolve(wiki("[[New#Open Overlay]]"), new_path).status, "resolved")
    end)
    common.rm(root, true)
  end)

  test.it("untracks old vault indexes when tracked docs move across roots", function()
    local root1 = temp_root("markdown-vault-rename-root-one")
    local root2 = temp_root("markdown-vault-rename-root-two")
    mkdirp(root1)
    mkdirp(root2)
    local old_path = join_path(root1, "Old.md")
    local new_path = join_path(root2, "New.md")
    local source_path = join_path(root1, "Source.md")
    write_file(source_path, "source\n")

    with_projects({ Project(root1), Project(root2) }, function()
      local old_index = vault_index.get_index(root1):rebuild("test")
      local new_index = vault_index.get_index(root2):rebuild("test")
      local doc = Doc(old_path, old_path, true)
      doc:insert(1, 1, "# Old\n")
      old_index:track_doc(doc)
      test.equal(old_index:resolve(wiki("[[Old]]"), source_path).status, "resolved")
      doc:set_filename(new_path, new_path)
      doc:insert(2, 1, "# New Heading\n")
      test.equal(old_index:resolve(wiki("[[New]]"), source_path).status, "missing")
      test.equal(new_index:resolve(wiki("[[New]]"), new_path).status, "resolved")
    end)

    common.rm(root1, true)
    common.rm(root2, true)
  end)

  test.it("updates after new file creation and deletion invalidation", function()
    local root = temp_root("markdown-vault-file-events")
    mkdirp(root)
    local note_path = join_path(root, "New.md")
    local source_path = join_path(root, "Source.md")
    write_file(source_path, "source\n")

    with_projects({ Project(root) }, function()
      local index = vault_index.get_index(root):rebuild("test")
      test.equal(index:resolve(wiki("[[New]]"), source_path).status, "missing")
      write_file(note_path, "# New\n")
      test.equal(index:update_path(note_path), true)
      test.equal(index:resolve(wiki("[[New]]"), source_path).status, "resolved")
      os.remove(note_path)
      test.equal(index:remove_path(note_path), true)
      test.equal(index:resolve(wiki("[[New]]"), source_path).status, "missing")
    end)

    common.rm(root, true)
  end)
end)
