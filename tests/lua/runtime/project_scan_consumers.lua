local core = require "core"
local common = require "core.common"
local process = require "core.process"
local project_files = require "core.project_files"
local symbol_index = require "core.treesitter.symbol_index"
local test = require "core.test"

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_for_index(root, opts)
  local index = symbol_index.ensure_scan(root, opts)
  local deadline = system.get_time() + 10
  while index.status == "indexing" and system.get_time() < deadline do coroutine.yield(0.01) end
  test.equal(index.status, "ready", tostring(index.reason))
end

local function has_symbol(root, name)
  local results = symbol_index.workspace_symbols(name, { root = root, refresh_after_seconds = 0 })
  for _, result in ipairs(results or {}) do
    if result.name == name then return true end
  end
  return false
end

test.describe("Project scan consumers", function()
  test.before_each(function(context)
    symbol_index.reset_for_tests()
    context.root = common.normalize_path(USERDIR .. PATHSEP .. "scan-consumers-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
    test.ok(common.mkdirp(context.root))
    write(context.root .. PATHSEP .. "existing.c", "int existing_symbol(void) { return 1; }\n")
    context.process_start = process.start
  end)

  test.after_each(function(context)
    process.start = context.process_start
    symbol_index.reset_for_tests()
    project_files.invalidate(context.root)
    test.ok(common.rm(context.root, true))
  end)

  test.it("uses a completed Project listing when the scanner is unavailable", function(context)
    test.not_nil(project_files.list(context.root))
    process.start = function(args, opts)
      if opts and common.path_equals(opts.cwd, context.root) then
        return nil, "The file scanner is unavailable"
      end
      return context.process_start(args, opts)
    end

    wait_for_index(context.root)

    test.ok(has_symbol(context.root, "existing_symbol"))
  end)

  test.it("discovers new files during an explicit symbol refresh", function(context)
    wait_for_index(context.root)
    write(context.root .. PATHSEP .. "added.c", "int added_symbol(void) { return 2; }\n")

    wait_for_index(context.root, { force = true })

    test.ok(has_symbol(context.root, "existing_symbol"))
    test.ok(has_symbol(context.root, "added_symbol"))
  end)
end)
