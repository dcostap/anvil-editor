local test = require "core.test"
local config = require "core.config"

local Model = require "plugins.git.model"

local real_backend = require "plugins.git.backend"

local function fake_backend(status_output, log_output)
  return {
    repo_for_path = function(path) return { root = path } end,
    build_log_args = function(opts) return { "log", tostring(opts and opts.offset or "") } end,
    parse_status_z = real_backend.parse_status_z,
    parse_log_page = real_backend.parse_log_page,
    run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = status_output or "" }, nil)
      else
        callback({ code = 0, stdout = log_output or "" }, nil)
      end
      return { cancel = function() end }
    end,
  }
end

local function one_record(hash, subject)
  return table.concat({hash, "", "Ada", "ada@example.test", "1710000000", "HEAD", subject, ""}, "\0")
end

local function log_output(records)
  local out = {}
  for _, record in ipairs(records or { { "abc123", "Initial" } }) do
    out[#out + 1] = one_record(record[1], record[2])
  end
  out[#out + 1] = ""
  return table.concat(out, "\30")
end

test.describe("plugins.git.model", function()
  test.test("creates a permanent Log tab", function()
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend("", "") })
    local tab = model:log_tab()
    test.equal(tab.id, "log")
    test.equal(tab.kind, "log")
    test.equal(tab.closable, false)
    test.equal(model:close_selected_tab(), false)
  end)

  test.test("refreshes log with working tree row and commits", function()
    local status = table.concat({ " M src/app.lua", "" }, "\0")
    local model = Model.new({ path = "C:/repo" }, { backend = fake_backend(status, log_output()) })
    local done = false
    model:refresh_log(function() done = true end)

    test.equal(done, true)
    local commits = model:log_tab().commits
    test.equal(#commits, 2)
    test.equal(commits[1].kind, "working_tree")
    test.equal(commits[1].subject, "Working Tree")
    test.equal(commits[2].hash, "abc123")
    test.equal(commits[2].subject, "Initial")
    test.equal(model:selected_commit().kind, "working_tree")
    test.equal(model:select_log_index(2).hash, "abc123")
    test.equal(model:selected_commit().subject, "Initial")
  end)

  test.test("ignores stale refresh results and cancels older jobs", function()
    local callbacks = {}
    local cancelled = 0
    local backend = fake_backend("", "")
    backend.run_git = function(repo, args, opts, callback)
      callbacks[#callbacks + 1] = { args = args, callback = callback }
      return { cancel = function() cancelled = cancelled + 1 end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    model:refresh_log()
    test.equal(cancelled, 2)
    callbacks[1].callback({ code = 0, stdout = " M stale.lua\0" }, nil)
    callbacks[2].callback({ code = 0, stdout = log_output() }, nil)
    callbacks[3].callback({ code = 0, stdout = "" }, nil)
    callbacks[4].callback({ code = 0, stdout = log_output() }, nil)

    local commits = model:log_tab().commits
    test.equal(#commits, 1)
    test.equal(commits[1].hash, "abc123")
  end)

  test.test("shows working tree row when log fails because repo has no commits", function()
    local backend = fake_backend(table.concat({ "?? new.lua", "" }, "\0"), "")
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = table.concat({ "?? new.lua", "" }, "\0") }, nil)
      else
        callback(nil, { kind = "exit", stderr = "fatal: your current branch 'main' does not have any commits yet" })
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    test.equal(model:log_tab().error, nil)
    test.equal(#model:log_tab().commits, 1)
    test.equal(model:log_tab().commits[1].kind, "working_tree")
  end)

  test.test("loads more commits from the next log page", function()
    local old_git = config.plugins.git
    config.plugins.git = { log_page_size = 1 }
    local backend = fake_backend("", "")
    backend.run_git = function(repo, args, opts, callback)
      if args[1] == "status" then
        callback({ code = 0, stdout = "" }, nil)
      elseif args[2] == "1" then
        callback({ code = 0, stdout = log_output({ { "def456", "Second" } }) }, nil)
      else
        callback({ code = 0, stdout = log_output({ { "abc123", "Initial" }, { "def456", "Second" } }) }, nil)
      end
      return { cancel = function() end }
    end
    local model = Model.new({ path = "C:/repo" }, { backend = backend })
    model:refresh_log()
    test.equal(#model:log_tab().commits, 1)
    test.equal(model:log_tab().has_more, true)
    test.equal(model:load_more_log(), true)
    test.equal(#model:log_tab().commits, 2)
    test.equal(model:log_tab().commits[2].hash, "def456")
    config.plugins.git = old_git
  end)
end)
