local core = require "core"
local command = require "core.command"
local common = require "core.common"
local test = require "core.test"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text or "")
  file:close()
end

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function remove_tree(path)
  if system.get_file_info(path) then common.rm(path, true) end
end

test.describe("open file prompt", function()
  local old_error
  local errors

  test.before_each(function()
    old_error = core.error
    errors = {}
    core.error = function(fmt, ...)
      errors[#errors + 1] = string.format(fmt, ...)
    end
  end)

  test.after_each(function()
    core.error = old_error
    if core.global_prompt_bar then
      core.global_prompt_bar:exit(true)
    end
  end)

  test.it("validates an absolute path with spaces outside the project", function()
    local dir = join_path(USERDIR, "open file prompt spaces")
    local path = join_path(dir, "01 comprobacion consumo comunes Materiales.sql")
    test.ok(common.mkdirp(dir))
    write_file(path, "select 1\n")

    command.perform("core:open-file")

    test.ok(core.global_prompt_bar.state.validate(path), errors[1])
  end)

  test.it("accepts a pasted absolute path with trailing CRLF", function()
    local dir = join_path(USERDIR, "open file prompt crlf")
    local path = join_path(dir, "01 comprobacion consumo comunes Materiales.sql")
    test.ok(common.mkdirp(dir))
    write_file(path, "select 1\n")

    command.perform("core:open-file")

    test.ok(core.global_prompt_bar.state.validate(path .. "\r\n"), errors[1])
  end)

  test.it("ignores the keyboard event payload when opened by a shortcut", function()
    command.perform("core:open-file", { key = "o", modifiers = { "ctrl" } })

    test.equal(core.global_prompt_bar.label, "Open File: ")
    test.equal(#errors, 0)
  end)

  test.it("enters the highlighted folder", function()
    local root = join_path(USERDIR, "open file folder navigation")
    local child = join_path(root, "child")
    remove_tree(root)
    test.ok(common.mkdirp(child))
    write_file(join_path(child, "inside.txt"), "inside\n")

    command.perform("core:open-file")
    local bar = core.global_prompt_bar
    bar:set_text(root .. PATHSEP)
    bar:update()
    local selected
    for index, item in ipairs(bar.suggestions) do
      if common.path_equals(common.home_expand(item.text:gsub("[\\/]$", "")), child) then
        bar.suggestion_idx = index
        selected = item.text
        break
      end
    end
    local suggestion_texts = {}
    for _, item in ipairs(bar.suggestions) do
      suggestion_texts[#suggestion_texts + 1] = item.text
    end
    test.ok(selected, "expected child folder suggestion; got " .. table.concat(suggestion_texts, ", "))

    bar:submit()
    bar:update()

    test.equal(core.active_view, bar)
    test.equal(bar:get_text(), selected)
    test.ok(#bar.suggestions > 0)
    remove_tree(root)
  end)

  test.it("creates a typed folder chain and enters it", function()
    local root = join_path(USERDIR, "open file create folders")
    local folder = join_path(root, "one", "two")
    remove_tree(root)

    command.perform("core:open-file")
    local bar = core.global_prompt_bar
    bar:set_text(folder .. PATHSEP)
    bar:submit()

    local info = system.get_file_info(folder)
    test.equal(info and info.type, "dir", errors[1])
    test.equal(core.active_view, bar)
    local notice = core.status_bar.message.text
    test.ok(notice:find("Created folder: ", 1, true) == 1, notice)
    test.ok(common.path_equals(notice:sub(#"Created folder: " + 1), folder), notice)
    remove_tree(root)
  end)

  test.it("creates missing parent folders for a new file", function()
    local root = join_path(USERDIR, "open file create parents")
    local parent = join_path(root, "one", "two")
    local filename = join_path(parent, "note.txt")
    local selected
    remove_tree(root)

    command.perform("core:open-file", "Select File", function(path)
      selected = path
    end)
    local bar = core.global_prompt_bar
    bar:set_text(filename)
    bar:submit()

    local info = system.get_file_info(parent)
    test.equal(info and info.type, "dir", errors[1])
    test.ok(common.path_equals(selected, filename), selected)
    local notice = core.status_bar.message.text
    test.ok(notice:find("Created folders: ", 1, true) == 1, notice)
    test.ok(common.path_equals(notice:sub(#"Created folders: " + 1), parent), notice)
    remove_tree(root)
  end)
end)
