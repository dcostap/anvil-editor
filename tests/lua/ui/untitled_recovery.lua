local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local Editor = require "core.editor"
local BufferRegistry = require "core.buffer_registry"
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
  local panel = { views = {} }
  function panel:close_all_views(keep_view)
    for i = #self.views, 1, -1 do
      if self.views[i] ~= keep_view then table.remove(self.views, i) end
    end
  end
  function panel:open_buffer(buffer, opts)
    opts = opts or {}
    local view = Editor(buffer)
    self.views[#self.views + 1] = view
    context.open_options = context.open_options or {}
    context.open_options[#context.open_options + 1] = opts
    core.active_view = view
    return view
  end
  context.views = panel.views
  return panel
end

local function tag_untitled(buffer, name, id)
  buffer.intellij_untitled = true
  buffer.intellij_untitled_name = name or "Untitled-1"
  buffer.intellij_untitled_id = id
  buffer.crlf = false
  recovery.ensure_buffer_backing(buffer)
  return buffer
end

test.describe("untitled recovery integration", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_buffers = core.buffers
    context.original_buffer_registry = core.buffer_registry
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
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
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
    core.buffers = context.original_buffers
    core.buffer_registry = context.original_buffer_registry
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

  test.test("editing an untitled buffer writes a backing file without cleaning user dirtiness", function()
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-one")
    buffer:insert(1, 1, "hello")

    local flushed, err = recovery.flush_buffer(buffer, "test", true)
    test.ok(flushed, err)
    test.equal(read_file(buffer.intellij_untitled_backing_path), "hello\n")
    test.ok(buffer:is_dirty(), "backing snapshot should not mark the untitled buffer clean")
    test.equal(buffer.filename, nil)
    test.equal(buffer.abs_filename, nil)
  end)

  test.test("creating an untitled buffer allocates backing metadata without publishing manifest", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "created-one")
    local manifest = recovery.load_manifest(context.project_dir)

    test.not_nil(buffer.intellij_untitled_backing_path)
    test.equal(system.get_file_info(buffer.intellij_untitled_backing_path), nil)
    test.equal(#manifest.buffers, 0)
  end)

  test.test("idle flush only writes dirty Untitled Buffers", function()
    local buffer1 = tag_untitled(core.open_buffer(), "Untitled-1", "dirty-one")
    local buffer2 = tag_untitled(core.open_buffer(), "Untitled-2", "current-two")
    buffer1:insert(1, 1, "one")
    buffer2:insert(1, 1, "two")
    test.ok(recovery.flush_buffer(buffer1, "test", true))
    test.ok(recovery.flush_buffer(buffer2, "test", true))

    local counts = {}
    local old_replace = recovery.safe_replace_bytes
    recovery.safe_replace_bytes = function(path, bytes, opts)
      counts[path] = (counts[path] or 0) + 1
      return old_replace(path, bytes, opts)
    end
    buffer1:insert(1, 4, " dirty")
    recovery.flush_all("idle")
    recovery.safe_replace_bytes = old_replace

    test.equal(counts[buffer1.intellij_untitled_backing_path], 1)
    test.equal(counts[buffer2.intellij_untitled_backing_path], nil)
  end)

  test.test("force flush verifies untitled buffers even when they are not pending dirty", function()
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "force-one")
    buffer:insert(1, 1, "force text")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local backing = buffer.intellij_untitled_backing_path
    test.ok(os.remove(backing))

    recovery.flush_all("force test", true)
    test.equal(read_file(backing), "force text\n")
  end)

  test.test("workspace attach prefers existing manifest backing over stale workspace metadata", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "manifest-good.txt"), "manifest wins\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "manifest-wins", name = "Untitled-1", backing = "buffers" .. PATHSEP .. "manifest-good.txt", crlf = false }
      }
    }))

    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-1",
      intellij_untitled_id = "manifest-wins",
      intellij_untitled_backing = "buffers" .. PATHSEP .. "stale-missing.txt",
      intellij_untitled_backing_current = true,
      scroll = { x = 0, y = 0 },
    }
    local view = Editor.from_state(state)
    test.not_nil(view)
    test.equal(view.buffer.intellij_untitled_backing_rel, "buffers" .. PATHSEP .. "manifest-good.txt")
    test.equal(view.buffer:get_text(1, 1, math.huge, math.huge), "manifest wins")
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(manifest.buffers[1].backing, "buffers" .. PATHSEP .. "manifest-good.txt")
  end)

  test.test("workspace state keeps inline fallback while backing snapshot is stale", function()
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-stale-state")
    buffer:insert(1, 1, "first")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    buffer:insert(1, 6, " second")

    local state = Editor(buffer):get_state()
    test.equal(state.intellij_untitled, true)
    test.not_nil(state.intellij_untitled_backing)
    test.equal(state.text, "first second")
  end)

  test.test("workspace state stores backing metadata instead of inline text", function()
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-state")
    buffer:insert(1, 1, "workspace text")
    test.ok(recovery.flush_buffer(buffer, "test", true))

    local view = Editor(buffer)
    local state = view:get_state()
    test.equal(state.intellij_untitled, true)
    test.equal(state.intellij_untitled_id, "buffer-state")
    test.not_nil(state.intellij_untitled_backing)
    test.equal(state.text, nil)
  end)

  test.test("Editor.from_state prefers manifest backing over stale workspace inline fallback", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "newer-backing.txt"), "newer backing text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        {
          id = "stale-workspace-inline",
          name = "Untitled-Stale-Workspace",
          backing = "buffers" .. PATHSEP .. "newer-backing.txt",
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
      intellij_untitled_backing = "buffers" .. PATHSEP .. "newer-backing.txt",
      intellij_untitled_backing_current = false,
      intellij_untitled_change_id = 3,
      text = "older workspace inline",
      crlf = false,
      scroll = { x = 0, y = 0 },
    }

    local restored = Editor.from_state(state)
    test.not_nil(restored)
    test.equal(restored.buffer:get_text(1, 1, math.huge, math.huge), "newer backing text")
    test.equal(read_file(join_path(paths.buffers, "newer-backing.txt")), "newer backing text\n")
  end)

  test.test("Editor.from_state prefers inline fallback when backing snapshot is stale", function()
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-stale-restore")
    buffer:insert(1, 1, "old")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    buffer:insert(1, 4, " new")
    local state = Editor(buffer):get_state()
    test.not_nil(state.text)

    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    local restored = Editor.from_state(state)
    test.not_nil(restored)
    test.equal(restored.buffer:get_text(1, 1, math.huge, math.huge), "old new")
    test.equal(read_file(restored.buffer.intellij_untitled_backing_path), "old new\n")
  end)

  test.test("Editor.from_state restores empty backed untitled buffers as dirty", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "empty-backed.txt"), "")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "empty-backed", name = "Untitled-Empty", backing = "buffers" .. PATHSEP .. "empty-backed.txt", crlf = false }
      }
    }))
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Empty",
      intellij_untitled_id = "empty-backed",
      intellij_untitled_backing = "buffers" .. PATHSEP .. "empty-backed.txt",
      intellij_untitled_backing_current = true,
      scroll = { x = 0, y = 0 },
    }

    local restored = Editor.from_state(state)
    test.not_nil(restored)
    test.equal(restored.buffer:get_text(1, 1, math.huge, math.huge), "")
    test.ok(restored.buffer:is_dirty(), "empty recovered untitled buffers should still require save/discard")
  end)

  test.test("blank forced-dirty untitled Pane closes without discard prompt", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-Blank", "blank-close")
    buffer.intellij_untitled_force_dirty = true
    test.ok(buffer:is_dirty(), "setup should exercise forced dirty restored-empty semantics")
    test.equal(buffer:get_text(1, 1, math.huge, math.huge), "")
    local view = core.root_panel:open_buffer(buffer)
    core.nag_view = {
      show = function()
        error("blank untitled close should not prompt")
      end
    }
    local prompt_bar = core.global_prompt_bar
    core.global_prompt_bar = {
      enter = function()
        error("blank untitled close should not prompt")
      end,
    }
    local ok, err = pcall(function()
      view:can_close(function()
        view:on_close()
        for i = #context.views, 1, -1 do
          if context.views[i] == view then table.remove(context.views, i) end
        end
      end)
    end)
    core.global_prompt_bar = prompt_bar
    test.ok(ok, err)

    test.equal(#core.get_views_referencing_buffer(buffer), 0)
    test.equal(buffer.intellij_untitled, nil)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.buffers, 0)
  end)

  test.test("Editor.from_state reuses one Buffer for multiple views of the same untitled id", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "shared-view.txt"), "shared text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "shared-view", name = "Untitled-Shared", backing = "buffers" .. PATHSEP .. "shared-view.txt", crlf = false }
      }
    }))
    local state1 = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Shared",
      intellij_untitled_id = "shared-view",
      intellij_untitled_backing = "buffers" .. PATHSEP .. "shared-view.txt",
      intellij_untitled_backing_current = true,
      selection_state = { selections = { 1, 1, 1, 1 }, last_selection = 1 },
      scroll = { x = 0, y = 0 },
    }
    local state2 = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Shared",
      intellij_untitled_id = "shared-view",
      intellij_untitled_backing = "buffers" .. PATHSEP .. "shared-view.txt",
      intellij_untitled_backing_current = true,
      selection_state = { selections = { 1, 3, 1, 3 }, last_selection = 1 },
      scroll = { x = 0, y = 5 },
    }

    local view1 = Editor.from_state(state1)
    local view2 = Editor.from_state(state2)
    test.not_nil(view1)
    test.not_nil(view2)
    test.equal(#core.buffers, 1)
    test.equal(view1.buffer, view2.buffer)
    test.equal(view2.buffer:get_text(1, 1, math.huge, math.huge), "shared text")
    test.equal(view2.selection_state.selections[1], 1)
    test.equal(view2.selection_state.selections[2], 3)
  end)

  test.test("Editor.from_state restores backed untitled text", function()
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-restore")
    buffer:insert(1, 1, "backed\ntext")
    buffer:set_selection(2, 3)
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local state = Editor(buffer):get_state()

    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    local restored = Editor.from_state(state)
    test.not_nil(restored)
    test.equal(restored.buffer.intellij_untitled_id, "buffer-restore")
    test.equal(restored.buffer:get_text(1, 1, math.huge, math.huge), "backed\ntext")
    local line, col = restored.buffer:get_selection()
    test.equal(line, 2)
    test.equal(col, 3)
    test.ok(restored.buffer:is_dirty())
  end)

  test.test("project-style close preserves backing recovery instead of discarding", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-project-switch")
    buffer:insert(1, 1, "project switch text")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local backing = buffer.intellij_untitled_backing_path
    local view = core.root_panel:open_buffer(buffer)

    core.confirm_close_buffers({ buffer }, function()
      for i = #context.views, 1, -1 do
        if context.views[i] == view then table.remove(context.views, i) end
      end
    end)

    test.not_nil(system.get_file_info(backing))
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.buffers, 1)
    test.equal(manifest.buffers[1].id, "buffer-project-switch")
  end)

  test.test("failed inline workspace migration writes emergency legacy recovery", function()
    local old_replace = recovery.safe_replace_bytes
    recovery.safe_replace_bytes = function() return false, "simulated failure" end
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-1",
      intellij_untitled_id = "workspace-inline-fail",
      intellij_untitled_backing = "buffers" .. PATHSEP .. "workspace-inline-fail.txt",
      intellij_untitled_backing_current = false,
      text = "workspace inline text",
      crlf = false,
      scroll = { x = 0, y = 0 },
    }
    local ok, view = pcall(Editor.from_state, state)
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
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "emergency-id.txt"), "newer backing text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "emergency-id", name = "Untitled-Emergency", backing = "buffers" .. PATHSEP .. "emergency-id.txt", crlf = false }
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
    test.equal(#core.buffers, 1)
    test.equal(core.buffers[1]:get_text(1, 1, math.huge, math.huge), "newer backing text")
    test.equal(read_file(join_path(paths.buffers, "emergency-id.txt")), "newer backing text\n")
    test.equal(storage.load("untitled_recovery", context.project_dir), nil)
  end)

  test.test("manifest recovery prefers complete temp over older backup when primary is missing", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "crash-id.txt.tmp"), "new temp text\n")
    write_file(join_path(paths.buffers, "crash-id.txt.bak"), "old backup text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "crash-id", name = "Untitled-Crash", backing = "buffers" .. PATHSEP .. "crash-id.txt", crlf = false }
      }
    }))

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(core.buffers[1]:get_text(1, 1, math.huge, math.huge), "new temp text")
    test.equal(read_file(join_path(paths.buffers, "crash-id.txt")), "new temp text\n")
  end)

  test.it("opens each recovered buffer for simultaneous work", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "first.txt"), "first recovery\n")
    write_file(join_path(paths.buffers, "second.txt"), "second recovery\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "first", name = "Untitled-1", backing = "buffers" .. PATHSEP .. "first.txt" },
        { id = "second", name = "Untitled-2", backing = "buffers" .. PATHSEP .. "second.txt" },
      }
    }))

    test.equal(recovery.restore_project(context.project_dir), 2)
    test.equal(#context.views, 2)
    test.equal(context.views[1].buffer.intellij_untitled_id, "first")
    test.equal(context.views[2].buffer.intellij_untitled_id, "second")
    test.equal(context.views[1]:get_name(), "Untitled-1*")
    test.equal(context.views[2]:get_name(), "Untitled-2*")
    test.equal(context.open_options[1].placement, "new")
    test.equal(context.open_options[2].placement, "new")
  end)

  test.it("loads recovery manifests saved before the Buffer naming cut", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.root))
    write_file(paths.manifest, [[return {
      version = 1,
      project = "]] .. context.project_dir:gsub("\\", "\\\\") .. [[",
      docs = {
        { id = "old-id", name = "Untitled-Old", backing = "buffers\\old-id.txt" }
      }
    }]])

    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.buffers, 1)
    test.equal(manifest.buffers[1].id, "old-id")
    test.equal(manifest.docs, nil)
  end)

  test.test("workspace-backed untitled buffers are not duplicated when manifest is missing", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "workspace-only.txt"), "workspace backing text\n")
    local state = {
      intellij_untitled = true,
      intellij_untitled_name = "Untitled-Workspace",
      intellij_untitled_id = "workspace-only",
      intellij_untitled_backing = "buffers" .. PATHSEP .. "workspace-only.txt",
      intellij_untitled_backing_current = true,
      scroll = { x = 0, y = 0 },
    }

    local view = Editor.from_state(state)
    test.not_nil(view)
    test.equal(#core.buffers, 1)
    test.equal(view.buffer:get_text(1, 1, math.huge, math.huge), "workspace backing text")

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
    test.equal(#core.buffers, 1)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.buffers, 1)
    test.equal(manifest.buffers[1].id, "workspace-only")
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
      intellij_untitled_backing = "buffers" .. PATHSEP .. "workspace-vs-legacy.txt",
      intellij_untitled_backing_current = false,
      text = "fresh workspace",
      crlf = false,
      scroll = { x = 0, y = 0 },
    }

    local view = Editor.from_state(state)
    test.not_nil(view)
    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
    test.equal(#core.buffers, 1)
    test.equal(view.buffer:get_text(1, 1, math.huge, math.huge), "fresh workspace")
    test.equal(read_file(view.buffer.intellij_untitled_backing_path), "fresh workspace\n")
    test.equal(storage.load("untitled_recovery", context.project_dir), nil)
  end)

  test.test("manifest restore honors stored backing path", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "custom-backing.txt"), "custom path text\n")
    test.ok(recovery.save_manifest(context.project_dir, {
      buffers = {
        { id = "custom-id", name = "Untitled-Custom", backing = "buffers" .. PATHSEP .. "custom-backing.txt", crlf = false }
      }
    }))

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.buffers, 1)
    test.equal(core.buffers[1].intellij_untitled_backing_rel, "buffers" .. PATHSEP .. "custom-backing.txt")
    test.equal(core.buffers[1]:get_text(1, 1, math.huge, math.huge), "custom path text")
  end)

  test.test("orphan recovery prefers primary over stale backup", function(context)
    local paths = recovery.project_paths(context.project_dir)
    test.ok(common.mkdirp(paths.buffers))
    write_file(join_path(paths.buffers, "orphan-one.txt"), "good primary\n")
    write_file(join_path(paths.buffers, "orphan-one.txt.bak"), "stale backup\n")

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.buffers, 1)
    test.equal(core.buffers[1]:get_text(1, 1, math.huge, math.huge), "good primary")
    test.equal(read_file(join_path(paths.buffers, "orphan-one.txt")), "good primary\n")
  end)

  test.test("manifest restore recovers untitled content without workspace state", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-manifest")
    buffer:insert(1, 1, "manifest text")
    test.ok(recovery.flush_buffer(buffer, "test", true))

    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    context.views = {}
    core.root_panel = make_root_panel(context)

    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 1)
    test.equal(#core.buffers, 1)
    test.equal(core.buffers[1].intellij_untitled_id, "buffer-manifest")
    test.equal(core.buffers[1]:get_text(1, 1, math.huge, math.huge), "manifest text")
    test.ok(core.buffers[1]:is_dirty())
  end)

  test.test("explicit close cleanup happens only after close succeeds", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-close")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local backing = buffer.intellij_untitled_backing_path
    local view = core.root_panel:open_buffer(buffer)
    write_file(backing .. ".bak", "backup")

    local old_close_all = core.root_panel.close_all_views
    core.root_panel.close_all_views = function() error("close failed") end
    local ok = pcall(core.confirm_close_buffers, { buffer }, core.root_panel.close_all_views, core.root_panel)
    core.root_panel.close_all_views = old_close_all
    test.equal(ok, false)
    test.not_nil(system.get_file_info(backing))
    test.not_nil(system.get_file_info(backing .. ".bak"))

    core.confirm_close_buffers({ buffer }, core.root_panel.close_all_views, core.root_panel)
    test.equal(system.get_file_info(backing), nil)
    test.equal(system.get_file_info(backing .. ".bak"), nil)
    recovery.flush_all("after discard regression")
    test.equal(system.get_file_info(backing), nil)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.buffers, 0)
  end)

  test.test("failed Save As cleanup tombstones leftover backing so it is not recovered as orphan", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "save-cleanup-fail")
    buffer:insert(1, 1, "leftover")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local old = {
      id = buffer.intellij_untitled_id,
      name = buffer.intellij_untitled_name,
      backing_path = buffer.intellij_untitled_backing_path,
      backing_rel = buffer.intellij_untitled_backing_rel,
      project = buffer.intellij_untitled_project_path,
    }
    local old_remove = os.remove
    os.remove = function(path)
      if path == old.backing_path then return nil, "simulated remove failure" end
      return old_remove(path)
    end
    local cleaned = recovery.handle_save_as_success(buffer, old)
    os.remove = old_remove

    test.equal(cleaned, false)
    test.not_nil(system.get_file_info(old.backing_path))
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
  end)

  test.test("failed discard quarantine tombstones leftover backing so it is not recovered as orphan", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "discard-cleanup-fail")
    buffer:insert(1, 1, "leftover discard")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local backing = buffer.intellij_untitled_backing_path
    local old_rename = os.rename
    os.rename = function(src, dst)
      if src == backing then return nil, "simulated rename failure" end
      return old_rename(src, dst)
    end
    recovery.handle_confirmed_discard(buffer)
    os.rename = old_rename

    test.not_nil(system.get_file_info(backing))
    core.buffers = {}
    core.buffer_registry = BufferRegistry(core.buffers)
    local restored_count = recovery.restore_project(context.project_dir)
    test.equal(restored_count, 0)
  end)

  test.test("Save As removes backing metadata and manifest entry after a successful file save", function(context)
    local buffer = tag_untitled(core.open_buffer(), "Untitled-1", "buffer-save-as")
    buffer:insert(1, 1, "saved text")
    test.ok(recovery.flush_buffer(buffer, "test", true))
    local backing = buffer.intellij_untitled_backing_path
    write_file(backing .. ".tmp", "stale temp")
    write_file(backing .. ".bak", "stale backup")

    local target = join_path(context.project_dir, "saved.txt")
    buffer:save("saved.txt", target)

    test.equal(read_file(target), "saved text\n")
    test.equal(system.get_file_info(backing), nil)
    test.equal(system.get_file_info(backing .. ".tmp"), nil)
    test.equal(system.get_file_info(backing .. ".bak"), nil)
    test.equal(buffer.intellij_untitled, nil)
    local manifest = recovery.load_manifest(context.project_dir)
    test.equal(#manifest.buffers, 0)
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
    test.equal(#core.buffers, 1)
    test.equal(core.buffers[1].intellij_untitled_id, "legacy-one")
    test.equal(core.buffers[1]:get_text(1, 1, math.huge, math.huge), "legacy text")
  end)
end)
