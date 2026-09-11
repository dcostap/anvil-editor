local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local backend = require "plugins.git.backend"
local fuzzy = require "plugins.fuzzy_searcher"
local panes = require "core.panes"

local function wait_until(predicate)
  local deadline = system.get_time() + 10
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.01) end
  return predicate()
end

local function git(root, args)
  local done, result, failure
  backend.run_git(root, args, {}, function(value, err)
    done, result, failure = true, value, err
  end)
  test.ok(wait_until(function() return done end), "Git fixture timed out")
  test.ok(result, failure and failure.message)
  return result.stdout:gsub("%s+$", "")
end

local function write_file(root, name, text)
  local file = assert(io.open(root .. PATHSEP .. name, "wb"))
  file:write(text)
  file:close()
end

test.describe("Fuzzy Searcher Commit Search", function()
  test.before_each(function(context)
    context.projects, context.cwd, context.recents = core.projects, system.getcwd(), core.visited_files
    context.root = USERDIR .. PATHSEP .. "commit-search-" .. math.floor(system.get_time() * 1000000)
    assert(common.mkdirp(context.root))
    core.projects, core.visited_files = { Project(context.root) }, {}
    system.chdir(context.root)
    project_paths.configure_workspace {}
    git(context.root, { "init", "-q" })
    git(context.root, { "config", "user.name", "Anvil Test" })
    git(context.root, { "config", "user.email", "test@example.invalid" })
    write_file(context.root, "gone.txt", "first line\nneedle needle\n")
    write_file(context.root, "same.txt", "old needle\n")
    write_file(context.root, ".hidden.txt", "hidden needle\n")
    write_file(context.root, ".gitignore", "ignored.txt\n")
    write_file(context.root, "ignored.txt", "ignored needle\n")
    git(context.root, { "add", "-f", "." })
    git(context.root, { "commit", "-qm", "First state" })
    context.revision = git(context.root, { "rev-parse", "HEAD" })
    assert(os.remove(context.root .. PATHSEP .. "gone.txt"))
    write_file(context.root, "same.txt", "new committed content\n")
    write_file(context.root, "later.txt", "later needle\n")
    git(context.root, { "add", "-A" })
    git(context.root, { "commit", "-qm", "Second state" })
    context.second_revision = git(context.root, { "rev-parse", "HEAD" })
    write_file(context.root, "same.txt", "working needle\n")
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    fuzzy._test.cancel_file_index_for_test()
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        local buffer = view.buffer
        if buffer and (buffer.git_historical_repo == context.root
          or buffer.abs_filename and common.path_belongs_to(buffer.abs_filename, context.root)) then
          panes.close_view(pane, { view = view, force = true })
        end
      end
    end
    project_paths.configure_workspace {}
    core.projects, core.visited_files = context.projects, context.recents
    system.chdir(context.cwd)
    for i = #core.buffers, 1, -1 do
      if core.buffers[i].git_historical_repo == context.root then table.remove(core.buffers, i) end
    end
    common.rm(context.root, true)
  end)

  test.it("searches the full committed state, including deleted and ignored files", function(context)
    fuzzy.open("size:<1k #needle commit:" .. context.revision:sub(1, 8) .. " sort:name")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "4 matches" end), tostring(picker.status))
    test.same({ picker.results[1].file, picker.results[2].file, picker.results[3].file, picker.results[4].file },
      { ".hidden.txt", "gone.txt", "ignored.txt", "same.txt" })
    test.equal(picker.results[2].line, 2)
    test.equal(picker.results[2].text, "needle needle")
    test.equal(picker.results[4].text, "old needle")
    test.equal(picker.results[2].revision, context.revision)
  end)

  test.it("previews historical content instead of today's file", function(context)
    fuzzy.open("same commit:" .. context.revision .. " #needle")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 match" end), tostring(picker.status))
    test.ok(wait_until(function()
      local preview = picker:update_preview_view()
      return preview and preview.buffer and table.concat(preview.buffer.lines) == "old needle\n"
    end), "expected the committed text in the preview")
    test.equal(picker.preview_view.buffer.git_historical_rev, context.revision)
  end)

  test.it("opens a matching Historical Buffer without changing working files", function(context)
    fuzzy.open("same commit:" .. context.revision .. " #needle")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 match" end), tostring(picker.status))
    picker:confirm()
    test.ok(wait_until(function()
      local buffer = core.active_view and core.active_view.buffer
      return buffer and buffer.git_historical_rev == context.revision
    end), "expected an opened Historical Buffer")
    local buffer = core.active_view.buffer
    test.equal(table.concat(buffer.lines), "old needle\n")
    buffer:text_input("do not insert")
    test.equal(table.concat(buffer.lines), "old needle\n")
    local file = assert(io.open(context.root .. PATHSEP .. "same.txt", "rb"))
    local text = file:read("*a")
    file:close()
    test.equal(text, "working needle\n")
  end)

  test.it("uses committed file sizes and changes preview content when the commit changes", function(context)
    fuzzy.open("same size:11 commit:" .. context.revision)
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker.status == "1 match" end), tostring(picker.status))
    test.equal(picker.results[1].file_size, 11)
    test.ok(wait_until(function()
      local preview = picker:update_preview_view()
      return preview and table.concat(preview.buffer.lines) == "old needle\n"
    end))
    picker.input:set_text("commit:" .. context.second_revision .. " same sort:name")
    test.ok(wait_until(function()
      return #picker.results == 1 and picker.results[1].revision == context.second_revision
    end), tostring(picker.status))
    test.ok(wait_until(function()
      local preview = picker:update_preview_view()
      return preview and table.concat(preview.buffer.lines) == "new committed content\n"
    end), "expected the second commit's preview")
  end)

  test.it("rejects historical date sorting and missing commits without searching current files", function(context)
    fuzzy.open("commit:" .. context.revision .. " sort:date")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.equal(#picker.results, 0)
    test.equal(picker.status, "Git commits do not store file modification dates")
    picker.input:set_text("same commit:" .. string.rep("0", 40))
    test.ok(wait_until(function() return picker.status ~= "Searching files…" end), tostring(picker.status))
    test.equal(#picker.results, 0)
    test.not_ok(picker.status:find("matches", 1, true))
  end)
end)
