local common = require "core.common"
local core = require "core"
local test = require "core.test"

local file_picker = require "plugins.file_picker"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local helpers = fuzzy_searcher._test

local function set_query(picker, text)
  picker.input:set_text(text)
  picker.current_query_key = nil
  picker.force_refresh = true
  picker.dirty = true
  picker:refresh(text)
end

local function result_path(result)
  return result and (result.path or result.project or result.abs_path or result.file)
end

test.describe("File Picker", function()
  test.before_each(function(context)
    context.everything_state = helpers.everything_state()
    helpers.set_everything_state("unavailable")
    context.root = common.normalize_path(USERDIR .. PATHSEP
      .. "file-picker-" .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000))
    context.folder = context.root .. PATHSEP .. "folder"
    context.lua_file = context.root .. PATHSEP .. "keep.lua"
    context.text_file = context.root .. PATHSEP .. "hide.txt"
    test.ok(common.mkdirp(context.folder))
    local fp = assert(io.open(context.lua_file, "wb"))
    fp:write("return true\n")
    fp:close()
    fp = assert(io.open(context.text_file, "wb"))
    fp:write("text\n")
    fp:close()
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    if core.global_prompt_bar and core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
    helpers.set_everything_state(context.everything_state)
    if system.get_file_info(context.root) then
      local ok, err = common.rm(context.root, true)
      test.ok(ok, err)
    end
  end)

  test.it("uses a plain query and shows only folders for folder selection", function(context)
    local selected
    local query = context.root .. PATHSEP
    local picker = file_picker.open {
      select = "folder",
      query = query,
      submit = function(path) selected = path end,
    }

    test.equal(picker.input:get_text(), query)
    local folder_index
    for index, result in ipairs(picker.results) do
      if not result.header then
        test.ok(result.is_folder == true or result.kind == "folder" or result.kind == "project")
        if common.path_equals(result_path(result), context.folder) then folder_index = index end
      end
    end
    picker.selected = test.not_nil(folder_index)
    picker:confirm(false)
    test.equal(selected, context.folder)
  end)

  test.it("shows folders but only matching files for filtered file selection", function(context)
    local selected
    local query = context.root .. PATHSEP
    local picker = file_picker.open {
      select = "file",
      extensions = { ".lua" },
      query = query,
      submit = function(path) selected = path end,
    }

    local folder_index, lua_index
    for index, result in ipairs(picker.results) do
      local path = result_path(result)
      test.ok(not path or not common.path_equals(path, context.text_file))
      if path and common.path_equals(path, context.folder) then folder_index = index end
      if path and common.path_equals(path, context.lua_file) then lua_index = index end
    end

    picker.selected = test.not_nil(folder_index)
    picker:confirm(false)
    test.equal(core.fuzzy_searcher_active_view, picker)
    test.is_nil(selected)

    set_query(picker, query)
    for index, result in ipairs(picker.results) do
      if common.path_equals(result_path(result), context.lua_file) then lua_index = index; break end
    end
    picker.selected = test.not_nil(lua_index)
    picker:confirm(false)
    test.equal(selected, context.lua_file)
  end)

  test.it("opens after a Global Prompt Bar step and cancels once", function()
    local cancelled = 0
    core.global_prompt_bar:enter("Choice", {
      text = "One",
      submit = function()
        file_picker.open {
          select = "any",
          submit = function() end,
          cancel = function() cancelled = cancelled + 1 end,
        }
      end,
    })

    core.global_prompt_bar:submit()
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    picker:close()
    picker:close()
    test.equal(cancelled, 1)
  end)
end)
