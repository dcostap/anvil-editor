local Buffer = require "core.buffer"
local common = require "core.common"
local config = require "core.config"
local core = require "core"
local Editor = require "core.editor"
local test = require "core.test"

local autosave_fast = require "plugins.autosave_fast"
local untitled_recovery = require "plugins.untitled_recovery"

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

test.describe("Autosave deadlines", function()
  test.before_each(function(context)
    local suffix = system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    context.path_a = system.absolute_path(USERDIR .. PATHSEP .. "autosave-deadline-a-" .. suffix .. ".txt")
    context.path_b = system.absolute_path(USERDIR .. PATHSEP .. "autosave-deadline-b-" .. suffix .. ".txt")
    context.timeout = autosave_fast.timeout
    context.max_delay = autosave_fast.max_delay
    write_file(context.path_a, "a\n")
    write_file(context.path_b, "b\n")
  end)

  test.after_each(function(context)
    autosave_fast.timeout = context.timeout
    autosave_fast.max_delay = context.max_delay
    if context.recovery_cfg then
      context.recovery_cfg.delay = context.recovery_defaults.delay
      context.recovery_cfg.max_delay = context.recovery_defaults.max_delay
      context.recovery_cfg.large_buffer_threshold = context.recovery_defaults.large_buffer_threshold
    end
    for _, buffer in ipairs({ context.untitled_a, context.untitled_b }) do
      if buffer then
        if untitled_recovery.is_untitled_buffer(buffer) then
          untitled_recovery.handle_confirmed_discard(buffer)
        end
        if core.buffer_registry then core.buffer_registry:remove(buffer, true) end
      end
    end
    if context.buffer_a then context.buffer_a:on_close() end
    if context.buffer_b then context.buffer_b:on_close() end
    pcall(os.remove, context.path_a)
    pcall(os.remove, context.path_b)
  end)

  test.it("saves one Buffer on its own deadline while another Buffer keeps changing", function(context)
    context.buffer_a = Buffer(context.path_a, context.path_a, false)
    context.buffer_b = Buffer(context.path_b, context.path_b, false)
    autosave_fast.timeout = 0.08
    autosave_fast.max_delay = 0.2
    context.buffer_b:insert(1, 1, "saved ")

    local started = system.get_time()
    while system.get_time() - started < 0.32 do
      context.buffer_a:insert(1, 1, "x")
      coroutine.yield(0.03)
    end

    test.not_ok(context.buffer_b:is_dirty(), "another Buffer must not postpone this save")
    test.equal(read_file(context.path_b), "saved b\n")
  end)

  test.it("checkpoints a continuously changing Buffer by its maximum wait", function(context)
    context.buffer_a = Buffer(context.path_a, context.path_a, false)
    autosave_fast.timeout = 0.08
    autosave_fast.max_delay = 0.2
    local checkpoint_seen = false

    local started = system.get_time()
    while system.get_time() - started < 0.32 do
      context.buffer_a:insert(1, 1, "x")
      coroutine.yield(0.03)
      checkpoint_seen = checkpoint_seen or read_file(context.path_a) ~= "a\n"
    end

    test.ok(checkpoint_seen, "continuous edits must not postpone all checkpoints")
  end)

  test.it("checkpoints one Untitled Buffer while another Untitled Buffer keeps changing", function(context)
    local cfg = config.plugins.untitled_recovery
    context.recovery_cfg = cfg
    context.recovery_defaults = {
      delay = cfg.delay,
      max_delay = cfg.max_delay,
      large_buffer_threshold = cfg.large_buffer_threshold,
    }
    cfg.delay = 0.08
    cfg.max_delay = 0.2
    cfg.large_buffer_threshold = math.huge

    local buffer_a = core.open_buffer()
    local buffer_b = core.open_buffer()
    context.untitled_a = buffer_a
    context.untitled_b = buffer_b
    local id_suffix = system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    buffer_a.intellij_untitled = true
    buffer_a.intellij_untitled_name = "Untitled-Deadline-A"
    buffer_a.intellij_untitled_id = "deadline-a-" .. id_suffix
    buffer_b.intellij_untitled = true
    buffer_b.intellij_untitled_name = "Untitled-Deadline-B"
    buffer_b.intellij_untitled_id = "deadline-b-" .. id_suffix
    untitled_recovery.ensure_buffer_backing(buffer_a)
    untitled_recovery.ensure_buffer_backing(buffer_b)
    buffer_b:insert(1, 1, "checkpointed ")

    local started = system.get_time()
    while system.get_time() - started < 0.32 do
      buffer_a:insert(1, 1, "x")
      coroutine.yield(0.03)
    end

    test.ok(
      untitled_recovery.buffer_backing_current(buffer_b),
      "another Untitled Buffer must not postpone this checkpoint"
    )
    test.equal(
      read_file(buffer_b.intellij_untitled_backing_path):gsub("\r\n", "\n"),
      "checkpointed \n"
    )
  end)

  test.it("checkpoints a continuously changing Untitled Buffer by its maximum wait", function(context)
    local cfg = config.plugins.untitled_recovery
    context.recovery_cfg = cfg
    context.recovery_defaults = {
      delay = cfg.delay,
      max_delay = cfg.max_delay,
      large_buffer_threshold = cfg.large_buffer_threshold,
    }
    cfg.delay = 0.08
    cfg.max_delay = 0.2
    cfg.large_buffer_threshold = math.huge

    local buffer = core.open_buffer()
    context.untitled_a = buffer
    buffer.intellij_untitled = true
    buffer.intellij_untitled_name = "Untitled-Maximum-Wait"
    buffer.intellij_untitled_id = "maximum-wait-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    untitled_recovery.ensure_buffer_backing(buffer)
    local checkpoint_seen = false

    local started = system.get_time()
    while system.get_time() - started < 0.32 do
      buffer:insert(1, 1, "x")
      coroutine.yield(0.03)
      checkpoint_seen = checkpoint_seen
        or system.get_file_info(buffer.intellij_untitled_backing_path) ~= nil
    end

    test.ok(checkpoint_seen, "continuous edits must not postpone all recovery checkpoints")
  end)
end)
