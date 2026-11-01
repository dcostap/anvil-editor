local command = require "core.command"
local common = require "core.common"
local core = require "core"
local fs = require "core.fs"
local machine_server = dofile("tests/fixtures/machine_server.lua")
local panes = require "core.panes"
local Project = require "core.project"
local project_files = require "core.project_files"
local project_paths = require "core.project_paths"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
local test = require "core.test"

-- Seam: the File Search picker in a Project process that uses a Machine. The Machine keeps its files
-- under a private folder (`--test-root`). The Client has other files at the same path, and the Machine
-- guard refuses raw reads of them.
test.describe("File Search on a Machine", function()
  local raw_open = io.open

  local function write_file(path, text)
    common.mkdirp(common.dirname(path))
    local file = assert(raw_open(path, "wb"))
    file:write(text)
    file:close()
  end

  local function machine_copy(context, path)
    return context.store .. PATHSEP .. path:gsub("^(%a):", "%1")
  end

  local function file_rows(picker)
    local names = {}
    for _, row in ipairs(picker.results or {}) do
      if row.kind == "file" then names[#names + 1] = common.basename(tostring(row.file)) end
    end
    table.sort(names)
    return names
  end


  local function wait_until(condition)
    local deadline = system.get_time() + 15
    while not condition() and system.get_time() < deadline do coroutine.yield(0.02) end
    return condition()
  end

  test.before_each(function(context)
    -- The mapped path holds this folder twice, so a short name stays within the Windows path limit.
    context.root = system.absolute_path(USERDIR) .. PATHSEP .. "ms" .. math.floor(system.get_time() * 1000) % 1000000
    context.user = context.root .. PATHSEP .. "user"
    context.store = context.root .. PATHSEP .. "machine"
    context.project = context.root .. PATHSEP .. "project"
    test.ok(common.mkdirp(context.user))
    write_file(context.project .. PATHSEP .. "client-only.md", "Client\n")
    write_file(machine_copy(context, context.project .. PATHSEP .. "notes.md"), "Notes\n")
    write_file(machine_copy(context, context.project .. PATHSEP .. "sub" .. PATHSEP .. "plan.md"), "Plan\n")
    context.projects, context.visited_files = core.projects, core.visited_files
    core.visited_files = {}
    core.projects = { Project(context.project) }
    project_paths.configure_workspace {}
    context.server = machine_server.start(context.user, { "--test-root", context.store, context.project })
    fs.use_machine(machine_server.discovery_path(context.user), { context.project })
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    for _, pane in ipairs(panes.ordered()) do
      for _, view in ipairs(panes.views(pane)) do
        local buffer = view.buffer
        if buffer and buffer.abs_filename and common.path_belongs_to(buffer.abs_filename, context.root) then
          panes.close_view(pane, { view = view, force = true })
        end
      end
    end
    project_files.invalidate(context.project)
    fs.use_local()
    project_paths.configure_workspace {}
    core.projects, core.visited_files = context.projects, context.visited_files
    machine_server.stop(context.server)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("finds the Machine's files and opens the chosen file", function(context)
    fuzzy_searcher.open("md")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return #file_rows(picker) == 2 end),
      "status=" .. tostring(picker.status) .. " files=" .. table.concat(file_rows(picker), ", "))
    test.same(file_rows(picker), { "notes.md", "plan.md" })

    picker.input:set_text("plan")
    test.ok(wait_until(function() return #file_rows(picker) == 1 end), table.concat(file_rows(picker), ", "))
    test.ok(command.perform("fuzzy:confirm"))
    local plan = context.project .. PATHSEP .. "sub" .. PATHSEP .. "plan.md"
    test.ok(wait_until(function()
      local buffer = core.buffer_registry:find(plan)
      return buffer and not buffer:is_loading() and table.concat(buffer.lines) == "Plan\n"
    end), "The chosen file did not open with the Machine's text")
  end)
end)
