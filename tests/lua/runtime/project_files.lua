local common = require "core.common"
local test = require "core.test"

local function join(...)
  return table.concat({...}, PATHSEP)
end

local function write(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
end

local function names(files)
  local out = {}
  for _, file in ipairs(files) do out[file.relative:gsub("\\", "/")] = true end
  return out
end

test.describe("Project files", function()
  test.it("uses ripgrep defaults and can include ignored files", function(context)
    local project_files = require "core.project_files"
    local root = join(USERDIR, "project-files-" .. system.get_process_id())
    assert(common.mkdirp(join(root, ".git")))
    assert(common.mkdirp(join(root, "build")))
    assert(common.mkdirp(join(root, "from-ignore")))
    assert(common.mkdirp(join(root, "from-rgignore")))
    write(join(root, ".gitignore"), "build/\n")
    write(join(root, ".ignore"), "from-ignore/\n")
    write(join(root, ".rgignore"), "from-rgignore/\n")
    write(join(root, "visible.txt"), "visible")
    write(join(root, "build", "ignored.txt"), "ignored")
    write(join(root, "from-ignore", "ignored.txt"), "ignored")
    write(join(root, "from-rgignore", "ignored.txt"), "ignored")
    write(join(root, ".hidden.txt"), "hidden")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end

    local default = names(assert(project_files.list(root, { refresh = true })))
    test.ok(default["visible.txt"], "default files: " .. table.concat((function()
      local out = {}; for name in pairs(default) do out[#out + 1] = name end; return out
    end)(), ", "))
    test.not_ok(default["build/ignored.txt"])
    test.not_ok(default["from-ignore/ignored.txt"])
    test.not_ok(default["from-rgignore/ignored.txt"])
    test.not_ok(default[".hidden.txt"])

    local unrestricted = names(assert(project_files.list(root, {
      refresh = true,
      include_ignored = true,
    })))
    test.ok(unrestricted["visible.txt"])
    test.ok(unrestricted["build/ignored.txt"])
    test.ok(unrestricted["from-ignore/ignored.txt"])
    test.ok(unrestricted["from-rgignore/ignored.txt"])
    test.not_ok(unrestricted[".hidden.txt"])
  end)

  test.it("requires a Git repository before applying gitignore files", function(context)
    local project_files = require "core.project_files"
    local root = join(os.getenv("TEMP") or USERDIR,
      "anvil-project-files-no-git-" .. system.get_process_id())
    assert(common.mkdirp(join(root, "build")))
    assert(common.mkdirp(join(root, "ignored")))
    write(join(root, ".gitignore"), "build/\n")
    write(join(root, ".ignore"), "ignored/\n")
    write(join(root, "build", "visible-without-git.txt"), "visible")
    write(join(root, "ignored", "hidden-by-ignore.txt"), "ignored")
    context.cleanup = function()
      project_files.invalidate(root)
      common.rm(root, true)
    end

    local listed = names(assert(project_files.list(root, { refresh = true })))
    test.ok(listed["build/visible-without-git.txt"])
    test.not_ok(listed["ignored/hidden-by-ignore.txt"])
  end)
end)
