local Buffer = require "core.buffer"
local common = require "core.common"
local core = require "core"
local Editor = require "core.editor"
local test = require "core.test"

local autosave_fast = require "plugins.autosave_fast"

local function read_file(path)
  local fp = assert(io.open(path, "rb"))
  local text = fp:read("*a")
  fp:close()
  return text
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
end

test.describe("Autosave Pane close", function()
  test.before_each(function(context)
    context.path = system.absolute_path(USERDIR .. PATHSEP
      .. "autosave-pane-close-" .. system.get_process_id() .. ".txt")
    context.prompt_enter = core.global_prompt_bar.enter
    context.nag_show = core.nag_view.show
    pcall(os.remove, context.path)
    write_file(context.path, "original\n")
  end)

  test.after_each(function(context)
    core.global_prompt_bar.enter = context.prompt_enter
    core.nag_view.show = context.nag_show
    if context.view then context.view:on_close() end
    if context.buffer and core.buffer_registry then
      core.buffer_registry:remove(context.buffer, true)
    elseif context.buffer then
      context.buffer:on_close()
    end
    pcall(os.remove, context.path)
  end)

  test.it("saves a dirty named Buffer before Pane close approval", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "changed ")
    test.ok(buffer:is_dirty())

    local prompted = false
    core.global_prompt_bar.enter = function() prompted = true end
    local approved = false
    view:can_close(function() approved = true end)

    test.ok(approved, "expected close approval after autosave")
    test.not_ok(prompted, "did not expect the unsaved-changes prompt")
    test.not_ok(buffer:is_dirty(), "expected autosave to clean the Buffer")
    test.equal(read_file(context.path), "changed original\n")
  end)

  test.it("keeps close pending when autosave detects a disk conflict", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")
    write_file(context.path, "external replacement\n")

    local prompt_title, resolve_prompt
    core.nag_view.show = function(_, title, _, _, callback)
      prompt_title = title
      resolve_prompt = callback
    end
    local unsaved_prompt = false
    core.global_prompt_bar.enter = function() unsaved_prompt = true end
    local approved = false
    view:can_close(function() approved = true end)

    test.not_ok(approved)
    test.not_ok(unsaved_prompt, "expected the conflict prompt to own close resolution")
    test.equal(prompt_title, "File Changed on Disk")
    test.equal(read_file(context.path), "external replacement\n")
    resolve_prompt({ text = "Cancel" })
    test.ok(view:get_name():find("*", 1, true), "cancelled conflict should expose unsaved state")
  end)
end)

