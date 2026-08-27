local common = require "core.common"
local config = require "core.config"
local core = require "core"
local test = require "core.test"
local filetree = assert(require("plugins.filetree").new())

local function write_file(path, text)
  local handle, err = io.open(path, "wb")
  test.not_nil(handle, err)
  handle:write(text or "")
  handle:close()
end

local function find_entry(name)
  for _, entry in ipairs(filetree:build_entries(false)) do
    if entry.text == name then return entry end
  end
end

test.describe("File Tree directory merge", function()
  test.before_each(function(context)
    context.previous_delete_to_trash = config.plugins.filetree.delete_to_trash
  end)

  test.after_each(function(context)
    config.plugins.filetree.delete_to_trash = context.previous_delete_to_trash
    if context.previous_dir then
      filetree.current_dir = context.previous_dir
      filetree:refresh(false, false)
    end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("merges expanded directories renamed to the same target", function(context)
    local root = core.root_project().path .. PATHSEP .. "filetree-merge-tests-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
    local code = root .. PATHSEP .. "code"
    local incoming = root .. PATHSEP .. "incoming"
    test.ok(common.mkdirp(code))
    test.ok(common.mkdirp(incoming))
    write_file(code .. PATHSEP .. "test.odin", "test")
    write_file(code .. PATHSEP .. "tokeniser.odin", "tokeniser")
    write_file(incoming .. PATHSEP .. "test2.odin", "test2")

    context.previous_dir = filetree.current_dir
    context.temp_root = root
    config.plugins.filetree.delete_to_trash = false
    filetree.current_dir = root
    filetree:refresh(false, false)

    local code_entry = find_entry("code")
    test.not_nil(code_entry)
    filetree:expand_folder(code_entry.line, code_entry, false)
    local incoming_entry = find_entry("incoming")
    test.not_nil(incoming_entry)
    filetree:expand_folder(incoming_entry.line, incoming_entry, false)

    incoming_entry = find_entry("incoming")
    local line = incoming_entry.line
    filetree.buffer:remove(line, 1, line, #filetree.buffer.lines[line])
    filetree.buffer:insert(line, 1, "code\\")

    local plan, err = filetree:plan_changes(false)
    test.not_nil(plan, err)
    filetree:apply_plan(plan)

    test.not_nil(system.get_file_info(code .. PATHSEP .. "test.odin"))
    test.not_nil(system.get_file_info(code .. PATHSEP .. "tokeniser.odin"))
    test.not_nil(system.get_file_info(code .. PATHSEP .. "test2.odin"))
    test.equal(system.get_file_info(incoming), nil)
  end)
end)
