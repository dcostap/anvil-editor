local common = require "core.common"
local core = require "core"
local Doc = require "core.doc"
local links = require "core.markdown.links"
local Project = require "core.project"
local test = require "core.test"
local vault_index = require "core.markdown.vault_index"
local rename_links = require "core.markdown.rename_links"

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

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.01) end
  return predicate()
end

test.describe("Markdown vault index", function()
  test.it("indexes notes with very long table padding without blocking", function()
    local root = temp_root("markdown-vault-long-table-padding")
    mkdirp(root)
    local path = join_path(root, "Padded.md")
    write_file(path, "|" .. string.rep(" ", 20000) .. "|\n")
    local index = vault_index.get_index(root)

    local started = system.get_time()
    test.equal(index:update_path(path), true)
    local elapsed = system.get_time() - started
    local note_count = index:note_count()
    common.rm(root, true)

    test.equal(note_count, 1)
    test.ok(elapsed < 1, string.format("Markdown indexing blocked for %.3fs", elapsed))
  end)

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

  test.it("reconciles filesystem changes while preserving open-Document overlays", function()
    local root = temp_root("markdown-vault-reconcile")
    mkdirp(root)
    local existing = join_path(root, "Existing.md")
    write_file(existing, "# Old\n")
    local index = vault_index.get_index(root):rebuild("reconcile-test")

    local added = join_path(root, "Added.md")
    write_file(added, "# Added\n")
    test.equal(index:reconcile_dir(root, "test-create"), true)
    test.equal(index:resolve(wiki("[[Added#Added]]"), existing).status, "resolved")

    write_file(added, "# Changed heading\nextra\n")
    test.equal(index:reconcile_dir(root, "test-modify"), true)
    test.equal(index:resolve(wiki("[[Added#Changed heading]]"), existing).status, "resolved")

    local nested = join_path(root, "nested")
    mkdirp(nested)
    write_file(join_path(nested, "Nested.md"), "# Nested\n")
    test.equal(index:reconcile_dir(root, "test-new-directory"), true)
    test.equal(index:resolve(wiki("[[nested/Nested]]"), existing).status, "resolved")

    local overlay_path = join_path(root, "Overlay.md")
    write_file(overlay_path, "# Disk\n")
    local overlay = Doc(overlay_path, overlay_path, true)
    overlay:insert(1, 1, "# Unsaved\n")
    index:track_doc(overlay)
    os.remove(overlay_path)
    index:reconcile_dir(root, "test-overlay-delete")
    test.equal(index:resolve(wiki("[[Overlay#Unsaved]]"), existing).status, "resolved")

    os.remove(existing)
    common.rm(nested, true)
    test.equal(index:reconcile_dir(root, "test-delete"), true)
    test.equal(index:resolve(wiki("[[Existing]]"), added).status, "missing")
    test.equal(index:resolve(wiki("[[nested/Nested]]"), added).status, "missing")
    test.equal(index:resolve(wiki("[[Overlay#Unsaved]]"), added).status, "resolved")

    index:on_doc_closed(overlay)
    common.rm(root, true)
  end)

  test.it("starts and stops filesystem watching with active consumers", function()
    local root = temp_root("markdown-vault-watch-lifecycle")
    mkdirp(root)
    local index = vault_index.get_index(root)
    test.equal(index:acquire("test-consumer"), true)
    test.not_nil(index.watcher)
    test.equal(index:acquire("test-consumer"), false)
    test.equal(index:release("test-consumer"), true)
    test.equal(index.watcher, nil)
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
    write_file(join_path(root, "Nested.md"), "# Parent\n## Child\n# Other\n## Child\n")
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

      result = index:resolve(wiki("[[Nested#Parent#Child]]"), join_path(root, "Source.md"))
      test.equal(result.status, "resolved")
      test.equal(result.line, 2)
      result = index:resolve(wiki("[[Nested#Other#Child]]"), join_path(root, "Source.md"))
      test.equal(result.status, "resolved")
      test.equal(result.line, 4)

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

  test.it("provides deterministic note, alias, heading, block, and attachment completion states", function()
    local root = temp_root("markdown-vault-completion")
    mkdirp(join_path(root, "folder"))
    write_file(join_path(root, "Source.md"), "# Local Heading\n\ntext ^local-block\n")
    write_file(join_path(root, "Note.md"), "---\naliases: [Alias Name]\n---\n# Global Heading\n\ntext ^global-block\n")
    write_file(join_path(root, "folder", "Note.md"), "# Other\n")
    write_file(join_path(root, "image.png"), "png")
    local index = vault_index.get_index(root):rebuild("completion-test")
    local source = join_path(root, "Source.md")
    local function find(items, kind, target)
      for _, item in ipairs(items) do
        if item.kind == kind and item.target == target then return item end
      end
    end

    test.not_nil(find(index:completion_candidates("note", "alias", source), "alias", "Note.md|Alias Name"))
    test.not_nil(find(index:completion_candidates("note", "image", source), "attachment", "image.png"))
    test.not_nil(find(index:completion_candidates("current_heading", "local", source), "heading", "#Local Heading"))
    test.not_nil(find(index:completion_candidates("global_heading", "global", source), "heading", "Note.md#Global Heading"))
    test.not_nil(find(index:completion_candidates("current_block", "local", source), "block", "^local-block"))
    test.not_nil(find(index:completion_candidates("global_block", "global", source), "block", "Note.md#^global-block"))
    local notes = index:completion_candidates("note", "note", source)
    test.not_nil(find(notes, "note", "Note.md"))
    test.not_nil(find(notes, "note", "folder/Note"))

    test.equal(index:set_link_path_policy("root"), true)
    notes = index:completion_candidates("note", "note", source)
    test.not_nil(find(notes, "note", "Note"))
    test.not_nil(find(notes, "note", "folder/Note"))
    test.equal(index:resolve(wiki("[[Note]]"), source).path, normalized(join_path(root, "Note.md")))

    test.equal(index:set_link_path_policy("relative"), true)
    notes = index:completion_candidates("note", "note", join_path(root, "folder", "Source.md"))
    test.not_nil(find(notes, "note", "../Note"))
    test.not_nil(find(notes, "note", "./Note"))
    test.equal(index:set_link_path_policy("shortest_unique"), true)
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

  test.it("resolves percent-encoded Markdown destinations", function()
    local root = temp_root("markdown-vault-percent-encoded")
    mkdirp(root)
    local source = join_path(root, "Source.md")
    write_file(source, "source\n")
    write_file(join_path(root, "Note name.md"), "# Note\n")
    local index = vault_index.get_index(root):rebuild("percent-encoded-test")
    local link = test.not_nil(links.find_links("[Note](Note%20name.md)", 1)[1])

    test.equal(index:resolve(link, source).status, "resolved")
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
      test.ok(wait_until(function()
        return index:resolve(wiki("[[Note#New]]"), note_path).status == "resolved"
      end), "initial tracked Document overlay was not published")

      local heading = index:resolve(wiki("[[Note#New]]"), note_path)
      test.equal(heading.status, "resolved")
      test.equal(heading.line, 1)
      local block = index:resolve(wiki("[[Note#^new]]"), note_path)
      test.equal(block.status, "resolved")
      test.equal(block.line, 3)

      doc:remove(1, 1, math.huge, math.huge)
      doc:insert(1, 1, "# New Heading\n\nText ^new\n")
      test.ok(wait_until(function()
        return index:resolve(wiki("[[Note#New Heading]]"), note_path).status == "resolved"
      end), "tracked Document update was not published")
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

  test.it("plans semantic target-only link edits for a note rename", function()
    local root = temp_root("markdown-vault-rename-plan")
    mkdirp(root)
    local old_path = join_path(root, "Old.md")
    local new_path = join_path(root, "Renamed.md")
    local ref_path = join_path(root, "Ref.md")
    write_file(old_path, "# Heading\n")
    write_file(ref_path, "[[Old#Heading|Alias]] ![[Old]] [old](Old.md#Heading) [[Old?mode#Heading]] `[[Old]]`\n")
    local index = vault_index.get_index(root):rebuild("rename-plan-test")
    local plan = test.not_nil(index:plan_note_rename(old_path, new_path))
    test.equal(#plan.files, 1)
    test.equal(plan.files[1].path, normalized(ref_path))
    test.equal(#plan.files[1].edits, 4)
    test.same({ plan.files[1].edits[1].text, plan.files[1].edits[2].text, plan.files[1].edits[3].text, plan.files[1].edits[4].text },
      { "Renamed#Heading", "Renamed", "Renamed.md#Heading", "Renamed?mode#Heading" })
    local applied, result = rename_links.apply(plan)
    test.equal(applied, true)
    test.same(result.applied, { normalized(ref_path) })
    local updated = test.not_nil(io.open(ref_path, "rb")); local updated_text = updated:read("*a"); updated:close()
    test.equal(updated_text,
      "[[Renamed#Heading|Alias]] ![[Renamed]] [old](Renamed.md#Heading) [[Renamed?mode#Heading]] `[[Old]]`\n")
    common.rm(root, true)
  end)

  test.it("coalesces ordinary tracked Document edits without publishing unchanged link facts", function()
    local root = temp_root("markdown-vault-doc-coalesce")
    mkdirp(root)
    local note_path = join_path(root, "Note.md")
    local lines = { "# Heading", "", "preview", "", "body" }
    for i = 1, 100 do lines[#lines + 1] = "line " .. i end
    write_file(note_path, table.concat(lines, "\n") .. "\n")
    local index = vault_index.get_index(root):rebuild("coalesce-test")
    local doc = Doc(note_path, note_path, true)
    doc:insert(1, 1, table.concat(lines, "\n") .. "\n")
    index:track_doc(doc)
    coroutine.yield(0.05)
    local generation = index.generation
    local updates = index.diagnostics.doc_updates

    doc:insert(80, 1, "a")
    doc:insert(80, 2, "b")
    doc:insert(80, 3, "c")
    test.equal(index.generation, generation)
    test.ok(wait_until(function() return index.diagnostics.doc_updates > updates end))
    test.ok(index.diagnostics.doc_updates - updates < 3)
    test.ok(index.diagnostics.doc_updates_coalesced >= 1)
    test.equal(index.generation, generation)
    index:on_doc_closed(doc)
    common.rm(root, true)
  end)

  test.it("enters degraded watcher mode after its deterministic directory budget", function()
    local root = temp_root("markdown-vault-watch-budget")
    local child = join_path(root, "child")
    mkdirp(child)
    local index = vault_index.get_index(root)
    index.watcher = { watch = function() end, scanned = {} }
    index.watcher_mode = "native"
    index.watch_dir_limit = 1

    test.equal(index:watch_dir(root), true)
    test.equal(index:watch_dir(child), false)
    test.equal(index.watcher_mode, "degraded")
    index.watcher = nil
    index.watched_dirs = {}
    index.watch_dir_count = 0
    common.rm(root, true)
  end)

  test.it("excludes raw HTML links from note rename plans", function()
    local root = temp_root("markdown-vault-rename-html")
    mkdirp(root)
    local old_path = join_path(root, "Old.md")
    local new_path = join_path(root, "New.md")
    write_file(old_path, "# Old\n")
    write_file(join_path(root, "Reference.md"), "<div>\n[Old](Old.md)\n</div>\n")
    local index = vault_index.get_index(root):rebuild("rename-html-test")

    local plan = test.not_nil(index:plan_note_rename(old_path, new_path))
    test.equal(#plan.files, 0)
    common.rm(root, true)
  end)

  test.it("rejects stale rename plans before changing any file", function()
    local root = temp_root("markdown-vault-stale-rename")
    mkdirp(root)
    local old_path = join_path(root, "Old.md")
    local new_path = join_path(root, "New.md")
    local first_path = join_path(root, "First.md")
    local second_path = join_path(root, "Second.md")
    write_file(old_path, "# Old\n")
    write_file(first_path, "[Old](Old.md)\n")
    write_file(second_path, "[Old](Old.md)\n")
    local index = vault_index.get_index(root):rebuild("stale-rename-test")
    local plan = test.not_nil(index:plan_note_rename(old_path, new_path))
    write_file(second_path, "prefix [Old](Old.md)\n")

    local applied, result = rename_links.apply(plan)
    test.equal(applied, false)
    test.equal(#result.applied, 0)
    local first = test.not_nil(io.open(first_path, "rb"))
    local first_text = first:read("*a")
    first:close()
    local second = test.not_nil(io.open(second_path, "rb"))
    local second_text = second:read("*a")
    second:close()
    test.equal(first_text, "[Old](Old.md)\n")
    test.equal(second_text, "prefix [Old](Old.md)\n")
    common.rm(root, true)
  end)

  test.it("indexes Setext headings and ignores block IDs inside raw blocks", function()
    local root = temp_root("markdown-vault-setext-raw")
    mkdirp(root)
    local note = join_path(root, "Note.md")
    write_file(note, table.concat({
      "Setext heading", "==============", "", "```", "code ^not-a-block", "```",
      "", "<div>", "html ^not-html-block", "</div>", "", "real ^real-block", "",
    }, "\n"))
    local index = vault_index.get_index(root):rebuild("setext-raw-test")
    local source = join_path(root, "Source.md")

    test.equal(index:resolve(wiki("[[Note#Setext heading]]"), source).status, "resolved")
    test.equal(index:resolve(wiki("[[Note#^real-block]]"), source).status, "resolved")
    test.equal(index:resolve(wiki("[[Note#^not-a-block]]"), source).status, "missing")
    test.equal(index:resolve(wiki("[[Note#^not-html-block]]"), source).status, "missing")
    common.rm(root, true)
  end)

  test.it("preserves commas inside quoted frontmatter aliases", function()
    local root = temp_root("markdown-vault-quoted-alias")
    mkdirp(root)
    write_file(join_path(root, "Person.md"), "---\naliases: [\"Last, First\", Other]\n---\n")
    local index = vault_index.get_index(root):rebuild("quoted-alias-test")
    local source = join_path(root, "Source.md")

    test.equal(index:resolve(wiki("[[Last, First]]"), source).status, "resolved")
    test.equal(index:resolve(wiki("[[Other]]"), source).status, "resolved")
    common.rm(root, true)
  end)

  test.it("publishes bounded note, heading, and block embed previews", function()
    local root = temp_root("markdown-vault-embed-preview")
    mkdirp(root)
    local note_path = join_path(root, "Note.md")
    write_file(note_path, "# Heading\nfirst\nsecond\n\n## Child\nchild text\n\nblock content ^block-id\n")
    local index = vault_index.get_index(root):rebuild("embed-preview-test")
    local entry = test.not_nil(index.notes_by_abs[common.path_compare_key(normalized(note_path))])
    test.same(entry.embed_preview, { "Heading", "first", "second" })
    test.same(entry.headings_by_slug.heading.embed_preview, { "first", "second" })
    test.same(entry.headings_by_slug.child.embed_preview, { "child text", "block content" })
    test.same(entry.blocks_by_id["block-id"].embed_preview, { "block content" })
    common.rm(root, true)
  end)

  test.it("indexes normalized frontmatter aliases and tags", function()
    local root = temp_root("markdown-vault-frontmatter")
    mkdirp(root)
    local note_path = join_path(root, "Note.md")
    write_file(note_path, "---\naliases: [One, 'Two']\ntags:\n  - project/anvil\n  - '#status/active'\ncategory: docs\n---\n# Note\n")
    local index = vault_index.get_index(root):rebuild("frontmatter-test")
    local entry = test.not_nil(index.notes_by_abs[common.path_compare_key(normalized(note_path))])
    test.same(entry.aliases, { "One", "Two" })
    test.same(entry.tags, { "project/anvil", "status/active" })
    test.equal(entry.frontmatter.category, "docs")
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
      test.ok(wait_until(function()
        return index:resolve(wiki("[[Old]]"), old_path).status == "resolved"
      end))
      test.equal(index:resolve(wiki("[[Old]]"), old_path).status, "resolved")
      doc:set_filename(new_path, new_path)
      test.ok(wait_until(function()
        return index:resolve(wiki("[[New]]"), new_path).status == "resolved"
      end))
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
      test.ok(wait_until(function()
        return index:resolve(wiki("[[New#Open Overlay]]"), new_path).status == "resolved"
      end))
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
