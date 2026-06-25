local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local DocView = require "core.docview"
local storage = require "core.storage"
local recovery = require "plugins.untitled_recovery"
require "plugins.untitled_tabs"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function read_file(path)
  local fp, err = io.open(path, "rb")
  test.not_nil(fp, err)
  local s = fp:read("*a")
  fp:close()
  return s
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  test.not_nil(fp, err)
  fp:write(text)
  fp:close()
end

local function make_root_panel(context)
  local node = { views = {} }
  function node:get_children() return self.views end
  function node:get_node_for_view() return nil end
  local panel = { root_node = node }
  function panel:close_all_views(root_node, keep_view)
    for i = #self.root_node.views, 1, -1 do
      if self.root_node.views[i] ~= keep_view then table.remove(self.root_node.views, i) end
    end
  end
  function panel:open_doc(doc)
    local view = DocView(doc)
    self.root_node.views[#self.root_node.views + 1] = view
    core.active_view = view
    return view
  end
  context.views = node.views
  return panel
end

local function tag_untitled(doc, name, id)
  doc.intellij_untitled = true
  doc.intellij_untitled_name = name or "Untitled-1"
  doc.intellij_untitled_id = id
  doc.crlf = false
  recovery.ensure_doc_backing(doc)
  return doc
end

test.describe("untitled recovery integration", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_docs = core.docs
    context.original_root_panel = core.root_panel
    context.original_active_view = core.active_view
    context.original_nag_view = core.nag_view
    context.original_add_thread = core.add_thread
    context.temp_root = USERDIR
      .. PATHSEP .. "untitled-recovery-ui-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.project_dir = join_path(context.temp_root, "project")
    test.ok(common.mkdirp(context.project_dir))
    core.projects = { Project(context.project_dir) }
    core.docs = {}
    core.active_view = nil
    core.root_panel = make_root_panel(context)
    core.add_thread = function(fn)
      context.threads = context.threads or {}
      context.threads[#context.threads + 1] = fn
      return #context.threads
    end
  end)

  test.after_each(function(context)
    core.projects = context.original_projects
    core.docs = context.original_docs
    core.root_panel = context.original_root_panel
    core.active_view = context.original_active_view
    core.nag_view = context.original_nag_view
    core.add_thread = context.original_add_thread
    if context.project_dir then
      storage.clear("untitled_recovery", context.project_dir)
      local root = recovery.project_paths(context.project_dir).root
      if system.get_file_info(root) then
        local ok, err = common.rm(root, true)
        test.ok(ok, err)
      end
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.test("editing an untitled document writes a backing file without cleaning user dirtiness", function()
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-one")
    doc:insert(1, 1, "hello")

    local flushed, err = recovery.flush_doc(doc, "test", true)
    test.ok(flushed, err)
    test.equal(read_file(doc.intellij_untitled_backing_path), "hello\n")
    test.ok(doc:is_dirty(), "backing snapshot should not mark the untitled document clean")
    test.equal(doc.filename, nil)
    test.equal(doc.abs_filename, nil)
  end)

  test.test("creating an untitled doc allocates backing metadata without publishing manifest", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "created-one")
    local manifest = recovery.load_manifest(context.project_dir)

    test.not_nil(doc.intellij_untitled_backing_path)
    test.equal(system.get_file_info(doc.intellij_untitled_backing_path), nil)
    test.equal(#manifest.docs, 0)
  end)

  test.test("idle flush only writes dirty untitled documents", function()
    local doc1 = tag_untitled(core.open_doc(), "Untitled-1", "dirty-one")
    local doc2 = tag_untitled(core.open_doc(), "Untitled-2", "current-two")
    doc1:insert(1, 1, "one")
    doc2:insert(1, 1, "two")
    test.ok(recovery.flush_doc(doc1, "test", true))
    test.ok(recovery.flush_doc(doc2, "test", true))

    local counts = {}
    local old_replace = recovery.safe_replace_bytes
    recovery.safe_replace_bytes = function(path, bytes, opts)
      counts[path] = (counts[path] or 0) + 1
      return old_replace(path, bytes, opts)
    end
    doc1:insert(1, 4, " dirty")
    recovery.flush_all("idle")
    recovery.safe_replace_bytes = old_replace

    test.equal(counts[doc1.intellij_untitled_backing_path], 1)
    test.equal(counts[doc2.intellij_untitled_backing_path], nil)
  end)

  test.test("force flush verifies untitled docs even when they are not pending dirty", function()
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "force-one")
    doc:insert(1, 1, "force text")
    test.ok(recovery.flush_doc(doc, "test", true))
    local backing = doc.intellij_untitled_backing_path
    test.ok(os.remove(backing))

    recovery.flush_all("force test", true)
    test.equal(read_file(backing), "force text\n")
  end)

  test.test("workspace attach prefers existing manifest backing over stale workspace metadata", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "manifest-good.txt"), "manifest wins\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        { id = "manifest-wins", name = "Untitled-1", backing = "docs" .. PATHSEP .. "manifest-good.txt", crlf = false }
      }
    }))

    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-1",
      intellij_untitled_id = "manifest-wins",
      intellij_untitled_backing = "docs" .. PATHSEP .. "stale-missing.txt",
      intellij_untitled_backing_current = true,
      scroll = { x = 0, y = 0 },
    }
    local view = DocView.from_state(state)
    test.not_nil(view)
    test.equal(view.doc.intellij_untitled_backing_rel, "docs" .. PATHSEP .. "manifest-good.txt")
    test.equal(view.doc:get_text(1, 1, math.huge, math.huge), "manifest wins")
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(manifest.docs[1].backing, "docs" .. PATHSEP .. "manifest-good.txt")
  end)

  test.test("workspace state keeps inline fallback while backing snapshot is stale", function()
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-stale-state")
    doc:insert(1, 1, "first")
    test.ok(recovery.flush_doc(doc, "test", true))
    doc:insert(1, 6, " second")

    local state = DocView(doc):get_state()
    test.equal(state.intellij_untitled, true)
    test.not_nil(state.intellij_untitled_backing)
    test.equal(state.text, "first second")
  end)

  test.test("workspace state stores backing metadata instead of inline text", function()
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-state")
    doc:insert(1, 1, "workspace text")
    test.ok(recovery.flush_doc(doc, "test", true))

    local view = DocView(doc)
    local state = view:get_state()
    test.equal(state.intellij_untitled, true)
    test.equal(state.intellij_untitled_id, "doc-state")
    test.not_nil(state.intellij_untitled_backing)
    test.equal(state.text, nil)
  end)

  test.test("DocView.from_state prefers manifest backing over stale workspace inline fallback", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "newer-backing.txt"), "newer backing text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        {
          id = "stale-workspace-inline",
          name = "Untitled-Stale-Workspace",
          backing = "docs" .. PATHSEP .. "newer-backing.txt",
          crlf = false,
          last_snapshot_change_id = 5,
          updated_at = os.time(),
        }
      }
    }))
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Stale-Workspace",
      intellij_untitled_id = "stale-workspace-inline",
      intellij_untitled_backing = "docs" .. PATHSEP .. "newer-backing.txt",
      intellij_untitled_backing_current = false,
      intellij_untitled_change_id = 3,
      text = "older workspace inline",
      crlf = false,
      scroll = { x = 0, y = 0 },
    }

    local restored = DocView.from_state(state)
    test.not_nil(restored)
    test.equal(restored.doc:get_text(1, 1, math.huge, math.huge), "newer backing text")
    test.equal(read_file(join_path(paths.docs, "newer-backing.txt")), "newer backing text\n")
  end)

  test.test("DocView.from_state prefers inline fallback when backing snapshot is stale", function()
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-stale-restore")
    doc:insert(1, 1, "old")
    test.ok(recovery.flush_doc(doc, "test", true))
    doc:insert(1, 4, " new")
    local state = DocView(doc):get_state()
    test.not_nil(state.text)

    core.docs = {}
    local restored = DocView.from_state(state)
    test.not_nil(restored)
    test.equal(restored.doc:get_text(1, 1, math.huge, math.huge), "old new")
    test.equal(read_file(restored.doc.intellij_untitled_backing_path), "old new\n")
  end)

  test.test("DocView.from_state restores empty backed untitled docs as dirty", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "empty-backed.txt"), "")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        { id = "empty-backed", name = "Untitled-Empty", backing = "docs" .. PATHSEP .. "empty-backed.txt", crlf = false }
      }
    }))
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Empty",
      intellij_untitled_id = "empty-backed",
      intellij_untitled_backing = "docs" .. PATHSEP .. "empty-backed.txt",
      intellij_untitled_backing_current = true,
      scroll = { x = 0, y = 0 },
    }

    local restored = DocView.from_state(state)
    test.not_nil(restored)
    test.equal(restored.doc:get_text(1, 1, math.huge, math.huge), "")
    test.ok(restored.doc:is_dirty(), "empty recovered untitled docs should still require save/discard")
  end)

  test.test("blank forced-dirty untitled tab closes without discard prompt", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-Blank", "blank-close")
    doc.intellij_untitled_force_dirty = true
    test.ok(doc:is_dirty(), "setup should exercise forced dirty restored-empty semantics")
    test.equal(doc:get_text(1, 1, math.huge, math.huge), "")
    local view = core.root_panel:open_doc(doc)
    core.nag_view = {
      show = function()
        error("blank untitled close should not prompt")
      end
    }

    view:try_close(function()
      for i = #context.views, 1, -1 do
        if context.views[i] == view then table.remove(context.views, i) end
      end
    end)

    test.equal(#core.get_views_referencing_doc(doc), 0)
    test.equal(doc.intellij_untitled, nil)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.docs, 0)
  end)

  test.test("DocView.from_state reuses one Doc for multiple views of the same untitled id", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "shared-view.txt"), "shared text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        { id = "shared-view", name = "Untitled-Shared", backing = "docs" .. PATHSEP .. "shared-view.txt", crlf = false }
      }
    }))
    local state1 = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Shared",
      intellij_untitled_id = "shared-view",
      intellij_untitled_backing = "docs" .. PATHSEP .. "shared-view.txt",
      intellij_untitled_backing_current = true,
      selection_state = { selections = { 1, 1, 1, 1 }, last_selection = 1 },
      scroll = { x = 0, y = 0 },
    }
    local state2 = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Shared",
      intellij_untitled_id = "shared-view",
      intellij_untitled_backing = "docs" .. PATHSEP .. "shared-view.txt",
      intellij_untitled_backing_current = true,
      selection_state = { selections = { 1, 3, 1, 3 }, last_selection = 1 },
      scroll = { x = 0, y = 5 },
    }

    local view1 = DocView.from_state(state1)
    local view2 = DocView.from_state(state2)
    test.not_nil(view1)
    test.not_nil(view2)
    test.equal(#core.docs, 1)
    test.equal(view1.doc, view2.doc)
    test.equal(view2.doc:get_text(1, 1, math.huge, math.huge), "shared text")
    test.equal(view2.selection_state.selections[1], 1)
    test.equal(view2.selection_state.selections[2], 3)
  end)

  test.test("DocView.from_state restores backed untitled text", function()
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-restore")
    doc:insert(1, 1, "backed\ntext")
    doc:set_selection(2, 3)
    test.ok(recovery.flush_doc(doc, "test", true))
    local state = DocView(doc):get_state()

    core.docs = {}
    local restored = DocView.from_state(state)
    test.not_nil(restored)
    test.equal(restored.doc.intellij_untitled_id, "doc-restore")
    test.equal(restored.doc:get_text(1, 1, math.huge, math.huge), "backed\ntext")
    local line, col = restored.doc:get_selection()
    test.equal(line, 2)
    test.equal(col, 3)
    test.ok(restored.doc:is_dirty())
  end)

  test.test("project-style close preserves backing recovery instead of discarding", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-project-switch")
    doc:insert(1, 1, "project switch text")
    test.ok(recovery.flush_doc(doc, "test", true))
    local backing = doc.intellij_untitled_backing_path
    local view = core.root_panel:open_doc(doc)

    core.confirm_close_docs({ doc }, function()
      for i = #context.views, 1, -1 do
        if context.views[i] == view then table.remove(context.views, i) end
      end
    end)

    test.not_nil(system.get_file_info(backing))
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.docs, 1)
    test.equal(manifest.docs[1].id, "doc-project-switch")
  end)

  test.test("failed inline workspace migration writes emergency legacy recovery", function()
    local old_replace = recovery.safe_replace_bytes
    recovery.safe_replace_bytes = function() return false, "simulated failure" end
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-1",
      intellij_untitled_id = "workspace-inline-fail",
      intellij_untitled_backing = "docs" .. PATHSEP .. "workspace-inline-fail.txt",
      intellij_untitled_backing_current = false,
      text = "workspace inline text",
      crlf = false,
      scroll = { x = 0, y = 0 },
    }
    local ok, view = pcall(DocView.from_state, state)
    recovery.safe_replace_bytes = old_replace

    test.ok(ok)
    test.not_nil(view)
    local data = storage.load("untitled_recovery", core.root_project().path)
    test.not_nil(data)
    test.equal(data.documents[1].id, "workspace-inline-fail")
    test.equal(data.documents[1].text, "workspace inline text")
  end)

  test.test("legacy inline recovery does not overwrite already-restored backing content", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "emergency-id.txt"), "newer backing text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        { id = "emergency-id", name = "Untitled-Emergency", backing = "docs" .. PATHSEP .. "emergency-id.txt", crlf = false }
      }
    }))
    storage.save("untitled_recovery", context.project_dir, {
      project = context.project_dir,
      documents = {
        { id = "emergency-id", name = "Untitled-Emergency", text = "stale legacy text", crlf = false }
      }
    })

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1]:get_text(1, 1, math.huge, math.huge), "newer backing text")
    test.equal(read_file(join_path(paths.docs, "emergency-id.txt")), "newer backing text\n")
    test.equal(storage.load("untitled_recovery", context.project_dir), nil)
  end)

  test.test("manifest recovery prefers complete temp over older backup when primary is missing", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "crash-id.txt.tmp"), "new temp text\n")
    write_file(join_path(paths.docs, "crash-id.txt.bak"), "old backup text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        { id = "crash-id", name = "Untitled-Crash", backing = "docs" .. PATHSEP .. "crash-id.txt", crlf = false }
      }
    }))

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(core.docs[1]:get_text(1, 1, math.huge, math.huge), "new temp text")
    test.equal(read_file(join_path(paths.docs, "crash-id.txt")), "new temp text\n")
  end)

  test.test("workspace-backed untitled docs are not duplicated when manifest is missing", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "workspace-only.txt"), "workspace backing text\n")
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Workspace",
      intellij_untitled_id = "workspace-only",
      intellij_untitled_backing = "docs" .. PATHSEP .. "workspace-only.txt",
      intellij_untitled_backing_current = true,
      scroll = { x = 0, y = 0 },
    }

    local view = DocView.from_state(state)
    test.not_nil(view)
    test.equal(#core.docs, 1)
    test.equal(view.doc:get_text(1, 1, math.huge, math.huge), "workspace backing text")

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
    test.equal(#core.docs, 1)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.docs, 1)
    test.equal(manifest.docs[1].id, "workspace-only")
  end)

  test.test("legacy inline recovery does not overwrite workspace-restored inline text", function(context)
    storage.save("untitled_recovery", context.project_dir, {
      project = context.project_dir,
      documents = {
        { id = "workspace-vs-legacy", name = "Untitled-Workspace", text = "stale legacy", crlf = false }
      }
    })
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Workspace",
      intellij_untitled_id = "workspace-vs-legacy",
      intellij_untitled_backing = "docs" .. PATHSEP .. "workspace-vs-legacy.txt",
      intellij_untitled_backing_current = false,
      text = "fresh workspace",
      crlf = false,
      scroll = { x = 0, y = 0 },
    }

    local view = DocView.from_state(state)
    test.not_nil(view)
    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
    test.equal(#core.docs, 1)
    test.equal(view.doc:get_text(1, 1, math.huge, math.huge), "fresh workspace")
    test.equal(read_file(view.doc.intellij_untitled_backing_path), "fresh workspace\n")
    test.equal(storage.load("untitled_recovery", context.project_dir), nil)
  end)

  test.test("manifest restore honors stored backing path", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "custom-backing.txt"), "custom path text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      docs = {
        { id = "custom-id", name = "Untitled-Custom", backing = "docs" .. PATHSEP .. "custom-backing.txt", crlf = false }
      }
    }))

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1].intellij_untitled_backing_rel, "docs" .. PATHSEP .. "custom-backing.txt")
    test.equal(core.docs[1]:get_text(1, 1, math.huge, math.huge), "custom path text")
  end)

  test.test("orphan recovery prefers primary over stale backup", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.docs))
    write_file(join_path(paths.docs, "orphan-one.txt"), "good primary\n")
    write_file(join_path(paths.docs, "orphan-one.txt.bak"), "stale backup\n")

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1]:get_text(1, 1, math.huge, math.huge), "good primary")
    test.equal(read_file(join_path(paths.docs, "orphan-one.txt")), "good primary\n")
  end)

  test.test("manifest restore recovers untitled content without workspace state", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-manifest")
    doc:insert(1, 1, "manifest text")
    test.ok(recovery.flush_doc(doc, "test", true))

    core.docs = {}
    context.views = {}
    core.root_panel = make_root_panel(context)

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1].intellij_untitled_id, "doc-manifest")
    test.equal(core.docs[1]:get_text(1, 1, math.huge, math.huge), "manifest text")
    test.ok(core.docs[1]:is_dirty())
  end)

  test.test("explicit close cleanup happens only after close succeeds", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-close")
    test.ok(recovery.flush_doc(doc, "test", true))
    local backing = doc.intellij_untitled_backing_path
    local view = core.root_panel:open_doc(doc)
    write_file(backing .. ".bak", "backup")

    local old_close_all = core.root_panel.close_all_views
    core.root_panel.close_all_views = function() error("close failed") end
    local ok = pcall(core.confirm_close_docs, { doc }, core.root_panel.close_all_views, core.root_panel)
    core.root_panel.close_all_views = old_close_all
    test.equal(ok, false)
    test.not_nil(system.get_file_info(backing))
    test.not_nil(system.get_file_info(backing .. ".bak"))

    core.confirm_close_docs({ doc }, core.root_panel.close_all_views, core.root_panel)
    test.equal(system.get_file_info(backing), nil)
    test.equal(system.get_file_info(backing .. ".bak"), nil)
    recovery.flush_all("after discard regression")
    test.equal(system.get_file_info(backing), nil)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.docs, 0)
  end)

  test.test("failed Save As cleanup tombstones leftover backing so it is not recovered as orphan", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "save-cleanup-fail")
    doc:insert(1, 1, "leftover")
    test.ok(recovery.flush_doc(doc, "test", true))
    local old = {
      id = doc.intellij_untitled_id,
      name = doc.intellij_untitled_name,
      backing_path = doc.intellij_untitled_backing_path,
      backing_rel = doc.intellij_untitled_backing_rel,
      project = doc.intellij_untitled_project_path,
    }
    local old_remove = os.remove
    os.remove = function(path)
      if path == old.backing_path then return nil, "simulated remove failure" end
      return old_remove(path)
    end
    local cleaned = recovery.handle_save_as_success(doc, old)
    os.remove = old_remove

    test.equal(cleaned, false)
    test.not_nil(system.get_file_info(old.backing_path))
    core.docs = {}
    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
  end)

  test.test("failed discard quarantine tombstones leftover backing so it is not recovered as orphan", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "discard-cleanup-fail")
    doc:insert(1, 1, "leftover discard")
    test.ok(recovery.flush_doc(doc, "test", true))
    local backing = doc.intellij_untitled_backing_path
    local old_rename = os.rename
    os.rename = function(src, dst)
      if src == backing then return nil, "simulated rename failure" end
      return old_rename(src, dst)
    end
    recovery.handle_confirmed_discard(doc)
    os.rename = old_rename

    test.not_nil(system.get_file_info(backing))
    core.docs = {}
    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
  end)

  test.test("Save As removes backing metadata and manifest entry after a successful file save", function(context)
    local doc = tag_untitled(core.open_doc(), "Untitled-1", "doc-save-as")
    doc:insert(1, 1, "saved text")
    test.ok(recovery.flush_doc(doc, "test", true))
    local backing = doc.intellij_untitled_backing_path
    write_file(backing .. ".tmp", "stale temp")
    write_file(backing .. ".bak", "stale backup")

    local target = join_path(context.project_dir, "saved.txt")
    doc:save("saved.txt", target)

    test.equal(read_file(target), "saved text\n")
    test.equal(system.get_file_info(backing), nil)
    test.equal(system.get_file_info(backing .. ".tmp"), nil)
    test.equal(system.get_file_info(backing .. ".bak"), nil)
    test.equal(doc.intellij_untitled, nil)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.docs, 0)
  end)

  test.test("failed legacy inline recovery migration does not clear old storage", function(context)
    storage.save("untitled_recovery", context.project_dir, {
      project = context.project_dir,
      documents = {
        { id = "legacy-fail", name = "Untitled-10", text = "legacy fail", crlf = false }
      }
    })
    local old_replace = recovery.safe_replace_bytes
    recovery.safe_replace_bytes = function() return false, "simulated failure" end
    local ok, restored_count = pcall(recovery.restore_project, context.project_dir)
    recovery.safe_replace_bytes = old_replace

    test.ok(ok)
    test.equal(restored_count, 0)
    test.not_nil(storage.load("untitled_recovery", context.project_dir))
  end)

  test.test("legacy inline recovery is cleared after successful migration", function(context)
    storage.save("untitled_recovery", context.project_dir, {
      project = context.project_dir,
      documents = {
        { id = "legacy-one", name = "Untitled-9", text = "legacy text", crlf = false }
      }
    })

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(storage.load("untitled_recovery", context.project_dir), nil)
    test.equal(#core.docs, 1)
    test.equal(core.docs[1].intellij_untitled_id, "legacy-one")
    test.equal(core.docs[1]:get_text(1, 1, math.huge, math.huge), "legacy text")
  end)
end)
