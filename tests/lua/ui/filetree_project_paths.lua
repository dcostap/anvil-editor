local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local fp, err = io.open(path, "wb")
  test.not_nil(fp, err)
  fp:write(text or "test\n")
  fp:close()
end

local function line_text(line)
  line = line or ""
  return line:sub(-1) == "\n" and line:sub(1, -2) or line
end

local function find_line(view, wanted)
  for i, line in ipairs(view.doc.lines) do
    if line_text(line) == wanted then return i end
  end
end

local function find_section_start(view, role)
  for i, meta in ipairs(view.line_meta or {}) do
    if type(meta) == "table" and meta.project_path_separator_before and meta.project_path_role == role then
      return i
    end
  end
end

local function setup_project_paths(context)
  context.original_projects = core.projects
  context.original_cwd = system.getcwd()
  context.temp_root = USERDIR
    .. PATHSEP .. "filetree-project-paths-tests-"
    .. system.get_process_id() .. "-"
    .. math.floor(system.get_time() * 1000000)
  context.root = join_path(context.temp_root, "app")
  context.external = join_path(context.temp_root, "jdk-src")
  context.missing = join_path(context.temp_root, "missing-src")
  context.vendor = join_path(context.root, "src", "vendor", "library1")
  context.excluded = join_path(context.root, "generated")
  mkdirp(join_path(context.root, "src", "app"))
  mkdirp(join_path(context.vendor, "foo"))
  mkdirp(join_path(context.external, "java", "lang"))
  mkdirp(context.excluded)
  write_file(join_path(context.root, "README.md"), "readme\n")
  write_file(join_path(context.vendor, "foo", "Baz.java"), "class Baz {}\n")
  write_file(join_path(context.external, "java", "lang", "String.java"), "class String {}\n")
  write_file(join_path(context.excluded, "Generated.java"), "class Generated {}\n")

  core.projects = { Project(context.root) }
  system.chdir(context.root)
  project_paths.configure_project {
    external = {
      { path = "../jdk-src", label = "jdk-src" },
      { path = "../missing-src", label = "missing-src" },
    },
    vendored = {
      { path = "src/vendor/library1", label = "library1" },
    },
    excluded = {
      { path = "generated", label = "generated" },
    },
  }

  local filetree = require "plugins.filetree"
  context.filetree = filetree
  context.previous_dir = filetree.current_dir
  filetree.current_dir = context.root
  filetree:refresh(false, false)
  return filetree
end

test.describe("File Tree Project Path Roles", function()
  test.after_each(function(context)
    project_paths.configure_project {}
    project_paths.load_workspace_state(nil)
    if context.filetree then
      context.filetree.current_dir = context.previous_dir or context.filetree.current_dir
      context.filetree:refresh(false, false)
    end
    core.projects = context.original_projects
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("shows vendored and external Project Directory sections after Root Project rows", function(context)
    local filetree = setup_project_paths(context)
    local readme_line = find_line(filetree, "README.md")
    local vendored_section = find_section_start(filetree, "vendored")
    local external_section = find_section_start(filetree, "external")
    local vendored_root = find_line(filetree, "library1/")
    local external_root = find_line(filetree, "jdk-src/")
    local missing_root = find_line(filetree, "missing-src/")

    test.not_nil(readme_line)
    test.not_nil(vendored_section)
    test.not_nil(external_section)
    test.not_nil(vendored_root)
    test.not_nil(external_root)
    test.not_nil(missing_root)
    test.ok(readme_line < vendored_section)
    test.not_equal(line_text(filetree.doc.lines[vendored_section - 1]), "")
    test.equal(vendored_section, vendored_root)
    test.ok(vendored_root < external_section)
    test.equal(external_section, external_root)

    test.ok(filetree.line_meta[vendored_section].project_path_separator_before)
    test.equal(filetree.line_meta[vendored_root].project_path_role, "vendored")
    test.equal(filetree.line_meta[external_root].project_path_role, "external")
    test.ok(filetree.line_meta[missing_root].project_path_missing)
  end)

  test.it("expands Project Directory roots and resolves children to absolute paths", function(context)
    local filetree = setup_project_paths(context)
    local external_root = find_line(filetree, "jdk-src/")
    test.not_nil(external_root)

    local entry = filetree:entry_for_line(external_root)
    test.not_nil(entry)
    test.ok(common.path_equals(entry.abs, context.external))
    test.ok(entry.readonly)

    filetree:expand_folder(external_root, entry, false)
    local java_line = find_line(filetree, "\tjava/")
    test.not_nil(java_line)
    local java_entry = filetree:entry_for_line(java_line)
    test.ok(common.path_equals(java_entry.abs, join_path(context.external, "java")))
    test.ok(java_entry.readonly)
  end)

  test.it("flags Excluded Project Path rows while keeping them visible", function(context)
    local filetree = setup_project_paths(context)
    local generated_line = find_line(filetree, "generated/")
    test.not_nil(generated_line)
    test.equal(filetree.line_meta[generated_line].project_path_role, "excluded")
    local entry = filetree:entry_for_line(generated_line)
    test.not_nil(entry)
    test.ok(common.path_equals(entry.abs, context.excluded))
  end)

  test.it("draws Project Directory separators as visual rows before the first section row", function(context)
    local filetree = setup_project_paths(context)
    local vendored_section = find_section_start(filetree, "vendored")
    test.not_nil(vendored_section)
    test.equal(line_text(filetree.doc.lines[vendored_section]), "library1/")
    local entry, err = filetree:entry_for_line(vendored_section)
    test.not_nil(entry)
    test.equal(err, nil)

    local found_provider_row = false
    for _, row in ipairs(filetree:composed_visual_rows()) do
      if row.type == "provider"
          and row.line == vendored_section
          and row.placement == "before"
          and row.provider_id == "filetree-project-path-separators" then
        found_provider_row = type(row.provider_row.draw) == "function"
        break
      end
    end
    test.ok(found_provider_row, "expected separator to be a visual row, not a document row")
  end)

  test.it("rejects new rows typed under browse-only Project Directory sections", function(context)
    local filetree = setup_project_paths(context)
    local external_root = find_line(filetree, "jdk-src/")
    local entry = filetree:entry_for_line(external_root)
    filetree:expand_folder(external_root, entry, false)

    filetree.doc:insert(external_root + 1, 1, "\tNewFile.java\n")
    local plan = filetree:plan_changes(true)
    test.ok(plan.invalid, "expected Project Directory section edits to be invalid")
    test.equal(plan.status[external_root + 1], "invalid")
  end)

  test.it("does not treat vendored section mirrors as duplicate editable targets", function(context)
    local filetree = setup_project_paths(context)
    local src_line = find_line(filetree, "src/")
    local src_entry = filetree:entry_for_line(src_line)
    filetree:expand_folder(src_line, src_entry, false)
    local vendor_line = find_line(filetree, "\tvendor/")
    local vendor_entry = filetree:entry_for_line(vendor_line)
    filetree:expand_folder(vendor_line, vendor_entry, false)

    local library_line = find_line(filetree, "\t\tlibrary1/")
    test.not_nil(library_line)
    test.not_nil(find_line(filetree, "library1/"))

    local plan = filetree:plan_changes(true)
    test.not_ok(plan.invalid, "unchanged vendored mirrors should not block File Tree operations")
  end)
end)
