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
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
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
