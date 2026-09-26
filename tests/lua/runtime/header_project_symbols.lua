local common = require "core.common"
local Buffer = require "core.buffer"
local Project = require "core.project"
local core = require "core"
local project_paths = require "core.project_paths"
local test = require "core.test"
local symbol_index = require "core.treesitter.symbol_index"
local treesitter = require "core.treesitter"

local function write_file(path, text)
  local file = test.not_nil(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function search(root, name, force)
  local deadline = system.get_time() + 8
  local results, reason, status
  local first = true
  repeat
    results, reason, status = symbol_index.workspace_symbols(name, {
      root = root, force = first and force ~= false, limit = 30,
    })
    first = false
    if status == "fresh" then return results end
    coroutine.yield(0.03)
  until system.get_time() >= deadline
  test.equal(status, "fresh", reason)
end

local function has_symbol(results, name, kind)
  local count = 0
  for _, item in ipairs(results or {}) do
    if item.name == name and item.kind == kind then count = count + 1 end
  end
  return count
end

local function project(tag, sources)
  symbol_index.reset_for_tests()
  local root = USERDIR .. PATHSEP .. "header-index-" .. tag .. "-"
    .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
  test.ok(common.mkdirp(root))
  for name, text in pairs(sources) do write_file(root .. PATHSEP .. name, text) end
  return root
end

test.describe("Project header symbols", function()
  test.it("finds a C++ field in a .h file in a C++-only Project", function()
    local root = project("cpp", {
      ["drawarea.cpp"] = "int main() { return 0; }\n",
      ["drawarea.h"] = "class TDrawSystem { public: long ScreenWidth; };\ninline int header_value() { return 1; }\n",
    })
    local fields = search(root, "ScreenWidth")
    test.equal(has_symbol(fields, "ScreenWidth", "field"), 1)
    for _, item in ipairs(fields) do
      if item.name == "ScreenWidth" then test.equal(item.parent_name, "TDrawSystem") end
    end
    test.equal(has_symbol(search(root, "header_value"), "header_value", "function"), 1)
    common.rm(root, true)
  end)

  test.it("keeps C declarations in a C-only Project", function()
    local root = project("c", {
      ["sample.c"] = "int main(void) { return 0; }\n",
      ["sample.h"] = "#define SCREEN_WIDTH(x) ((x) + 1)\nstruct Screen { int width; };\n",
    })
    test.equal(has_symbol(search(root, "SCREEN_WIDTH"), "SCREEN_WIDTH", "macro"), 1)
    common.rm(root, true)
  end)

  test.it("finds C and C++ declarations in a mixed Project header without duplicate symbols", function()
    local root = project("mixed", {
      ["sample.c"] = "int main(void) { return 0; }\n",
      ["drawarea.cpp"] = "int draw() { return 0; }\n",
      ["drawarea.h"] = "#define SCREEN_WIDTH(x) ((x) + 1)\nstruct Both { int width; };\nclass TDrawSystem { public: long ScreenWidth; };\n",
    })
    test.equal(has_symbol(search(root, "ScreenWidth"), "ScreenWidth", "field"), 1)
    test.equal(has_symbol(search(root, "SCREEN_WIDTH"), "SCREEN_WIDTH", "macro"), 1)
    test.equal(has_symbol(search(root, "Both"), "Both", "struct"), 1)
    common.rm(root, true)
  end)

  test.it("updates header symbols when a C source file joins a C++ Project", function()
    local root = project("change", {
      ["drawarea.cpp"] = "int draw() { return 0; }\n",
      ["drawarea.h"] = "#define SCREEN_WIDTH(x) ((x) + 1)\nclass TDrawSystem { public: long ScreenWidth; };\n",
    })
    test.equal(has_symbol(search(root, "ScreenWidth"), "ScreenWidth", "field"), 1)
    local path = root .. PATHSEP .. "sample.c"
    write_file(path, "int main(void) { return 0; }\n")
    test.ok(symbol_index.mark_file_dirty(path))
    local deadline = system.get_time() + 8
    local results
    repeat
      results = search(root, "SCREEN_WIDTH", false)
      if has_symbol(results, "SCREEN_WIDTH", "macro") == 1 then break end
      coroutine.yield(0.03)
    until system.get_time() >= deadline
    test.equal(has_symbol(results, "SCREEN_WIDTH", "macro"), 1)
    common.rm(root, true)
  end)

  test.it("keeps both mixed-header symbols when the header is open", function()
    local root = project("open", {
      ["sample.c"] = "int main(void) { return 0; }\n",
      ["drawarea.cpp"] = "int draw() { return 0; }\n",
      ["drawarea.h"] = "#define SCREEN_WIDTH(x) ((x) + 1)\nclass TDrawSystem { public: long ScreenWidth; };\n",
    })
    local previous_projects = core.projects
    core.projects = { Project(root) }
    project_paths.load_workspace_state(nil)
    test.equal(has_symbol(search(root, "SCREEN_WIDTH"), "SCREEN_WIDTH", "macro"), 1)
    local path = root .. PATHSEP .. "drawarea.h"
    local buffer = Buffer()
    buffer.lines = { "#define SCREEN_WIDTH(x) ((x) + 1)\n", "class TDrawSystem { public: long ScreenWidth; };\n" }
    buffer:set_filename(path, path)
    buffer:clean()
    treesitter.attach_or_update_buffer(buffer, "test-open-header")
    test.equal(buffer.treesitter.language_id, "cpp")
    local deadline = system.get_time() + 5
    repeat
      treesitter.poll_buffer(buffer)
      if buffer.treesitter.status == "ready" then break end
      coroutine.yield(0.01)
    until system.get_time() >= deadline
    test.equal(buffer.treesitter.status, "ready")
    symbol_index.update_open_buffer(buffer, "test-open-header")
    test.equal(has_symbol(search(root, "SCREEN_WIDTH", false), "SCREEN_WIDTH", "macro"), 1)
    test.equal(has_symbol(search(root, "ScreenWidth", false), "ScreenWidth", "field"), 1)
    symbol_index.clear_open_buffer(buffer, "test-end")
    treesitter.close_buffer(buffer)
    core.projects = previous_projects
    project_paths.load_workspace_state(nil)
    common.rm(root, true)
  end)
end)