test.describe("Autosave save failures", function()
  test.before_each(function(context)
    context.path = system.absolute_path(USERDIR .. PATHSEP
      .. "autosave-retry-" .. system.get_process_id() .. ".txt")
    context.timeout = autosave_fast.timeout
    context.enabled = autosave_fast.enabled
    pcall(os.remove, context.path)
    write_file(context.path, "original\n")
  end)

  test.after_each(function(context)
    autosave_fast.timeout = context.timeout
    autosave_fast.enabled = context.enabled
    if context.view then context.view:on_close() end
    if context.buffer and core.buffer_registry then
      core.buffer_registry:remove(context.buffer, true)
    elseif context.buffer then
      context.buffer:on_close()
    end
    pcall(os.remove, context.path)
  end)

  test.it("hides pending saves, exposes failures, and retries without more input", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    local real_save = Buffer.save
    local save_calls = 0
    buffer.save = function(self, ...)
      save_calls = save_calls + 1
      if save_calls == 1 then error("simulated transient save failure") end
      return real_save(self, ...)
    end
    autosave_fast.timeout = 0.01

    buffer:insert(1, 1, "changed ")
    test.not_ok(view:get_name():find("*", 1, true), "pending autosave should stay invisible")
    test.not_ok(core.get_view_title(view):find("*", 1, true), "window title should stay clean")

    test.equal(autosave_fast.save_all_dirty("test failure"), 0)
    test.ok(buffer:is_dirty())
    test.ok(view:get_name():find("*", 1, true), "failed autosave should expose unsaved state")

    local deadline = system.get_time() + 1
    while buffer:is_dirty() and system.get_time() < deadline do coroutine.yield(0.01) end

    test.ok(save_calls >= 2, "expected an automatic retry")
    test.not_ok(buffer:is_dirty(), "expected retry to save the Buffer")
    test.equal(read_file(context.path), "changed original\n")
    test.not_ok(view:get_name():find("*", 1, true), "successful retry should clear the marker")
  end)

  test.it("exposes a manual save failure", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    local sync_file = system.sync_file
    system.sync_file = function() return false, "simulated manual save failure" end

    buffer:insert(1, 1, "changed ")
    local ok = pcall(buffer.save, buffer)
    system.sync_file = sync_file

    test.not_ok(ok)
    test.ok(buffer:is_dirty())
    test.ok(view:get_name():find("*", 1, true), "failed manual save should expose unsaved state")
  end)

  test.it("stops a pending retry when Autosave is disabled", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    local real_save = buffer.save
    buffer.save = function() error("simulated save failure") end
    autosave_fast.timeout = 0.01

    buffer:insert(1, 1, "changed ")
    autosave_fast.save_all_dirty("disable after failure")
    autosave_fast.enabled = false
    coroutine.yield(0.1)
    buffer.save = real_save

    test.ok(buffer:is_dirty())
    test.ok(view:get_name():find("*", 1, true))
  end)

  test.it("does not overwrite a new file created by another process", function(context)
    pcall(os.remove, context.path)
    local buffer = Buffer(context.path, context.path, true)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil text")
    write_file(context.path, "external text\n")

    local prompt_title
    core.nag_view.show = function(_, title) prompt_title = title end
    local saved = autosave_fast.save_all_dirty("new target collision")

    test.equal(saved, 0)
    test.equal(read_file(context.path), "external text\n")
    test.ok(buffer:is_dirty())
    test.equal(prompt_title, "File Changed on Disk")
  end)

  test.it("does not overwrite a file when its current snapshot cannot be read", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")

    local prompt_title
    core.nag_view.show = function(_, title) prompt_title = title end
    local open = io.open
    io.open = function(path, mode)
      if path == context.path and mode == "rb" then
        return nil, "simulated snapshot read failure"
      end
      return open(path, mode)
    end
    local saved = autosave_fast.save_all_dirty("unreadable snapshot")
    io.open = open

    test.equal(saved, 0)
    test.equal(read_file(context.path), "original\n")
    test.ok(buffer:is_dirty())
    test.equal(prompt_title, "File Changed on Disk")
  end)

  test.it("overwrites the disk after explicit conflict approval", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")
    write_file(context.path, "external replacement\n")

    local resolve_prompt
    core.nag_view.show = function(_, _, _, _, callback) resolve_prompt = callback end
    autosave_fast.save_all_dirty("approved conflict")
    test.not_nil(resolve_prompt)
    resolve_prompt({ text = "Overwrite Disk" })

    test.equal(read_file(context.path), "Anvil original\n")
    test.not_ok(buffer:is_dirty())
  end)

  test.it("asks again when the disk changes after overwrite approval was requested", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")
    write_file(context.path, "first external replacement\n")

    local prompts = {}
    core.nag_view.show = function(_, title, _, _, callback)
      prompts[#prompts + 1] = { title = title, resolve = callback }
    end
    autosave_fast.save_all_dirty("changing conflict")
    test.equal(#prompts, 1)

    write_file(context.path, "second external replacement\n")
    prompts[1].resolve({ text = "Overwrite Disk" })

    test.equal(read_file(context.path), "second external replacement\n")
    test.ok(buffer:is_dirty())
    test.equal(#prompts, 2)
    test.equal(prompts[2].title, "File Changed on Disk")
  end)

  test.it("rechecks the disk while writing an approved overwrite", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")
    write_file(context.path, "first external replacement\n")

    local prompts = {}
    core.nag_view.show = function(_, title, _, _, callback)
      prompts[#prompts + 1] = { title = title, resolve = callback }
    end
    autosave_fast.save_all_dirty("approved changing conflict")
    test.equal(#prompts, 1)

    local sync_file = system.sync_file
    local changed = false
    system.sync_file = function(file)
      local ok, err = sync_file(file)
      if ok and not changed then
        changed = true
        write_file(context.path, "second external replacement\n")
      end
      return ok, err
    end
    prompts[1].resolve({ text = "Overwrite Disk" })
    system.sync_file = sync_file

    test.equal(read_file(context.path), "second external replacement\n")
    test.ok(buffer:is_dirty())
    test.equal(#prompts, 2)
    test.equal(prompts[2].title, "File Changed on Disk")
  end)

  test.it("rechecks the disk after writing temporary content", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    buffer:insert(1, 1, "Anvil ")

    local prompt_title
    core.nag_view.show = function(_, title) prompt_title = title end
    local sync_file = system.sync_file
    local changed = false
    system.sync_file = function(file)
      local ok, err = sync_file(file)
      if ok and not changed then
        changed = true
        write_file(context.path, "external replacement\n")
      end
      return ok, err
    end
    local saved = autosave_fast.save_all_dirty("late conflict")
    system.sync_file = sync_file

    test.equal(saved, 0)
    test.equal(read_file(context.path), "external replacement\n")
    test.ok(buffer:is_dirty())
    test.equal(prompt_title, "File Changed on Disk")
  end)

  test.it("stops automatic retries after a persistent failure", function(context)
    local buffer = Buffer(context.path, context.path, false)
    context.buffer = buffer
    local view = Editor(buffer)
    context.view = view
    local real_save = buffer.save
    local save_calls = 0
    buffer.save = function()
      save_calls = save_calls + 1
      error("simulated persistent save failure")
    end
    autosave_fast.timeout = 0.01
    buffer:insert(1, 1, "changed ")
    autosave_fast.save_all_dirty("persistent failure")

    local deadline = system.get_time() + 0.6
    while system.get_time() < deadline do coroutine.yield(0.02) end
    local settled_calls = save_calls
    coroutine.yield(0.2)
    buffer.save = real_save

    test.ok(settled_calls > 1, "expected transient retries")
    test.equal(save_calls, settled_calls)
    test.ok(buffer:is_dirty())
    test.ok(view:get_name():find("*", 1, true), "persistent failure should remain visible")
  end)
end)
