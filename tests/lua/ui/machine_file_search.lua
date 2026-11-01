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
  local raw_open, raw_info = io.open, system.get_file_info

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
    write_file(machine_copy(context, context.project .. PATHSEP .. "sub" .. PATHSEP .. "steps.md"),
      "one\nfind the needle\n")
    write_file(context.project .. PATHSEP .. "client-steps.md", "a needle on the Client\n")
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
    test.ok(wait_until(function() return #file_rows(picker) == 3 end),
      "status=" .. tostring(picker.status) .. " files=" .. table.concat(file_rows(picker), ", "))
    test.same(file_rows(picker), { "notes.md", "plan.md", "steps.md" })

    picker.input:set_text("plan")
    test.ok(wait_until(function() return #file_rows(picker) == 1 end), table.concat(file_rows(picker), ", "))
    -- As in a local Project, a bare missing name offers its creation first.
    test.equal(picker.results[1].kind, "create_path")
    test.ok(command.perform("fuzzy:next"))
    test.ok(wait_until(function()
      local preview = picker.preview_view
      return preview and preview.buffer and table.concat(preview.buffer.lines) == "Plan\n"
    end), "The preview did not show the Machine's text")
    test.ok(command.perform("fuzzy:confirm"))
    local plan = context.project .. PATHSEP .. "sub" .. PATHSEP .. "plan.md"
    test.ok(wait_until(function()
      local buffer = core.buffer_registry:find(plan)
      return buffer and not buffer:is_loading() and table.concat(buffer.lines) == "Plan\n"
    end), "The chosen file did not open with the Machine's text")
  end)

  test.it("creates the file that the query names on the Machine, and opens it", function(context)
    local path = context.project .. PATHSEP .. "made" .. PATHSEP .. "new.md"
    fuzzy_searcher.open(path)
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    local function create_row()
      for _, row in ipairs(picker.results or {}) do
        if row.create_path then return row end
      end
    end
    test.ok(wait_until(create_row), "status=" .. tostring(picker.status))
    picker:activate_create_path(create_row())
    test.ok(wait_until(function() return system.get_file_info(machine_copy(context, path)) ~= nil end),
      "The Machine has no new file")
    test.ok(wait_until(function()
      local buffer = core.buffer_registry:find(path)
      return buffer and not buffer:is_loading()
    end), "The new file did not open")
    test.is_nil(raw_info(context.project .. PATHSEP .. "made"))
  end)

  test.it("tells that a Text Search did not reach the Machine", function(context)
    machine_server.stop(context.server)
    test.ok(wait_until(function() return fs.machine.state == "waiting" end), "The Client did not see the disconnect")
    -- Exact and fuzzy text use different searches.
    for _, query in ipairs({ "#needle", "#find needle" }) do
      fuzzy_searcher.open(query)
      local picker = test.not_nil(core.fuzzy_searcher_active_view)
      test.ok(wait_until(function() return tostring(picker.status):find("failed", 1, true) ~= nil end),
        query .. ": " .. tostring(picker.status))
      picker:close()
    end
  end)

  -- Each query uses a different search path: exact text, fuzzy text, text in the files that match a name, and
  -- text with a query modifier.
  test.it("finds the text of the Machine's files", function()
    for _, query in ipairs({ "#needle", "#find needle", "steps #needle", "#needle sort:name" }) do
      fuzzy_searcher.open(query)
      local picker = test.not_nil(core.fuzzy_searcher_active_view)
      local function lines()
        local found = {}
        for _, row in ipairs(picker.results or {}) do
          if row.kind == "grep" then
            found[#found + 1] = common.basename(tostring(row.file)) .. ":" .. tostring(row.line) .. ":" .. tostring(row.text)
          end
        end
        return table.concat(found, ", ")
      end
      test.ok(wait_until(function() return lines() == "steps.md:2:find the needle" end),
        query .. ": status=" .. tostring(picker.status) .. " lines=" .. lines())
      picker:close()
    end
  end)
end)
