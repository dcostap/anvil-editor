local common = require "core.common"
local config = require "core.config"
local process = require "core.process"
local test = require "core.test"

local backend = require "plugins.git.backend"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  test.not_nil(fp, err)
  fp:write(text or "")
  fp:close()
end

local function wait_until(predicate, timeout, message)
  local deadline = system.get_time() + (timeout or 5)
  while system.get_time() < deadline do
    if predicate() then return end
    coroutine.yield(0.01)
  end
  test.fail(message or "timed out waiting", 2)
end

local function run(args, cwd)
  local proc = process.start(args, {
    cwd = cwd,
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
  if not proc then return nil end
  local code = proc:wait(process.WAIT_INFINITE, 0.01)
  return code, proc:read_stdout(16 * 1024 * 1024) or "", proc:read_stderr(1024 * 1024) or ""
end

test.describe("plugins.git.backend", function()
  test.describe("parse_name_status_z", function()
    test.test("parses modified, rename, copy, and delete records with per-side paths", function()
      local records = backend.parse_name_status_z(
        table.concat({
          "M", "src/app.lua",
          "R087", "old/name.lua", "new/name.lua",
          "C100", "template.lua", "copy.lua",
          "D", "gone.lua",
          "",
        }, "\0")
      )

      test.equal(#records, 4)
      test.equal(records[1].status, "modified")
      test.equal(records[1].old_path, "src/app.lua")
      test.equal(records[1].new_path, "src/app.lua")

      test.equal(records[2].status, "renamed")
      test.equal(records[2].score, 87)
      test.equal(records[2].old_path, "old/name.lua")
      test.equal(records[2].new_path, "new/name.lua")

      test.equal(records[3].status, "copied")
      test.equal(records[3].score, 100)
      test.equal(records[3].old_path, "template.lua")
      test.equal(records[3].new_path, "copy.lua")

      test.equal(records[4].status, "deleted")
      test.equal(records[4].old_path, "gone.lua")
      test.equal(records[4].new_path, nil)
    end)
  end)

  test.describe("parse_numstat_z", function()
    test.it("parses simple and rename stats by displayed path", function()
      local stats = backend.parse_numstat_z(table.concat({
        "2\t44\tsrc/app.lua",
        "1\t0\t", "old/name.lua", "new/name.lua",
        "",
      }, "\0"))

      test.equal(stats["src/app.lua"].additions, 2)
      test.equal(stats["src/app.lua"].deletions, 44)
      test.equal(stats["new/name.lua"].additions, 1)
      test.equal(stats["new/name.lua"].deletions, 0)
    end)

    test.it("marks binary paths", function()
      local stats = backend.parse_numstat_z("-\t-\timage.png\0")
      test.equal(stats["image.png"].binary, true)
      test.equal(stats["image.png"].additions, nil)
      test.equal(stats["image.png"].deletions, nil)
    end)
  end)

  test.describe("parse_status_z", function()
    test.test("parses porcelain status and rename source paths", function()
      local status = backend.parse_status_z(table.concat({
        " M src/app.lua",
        "?? new.lua",
        "R  renamed.lua", "old.lua",
        "",
      }, "\0"))

      test.equal(#status, 3)
      test.equal(status[1].kind, "modified")
      test.equal(status[1].path, "src/app.lua")
      test.equal(status[2].kind, "untracked")
      test.equal(status[2].path, "new.lua")
      test.equal(status[3].kind, "renamed")
      test.equal(status[3].path, "renamed.lua")
      test.equal(status[3].old_path, "old.lua")
    end)

    test.test("classifies AA and DD porcelain statuses as unmerged", function()
      local status = backend.parse_status_z(table.concat({
        "AA both-added.lua",
        "DD both-deleted.lua",
        "",
      }, "\0"))

      test.equal(status[1].kind, "unmerged")
      test.equal(status[2].kind, "unmerged")
    end)
  end)

  test.describe("parse_log_page", function()
    test.test("parses bounded log records and reports next offset", function()
      local output = table.concat({
        table.concat({"aaa111", "p1 p2", "Ada", "ada@example.test", "1710000000", "main, tag: v1", "Subject A", "Body A"}, "\0"),
        table.concat({"bbb222", "", "Ben", "ben@example.test", "1710000100", "", "Subject B", ""}, "\0"),
        "",
      }, "\30")

      local page = backend.parse_log_page(output, { limit = 1, offset = 10 })
      test.equal(#page.commits, 1)
      test.equal(page.commits[1].hash, "aaa111")
      test.equal(page.commits[1].parents[2], "p2")
      test.equal(page.commits[1].subject, "Subject A")
      test.equal(page.commits[1].ref_labels[1].kind, "branch")
      test.equal(page.commits[1].ref_labels[1].label, "main")
      test.equal(page.commits[1].ref_labels[2].kind, "tag")
      test.equal(page.commits[1].ref_labels[2].label, "v1")
      test.equal(page.has_more, true)
      test.equal(page.next_offset, 11)
      test.equal(page.next_cursor, "aaa111")
    end)

    test.test("uses configured default page size consistently", function()
      local old_git = config.plugins.git
      config.plugins.git = common.merge(old_git or {}, { log_page_size = 1 })

      local output = table.concat({
        table.concat({"aaa111", "", "Ada", "ada@example.test", "1710000000", "", "Subject A", ""}, "\0"),
        table.concat({"bbb222", "", "Ben", "ben@example.test", "1710000100", "", "Subject B", ""}, "\0"),
        "",
      }, "\30")
      local page = backend.parse_log_page(output)
      local args = backend.build_log_args({})

      config.plugins.git = old_git

      test.equal(#page.commits, 1)
      test.equal(page.has_more, true)
      test.ok(backend._contains_arg(args, "--max-count=2"), "expected configured limit plus one")
    end)

    test.it("classifies full Git decorations without duplicating the HEAD branch", function()
      local labels = backend.parse_ref_labels(table.concat({
        "HEAD -> refs/heads/main",
        "refs/heads/main",
        "tag: refs/tags/v1",
        "refs/remotes/origin/main",
      }, ", "))

      test.equal(#labels, 3)
      test.equal(labels[1].kind, "head")
      test.equal(labels[1].label, "main")
      test.equal(labels[2].kind, "tag")
      test.equal(labels[2].label, "v1")
      test.equal(labels[3].kind, "remote")
      test.equal(labels[3].label, "origin/main")
    end)
  end)

  test.describe("diff planning", function()
    test.test("builds changed-file diff args for commits and working tree", function()
      local args = backend.build_changed_files_args("parent", "child", { relpath = "src/app.lua" })
      test.equal(args[1], "diff")
      test.ok(backend._contains_arg(args, "--name-status"), "missing name-status")
      test.ok(backend._contains_arg(args, "-z"), "missing NUL delimiter")
      test.ok(backend._contains_arg(args, "parent"), "missing left revision")
      test.ok(backend._contains_arg(args, "child"), "missing right revision")
      test.equal(args[#args], "src/app.lua")

      local stats = backend.build_changed_file_stats_args("parent", "child", { relpath = "src/app.lua" })
      test.equal(stats[1], "diff")
      test.ok(backend._contains_arg(stats, "--numstat"), "missing numstat")
      test.equal(stats[#stats], "src/app.lua")

      local working = backend.build_changed_files_args("HEAD", backend.WORKING_TREE, {})
      test.ok(backend._contains_arg(working, "HEAD"), "missing working tree base")
      test.ok(not backend._contains_arg(working, backend.WORKING_TREE), "WORKING_TREE sentinel leaked to git args")
    end)

    test.test("uses empty tree for root and unborn working-tree diffs", function()
      local root = backend.diff_endpoint_for_commit({ hash = "root", parents = {} })
      test.equal(root.left, backend.EMPTY_TREE)
      test.equal(root.right, "root")

      local working = backend.diff_endpoint_for_working_tree({ head = nil })
      test.equal(working.left, backend.EMPTY_TREE)
      test.equal(working.right, backend.WORKING_TREE)
    end)

    test.it("loads working-tree changed-line statistics", function()
      local old_run_git = backend.run_git
      local captured_args
      backend.run_git = function(repo, args, opts, callback)
        captured_args = args
        callback({ code = 0, stdout = "4\t2\tsrc/app.lua\0" }, nil)
        return { cancel = function() end }
      end
      local stats

      backend.changed_file_stats({ root = "repo" }, "HEAD", backend.WORKING_TREE, {}, function(result)
        stats = result
      end)
      backend.run_git = old_run_git

      test.ok(backend._contains_arg(captured_args, "--numstat"))
      test.ok(not backend._contains_arg(captured_args, backend.WORKING_TREE))
      test.same(stats["src/app.lua"], { additions = 4, deletions = 2 })
    end)

    test.it("cancels every changed-file child job", function()
      local old_run_git = backend.run_git
      local callbacks, cancelled = {}, 0
      backend.run_git = function(repo, args, opts, callback)
        callbacks[#callbacks + 1] = callback
        return {
          cancel = function()
            cancelled = cancelled + 1
            callback(nil, { kind = "cancelled" })
          end,
        }
      end
      local calls, callback_err = 0, nil
      local job = backend.changed_files({ root = "repo" }, "left", "right", {}, function(_, err)
        calls, callback_err = calls + 1, err
      end)
      callbacks[1]({ stdout = "M\0src/app.lua\0" }, nil)
      job:cancel()
      backend.run_git = old_run_git

      test.equal(cancelled, 2)
      test.equal(calls, 1)
      test.equal(callback_err.kind, "cancelled")
    end)
  end)

  test.describe("command builders", function()
    test.it("counts commits with a lightweight revision query", function()
      local old_run_git = backend.run_git
      local captured_args
      backend.run_git = function(repo, args, opts, callback)
        captured_args = args
        callback({ code = 0, stdout = "1234\n" }, nil)
        return { cancel = function() end }
      end
      local count, count_err

      backend.commit_count({ root = "C:/repo" }, {}, function(value, err)
        count, count_err = value, err
      end)
      backend.run_git = old_run_git

      test.same(captured_args, { "rev-list", "--count", "HEAD" })
      test.equal(count, 1234)
      test.equal(count_err, nil)
    end)

    test.test("builds selection history commands with line range", function()
      local args = backend.build_selection_history_args("src/app.lua", 10, 20, { limit = 3 })
      test.equal(args[1], "log")
      test.ok(backend._contains_arg(args, "--max-count=4"), "missing limit plus one")
      test.ok(backend._contains_arg(args, "-L"), "missing -L")
      test.ok(backend._contains_arg(args, "10,20:src/app.lua"), "missing line range path")
    end)

    test.it("parses tracked Selection History blocks from Git patches", function()
      local fields = {
        "abc123", "parent", "Ada", "ada@example.test", "1710000000", "", "Change block", "",
        "Ada", "ada@example.test", "1710000001",
      }
      local patch = table.concat({
        "", "diff --git a/src/app.lua b/src/app.lua",
        "@@ -10,2 +12,3 @@", " keep", "-old", "+new", "+extra", "",
      }, "\n")
      local output = backend.LOG_RECORD_SEPARATOR .. table.concat(fields, "\0") .. "\0" .. patch

      local page = backend.parse_selection_history_page(output, { limit = 10 })

      test.equal(page.commits[1].selection_diff.left_text, "keep\nold")
      test.equal(page.commits[1].selection_diff.right_text, "keep\nnew\nextra")
      test.equal(page.commits[1].selection_diff.left_start_line, 10)
      test.equal(page.commits[1].selection_diff.right_start_line, 12)
    end)

    test.test("builds file history commands with follow and pathspec terminator", function()
      local args = backend.build_file_history_args("src/app.lua", { limit = 10, offset = 5 })
      test.equal(args[1], "log")
      test.ok(backend._contains_arg(args, "--follow"), "missing follow")
      test.ok(backend._contains_arg(args, "--max-count=11"), "missing limit plus one")
      test.ok(backend._contains_arg(args, "--skip=5"), "missing offset")
      test.ok(backend._contains_arg(args, "--"), "missing pathspec terminator")
      test.equal(args[#args], "src/app.lua")
    end)

    test.it("tracks old and new paths in renamed File History records", function()
      local fields = {
        "abc123", "parent", "Ada", "ada@example.test", "1710000000", "", "Rename file", "",
        "Ada", "ada@example.test", "1710000001",
      }
      local output = backend.LOG_RECORD_SEPARATOR .. table.concat(fields, "\0")
        .. "\0\0\nR100\0src/old.lua\0src/new.lua\0"

      local page = backend.parse_file_history_page(output, { limit = 10 })

      test.equal(page.commits[1].history_parent_path, "src/old.lua")
      test.equal(page.commits[1].history_path, "src/new.lua")
    end)

    test.test("builds paged log commands with bounded count and pathspec terminator", function()
      local args = backend.build_log_args({ limit = 51, offset = 25, relpath = "src/app.lua" })
      test.equal(args[1], "log")
      test.ok(backend._contains_arg(args, "--max-count=52"), "missing limit plus one")
      test.ok(backend._contains_arg(args, "--skip=25"), "missing page offset skip")
      test.ok(backend._contains_arg(args, "--"), "missing pathspec terminator")
      test.equal(args[#args], "src/app.lua")
      for _, arg in ipairs(args) do
        if arg:find("^%-%-format=") then
          test.ok(arg:find("%b", 1, true), "Git Log details should include the full commit message")
        end
      end
    end)
  end)

  test.describe("repo_for_path", function()
    test.test("discovers the canonical repository root from a file path", function(context)
      local code = run({ backend.git_path(), "--version" })
      test.skip_if(code ~= 0, "git executable is not available")

      local root = join_path(USERDIR, "git-backend-repo-" .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
      context.root = root
      local ok, err = common.mkdirp(join_path(root, "src"))
      test.ok(ok, err)
      write_file(join_path(root, "src", "app.lua"), "return true\n")

      code = run({ backend.git_path(), "-C", root:gsub("\\", "/"), "init" })
      test.equal(code, 0)

      local repo, repo_err = backend.repo_for_path(join_path(root, "src", "app.lua"))
      test.not_nil(repo, repo_err and repo_err.message)
      test.equal(common.normalize_path(repo.root), common.normalize_path(root))
      test.equal(repo.relpath, "src" .. PATHSEP .. "app.lua")
    end)

    test.test("enforces output caps for fast Git commands", function(context)
      local code = run({ backend.git_path(), "--version" })
      test.skip_if(code ~= 0, "git executable is not available")

      local root = join_path(USERDIR, "git-backend-cap-" .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
      context.root = root
      local ok, err = common.mkdirp(root)
      test.ok(ok, err)
      write_file(join_path(root, "untracked.lua"), "return true\n")
      code = run({ backend.git_path(), "-C", root:gsub("\\", "/"), "init" })
      test.equal(code, 0)

      local result, callback_err
      backend.run_git({ root = root }, { "status", "--porcelain=v1", "-z" }, { max_output = 1 }, function(res, e)
        result, callback_err = res, e
      end)
      wait_until(function() return result ~= nil or callback_err ~= nil end, 5, "git status callback did not run")
      test.equal(result, nil)
      test.equal(callback_err.kind, "output_too_large")
    end)

    test.test("reports success for a completed Git command", function()
      local code = run({ backend.git_path(), "--version" })
      test.skip_if(code ~= 0, "git executable is not available")

      local result, callback_err
      backend.run_git(nil, { "--version" }, {}, function(res, e)
        result, callback_err = res, e
      end)
      wait_until(function() return result ~= nil or callback_err ~= nil end, 5, "git version callback did not run")
      test.equal(callback_err, nil)
      test.equal(result.code, 0)
      test.ok(result.stdout:match("git version") ~= nil, "expected git version output")
    end)

    test.test("reports cancellation exactly once", function()
      local executable, args
      if PLATFORM == "Windows" then
        executable = "cmd"
        args = { "/C", "ping -n 6 127.0.0.1 >NUL" }
      else
        executable = "sh"
        args = { "-c", "sleep 5" }
      end

      local calls, result, callback_err = 0, nil, nil
      local job = backend.run_git(nil, args, { git_path = executable }, function(res, e)
        calls = calls + 1
        result, callback_err = res, e
      end)
      job:cancel()

      wait_until(function() return calls > 0 end, 5, "cancel callback did not run")
      coroutine.yield(0.05)
      test.equal(calls, 1)
      test.equal(result, nil)
      test.equal(callback_err.kind, "cancelled")
    end)

    test.test("respects disabled Git config without re-enabling it", function()
      local old_git = config.plugins.git
      config.plugins.git = false
      local repo, repo_err = backend.repo_for_path(system.getcwd())
      test.equal(repo, nil)
      test.equal(repo_err.kind, "disabled")

      local result, callback_err
      backend.run_git(nil, { "--version" }, {}, function(res, e)
        result, callback_err = res, e
      end)
      wait_until(function() return result ~= nil or callback_err ~= nil end, 5, "disabled callback did not run")
      test.equal(result, nil)
      test.equal(callback_err.kind, "disabled")

      result, callback_err = nil, nil
      backend.run_git(nil, { "--version" }, { git_path = "git" }, function(res, e)
        result, callback_err = res, e
      end)
      wait_until(function() return result ~= nil or callback_err ~= nil end, 5, "disabled callback with override did not run")
      test.equal(result, nil)
      test.equal(callback_err.kind, "disabled")

      test.equal(config.plugins.git, false)
      config.plugins.git = old_git
    end)

    test.test("parses actual git log output without separator-newline bogus commits", function(context)
      local code = run({ backend.git_path(), "--version" })
      test.skip_if(code ~= 0, "git executable is not available")

      local root = join_path(USERDIR, "git-backend-log-" .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
      context.root = root
      local ok, err = common.mkdirp(root)
      test.ok(ok, err)
      local git_root = root:gsub("\\", "/")
      test.equal(run({ backend.git_path(), "-C", git_root, "init" }), 0)
      test.equal(run({ backend.git_path(), "-C", git_root, "config", "user.email", "anvil@example.test" }), 0)
      test.equal(run({ backend.git_path(), "-C", git_root, "config", "user.name", "Anvil Test" }), 0)

      write_file(join_path(root, "a.txt"), "one\n")
      test.equal(run({ backend.git_path(), "-C", git_root, "add", "a.txt" }), 0)
      test.equal(run({ backend.git_path(), "-C", git_root, "commit", "-m", "first" }), 0)
      write_file(join_path(root, "a.txt"), "two\n")
      test.equal(run({ backend.git_path(), "-C", git_root, "commit", "-am", "second" }), 0)

      local args = { backend.git_path(), "-C", git_root }
      for _, arg in ipairs(backend.build_log_args({ limit = 10 })) do args[#args + 1] = arg end
      local _, out = run(args)
      local page = backend.parse_log_page(out, { limit = 10 })
      test.equal(#page.commits, 2)
      test.ok(not page.commits[1].hash:match("^%s"), "first hash has leading whitespace")
      test.ok(not page.commits[2].hash:match("^%s"), "second hash has leading whitespace")
    end)
  end)

  test.after_each(function(context)
    if context.root and system.get_file_info(context.root) then
      if PLATFORM == "Windows" then
        os.execute('attrib -R /S /D "' .. context.root .. '\\*" >NUL 2>NUL')
      end
      local ok, err
      local deadline = system.get_time() + 2
      repeat
        ok, err = common.rm(context.root, true)
        if ok or not system.get_file_info(context.root) then return end
        coroutine.yield(0.05)
      until system.get_time() >= deadline
      test.ok(ok, err)
    end
  end)
end)
