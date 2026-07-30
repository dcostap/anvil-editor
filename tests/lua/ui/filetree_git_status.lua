local common = require "core.common"
local test = require "core.test"

local git_status = require "plugins.filetree.git_status"

local function fake_backend()
  local backend = { repo_calls = {}, git_calls = {} }

  function backend.repo_for_path_async(path, callback)
    local job = { cancelled = false }
    function job:cancel() self.cancelled = true end
    backend.repo_calls[#backend.repo_calls + 1] = {
      path = path,
      callback = callback,
      job = job,
    }
    return job
  end

  function backend.run_git(repo, args, opts, callback)
    local job = { cancelled = false }
    function job:cancel() self.cancelled = true end
    backend.git_calls[#backend.git_calls + 1] = {
      repo = repo,
      args = args,
      opts = opts,
      callback = callback,
      job = job,
    }
    return job
  end

  function backend.is_enabled() return true end
  return backend
end

local function contains(items, expected)
  for _, item in ipairs(items or {}) do
    if item == expected then return true end
  end
  return false
end

local function make_controller(options)
  options = options or {}
  local backend = options.backend or fake_backend()
  local presented = options.presented ~= false
  local now = 10
  local publications = {}
  local function build_snapshot(payload, _, callback)
    local snapshot = { payload = payload }
    function snapshot:summary() return { status_records = 1, numstat_records = 1 } end
    function snapshot:lookup(path)
      path = path:lower():gsub("\\", "/")
      if path == "src/app.lua" then
        return { kind = "modified", additions = 2, deletions = 1 }
      elseif path == "first.lua" then
        return { kind = "modified" }
      end
    end
    function snapshot:close() self.closed = true end
    callback(snapshot)
  end
  local controller = git_status.new {
    backend = backend,
    root = function() return options.root or "C:/repo/project" end,
    presented = function() return presented end,
    clock = function() return now end,
    build_snapshot = options.build_snapshot or build_snapshot,
    publish = function(snapshot, detail)
      publications[#publications + 1] = { snapshot = snapshot, detail = detail }
    end,
  }
  return controller, backend, publications, {
    set_presented = function(value) presented = value end,
    advance = function(seconds) now = now + seconds end,
  }
end

test.describe("File Tree Git status controller", function()
  test.it("defers and coalesces requests until the File Tree is presented", function()
    local controller, backend, _, state = make_controller { presented = false }

    controller:request("construction")
    controller:request("workspace-restoration")
    controller:update()
    test.equal(#backend.repo_calls, 0)

    state.set_presented(true)
    controller:update()
    test.equal(#backend.repo_calls, 1)
    controller:update()
    test.equal(#backend.repo_calls, 1)
  end)

  test.it("uses collapsed status output and publishes one atomic status/numstat build", function()
    local controller, backend, publications = make_controller()
    controller:request("visible")
    controller:update()

    backend.repo_calls[1].callback({ root = "C:/repo" })
    test.equal(#backend.git_calls, 2)
    local status_call, numstat_call
    for _, call in ipairs(backend.git_calls) do
      if call.args[1] == "status" then status_call = call else numstat_call = call end
    end
    test.not_nil(status_call)
    test.not_nil(numstat_call)
    test.ok(contains(status_call.args, "--untracked-files=normal"))
    test.not_ok(contains(status_call.args, "-uall"))
    test.equal(status_call.opts.max_output, nil,
      "the shared Git backend should apply its configured output cap")

    status_call.callback({ stdout = " M src/app.lua\0" })
    test.equal(#publications, 0)
    numstat_call.callback({ stdout = "2\t1\tsrc/app.lua\0" })
    test.equal(#publications, 1)
    local info = publications[1].snapshot:lookup("src/app.lua", false)
    test.equal(info.kind, "modified")
    test.equal(info.additions, 2)
    test.equal(info.deletions, 1)
  end)

  test.it("cancels hidden work and rejects its stale completion", function()
    local controller, backend, publications, state = make_controller()
    controller:request("visible")
    controller:update()
    local discovery = backend.repo_calls[1]

    state.set_presented(false)
    controller:update()
    test.ok(discovery.job.cancelled)
    discovery.callback({ root = "C:/repo" })
    test.equal(#backend.git_calls, 0)
    test.equal(#publications, 0)
  end)

  test.it("preserves the last valid snapshot after failure and remains retryable", function()
    local controller, backend, publications, state = make_controller()
    controller:request("first", true)
    controller:update()
    backend.repo_calls[1].callback({ root = "C:/repo" })
    local status_call, numstat_call = backend.git_calls[1], backend.git_calls[2]
    if status_call.args[1] ~= "status" then status_call, numstat_call = numstat_call, status_call end
    status_call.callback({ stdout = " M first.lua\0" })
    numstat_call.callback({ stdout = "" })
    test.equal(#publications, 1)

    state.advance(3)
    controller:request("failure", true)
    controller:update()
    local failed_status = backend.git_calls[3]
    if failed_status.args[1] ~= "status" then failed_status = backend.git_calls[4] end
    failed_status.callback(nil, { kind = "exit", message = "failed" })
    test.equal(#publications, 1)
    test.equal(controller:status().active, false)

    controller:request("retry", true)
    controller:update()
    test.equal(#backend.repo_calls, 1)
    test.equal(#backend.git_calls, 6)
  end)
end)
