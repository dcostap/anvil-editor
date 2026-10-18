local common = require "core.common"
local core = require "core"
local command = require "core.command"
local test = require "core.test"

test.describe("Project window launch", function()
  test.before_each(function(context)
    context.temp_root = USERDIR
      .. PATHSEP .. "project-launch-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.temp_root))
  end)

  test.after_each(function(context)
    if context.original_process_start then
      require("core.process").start = context.original_process_start
    end
    if context.original_system_exec then system.exec = context.original_system_exec end
    if context.restore_allow_process_foreground then
      system.allow_process_foreground = context.original_allow_process_foreground
    end
    if context.original_projects then core.projects = context.original_projects end
    if context.shell then
      system.is_hosted_surface = context.shell.hosted
      system.select_project = context.shell.select
      system.open_project_window = context.shell.open_window
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function stub_shell(context)
    context.shell = {
      hosted = system.is_hosted_surface,
      select = system.select_project,
      open_window = system.open_project_window,
      selected = {},
      windows = {},
    }
    system.is_hosted_surface = function() return true end
    system.select_project = function(path)
      table.insert(context.shell.selected, path); return true
    end
    system.open_project_window = function(path)
      table.insert(context.shell.windows, path); return true
    end
  end

  local function submit_project_prompt(name, path)
    test.ok(command.perform(name))
    core.global_prompt_bar:set_text(path)
    core.global_prompt_bar:submit()
  end

  test.it("opens a Project in this Anvil Window under the shell", function(context)
    local project = context.temp_root .. PATHSEP .. "shell-project"
    test.ok(common.mkdirp(project))
    stub_shell(context)

    submit_project_prompt("core:open_project_folder", project)

    test.equal(#context.shell.selected, 1)
    test.ok(common.path_equals(context.shell.selected[1], project))
    test.same(context.shell.windows, {})
  end)

  test.it("opens a Project in a new Anvil Window only through its explicit command", function(context)
    local project = context.temp_root .. PATHSEP .. "shell-window-project"
    test.ok(common.mkdirp(project))
    stub_shell(context)

    submit_project_prompt("core:open_project_folder_in_new_window", project)

    test.equal(#context.shell.windows, 1)
    test.ok(common.path_equals(context.shell.windows[1], project))
    test.same(context.shell.selected, {})
  end)

  test.it("starts a new Windows Project directly and grants it foreground access", function(context)
    if PLATFORM ~= "Windows" then return end

    local project = context.temp_root .. PATHSEP .. "direct-launch-project"
    test.ok(common.mkdirp(project))
    context.original_projects = core.projects
    core.projects = {}

    local process = require "core.process"
    context.original_process_start = process.start
    local started
    process.start = function(args, options)
      started = { args = args, options = options }
      return { pid = function() return 4242 end }
    end

    context.original_system_exec = system.exec
    local exec_calls = 0
    system.exec = function() exec_calls = exec_calls + 1 end

    context.original_allow_process_foreground = system.allow_process_foreground
    context.restore_allow_process_foreground = true
    local allowed_pid
    system.allow_process_foreground = function(pid)
      allowed_pid = pid
      return true
    end

    test.ok(core.open_project_in_new_window(project))
    test.not_nil(started)
    test.same(started.args, { EXEFILE, project })
    test.equal(started.options.detach, true)
    test.equal(started.options.background, false)
    test.equal(started.options.stdin, process.REDIRECT_DISCARD)
    test.equal(started.options.stdout, process.REDIRECT_DISCARD)
    test.equal(started.options.stderr, process.REDIRECT_DISCARD)
    test.equal(started.options.env, nil)
    test.equal(allowed_pid, 4242)
    test.equal(exec_calls, 0)
  end)

  test.it("starts a new empty Anvil window through the command", function(context)
    if PLATFORM ~= "Windows" then return end

    local process = require "core.process"
    context.original_process_start = process.start
    local started
    process.start = function(args, options)
      started = { args = args, options = options }
      return { pid = function() return 4243 end }
    end

    context.original_system_exec = system.exec
    local exec_calls = 0
    system.exec = function() exec_calls = exec_calls + 1 end

    context.original_allow_process_foreground = system.allow_process_foreground
    context.restore_allow_process_foreground = true
    local allowed_pid
    system.allow_process_foreground = function(pid)
      allowed_pid = pid
      return true
    end

    test.ok(command.perform("core:new_anvil_window"))
    test.not_nil(started)
    test.same(started.args, { EXEFILE, "--new-window" })
    test.equal(started.options.detach, true)
    test.equal(started.options.background, false)
    test.equal(started.options.stdin, process.REDIRECT_DISCARD)
    test.equal(started.options.stdout, process.REDIRECT_DISCARD)
    test.equal(started.options.stderr, process.REDIRECT_DISCARD)
    test.equal(allowed_pid, 4243)
    test.equal(exec_calls, 0)
  end)
end)
