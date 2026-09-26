local common = require "core.common"
local test = require "core.test"
local symbol_index = require "core.treesitter.symbol_index"

local function mkdir(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local file = test.not_nil(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_workspace_symbols(query, opts)
  local deadline = system.get_time() + 10
  local results, reason, status
  local first = true
  repeat
    local call_opts = opts
    if opts.force and not first then
      call_opts = common.merge(opts, { force = false })
    end
    first = false
    results, reason, status = symbol_index.workspace_symbols(query, call_opts)
    if status == "fresh" or status == "stale" then return results, reason, status end
    coroutine.yield(0.03)
  until system.get_time() >= deadline
  return results, reason, status
end

local function assert_global_symbols(root, expected_paths, local_name)
  local symbols, reason, status = wait_workspace_symbols("do_color_log", {
    root = root,
    force = true,
    limit = 20,
    refresh_after_seconds = 0,
  })
  test.equal(status, "fresh", reason)

  local paths = {}
  for _, symbol in ipairs(symbols or {}) do
    if symbol.name == "do_color_log" then
      test.equal(symbol.kind, "variable")
      paths[symbol.relpath] = true
    end
  end
  for _, path in ipairs(expected_paths) do
    test.ok(paths[path], "missing Project symbol from " .. path)
  end

  symbols, reason, status = wait_workspace_symbols(local_name, {
    root = root,
    limit = 20,
    refresh_after_seconds = 0,
  })
  test.equal(status, "fresh", reason)
  test.equal(#(symbols or {}), 0, "local variables are not Project symbols")
end

test.describe("Tree-sitter Project symbols", function()
  test.it("indexes C and mixed C/C++ globals and pointer fields", function()
    symbol_index.reset_for_tests()
    local suffix = tostring(system.get_process_id()) .. "-" .. tostring(math.floor(system.get_time() * 1000000))
    local c_root = USERDIR .. PATHSEP .. "treesitter-c-globals-" .. suffix
    local mixed_root = USERDIR .. PATHSEP .. "treesitter-mixed-globals-" .. suffix

    mkdir(c_root .. PATHSEP .. "include")
    mkdir(c_root .. PATHSEP .. "src")
    write_file(c_root .. PATHSEP .. "include" .. PATHSEP .. "colorlog.h",
      "extern unsigned char do_color_log;\n")
    write_file(c_root .. PATHSEP .. "src" .. PATHSEP .. "game_globals.c",
      "unsigned char do_color_log = 0;\n"
        .. "void use_color_log(void) { int local_color_log = 0; (void)local_color_log; }\n")
    assert_global_symbols(c_root, {
      "include/colorlog.h",
      "src/game_globals.c",
    }, "local_color_log")
    common.rm(c_root, true)

    mkdir(mixed_root .. PATHSEP .. "include")
    mkdir(mixed_root .. PATHSEP .. "src")
    write_file(mixed_root .. PATHSEP .. "include" .. PATHSEP .. "colorlog.h",
      "extern unsigned char do_color_log;\n"
        .. "class RGE_Base_Game { public: TShape** shapes; };\n")
    write_file(mixed_root .. PATHSEP .. "src" .. PATHSEP .. "game_globals.cpp",
      "unsigned char do_color_log = 0;\n"
        .. "void use_color_log() { int local_color_log = 0; (void)local_color_log; }\n")
    write_file(mixed_root .. PATHSEP .. "src" .. PATHSEP .. "marker.c", "void marker(void) {}\n")
    assert_global_symbols(mixed_root, {
      "include/colorlog.h",
      "src/game_globals.cpp",
    }, "local_color_log")
    local fields, reason, status = wait_workspace_symbols("shapes", {
      root = mixed_root,
      limit = 20,
      refresh_after_seconds = 0,
    })
    test.equal(status, "fresh", reason)
    local shapes
    for _, symbol in ipairs(fields or {}) do
      if symbol.name == "shapes" then shapes = symbol end
    end
    test.ok(shapes, "missing C++ pointer-to-pointer field from mixed Project header")
    test.equal(shapes.kind, "field")
    test.equal(shapes.relpath, "include/colorlog.h")
    common.rm(mixed_root, true)
    symbol_index.reset_for_tests()
  end)
end)
