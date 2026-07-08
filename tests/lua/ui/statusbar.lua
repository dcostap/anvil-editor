local test = require "core.test"
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local StatusBar = require "core.statusbar"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function styled_text_string(item)
  local text = {}
  for _, part in ipairs(item or {}) do
    if type(part) == "string" then text[#text + 1] = part end
  end
  return table.concat(text)
end

test.describe("status bar messages", function()
  local old_timeout

  test.before_each(function()
    old_timeout = config.message_timeout
    config.message_timeout = 2
  end)

  test.after_each(function()
    config.message_timeout = old_timeout
  end)

  local function shown_duration_for(text)
    local status_bar = StatusBar()
    status_bar:show_message("i", {}, text)
    return status_bar.message_timeout - status_bar.message_pulse_start
  end

  test.it("uses the configured timeout for short messages", function()
    test.equal(shown_duration_for(string.rep("a", 20)), 2)
  end)

  test.it("scales message timeout linearly by bounded text length", function()
    test.equal(shown_duration_for(string.rep("a", 60)), 5)
    test.equal(shown_duration_for(string.rep("a", 100)), 8)
    test.equal(shown_duration_for(string.rep("a", 120)), 8)
  end)
end)

test.describe("status bar document file item", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "statusbar-project-paths-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.root = join_path(context.temp_root, "app")
    context.external = join_path(context.temp_root, "jdk-src")
    mkdirp(join_path(context.root, "src", "vendor", "library1", "foo"))
    mkdirp(join_path(context.external, "java", "lang"))
    core.projects = { Project(context.root) }
    system.chdir(context.root)
    project_paths.configure_project {
      external = {
        { path = "../jdk-src", label = "Java Sources" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
    }
  end)

  test.after_each(function(context)
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  local function status_file_text(abs_filename)
    local doc = Doc(nil, nil, true)
    doc:set_filename(abs_filename, abs_filename)
    core.active_view = DocView(doc)
    local status_bar = StatusBar()
    return styled_text_string(status_bar:get_item("doc:file"):get_item())
  end

  test.it("uses Project Path labels like fuzzy file results", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    write_file(external_file)
    write_file(vendored_file)

    test.equal(status_file_text(external_file), "Java Sources" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "String.java")
    test.equal(status_file_text(vendored_file), "library1" .. PATHSEP .. "foo" .. PATHSEP .. "Baz.java")
  end)
end)
